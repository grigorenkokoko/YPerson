# YPerson Python Backend and Deployment Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the temporary Node.js/in-memory YPerson backend with a tested Python service that preserves the current iOS wire contract, persists approved state in PostgreSQL, and is ready for a later staging deployment as a portable OCI container.

**Architecture:** A synchronous FastAPI application runs under Uvicorn, validates requests with strict Pydantic models, and accesses PostgreSQL through SQLAlchemy sessions and Alembic migrations. `/health`, `/config`, and `/sync` keep the existing camelCase client contract; storage becomes durable, configuration moves to environment variables, and production startup remains fail-closed until authentication is separately approved. Deployment artifacts are provider-neutral: a non-root OCI image, Docker Compose for local/staging parity, explicit migrations, health checks, graceful shutdown, and structured non-PII logs.

**Tech Stack:** Python 3.12, FastAPI 0.141.1, Uvicorn 0.52.3, Pydantic 2.13.4, pydantic-settings 2.15.0, SQLAlchemy 2.0.52, Alembic 1.19.1, psycopg 3.3.4, PostgreSQL 17, pytest 9.1.1, HTTPX 0.28.1, PyYAML 6.0.3, Ruff 0.16.3, pip-tools 7.6.1, Docker/OCI.

**Spec:** `docs/superpowers/specs/2026-08-18-python-backend-deployment-design.md`

## Global Constraints

- Preserve the exact current iOS request/response field names and the three-route surface: `GET /health`, public `GET /config`, and `POST /sync`.
- Preserve `ETag`/`If-None-Match`, `304`, 64 KiB body limit, strict unknown-field rejection, prohibited-field rejection, `X-Request-ID`, and `updateCount: 0` for a new installation.
- Do not add permissions, collection, retention, remote code, analytics payloads, new iOS features, or a new API route.
- The existing `bearer` field and `Authorization` header are not accepted as proven authentication. `YPERSON_ENV=production` must refuse startup until an approved authentication design is implemented.
- Staging readiness is not production readiness. TLS termination, domain, managed PostgreSQL, backups/restore, hosting jurisdiction, processor terms, moderation operations, secrets, and production authentication remain release blockers.
- Backend pytest coverage is required. The existing ban on XCTest/UI-test targets remains unchanged and must be clarified as iOS-only in the reusable skill.
- Use test-driven development: observe each new test or structural assertion fail for the expected reason before adding the implementation that makes it pass.
- Use `apply_patch` for authored file changes. Do not overwrite unrelated user work.
- Before any push, stop and present the exact branch, commits, and remote destination for a fresh explicit approval.

---

### Task 1: Establish the Python project and RED contract baseline

**Files:**

- Create: `backend/app/__init__.py`
- Create: `backend/app/settings.py`
- Create: `backend/app/schemas.py`
- Create: `backend/tests/__init__.py`
- Create: `backend/tests/test_settings.py`
- Create: `backend/tests/test_schemas.py`
- Create: `backend/pyproject.toml`
- Create: `backend/requirements.lock`
- Create: `backend/requirements-dev.lock`
- Modify: `.gitignore`

- [ ] **Step 1: Capture the current migration RED state**

Run from the repository root:

```bash
test ! -f backend/server.mjs
test -f backend/app/main.py
test -f backend/pyproject.toml
```

Expected: the first assertion fails because the Node entry point still exists, and the Python project assertions fail because the new service has not been created.

- [ ] **Step 2: Add failing settings and schema tests**

Create tests that define the required contract before implementation:

```python
# backend/tests/test_settings.py
import pytest
from pydantic import ValidationError

from app.settings import Settings


def test_development_defaults_are_safe() -> None:
    settings = Settings(_env_file=None)
    assert settings.environment == "development"
    assert settings.host == "127.0.0.1"
    assert settings.port == 8080
    assert settings.max_body_bytes == 65_536


def test_production_is_fail_closed_without_approved_authentication() -> None:
    with pytest.raises(ValidationError, match="approved authentication"):
        Settings(YPERSON_ENV="production", _env_file=None)
```

```python
# backend/tests/test_schemas.py
import pytest
from pydantic import ValidationError

from app.schemas import SyncOperation, SyncRequest


def valid_request() -> dict[str, object]:
    return {"installationID": "ios-installation", "operation": "refresh"}


def test_sync_request_rejects_unknown_fields() -> None:
    payload = valid_request() | {"cursor": "not-in-current-wire-contract"}
    with pytest.raises(ValidationError):
        SyncRequest.model_validate(payload)


@pytest.mark.parametrize(
    "field",
    [
        "contacts",
        "addressBook",
        "rawPhotos",
        "cameraFrames",
        "preciseLocation",
        "meetingNote",
        "biometricData",
        "analyticsParameters",
    ],
)
def test_sync_request_rejects_prohibited_nested_fields(field: str) -> None:
    payload = valid_request() | {"card": {"id": "card", field: "secret"}}
    with pytest.raises(ValidationError, match="prohibited data field"):
        SyncRequest.model_validate(payload)


def test_all_existing_operations_remain_supported() -> None:
    assert {item.value for item in SyncOperation} == {
        "refresh",
        "publishCard",
        "claimExchange",
        "updatePushToken",
        "removePushToken",
        "deleteProfile",
        "report",
        "block",
    }
```

