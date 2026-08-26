import asyncio
import logging
import os
import socket
import time
from collections.abc import Awaitable, Callable

from fastapi import APIRouter, Query, Response

log = logging.getLogger(__name__)

Check = Callable[[], Awaitable[None]]


def health_router(checks: dict[str, Check]) -> APIRouter:
    """/healthz — liveness (процесс жив), /readyz — readiness (зависимости доступны).

    В k8s это разные пробы: провал readiness выводит под из Endpoints сервиса,
    провал liveness — перезапускает контейнер.
    """
    router = APIRouter(tags=["ops"])

    @router.get("/healthz", include_in_schema=False)
    async def healthz():
        return {"status": "ok"}

    @router.get("/readyz", include_in_schema=False)
    async def readyz(response: Response):
        results: dict[str, str] = {}
        for name, check in checks.items():
            try:
                await asyncio.wait_for(check(), timeout=2)
                results[name] = "ok"
            except Exception as exc:  # noqa: BLE001
                log.warning("readiness check %s failed: %s", name, exc)
                results[name] = f"fail: {exc.__class__.__name__}"
        ready = all(v == "ok" for v in results.values())
        response.status_code = 200 if ready else 503
        return {"ready": ready, "checks": results}

    @router.get("/info")
    async def info():
        """Показывает, какой именно под ответил — удобно наблюдать балансировку."""
        return {
            "hostname": socket.gethostname(),
            "pod_ip": os.getenv("POD_IP"),
            "node": os.getenv("NODE_NAME"),
            "version": os.getenv("APP_VERSION", "dev"),
        }

    @router.get("/burn")
    def burn(seconds: float = Query(2, ge=0, le=60)):
        """Синхронно жжёт CPU (выполняется в threadpool) — нагрузка для демонстрации HPA/VPA."""
        end = time.perf_counter() + seconds
        x = 0
        while time.perf_counter() < end:
            x += 1
        return {"burned_seconds": seconds, "iterations": x}

    return router
