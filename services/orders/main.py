"""Orders — приём заказов.

POST /orders: HTTP-вызов inventory (резерв) -> запись в Postgres -> событие в RabbitMQ.
GET  /orders/{id}: Redis cache-aside.
Один трейс проходит через orders -> inventory -> (очередь) -> notifier.
"""

import json
import logging
import time
from contextlib import asynccontextmanager
from datetime import datetime

import httpx
import redis.asyncio as aioredis
from fastapi import Depends, FastAPI, HTTPException
from opentelemetry import trace
from prometheus_client import Counter, Histogram
from pydantic import BaseModel, Field
from sqlalchemy import DateTime, String, func, select, text
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Mapped, mapped_column

from common import messaging
from common.db import Base, make_engine, make_session_factory
from common.health import health_router
from common.logging import configure_logging
from common.settings import settings
from common.telemetry import setup_telemetry

configure_logging()
log = logging.getLogger("orders")
tracer = trace.get_tracer("orders")

# ---------- модель ----------


class Order(Base):
    __tablename__ = "orders"

    id: Mapped[int] = mapped_column(primary_key=True)
    sku: Mapped[str] = mapped_column(String(64), index=True)
    qty: Mapped[int]
    status: Mapped[str] = mapped_column(String(16), default="created")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class OrderIn(BaseModel):
    sku: str = Field(min_length=1, max_length=64)
    qty: int = Field(gt=0, le=1000)


class OrderOut(BaseModel):
    id: int
    sku: str
    qty: int
    status: str
    created_at: datetime
    source: str = "db"

    @classmethod
    def from_row(cls, o: Order, source: str = "db") -> "OrderOut":
        return cls(id=o.id, sku=o.sku, qty=o.qty, status=o.status, created_at=o.created_at, source=source)


# ---------- метрики ----------

ORDERS_CREATED = Counter("orders_created_total", "Orders by outcome", ["outcome"])
ORDER_LATENCY = Histogram("order_create_seconds", "End-to-end order creation time")
CACHE_REQUESTS = Counter("orders_cache_requests_total", "Cache lookups", ["result"])

# ---------- инфраструктура ----------

engine = make_engine()
SessionFactory = make_session_factory(engine)


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.redis = aioredis.from_url(settings.redis_url, decode_responses=True)
    app.state.http = httpx.AsyncClient(base_url=settings.inventory_url, timeout=5.0)
    app.state.rabbit = await messaging.connect()
    channel = await app.state.rabbit.channel()
    app.state.exchange = await messaging.declare_exchange(channel)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    log.info("orders started")
    yield
    await app.state.rabbit.close()
    await app.state.http.aclose()
    await app.state.redis.aclose()
    await engine.dispose()


app = FastAPI(title="orders", lifespan=lifespan)
setup_telemetry(app, engine)


async def get_session():
    async with SessionFactory() as session:
        yield session


async def check_db():
    async with engine.connect() as conn:
        await conn.execute(text("SELECT 1"))


async def check_redis():
    await app.state.redis.ping()


async def check_rabbit():
    if app.state.rabbit.is_closed:
        raise RuntimeError("rabbitmq connection closed")


async def check_inventory():
    (await app.state.http.get("/healthz")).raise_for_status()


app.include_router(
    health_router({"postgres": check_db, "redis": check_redis, "rabbitmq": check_rabbit, "inventory": check_inventory})
)


def cache_key(order_id: int) -> str:
    return f"order:{order_id}"


# ---------- API ----------


@app.post("/orders", response_model=OrderOut, status_code=201)
async def create_order(body: OrderIn, session: AsyncSession = Depends(get_session)):
    started = time.perf_counter()

    # 1. синхронный вызов другого сервиса (trace-контекст уходит в заголовках httpx)
    with tracer.start_as_current_span("reserve_stock"):
        resp = await app.state.http.post(f"/items/{body.sku}/reserve", json={"qty": body.qty})
    if resp.status_code == 404:
        ORDERS_CREATED.labels("unknown_sku").inc()
        raise HTTPException(404, f"unknown sku {body.sku}")
    if resp.status_code == 409:
        ORDERS_CREATED.labels("out_of_stock").inc()
        raise HTTPException(409, f"out of stock: {body.sku}")
    resp.raise_for_status()

    # 2. запись в БД
    order = Order(sku=body.sku, qty=body.qty)
    session.add(order)
    await session.commit()
    await session.refresh(order)

    # 3. асинхронное событие (trace-контекст уходит в headers сообщения)
    out = OrderOut.from_row(order)
    await messaging.publish(app.state.exchange, "order.created", json.loads(out.model_dump_json(exclude={"source"})))

    ORDERS_CREATED.labels("ok").inc()
    ORDER_LATENCY.observe(time.perf_counter() - started)
    log.info("order %d created: %s x%d", order.id, order.sku, order.qty)
    return out


@app.get("/orders", response_model=list[OrderOut])
async def list_orders(limit: int = 50, session: AsyncSession = Depends(get_session)):
    rows = (await session.execute(select(Order).order_by(Order.id.desc()).limit(limit))).scalars().all()
    return [OrderOut.from_row(r) for r in rows]


@app.get("/orders/{order_id}", response_model=OrderOut)
async def get_order(order_id: int, session: AsyncSession = Depends(get_session)):
    cached = await app.state.redis.get(cache_key(order_id))
    if cached:
        CACHE_REQUESTS.labels("hit").inc()
        return OrderOut(**json.loads(cached), source="cache")
    CACHE_REQUESTS.labels("miss").inc()

    order = await session.get(Order, order_id)
    if order is None:
        raise HTTPException(404, f"order {order_id} not found")
    out = OrderOut.from_row(order)
    await app.state.redis.set(cache_key(order_id), out.model_dump_json(exclude={"source"}), ex=settings.cache_ttl_seconds)
    return out