- [ ] **Step 3: Create the isolated environment and confirm RED**

Create `backend/pyproject.toml` with the following project dependency contract, plus pytest `testpaths = ["tests"]` and Ruff configured for Python 3.12 and a 100-column limit:

```toml
[project]
name = "yperson-backend"
version = "0.1.0"
requires-python = ">=3.12,<3.13"
dependencies = [
  "alembic==1.19.1",
  "fastapi==0.141.1",
  "psycopg[binary]==3.3.4",
  "pydantic==2.13.4",
  "pydantic-settings==2.15.0",
  "sqlalchemy==2.0.52",
  "uvicorn==0.52.3",
]

[project.optional-dependencies]
dev = [
  "httpx==0.28.1",
  "pip-tools==7.6.1",
  "pytest==9.1.1",
  "pyyaml==6.0.3",
  "ruff==0.16.3",
]
```

Check `python3.12 --version` before creating the environment. If Python 3.12 is unavailable, request approval for `brew install python@3.12`; generate the lock files with Python 3.12 rather than the machine's current Python 3.14 so environment markers match the deployment runtime.

Then run:

```bash
cd backend
python3.12 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install "pip-tools==7.6.1"
.venv/bin/python -m piptools compile --generate-hashes --output-file requirements.lock pyproject.toml
.venv/bin/python -m piptools compile --extra dev --generate-hashes --output-file requirements-dev.lock pyproject.toml
.venv/bin/python -m pip install --require-hashes -r requirements-dev.lock
.venv/bin/python -m pytest tests/test_settings.py tests/test_schemas.py -q
```

Expected: collection fails because `app.settings` and `app.schemas` do not yet exist.

- [ ] **Step 4: Implement strict settings**

Implement `Settings` with these aliases and defaults:

```python
environment: Literal["development", "staging", "production"]  # YPERSON_ENV; development
host: str                                                       # HOST; 127.0.0.1
port: int                                                       # PORT; 8080
database_url: str                                               # DATABASE_URL; postgresql+psycopg://yperson:yperson@127.0.0.1:5432/yperson
config_version: str                                             # YPERSON_CONFIG_VERSION; 2026-08-18.1
privacy_url: AnyHttpUrl                                         # YPERSON_PRIVACY_URL
support_url: AnyHttpUrl                                         # YPERSON_SUPPORT_URL
analytics_kill_switch: bool                                     # YPERSON_ANALYTICS_KILL_SWITCH; false
database_pool_size: int                                         # DATABASE_POOL_SIZE; 5
database_pool_timeout_seconds: int                              # DATABASE_POOL_TIMEOUT_SECONDS; 5
graceful_shutdown_seconds: int                                  # GRACEFUL_SHUTDOWN_SECONDS; 15
max_body_bytes: int = 65_536
```

Use `SettingsConfigDict(env_file=".env", extra="forbid", populate_by_name=True)`. A model validator must raise `ValueError("production requires separately approved authentication")` whenever `environment == "production"`; do not add a bypass flag that merely claims authentication exists.

- [ ] **Step 5: Implement strict wire schemas**

In `backend/app/schemas.py`:

- use camelCase field names exactly as Swift encodes them;
- set `extra="forbid"` on every model;
- model `PersonCard` with the existing Swift fields and allow `meetingPlace` only because it is already part of the published card model;
- recursively walk keys before validation and reject the eight prohibited keys anywhere in the payload;
- constrain `installationID` to 3–128 characters, `apnsToken` to at most 256 characters, and `exchangeToken` to at most 256 characters;
- constrain `moderationCategory` to `spam`, `abusive_content`, or `impersonation` when present;
- define `SyncResponse(accepted, serverVersion, updateCount, message)` and the exact public config response models.

- [ ] **Step 6: Confirm GREEN and lint**

```bash
cd backend
.venv/bin/python -m pytest tests/test_settings.py tests/test_schemas.py -q
.venv/bin/python -m ruff check app tests
.venv/bin/python -m ruff format --check app tests
```

Expected: all settings/schema tests pass and Ruff exits 0.

- [ ] **Step 7: Ignore only local Python artifacts and commit**

