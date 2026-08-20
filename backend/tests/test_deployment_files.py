"""Deployment artifact behavior tests.

These tests parse the inputs consumed by Docker Compose and dotenv rather than
checking README prose or matching authored configuration lines.
"""

from __future__ import annotations

import ast
import json
import re
import shlex
import tomllib
from fnmatch import fnmatch
from pathlib import Path

import yaml
from packaging.requirements import Requirement
from packaging.utils import canonicalize_name

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
FORBIDDEN_DATABASE_PACKAGES = {
    "alembic",
    "greenlet",
    "psycopg",
    "psycopg-binary",
    "sqlalchemy",
}
LOCKED_REQUIREMENT = re.compile(r"^([A-Za-z0-9_.-]+)(?:\[[^\]]+\])?==[^\s\\]+(?:\s+\\)?$")
SHA256_HASH = re.compile(r"--hash=sha256:[0-9a-f]{64}")


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
        elif "/" in pattern or "*" in pattern or "[" in pattern:
            matches = fnmatch(
                candidate, pattern.rstrip("/") + ("/*" if pattern.endswith("/") else "")
            )
        else:
            matches = candidate == pattern or candidate.startswith(f"{pattern}/")
        if matches:
            included = negated
    return included


def json_healthcheck(instructions: list[tuple[str, str]]) -> list[str]:
    """Return the JSON exec command carried by the Docker HEALTHCHECK instruction."""

    healthchecks = [value for keyword, value in instructions if keyword == "HEALTHCHECK"]
    assert len(healthchecks) == 1
    _, separator, payload = healthchecks[0].partition(" CMD ")
    assert separator, "HEALTHCHECK must use exec-form CMD payload"
    command = json.loads(payload)
    assert isinstance(command, list) and all(isinstance(part, str) for part in command)
    return command


def compose_port_pair(mapping: str, environment: dict[str, str]) -> tuple[str, str]:
    """Resolve the `${PORT:-default}` shorthand used by the Compose port mapping."""

    match = re.fullmatch(
        r"\$\{PORT:-(?P<host_default>\d+)\}:\$\{PORT:-(?P<container_default>\d+)\}",
        mapping,
    )
    assert match, "API port mapping must derive both endpoints from PORT"
    port = environment.get("PORT") or match.group("host_default")
    assert match.group("host_default") == match.group("container_default")
    return port, port


def locked_requirement_entries(path: Path) -> dict[str, list[str]]:
    """Return each normalized pinned package and its logical lock-file block."""

    entries: dict[str, list[str]] = {}
    current_entry: str | None = None
    for raw_line in path.read_text().splitlines():
        if match := LOCKED_REQUIREMENT.fullmatch(raw_line):
            current_entry = canonicalize_name(match.group(1))
            entries[current_entry] = []
        elif current_entry and raw_line.startswith((" ", "\t")):
            entries[current_entry].append(raw_line.strip().removesuffix("\\").rstrip())
        else:
            current_entry = None
    return entries


def locked_requirement_names(path: Path) -> set[str]:
    """Return normalized package names pinned by a hashed requirements file."""

    return set(locked_requirement_entries(path))


def assert_every_locked_requirement_has_sha256_hash(path: Path) -> None:
    """Require a valid SHA-256 hash in each logical requirement block."""

    entries = locked_requirement_entries(path)
    assert entries, f"{path.name} has no pinned requirement entries"
    missing_hashes = sorted(
        name
        for name, lines in entries.items()
        if not any(SHA256_HASH.fullmatch(line) for line in lines)
    )
    assert not missing_hashes, f"{path.name} has unhashed pinned requirements: {missing_hashes}"


def test_database_packages_are_absent_from_project_and_locks() -> None:
    """A database dependency would make the serverless image non-portable."""

    project = tomllib.loads((BACKEND / "pyproject.toml").read_text())
    runtime_names = {
        canonicalize_name(Requirement(value).name) for value in project["project"]["dependencies"]
    }
    assert runtime_names.isdisjoint(FORBIDDEN_DATABASE_PACKAGES)
    for filename in ("requirements.lock", "requirements-dev.lock"):
        lock_path = BACKEND / filename
        names = locked_requirement_names(lock_path)
        assert runtime_names <= names
        assert names.isdisjoint(FORBIDDEN_DATABASE_PACKAGES)
        if filename == "requirements-dev.lock":
            assert {"pip", "setuptools"} <= names
        assert_every_locked_requirement_has_sha256_hash(lock_path)


def test_runtime_includes_ydb_metadata_http_transport() -> None:
    """Production metadata authentication requires YDB's Requests transport."""

    project = tomllib.loads((BACKEND / "pyproject.toml").read_text())
    runtime_names = {
        canonicalize_name(Requirement(value).name) for value in project["project"]["dependencies"]
    }
    assert "requests" in runtime_names


