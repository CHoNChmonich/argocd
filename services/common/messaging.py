import json
import logging

import aio_pika
from aio_pika.abc import AbstractRobustChannel, AbstractRobustConnection

from .settings import settings

log = logging.getLogger(__name__)


async def connect() -> AbstractRobustConnection:
    # robust-соединение само переподключается при рестарте брокера
    return await aio_pika.connect_robust(settings.rabbitmq_url)


async def declare_exchange(channel: AbstractRobustChannel):
    return await channel.declare_exchange(settings.events_exchange, aio_pika.ExchangeType.TOPIC, durable=True)


async def publish(exchange, routing_key: str, payload: dict) -> None:
    msg = aio_pika.Message(
        body=json.dumps(payload).encode(),
        content_type="application/json",
        delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
    )
    await exchange.publish(msg, routing_key=routing_key)
    log.info("published %s %s", routing_key, payload)
