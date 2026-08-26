# Multistage-сборка: один Dockerfile, три отдельных образа.
#
#   docker build --target orders    -t shop/orders:dev    .
#   docker build --target inventory -t shop/inventory:dev .
#   docker build --target notifier  -t shop/notifier:dev  .
#
# Стадии builder-* собирают venv со своим набором зависимостей (requirements/<service>.txt),
# в runtime-образ попадают только venv и код нужного сервиса — без pip, компиляторов и чужого кода.

ARG PYTHON_VERSION=3.12

# ---------- builder: общая база для сборки зависимостей ----------
FROM python:${PYTHON_VERSION}-slim AS builder-base
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
WORKDIR /build
COPY requirements/ requirements/

FROM builder-base AS builder-orders
RUN pip install -r requirements/orders.txt

FROM builder-base AS builder-inventory
RUN pip install -r requirements/inventory.txt

FROM builder-base AS builder-notifier
RUN pip install -r requirements/notifier.txt

# ---------- runtime: тонкий образ без инструментов сборки ----------
FROM python:${PYTHON_VERSION}-slim AS runtime-base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH \
    PORT=8000 \
    WORKERS=1
WORKDIR /app
# непривилегированный пользователь — нужен для securityContext.runAsNonRoot / Pod Security Standards
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY common ./common
USER 10001
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s \
    CMD python -c "import urllib.request,os; urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/healthz')"

# ---------- финальные образы ----------
FROM runtime-base AS orders
COPY --from=builder-orders /opt/venv /opt/venv
COPY orders ./orders
ENV SERVICE_NAME=orders
CMD ["sh", "-c", "exec uvicorn orders.main:app --host 0.0.0.0 --port ${PORT} --workers ${WORKERS} --no-access-log"]

FROM runtime-base AS inventory
COPY --from=builder-inventory /opt/venv /opt/venv
COPY inventory ./inventory
ENV SERVICE_NAME=inventory
CMD ["sh", "-c", "exec uvicorn inventory.main:app --host 0.0.0.0 --port ${PORT} --workers ${WORKERS} --no-access-log"]

FROM runtime-base AS notifier
COPY --from=builder-notifier /opt/venv /opt/venv
COPY notifier ./notifier
ENV SERVICE_NAME=notifier
CMD ["sh", "-c", "exec uvicorn notifier.main:app --host 0.0.0.0 --port ${PORT} --workers ${WORKERS} --no-access-log"]
