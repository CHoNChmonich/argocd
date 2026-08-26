from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from .settings import settings


class Base(DeclarativeBase):
    pass


def make_engine() -> AsyncEngine:
    return create_async_engine(settings.database_url, pool_pre_ping=True, pool_size=5, max_overflow=5)


def make_session_factory(engine: AsyncEngine):
    return async_sessionmaker(engine, expire_on_commit=False)