Add `.venv/`, `__pycache__/`, `.pytest_cache/`, `.ruff_cache/`, and `.env` without ignoring `.env.example` or lock files.

```bash
git add .gitignore backend/app backend/tests backend/pyproject.toml backend/requirements.lock backend/requirements-dev.lock
git commit -m "Start strict Python backend contract"
```

---

### Task 2: Add PostgreSQL persistence and Alembic migrations

**Files:**

- Create: `backend/app/storage.py`
- Create: `backend/app/maintenance.py`
- Create: `backend/alembic.ini`
- Create: `backend/migrations/env.py`
- Create: `backend/migrations/script.py.mako`
- Create: `backend/migrations/versions/20260818_0001_initial.py`
- Create: `backend/tests/conftest.py`
- Create: `backend/tests/test_storage.py`

- [ ] **Step 1: Write failing persistence tests**

Cover these behaviors against a real PostgreSQL database supplied by `TEST_DATABASE_URL`. Name the tests `test_new_profile_has_zero_updates`, `test_published_card_survives_a_new_session`, `test_apns_token_can_be_added_and_removed`, `test_exchange_token_is_hashed_and_expires_after_ten_minutes`, `test_report_and_block_are_durable`, and `test_delete_profile_removes_owned_rows`.

The exchange-token test must query the table directly and assert that the raw token is absent while `sha256(token).hexdigest()` is present.

- [ ] **Step 2: Start an isolated local PostgreSQL and confirm RED**

Use the installed PostgreSQL 17 binaries and a temporary directory, never a user or workspace database directory:

```bash
BACKEND_PG_DIR="$(mktemp -d)"
initdb -D "$BACKEND_PG_DIR/data" -A trust --no-locale --encoding=UTF8
pg_ctl -D "$BACKEND_PG_DIR/data" -o "-p 55432 -h 127.0.0.1" -w start
createdb -h 127.0.0.1 -p 55432 yperson_test
cd backend
TEST_DATABASE_URL="postgresql+psycopg://127.0.0.1:55432/yperson_test" .venv/bin/python -m pytest tests/test_storage.py -q
```

Expected: tests fail because storage models and migrations are not implemented. Keep the temporary cluster running through Tasks 2–3; stop it with `pg_ctl -D "$BACKEND_PG_DIR/data" -m fast -w stop` when those tasks finish.

- [ ] **Step 3: Implement the SQLAlchemy model and session boundary**

Create one declarative `Base` and these tables:

| Table | Required columns |
|---|---|
| `profiles` | `installation_id` PK, `card` JSONB nullable, `apns_token` nullable, `update_count` default 0, UTC `created_at`, UTC `updated_at` |
| `exchange_tokens` | `token_hash` PK, `owner_installation_id` FK cascade, `expires_at`, nullable `claimed_at`, `created_at` |
| `moderation_actions` | UUID-string PK, `reporter_installation_id` FK cascade, nullable fixed `category`, `created_at` |
| `blocked_connections` | UUID-string PK, `installation_id` FK cascade, opaque `blocked_reference`, `created_at` |

Build the SQLAlchemy engine from `Settings.database_url` with `pool_pre_ping=True`, `pool_size=settings.database_pool_size`, and `pool_timeout=settings.database_pool_timeout_seconds`. Construct a fresh engine/session factory per app instance so tests can inject an isolated database and process shutdown can dispose the correct pool.

Define a frozen `ProfileSnapshot` dataclass with `installation_id: str`, `card: dict[str, object] | None`, `apns_token: str | None`, and `update_count: int`. Expose small transaction-level functions rather than leaking ORM objects into routes:

- `ensure_profile(session: Session, installation_id: str) -> ProfileSnapshot`
- `publish_card(session: Session, installation_id: str, card: dict[str, object] | None) -> ProfileSnapshot`
- `store_exchange_claim(session: Session, installation_id: str, token: str, now: datetime) -> None`
- `set_push_token(session: Session, installation_id: str, token: str | None) -> ProfileSnapshot`
- `record_report(session: Session, installation_id: str, category: str | None) -> None`
- `record_block(session: Session, installation_id: str, now: datetime) -> None`
- `delete_profile(session: Session, installation_id: str) -> None`
- `prune_expired_exchange_tokens(session: Session, now: datetime) -> int`
- `database_is_ready(session: Session) -> bool`

The session dependency must wrap each `/sync` request in one transaction. Storage functions may flush but must not commit independently; the route commits once or rolls back the whole operation. No module-level mutable state is allowed. `store_exchange_claim` must prune expired claims within the same transaction. `backend/app/maintenance.py` must provide `python -m app.maintenance prune-exchange-tokens`, print only the number pruned, and return nonzero on database failure without logging token values.

- [ ] **Step 4: Add and exercise the initial Alembic migration**

