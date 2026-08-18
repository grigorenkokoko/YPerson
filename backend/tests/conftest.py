"""Fixtures for PostgreSQL-backed backend tests."""

import os
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session, sessionmaker


@pytest.fixture
def session_factory() -> sessionmaker[Session]:
    """Return sessions in a freshly migrated, per-test PostgreSQL schema."""

    database_url = os.environ["TEST_DATABASE_URL"]
    schema_name = f"yperson_test_{uuid4().hex}"
    admin_engine = create_engine(database_url, pool_pre_ping=True)
    schema_url = make_url(database_url).update_query_dict(
        {"options": f"-csearch_path={schema_name}"}
    )
    config = Config("alembic.ini")
    config.set_main_option("sqlalchemy.url", str(schema_url).replace("%", "%%"))

    try:
        with admin_engine.begin() as connection:
            connection.execute(text(f"CREATE SCHEMA {schema_name}"))
        command.upgrade(config, "head")
        engine = create_engine(schema_url, pool_pre_ping=True)
        factory = sessionmaker(engine, expire_on_commit=False)
        yield factory
    finally:
        if "engine" in locals():
            engine.dispose()
        with admin_engine.begin() as connection:
            connection.execute(text(f"DROP SCHEMA IF EXISTS {schema_name} CASCADE"))
        admin_engine.dispose()
