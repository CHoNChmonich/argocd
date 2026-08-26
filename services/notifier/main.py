"""Notifier — фоновый воркер, потребитель очереди RabbitMQ.

HTTP-часть нужна только для проб, /metrics и просмотра последних уведомлений.
Кандидат на масштабирование по длине очереди (KEDA) — отдельная тема в k8s-части.
"""

import asyncio
import json
import logging
from contextlib import asynccontextmanager

import aio_pika
import redis.asyncio as aioredis
from fastapi import FastAPI
from opentelemetry import trace
from prometheus_client import Counter, Histogram

from common import messaging
from common.health import health_router
from common.logging import configure_logging
from common.settings import settings
from common.telemetry import setup_telemetry

configure_logging()
log = logging.getLogger("notifier")
tracer = trace.get_tracer("notifier")

QUEUE = "notifications"
RECENT_KEY = "notifications:recent"

PROCESSED = Counter("notifications_processed_total", "Processed messages", ["routing_key", "result"])
PROCESSING_TIME = Histogram("notification_processing_seconds", "Handler time")


async def handle(message: aio_pika.abc.AbstractIncomingMessage, redis: aioredis.Redis) -> None:
    # AioPikaInstrumentor восстанавливает trace-контекст из headers -> спан становится
    # частью трейса, начатого в orders.
    async with message.process(requeue=False):
        with PROCESSING_TIME.time():
            payload = json.loads(message.body)
            with tracer.start_as_current_span("send_notification") as span:
                span.set_attribute("order.id", payload.get("id", -1))
                await asyncio.sleep(0.1)  # имитация похода во внешний email/SMS-провайдер
            await redis.lpush(RECENT_KEY, json.dumps({"routing_key": message.routing_key, **payload}))
            await redis.ltrim(RECENT_KEY, 0, 99)
        PROCESSED.labels(message.routing_key or "", "ok").inc()
        log.info("notified about %s: %s", message.routing_key, payload)


async def consume(app: FastAPI) -> None:
    channel = await app.state.rabbit.channel()
    await channel.set_qos(prefetch_count=10)
    exchange = await messaging.declare_exchange(channel)
    queue = await channel.declare_queue(QUEUE, durable=True)
    await queue.bind(exchange, routing_key="order.*")
    log.info("consuming %s", QUEUE)
    async with queue.iterator() as it:
        async for message in it:
            try:
                await handle(message, app.state.redis)
            except Exception:  # noqa: BLE001
                PROCESSED.labels(message.routing_key or "", "error").inc()
                log.exception("failed to process message")


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.redis = aioredis.from_url(settings.redis_url, decode_responses=True)
    app.state.rabbit = await messaging.connect()
    app.state.consumer = asyncio.create_task(consume(app))
    log.info("notifier started")
    yield
    app.state.consumer.cancel()
    await app.state.rabbit.close()
    await app.state.redis.aclose()


app = FastAPI(title="notifier", lifespan=lifespan)
setup_telemetry(app)


async def check_redis():
    await app.state.redis.ping()


async def check_rabbit():
    if app.state.rabbit.is_closed or app.state.consumer.done():
        raise RuntimeError("consumer is not running")


app.include_router(health_router({"redis": check_redis, "rabbitmq": check_rabbit}))


@app.get("/notifications")
async def recent(limit: int = 20):
    items = await app.state.redis.lrange(RECENT_KEY, 0, limit - 1)
    return [json.loads(i) for i in items]