def test_runtime_image_is_immutable_nonroot_and_executable() -> None:
    """A mutable base, root user, shell command, or curl-only check breaks runtime safety."""

    instructions = docker_instructions(BACKEND / "Dockerfile")
    bases = [value for keyword, value in instructions if keyword == "FROM"]
    assert len(bases) >= 2
    for base in bases:
        image = base.split(" AS ", maxsplit=1)[0].strip()
        assert re.fullmatch(r"python:3\.12-slim-bookworm@sha256:[0-9a-f]{64}", image)

    runs = [value for keyword, value in instructions if keyword == "RUN"]
    install_commands = []
    for keyword, value in instructions:
        if keyword != "RUN":
            continue
        tokens = shlex.split(value)
        if tokens[:4] == ["python", "-m", "pip", "install"]:
            install_commands.append(tokens)
    assert len(install_commands) == 1
    install = install_commands[0]
    assert "--require-hashes" in install
    requirement_flags = [
        index for index, token in enumerate(install) if token in {"-r", "--requirement"}
    ]
    assert requirement_flags == [install.index("-r")]
    assert install[install.index("-r") + 1] == "requirements.lock"
    assert any(re.search(r"addgroup.*10001.*adduser.*10001", value) for value in runs)
    assert ("USER", "10001:10001") in instructions
    assert ("EXPOSE", "8080") in instructions
    healthcheck = json_healthcheck(instructions)
    assert healthcheck[:2] == ["python", "-c"]
    health_program = ast.parse(healthcheck[2])
    getenv_calls = [
        node
        for node in ast.walk(health_program)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "getenv"
        and [getattr(argument, "value", None) for argument in node.args] == ["PORT", "8080"]
    ]
    assert getenv_calls
    health_calls = [
        node
        for node in ast.walk(health_program)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "urlopen"
    ]
    assert len(health_calls) == 1
    health_url = health_calls[0].args[0]
    assert isinstance(health_url, ast.JoinedStr)
    assert any(
        isinstance(value, ast.FormattedValue)
        and isinstance(value.value, ast.Name)
        and value.value.id == "port"
        for value in health_url.values
    )
    assert any(
        isinstance(value, ast.Constant) and value.value in {"http://127.0.0.1:", "/health"}
        for value in health_url.values
    )
    cmd = [value for keyword, value in instructions if keyword == "CMD"]
    assert [json.loads(value) for value in cmd] == [["python", "-m", "app.serve"]]


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
    assert copied_sources == {
        "backend/requirements.lock",
        "backend/app/",
    }

    dockerignore = ROOT / ".dockerignore"
    assert dockerignore_includes(dockerignore, "backend/requirements.lock")
    assert dockerignore_includes(dockerignore, "backend/app/main.py")
    for unsafe_path in (
        ".env",
        ".git/config",
        "backend/.env",
        "backend/tests/test_contract.py",
        "backend/__pycache__/main.pyc",
        "backend/app/__pycache__/main.cpython-312.pyc",
        "backend/app/.env",
        "backend/app/state.sqlite3",
    ):
        assert not dockerignore_includes(dockerignore, unsafe_path)


def test_compose_models_detached_local_api_shutdown() -> None:
    """A detached local start needs one directly reachable API service."""

    compose = yaml.safe_load((BACKEND / "compose.yaml").read_text())
    services = compose["services"]
    assert set(services) == {"api"}
    assert "volumes" not in compose

    api = services["api"]
    assert api["build"] == {"context": "..", "dockerfile": "backend/Dockerfile"}
    assert api["env_file"] == [".env"]
    assert "depends_on" not in api
    assert api["stop_grace_period"] == "20s"
    assert "volumes" not in api
    port_mapping = api["ports"]
    assert port_mapping == ["${PORT:-8080}:${PORT:-8080}"]
    assert compose_port_pair(port_mapping[0], {}) == ("8080", "8080")
    assert compose_port_pair(port_mapping[0], {"PORT": "9000"}) == ("9000", "9000")


def test_dotenv_example_is_complete_and_uses_safe_development_values() -> None:
    """Missing configuration or a production default can turn a local start into unsafe deployment."""

    assert dotenv(BACKEND / ".env.example") == {
        "YPERSON_ENV": "development",
        "HOST": "0.0.0.0",
        "PORT": "8080",
        "YPERSON_CONFIG_VERSION": "2026-08-18.1",
        "YPERSON_PRIVACY_URL": "https://example.invalid/yperson/privacy",
        "YPERSON_SUPPORT_URL": "https://example.invalid/yperson/support",
        "YPERSON_ANALYTICS_KILL_SWITCH": "false",
        "GRACEFUL_SHUTDOWN_SECONDS": "15",
    }
