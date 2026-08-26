"""Inventory — склад. Postgres как источник истины, Redis как cache-aside."""

import json
import logging
from contextlib import asynccontextmanager

import redis.asyncio as aioredis
from fastapi import Depends, FastAPI, HTTPException
from prometheus_client import Counter
from pydantic import BaseModel, Field
from sqlalchemy import String, select, text
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Mapped, mapped_column

from common.db import Base, make_engine, make_session_factory
from common.health import health_router
from common.logging import configure_logging
from common.settings import settings
from common.telemetry import setup_telemetry

configure_logging()
log = logging.getLogger("inventory")

# ---------- модель ----------


class Item(Base):
    __tablename__ = "items"

    sku: Mapped[str] = mapped_column(String(64), primary_key=True)
    name: Mapped[str] = mapped_column(String(255))
    qty: Mapped[int]


class ItemIn(BaseModel):
    sku: str = Field(min_length=1, max_length=64)
    name: str
    qty: int = Field(ge=0)


class ItemOut(ItemIn):
    source: str = "db"  # db | cache — видно, откуда пришёл ответ


class ReserveIn(BaseModel):
    qty: int = Field(gt=0)


SEED = [
    ItemIn(sku="kbd-001", name="Mechanical keyboard", qty=100),
    ItemIn(sku="mouse-002", name="Wireless mouse", qty=250),
    ItemIn(sku="mon-003", name="27'' monitor", qty=30),
]

# ---------- метрики ----------

CACHE_REQUESTS = Counter("inventory_cache_requests_total", "Cache lookups", ["result"])
RESERVATIONS = Counter("inventory_reservations_total", "Reservation attempts", ["result"])

# ---------- инфраструктура ----------

engine = make_engine()
SessionFactory = make_session_factory(engine)


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.redis = aioredis.from_url(settings.redis_url, decode_responses=True)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    async with SessionFactory() as session:
        for seed in SEED:
            if await session.get(Item, seed.sku) is None:
                session.add(Item(**seed.model_dump()))
        await session.commit()
    log.info("inventory started")
    yield
    await app.state.redis.aclose()
    await engine.dispose()


app = FastAPI(title="inventory", lifespan=lifespan)
setup_telemetry(app, engine)


async def get_session():
    async with SessionFactory() as session:
        yield session


async def check_db():
    async with engine.connect() as conn:
        await conn.execute(text("SELECT 1"))


async def check_redis():
    await app.state.redis.ping()


app.include_router(health_router({"postgres": check_db, "redis": check_redis}))


def cache_key(sku: str) -> str:
    return f"item:{sku}"


# ---------- API ----------


@app.get("/items", response_model=list[ItemOut])
async def list_items(session: AsyncSession = Depends(get_session)):
    rows = (await session.execute(select(Item).order_by(Item.sku))).scalars().all()
    return [ItemOut(sku=r.sku, name=r.name, qty=r.qty) for r in rows]


@app.get("/items/{sku}", response_model=ItemOut)
async def get_item(sku: str, session: AsyncSession = Depends(get_session)):
    cached = await app.state.redis.get(cache_key(sku))
    if cached:
        CACHE_REQUESTS.labels("hit").inc()
        return ItemOut(**json.loads(cached), source="cache")
    CACHE_REQUESTS.labels("miss").inc()

    item = await session.get(Item, sku)
    if item is None:
        raise HTTPException(404, f"sku {sku} not found")
    out = ItemOut(sku=item.sku, name=item.name, qty=item.qty)
    await app.state.redis.set(cache_key(sku), out.model_dump_json(exclude={"source"}), ex=settings.cache_ttl_seconds)
    return out


@app.put("/items/{sku}", response_model=ItemOut)
async def upsert_item(sku: str, body: ItemIn, session: AsyncSession = Depends(get_session)):
    if body.sku != sku:
        raise HTTPException(400, "sku in path and body differ")
    item = await session.get(Item, sku)
    if item is None:
        item = Item(**body.model_dump())
        session.add(item)
    else:
        item.name, item.qty = body.name, body.qty
    await session.commit()
    await app.state.redis.delete(cache_key(sku))
    return ItemOut(sku=item.sku, name=item.name, qty=item.qty)


@app.post("/items/{sku}/reserve", response_model=ItemOut)
async def reserve(sku: str, body: ReserveIn, session: AsyncSession = Depends(get_session)):
    """Атомарно уменьшает остаток; 409 если товара не хватает."""
    row = (
        await session.execute(
            text("UPDATE items SET qty = qty - :q WHERE sku = :sku AND qty >= :q RETURNING sku, name, qty"),
            {"q": body.qty, "sku": sku},
        )
    ).first()
    if row is None:
        await session.rollback()
        if await session.get(Item, sku) is None:
            RESERVATIONS.labels("not_found").inc()
            raise HTTPException(404, f"sku {sku} not found")
        RESERVATIONS.labels("insufficient").inc()
        raise HTTPException(409, f"insufficient stock for {sku}")
    await session.commit()
    await app.state.redis.delete(cache_key(sku))
    RESERVATIONS.labels("ok").inc()
    log.info("reserved %s x%d, left %d", sku, body.qty, row.qty)
    return ItemOut(sku=row.sku, name=row.name, qty=row.qty)
