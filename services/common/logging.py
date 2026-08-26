import json
import logging
import sys

from opentelemetry import trace

from .settings import settings


class JsonFormatter(logging.Formatter):
    """JSON-логи с trace_id/span_id текущего спана — чтобы связывать логи и трейсы."""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "service": settings.service_name,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            payload["trace_id"] = format(ctx.trace_id, "032x")
            payload["span_id"] = format(ctx.span_id, "016x")
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(settings.log_level.upper())
    # uvicorn ставит свои хендлеры — переводим на общий формат.
    # uvicorn.access не трогаем: им управляет флаг --no-access-log (иначе /metrics и пробы засоряют лог)
    for name in ("uvicorn", "uvicorn.error"):
        lg = logging.getLogger(name)
        lg.handlers = []
        lg.propagate = True
    # httpx пишет INFO на каждый исходящий запрос, включая GET /healthz из readiness-пробы —
    # это 90% лога без пользы; исходящие вызовы и так видны в трейсе
    logging.getLogger("httpx").setLevel(logging.WARNING)