Configure Alembic to read `DATABASE_URL`, import `Base.metadata`, and use PostgreSQL transactional DDL.

```bash
cd backend
DATABASE_URL="postgresql+psycopg://127.0.0.1:55432/yperson_test" .venv/bin/alembic upgrade head
DATABASE_URL="postgresql+psycopg://127.0.0.1:55432/yperson_test" .venv/bin/alembic current
```

Expected: `20260818_0001 (head)`.

- [ ] **Step 5: Confirm persistence GREEN**

```bash
cd backend
TEST_DATABASE_URL="postgresql+psycopg://127.0.0.1:55432/yperson_test" .venv/bin/python -m pytest tests/test_storage.py -q
.venv/bin/python -m ruff check app migrations tests
.venv/bin/python -m ruff format --check app migrations tests
```

Expected: all tests and lint checks pass.

- [ ] **Step 6: Commit durable storage**

```bash
git add backend/app/storage.py backend/app/maintenance.py backend/alembic.ini backend/migrations backend/tests/conftest.py backend/tests/test_storage.py
git commit -m "Persist YPerson backend state in PostgreSQL"
```

---

### Task 3: Implement the FastAPI endpoints with exact iOS compatibility

**Files:**

- Create: `backend/app/main.py`
- Create: `backend/app/observability.py`
- Create: `backend/app/serve.py`
- Create: `backend/tests/test_contract.py`
- Delete: `backend/server.mjs`

- [ ] **Step 1: Write the failing end-to-end API contract suite**

Use FastAPI `TestClient` with the real test database and assert exact status/body/header behavior. Name the tests `test_health_returns_version_when_database_is_ready`, `test_health_returns_503_when_database_is_unavailable`, `test_config_matches_swift_shape_and_contains_no_personal_data`, `test_config_etag_is_stable_and_if_none_match_returns_empty_304`, `test_valid_sync_returns_existing_response_shape`, `test_fresh_installation_update_count_is_zero`, `test_publish_card_persists_across_app_instances`, `test_sync_rejects_non_json_with_415`, `test_sync_rejects_invalid_json_with_400`, `test_sync_rejects_unknown_and_nested_prohibited_fields_with_400`, `test_sync_rejects_body_over_64_kib_with_413`, `test_claim_exchange_requires_at_least_eight_characters`, `test_report_block_push_and_delete_operations`, `test_known_route_wrong_method_returns_405_and_allow_header`, `test_unknown_route_returns_404`, and `test_every_response_has_request_id`.

Also assert the exact config values currently used by the iOS app:

```python
assert response.json() == {
    "version": "2026-08-18.1",
    "minimumContract": 1,
    "maintenance": False,
    "features": {
        "nearbyExchange": True,
        "sponsoredTemplates": True,
        "remoteNotifications": True,
    },
    "sponsoredTemplates": [
        {"id": "mint-conference", "title": "Mint Conference", "accentHex": "#AEEBD3"},
        {"id": "indigo-studio", "title": "Indigo Studio", "accentHex": "#4F5FE7"},
    ],
    "privacyURL": "https://example.invalid/yperson/privacy",
    "supportURL": "https://example.invalid/yperson/support",
    "moderationCategories": ["spam", "abusive_content", "impersonation"],
    "analyticsKillSwitch": False,
}
```

- [ ] **Step 2: Confirm endpoint RED**

```bash
cd backend
TEST_DATABASE_URL="postgresql+psycopg://127.0.0.1:55432/yperson_test" .venv/bin/python -m pytest tests/test_contract.py -q
```

Expected: collection or app creation fails because `app.main` does not exist.

- [ ] **Step 3: Implement the app factory, middleware, and handlers**

Implement `create_app(settings: Settings | None = None) -> FastAPI` and module-level `app = create_app()` with:

- a lifespan that validates settings and disposes the engine on shutdown;
- request-ID middleware using UUID4 and an `X-Request-ID` response header;
- ASGI body-size enforcement before JSON parsing, including chunked bodies;
- standard-library JSON log records containing timestamp, level, event, request ID, method, route, status, and latency only;
- no request body, token, card, installation ID, IP, or free text in logs;
- exception handlers that convert validation/JSON failures to the existing `400 invalid_request` shape, body overflow to `413`, media type failure to `415`, unknown route to `404`, wrong method to `405`, and unexpected errors to `500 internal_error`;
- `Cache-Control: no-store` by default, except `/config` uses `public, max-age=60`.

Implement `backend/app/serve.py` as the production-style process entry point. It must load `Settings` once and call Uvicorn programmatically with `settings.host`, `settings.port`, and `settings.graceful_shutdown_seconds`; this keeps `HOST` and `PORT` configurable while allowing an exec-form container command.

- [ ] **Step 4: Implement the three route behaviors**

