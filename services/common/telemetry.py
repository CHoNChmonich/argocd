import importlib
import logging

from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_fastapi_instrumentator import Instrumentator

from .settings import settings

log = logging.getLogger(__name__)

_NOISY = "healthz|readyz|metrics"


def _optional_instrumentor(module: str, cls: str):
    """Инструментаторы БД/очереди есть не в каждом образе (см. requirements/*.txt)."""
    try:
        return getattr(importlib.import_module(module), cls)()
    except ImportError:
        return None


def setup_telemetry(app: FastAPI, engine=None) -> None:
    """Трейсинг (OTLP -> Jaeger/Tempo/OTel Collector) + Prometheus /metrics.

    Автоинструментация: входящие HTTP (FastAPI), исходящие HTTP (httpx), Redis,
    и, если пакеты установлены, SQL (SQLAlchemy) и RabbitMQ (aio-pika, с пробросом
    trace-контекста в заголовках сообщений).
    """
    provider = TracerProvider(resource=Resource.create({SERVICE_NAME: settings.service_name}))
    if settings.otel_enabled:
        exporter = OTLPSpanExporter(endpoint=settings.otel_exporter_otlp_endpoint, insecure=True)
        provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    FastAPIInstrumentor.instrument_app(app, excluded_urls=_NOISY)
    HTTPXClientInstrumentor().instrument()
    RedisInstrumentor().instrument()

    if mq := _optional_instrumentor("opentelemetry.instrumentation.aio_pika", "AioPikaInstrumentor"):
        mq.instrument()
    if engine is not None:
        sql = _optional_instrumentor("opentelemetry.instrumentation.sqlalchemy", "SQLAlchemyInstrumentor")
        if sql:
            sql.instrument(engine=engine.sync_engine)
        else:
            log.warning("engine passed but SQLAlchemy instrumentation is not installed")

    Instrumentator(
        excluded_handlers=["/metrics", "/healthz", "/readyz"],
        should_group_status_codes=False,
    ).instrument(app).expose(app, include_in_schema=False)
