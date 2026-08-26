from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Общие настройки. Все значения переопределяются переменными окружения.

    Два способа задать подключения:
      1) готовый URL: DATABASE_URL / REDIS_URL / RABBITMQ_URL (docker-compose, локальный запуск);
      2) по частям: DB_HOST, DB_PASSWORD, ... (k8s: хост/порт из ConfigMap, пароль — из Secret,
         созданного helm-чартом самой БД, через secretKeyRef — пароль нигде не дублируется).
    Если задан URL — он в приоритете.
    """

    model_config = SettingsConfigDict(extra="ignore")

    service_name: str = "service"
    log_level: str = "INFO"

    # --- вариант 1: готовые URL ---
    database_url: str | None = None
    redis_url: str | None = None
    rabbitmq_url: str | None = None

    # --- вариант 2: по частям ---
    db_host: str = "localhost"
    db_port: int = 5432
    db_user: str = "app"
    db_password: str = "app"
    db_name: str = "app"

    redis_host: str = "localhost"
    redis_port: int = 6379
    redis_password: str = ""
    redis_db: int = 0

    rabbitmq_host: str = "localhost"
    rabbitmq_port: int = 5672
    rabbitmq_user: str = "guest"
    rabbitmq_password: str = "guest"
    rabbitmq_vhost: str = "/"

    inventory_url: str = "http://localhost:8002"

    # OTEL_EXPORTER_OTLP_ENDPOINT — стандартное имя переменной OpenTelemetry
    otel_exporter_otlp_endpoint: str = "http://localhost:4317"
    otel_enabled: bool = True

    cache_ttl_seconds: int = 60
    events_exchange: str = "orders"

    @model_validator(mode="after")
    def _build_urls(self) -> "Settings":
        if not self.database_url:
            self.database_url = (
                f"postgresql+asyncpg://{self.db_user}:{self.db_password}@{self.db_host}:{self.db_port}/{self.db_name}"
            )
        if not self.redis_url:
            auth = f":{self.redis_password}@" if self.redis_password else ""
            self.redis_url = f"redis://{auth}{self.redis_host}:{self.redis_port}/{self.redis_db}"
        if not self.rabbitmq_url:
            vhost = self.rabbitmq_vhost if self.rabbitmq_vhost.startswith("/") else f"/{self.rabbitmq_vhost}"
            self.rabbitmq_url = (
                f"amqp://{self.rabbitmq_user}:{self.rabbitmq_password}@{self.rabbitmq_host}:{self.rabbitmq_port}{vhost}"
            )
        return self


settings = Settings()