`GET /health`:

- execute `SELECT 1`;
- return `200` with `status` equal to `ok` and `version` equal to `settings.config_version` when reachable;
- return `503` with `status` equal to `unavailable` and `version` equal to `settings.config_version` without exposing the database error.

`GET /config`:

- serialize one canonical UTF-8 JSON byte sequence with sorted keys and compact separators;
- compute quoted SHA-256 `ETag` from those exact bytes;
- return the same bytes for every request with unchanged settings;
- return no body for matching `If-None-Match` and status 304.

`POST /sync`:

- validate the strict schema and preserve all eight operation names;
- create a profile only as needed and keep new `updateCount` at 0;
- preserve the message expression `f"{payload.operation.value} accepted"` and the exact deletion message `profile deletion accepted; backup purge window is 30 days`;
- persist card, APNs token, hashed 10-minute claim, report, and block state;
- delete the profile and owned rows for `deleteProfile`;
- do not treat `bearer` or the Authorization header as verified identity.

- [ ] **Step 5: Confirm API GREEN, then remove Node**

```bash
cd backend
TEST_DATABASE_URL="postgresql+psycopg://127.0.0.1:55432/yperson_test" .venv/bin/python -m pytest tests/test_contract.py -q
.venv/bin/python -m pytest -q
.venv/bin/python -m ruff check app migrations tests
.venv/bin/python -m ruff format --check app migrations tests
```

Expected: all tests pass. Only after parity passes, delete `backend/server.mjs` and rerun:

```bash
test ! -f backend/server.mjs
! rg -n "node:http|node:crypto|new Map\(" backend
```

- [ ] **Step 6: Run a real Uvicorn smoke test**

```bash
cd backend
DATABASE_URL="postgresql+psycopg://127.0.0.1:55432/yperson_test" .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8080
```

In another shell, call `/health`, `/config`, conditional `/config`, and `/sync`; stop Uvicorn with SIGTERM and confirm a clean exit within 15 seconds.

- [ ] **Step 7: Commit the compatible API**

```bash
git add backend/app/main.py backend/app/observability.py backend/app/serve.py backend/tests/test_contract.py backend/server.mjs
git commit -m "Replace Node backend with compatible FastAPI service"
```

---

### Task 4: Prepare provider-neutral deployment artifacts

**Files:**

- Create: `backend/Dockerfile`
- Create: `backend/compose.yaml`
- Create: `backend/.env.example`
- Create: `.dockerignore`
- Rewrite: `backend/README.md`
- Create: `backend/tests/test_deployment_files.py`

- [ ] **Step 1: Write failing deployment-structure tests**

Add tests that read the authored artifacts and require:

- a Python 3.12 slim base pinned to an immutable digest before deployment;
- installation from `requirements.lock` with `--require-hashes`;
- a numeric non-root runtime user;
- environment-controlled `HOST`/`PORT`, an OCI health check, and an exec-form Python command;
- no secret copied into the image;
- Compose services `db`, `migrate`, and `api`;
- PostgreSQL 17 with a named volume and health check;
- migration completion before API startup;
- a 20-second stop grace period;
- all required environment variables in `.env.example` with non-secret development values;
- README sections for local setup, migrations, tests, Compose, staging deployment, structured-log inspection, rollback, backup/restore expectations, and production blockers.

Run:

```bash
cd backend
.venv/bin/python -m pytest tests/test_deployment_files.py -q
```

Expected: tests fail because the deployment files do not exist.

- [ ] **Step 2: Add the locked non-root OCI image**

Use a multi-stage Dockerfile. Resolve the current official `python:3.12-slim-bookworm` digest on a Docker-capable machine and append the returned `sha256` digest to the base-image reference in every `FROM` instruction; do not leave a mutable-only base before any staging deployment. The final image must:

- install only `requirements.lock` with hash verification;
- use the repository root as build context and copy only `backend/requirements.lock`, `backend/app/`, `backend/migrations/`, and `backend/alembic.ini` into the image;
- create and switch to numeric UID/GID 10001;
- expose 8080;
- health-check `/health` with Python standard-library `urllib`;
- start `python -m app.serve` in exec form; `app.serve` supplies host, port, and graceful-shutdown timeout to Uvicorn from validated settings.

- [ ] **Step 3: Add Compose parity without hiding migrations**

Use `postgres:17.11-alpine` for `db`, a named `yperson-postgres` volume, and health checks. Configure the image build with context `..` and Dockerfile `backend/Dockerfile` so the repository-root `.dockerignore` is applied. `migrate` must run `alembic upgrade head` once; `api` must depend on successful migration completion and database health. Do not mount source code into the staging-like API container.

- [ ] **Step 4: Document configuration and operational boundaries**

`.env.example` must include:

