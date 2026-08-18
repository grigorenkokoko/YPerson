"""Fixtures for PostgreSQL-backed backend tests."""

import os

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session, sessionmaker


@pytest.fixture
def session_factory() -> sessionmaker[Session]:
    """Return sessions for the isolated PostgreSQL database named by the test runner."""

    database_url = os.environ["TEST_DATABASE_URL"]
    engine = create_engine(database_url, pool_pre_ping=True)
    with engine.begin() as connection:
        connection.execute(text("TRUNCATE TABLE profiles CASCADE"))

    factory = sessionmaker(engine, expire_on_commit=False)
    try:
        yield factory
    finally:
        engine.dispose()
