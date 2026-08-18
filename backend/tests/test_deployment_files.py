"""Deployment artifact behavior tests.

These tests parse the inputs consumed by Docker Compose and dotenv rather than
checking README prose or matching authored configuration lines.
"""

from __future__ import annotations

import re
import shlex
from pathlib import Path

import yaml

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent


def docker_instructions(path: Path) -> list[tuple[str, str]]:
    """Return logical Dockerfile instructions with continuations joined."""

    logical_lines: list[str] = []
    pending = ""
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        pending = f"{pending} {line}".strip()
        if pending.endswith("\\"):
            pending = pending[:-1].rstrip()
            continue
        keyword, value = pending.split(maxsplit=1)
        logical_lines.append((keyword.upper(), value))
        pending = ""
    assert not pending, "Dockerfile must not end with an unfinished instruction"
    return logical_lines


def dotenv(path: Path) -> dict[str, str]:
    """Parse the simple KEY=value syntax accepted by Docker Compose env files."""

    values = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", maxsplit=1)
        values[key] = value
    return values


def dockerignore_includes(path: Path, candidate: str) -> bool:
    """Evaluate the limited ordered ignore patterns used by this allowlist."""

    included = True
    for raw_pattern in path.read_text().splitlines():
        pattern = raw_pattern.strip()
        if not pattern or pattern.startswith("#"):
            continue
        negated = pattern.startswith("!")
        pattern = pattern.removeprefix("!").rstrip("/")
        if pattern == "**":
            matches = True
        elif pattern.endswith("/**"):
            matches = candidate.startswith(pattern[:-3])
        else:
            matches = candidate == pattern or candidate.startswith(f"{pattern}/")
        if matches:
            included = negated
    return included


def test_runtime_image_is_immutable_nonroot_and_executable() -> None:
    """A mutable base, root user, shell command, or curl-only check breaks runtime safety."""

    instructions = docker_instructions(BACKEND / "Dockerfile")
    bases = [value for keyword, value in instructions if keyword == "FROM"]
    assert len(bases) >= 2
    for base in bases:
        image = base.split(" AS ", maxsplit=1)[0].strip()
        assert re.fullmatch(r"python:3\.12-slim-bookworm@sha256:[0-9a-f]{64}", image)

    runs = [value for keyword, value in instructions if keyword == "RUN"]
    assert any("pip install" in value and "--require-hashes" in value for value in runs)
    assert any(re.search(r"addgroup.*10001.*adduser.*10001", value) for value in runs)
    assert ("USER", "10001:10001") in instructions
    assert ("EXPOSE", "8080") in instructions
    assert any(
        keyword == "HEALTHCHECK" and "urllib.request.urlopen" in value and "/health" in value
        for keyword, value in instructions
    )
    assert ("CMD", '["python", "-m", "app.serve"]') in instructions


def test_image_copies_only_runtime_allowlist_and_context_excludes_secrets() -> None:
    """Copying a local env file, test, cache, or repository metadata would leak it to a build."""

    instructions = docker_instructions(BACKEND / "Dockerfile")
    copied_sources: set[str] = set()
    for keyword, value in instructions:
        if keyword != "COPY":
            continue
        parts = shlex.split(value)
        if any(part.startswith("--from=") for part in parts):
            continue
        copied_sources.update(part for part in parts[:-1] if not part.startswith("--"))
    assert copied_sources <= {
        "backend/requirements.lock",
        "backend/app/",
        "backend/migrations/",
        "backend/alembic.ini",
    }

    dockerignore = ROOT / ".dockerignore"
    assert dockerignore_includes(dockerignore, "backend/requirements.lock")
    assert dockerignore_includes(dockerignore, "backend/app/main.py")
    assert dockerignore_includes(dockerignore, "backend/migrations/env.py")
    assert dockerignore_includes(dockerignore, "backend/alembic.ini")
    for unsafe_path in (
        ".env",
        ".git/config",
        "backend/.env",
        "backend/tests/test_contract.py",
        "backend/__pycache__/main.pyc",
    ):
        assert not dockerignore_includes(dockerignore, unsafe_path)


def test_compose_models_database_migration_gate_and_api_shutdown() -> None:
    """Starting traffic before a healthy migrated database risks an unavailable application."""

    compose = yaml.safe_load((BACKEND / "compose.yaml").read_text())
    services = compose["services"]
    assert set(services) == {"db", "migrate", "api"}
    assert compose["volumes"] == {"yperson-postgres": None}

    db = services["db"]
    assert db["image"] == "postgres:17.11-alpine"
    assert db["volumes"] == ["yperson-postgres:/var/lib/postgresql/data"]
    assert db["healthcheck"]["test"] == ["CMD-SHELL", "pg_isready -U yperson -d yperson"]

    for service_name in ("migrate", "api"):
        build = services[service_name]["build"]
        assert build == {"context": "..", "dockerfile": "backend/Dockerfile"}
        assert services[service_name]["env_file"] == [".env"]
        assert services[service_name]["depends_on"]["db"]["condition"] == "service_healthy"
    assert services["migrate"]["command"] == ["alembic", "upgrade", "head"]
    assert services["api"]["depends_on"]["migrate"]["condition"] == "service_completed_successfully"
    assert services["api"]["stop_grace_period"] == "20s"
    assert "volumes" not in services["api"]


def test_dotenv_example_is_complete_and_uses_safe_development_values() -> None:
    """Missing configuration or a production default can turn a local start into unsafe deployment."""

    assert dotenv(BACKEND / ".env.example") == {
        "YPERSON_ENV": "development",
        "HOST": "0.0.0.0",
        "PORT": "8080",
        "DATABASE_URL": "postgresql+psycopg://yperson:yperson@db:5432/yperson",
        "YPERSON_CONFIG_VERSION": "2026-08-18.1",
        "YPERSON_PRIVACY_URL": "https://example.invalid/yperson/privacy",
        "YPERSON_SUPPORT_URL": "https://example.invalid/yperson/support",
        "YPERSON_ANALYTICS_KILL_SWITCH": "false",
        "DATABASE_POOL_SIZE": "5",
        "DATABASE_POOL_TIMEOUT_SECONDS": "5",
        "GRACEFUL_SHUTDOWN_SECONDS": "15",
    }