```dotenv
YPERSON_ENV=development
HOST=0.0.0.0
PORT=8080
DATABASE_URL=postgresql+psycopg://yperson:yperson@db:5432/yperson
YPERSON_CONFIG_VERSION=2026-08-18.1
YPERSON_PRIVACY_URL=https://example.invalid/yperson/privacy
YPERSON_SUPPORT_URL=https://example.invalid/yperson/support
YPERSON_ANALYTICS_KILL_SWITCH=false
DATABASE_POOL_SIZE=5
DATABASE_POOL_TIMEOUT_SECONDS=5
GRACEFUL_SHUTDOWN_SECONDS=15
```

The README must say explicitly:

- this repository is staging-deployable, not production-ready;
- production mode intentionally refuses startup;
- a platform migration job runs before new application traffic;
- at least one tested restore path and managed backup policy are required before production;
- TLS/domain, managed database, jurisdiction, processor terms, moderation operations, secrets, monitoring, and approved authentication remain blockers;
- rollback means redeploying the previous image and only downgrading a migration after reviewing the migration's `downgrade()` data-loss risk.

- [ ] **Step 5: Confirm authored deployment artifacts GREEN**

```bash
cd backend
.venv/bin/python -m pytest tests/test_deployment_files.py -q
.venv/bin/python -m pytest -q
.venv/bin/python -m ruff check app migrations tests
.venv/bin/python -m ruff format --check app migrations tests
```

Expected: all local checks pass.

- [ ] **Step 6: Run container verification when Docker is available**

```bash
docker compose -f backend/compose.yaml config
docker compose -f backend/compose.yaml build --pull
docker compose -f backend/compose.yaml up --wait
curl --fail --silent http://127.0.0.1:8080/health
docker compose -f backend/compose.yaml exec -T api id -u
curl --fail --silent --request POST http://127.0.0.1:8080/sync --header 'Content-Type: application/json' --data '{"installationID":"container-smoke","operation":"publishCard","card":{"id":"container-card","name":"Container Smoke","role":"QA","company":"YPerson","phone":"","email":"","tagline":"Persistence check","hasAudioGreeting":false,"meetingPlace":null,"isBlocked":false}}'
docker compose -f backend/compose.yaml restart api
curl --fail --silent http://127.0.0.1:8080/health
docker compose -f backend/compose.yaml exec -T db psql -U yperson -d yperson -tAc "SELECT card->>'id' FROM profiles WHERE installation_id='container-smoke'"
docker compose -f backend/compose.yaml down
```

Expected: config/build/start pass, health is 200, runtime UID is `10001`, data survives an API restart, and the named database volume is not deleted. If Docker remains unavailable, record this exact verification as a deployment blocker; do not claim the image was run.

- [ ] **Step 7: Commit deployment preparation**

```bash
git add .dockerignore backend/Dockerfile backend/compose.yaml backend/.env.example backend/README.md backend/tests/test_deployment_files.py
git commit -m "Prepare Python backend for staging deployment"
```

---

### Task 5: Reconcile the app, privacy contract, and release evidence

**Files:**

- Modify: `AppSpec.md`
- Modify: `AppPrivacy.yml`
- Modify: `release/release-manifest.json`
- Modify: `release/reconciliation.json`
- Modify: `release/implementation-verification.md`
- Modify: `release/manual-device-checks.md`

- [ ] **Step 1: Capture stale-document RED**

```bash
rg -n "Node.js|backend/server.mjs|one JSON file|один JSON-файл|in memory|in-memory" AppSpec.md AppPrivacy.yml release backend
```

Expected: matches identify the obsolete Node/in-memory claims and evidence paths.

- [ ] **Step 2: Update the source-of-truth documents**

In `AppSpec.md`:

- replace the prototype JSON allowance with the approved FastAPI/PostgreSQL/Alembic stack;
- explicitly distinguish the current camelCase implementation wire format from the broader product-level field inventory;
- state that any expansion to the broader product-level `/sync` model requires versioning, iOS work, privacy reconciliation, tests, and renewed approval;
- state that staging deployment readiness does not satisfy production authentication, backups, TLS/domain, jurisdiction, processor, or moderation blockers.

In `AppPrivacy.yml`:

- change `prototype_storage` to PostgreSQL-backed durable storage for the implemented subset;
- add staging container/migration/health-check facts without claiming production deployment;
- preserve all prohibited payloads, retention promises, and the `production_api` blocker;
- note that raw exchange tokens are stored only as SHA-256 hashes and expire after ten minutes.

- [ ] **Step 3: Refresh release evidence without advancing status**

In the release manifest and reports:

- replace Node toolchain/runtime with the verified Python/PostgreSQL versions;
- point evidence to `backend/app/main.py`, `backend/app/storage.py`, migrations, tests, and deployment files;
- add exact pytest, migration, local Uvicorn smoke, persistence, and graceful-shutdown results;
- add container verification only if it actually ran;
- keep `releaseReady: false`/`implementation-verified` and production blockers intact;
- update timestamps only for checks rerun during this implementation.

- [ ] **Step 4: Validate JSON/YAML structure and stale claims**

```bash
python3 -m json.tool release/release-manifest.json >/dev/null
python3 -m json.tool release/reconciliation.json >/dev/null
backend/.venv/bin/python - <<'PY'
from pathlib import Path
import yaml
yaml.safe_load(Path("AppPrivacy.yml").read_text(encoding="utf-8"))
PY
! rg -n "Node.js|backend/server.mjs|one JSON file|один JSON-файл|in memory|in-memory" AppSpec.md AppPrivacy.yml release backend
```

Expected: parsers exit 0 and stale-claim search returns no matches.

- [ ] **Step 5: Verify the unchanged iOS consumer still builds**

```bash
xcodegen generate
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: both builds succeed with the same shared `YPerson` scheme; no iOS deployment target or endpoint model changes are needed.

- [ ] **Step 6: Commit reconciled evidence**

```bash
git add AppSpec.md AppPrivacy.yml release
git commit -m "Document deployable Python backend evidence"
```

---

### Task 6: Update and test the reusable iOS build skill

**Files outside this repository:**

- Modify: `/Users/grigornkokoko/.agents/skills/build-minimal-ios-app-for-app-store-review/SKILL.md`
- Modify: `/Users/grigornkokoko/.agents/skills/build-minimal-ios-app-for-app-store-review/references/build-stage.md`
- Modify: `/Users/grigornkokoko/.agents/skills/build-minimal-ios-app-for-app-store-review/README.md`
- Modify: `/Users/grigornkokoko/.agents/skills/build-minimal-ios-app-for-app-store-review/scripts/validate_skill.py`
- Modify: `/Users/grigornkokoko/.agents/skills/build-minimal-ios-app-for-app-store-review/version.json`

- [ ] **Step 1: Read the required skill-development instructions**

Read `superpowers:test-driven-development`, `superpowers:writing-skills`, and the system `skill-creator` instructions completely before changing the installed skill.

- [ ] **Step 2: Run independent baseline pressure tests before editing**

Because the writing-skills workflow requires baseline and forward tests, start independent fresh-context agents and give them scenarios such as:

1. “Build a new minimal iOS app whose backend will be deployed later; choose a maintainable backend and describe required verification.”
2. “Continue an existing Node/in-memory prototype, migrate it to Python, and preserve `/config` and `/sync`.”
3. “Explain whether the skill's no-test rule forbids backend pytest tests.”

Record whether the current skill incorrectly prefers one dependency-free source file, lacks deployment preparation, or reads the test ban as applying to backend tests.

The installed skill is outside the current writable repository root. Request the required filesystem approval immediately before the first skill patch; do not copy the skill into the app repository as a workaround.

- [ ] **Step 3: Make validator expectations fail first**

Extend `scripts/validate_skill.py` to require language equivalent to all of these rules:

- default a newly created maintainable backend to Python 3.12 + FastAPI unless the approved existing ecosystem dictates another stack;
- deployment-expected backends require environment configuration, durable storage, migrations, health checks, graceful shutdown, non-root OCI packaging, locked dependencies, and deployment documentation;
- PostgreSQL is the default durable relational store for this workflow;
- preserve approved endpoint contracts, including mandatory public `/config` when specified;
- backend automated tests are required and explicitly allowed;
- “Do not create unit-test or UI-test targets” applies only to the iOS Xcode project;
- production readiness still requires authentication, secrets, TLS/domain, backups/restore, jurisdiction, processor terms, moderation operations, and actual deployment evidence.

Also make the validator reject the obsolete sentence:

```text
Prefer one source file, the simplest installed runtime, standard-library HTTP support, and no third-party packages.
```

Run the validator and confirm it fails for the newly required rules:

```bash
python3 /Users/grigornkokoko/.agents/skills/build-minimal-ios-app-for-app-store-review/scripts/validate_skill.py
```

- [ ] **Step 4: Update the skill instructions**

In `SKILL.md`, add the backend stack/deployment choice to the build-stage summary and explicitly scope the no-XCTest rule.

In `references/build-stage.md`, replace the one-file/no-dependency preference with this decision order:

1. Preserve an approved existing backend ecosystem when it is maintainable and deployment-compatible.
2. For a new backend, default to Python 3.12, FastAPI, Pydantic, SQLAlchemy, Alembic, PostgreSQL, and Uvicorn.
3. Use strict contract tests before replacing an existing implementation.
4. When deployment is expected, create locked dependencies, env configuration, explicit migrations, a non-root OCI image, health checks, graceful shutdown, structured non-PII logs, and operator documentation.
5. Do not claim production readiness without actual deployment and the production controls listed above.

Clarify that backend pytest tests are required while XCTest/UI-test targets, test files, mocks, and test-only iOS infrastructure remain forbidden by this particular workflow.

Update the installed README for users and bump `version.json` from `1.0.1` to `1.0.2`.

- [ ] **Step 5: Validate the updated skill**

```bash
python3 /Users/grigornkokoko/.agents/skills/build-minimal-ios-app-for-app-store-review/scripts/validate_skill.py
backend/.venv/bin/python /Users/grigornkokoko/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/grigornkokoko/.agents/skills/build-minimal-ios-app-for-app-store-review
```

Expected: both validators pass. If the general validator lacks a local dependency, install it only with the required approval or record that exact validation blocker; the skill's own validator must still pass.

- [ ] **Step 6: Run independent forward pressure tests**

Give fresh-context agents the same scenarios from Step 2. Require their outputs to choose Python for a new deployable backend, preserve existing contracts during migration, require backend tests, keep the iOS test ban scoped to Xcode targets, and distinguish staging preparation from production readiness.

If any agent reproduces the old failure, revise the skill and rerun the validator and scenario until the behavior is stable.

- [ ] **Step 7: Record the external skill change honestly**

The installed skill directory is outside the YPerson repository. Do not include it in the YPerson commit or claim it was pushed with the app. Report its absolute path and version `1.0.2` separately in the final handoff.

---

### Task 7: Run the full verification matrix and prepare the push gate

**Files:**

- Modify if results changed: `release/release-manifest.json`
- Modify if results changed: `release/implementation-verification.md`

- [ ] **Step 1: Run the complete backend suite against fresh PostgreSQL**

Create a new temporary cluster on port 55433 and database `yperson_verify`, set `TEST_DATABASE_URL=postgresql+psycopg://127.0.0.1:55433/yperson_verify`, then run:

```bash
cd backend
DATABASE_URL="$TEST_DATABASE_URL" .venv/bin/alembic upgrade head
TEST_DATABASE_URL="$TEST_DATABASE_URL" .venv/bin/python -m pytest -q
.venv/bin/python -m ruff check app migrations tests
.venv/bin/python -m ruff format --check app migrations tests
DATABASE_URL="$TEST_DATABASE_URL" .venv/bin/alembic downgrade base
DATABASE_URL="$TEST_DATABASE_URL" .venv/bin/alembic upgrade head
```

Expected: tests/lint pass and the migration can cleanly downgrade and re-upgrade on a disposable database.

- [ ] **Step 2: Re-run live contract and persistence smoke checks**

Run Uvicorn, exercise every status listed in Task 3, restart only the API process, and verify a published card/APNs token remains in PostgreSQL. Send SIGTERM and measure shutdown below the configured 15-second budget.

- [ ] **Step 3: Re-run iOS build and static contract checks**

```bash
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
rg -n 'appendingPathComponent\("config"\)|appendingPathComponent\("sync"\)' YPerson/Networking/APIClient.swift
! rg -n "server\.mjs|Node.js standard library|node:http|node:crypto" . --glob '!docs/superpowers/plans/**' --glob '!docs/superpowers/specs/**'
```

Expected: both builds pass, client routes remain present, and no active Node backend reference remains.

- [ ] **Step 4: Re-run skill validation**

```bash
python3 /Users/grigornkokoko/.agents/skills/build-minimal-ios-app-for-app-store-review/scripts/validate_skill.py
```

Expected: `Skill validation passed`.

- [ ] **Step 5: Update evidence only from fresh results and commit**

If full verification changes timestamps or results, patch the release evidence and commit it:

```bash
git add release/release-manifest.json release/implementation-verification.md
git commit -m "Record final Python backend verification"
```

Do not create an empty commit.

- [ ] **Step 6: Inspect the final change set**

```bash
git status --short --branch
git log --oneline origin/init..HEAD
git diff --stat origin/init...HEAD
git diff --check origin/init...HEAD
```

Expected: only intended YPerson changes are present, the branch is ahead of `origin/init`, and `git diff --check` is clean.

- [ ] **Step 7: Stop at the external push approval gate**

Present the user with:

- remote: `origin` and its resolved URL;
- branch: `init`;
- every unpushed commit hash and subject, including design/plan commits;
- a concise file/change summary;
- verification results and the honest Docker status;
- confirmation that the installed skill change is outside the repository and will not be part of the push.

Ask for explicit approval immediately before `git push origin init`. Only after that approval:

```bash
git push origin init
```

Expected: the remote branch advances to the final verified commit.
