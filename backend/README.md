# YPerson Python backend

This repository is **staging-deployable, not production-ready**. It exposes
the approved `GET /health`, `GET /config`, and `POST /sync` contract, keeps
the public config free of personal data, and avoids logging request bodies or
secrets. `YPERSON_ENV=production` intentionally refuses startup until an
approved installation-authentication mode is implemented and configured.

## Local setup

Use Python 3.12 and PostgreSQL, then install the development lock file:

```bash
cd backend
python3.12 -m venv .venv
.venv/bin/python -m pip install --require-hashes -r requirements-dev.lock
cp .env.example .env
```

The example database URL targets the Compose database. For direct local use,
set `DATABASE_URL` to a non-committed local PostgreSQL URL. Do not commit
`.env`, database credentials, APNs credentials, access tokens, or production
URLs containing secrets.

## Migrations

Run migrations as an explicit release action; do not let replicas race to
migrate on application startup:

```bash
cd backend
.venv/bin/alembic upgrade head
.venv/bin/python -m app.maintenance --remove-expired-exchange-tokens
```

On a platform, a migration job runs before new application traffic is
switched to the API image.

## Tests

```bash
cd backend
.venv/bin/python -m pytest -q
.venv/bin/python -m ruff check app migrations tests
.venv/bin/python -m ruff format --check app migrations tests
```

## Docker Compose

From the repository root, configure a local staging-like stack and start it:

```bash
cp backend/.env.example backend/.env
docker compose -f backend/compose.yaml config
docker compose -f backend/compose.yaml up --build --wait
curl --fail --silent http://127.0.0.1:8080/health
docker compose -f backend/compose.yaml down
```

The API image runs as numeric UID/GID `10001`, uses a Python standard-library
health check, and has no source-code mount. PostgreSQL data is retained in the
named `yperson-postgres` volume when `down` is used without `--volumes`.

## Staging deployment

Build from the repository root, push a uniquely versioned image to the chosen
OCI registry, run `alembic upgrade head` as a one-shot platform migration job,
then switch traffic only after that job succeeds and `/health` is healthy.
Keep the image digest recorded in the release record. The Dockerfile pins the
official multi-platform `python:3.12-slim-bookworm` manifest digest; refresh
that digest deliberately through Docker's official registry during image
maintenance.

Inspect structured logs through the platform log service, filtering by
`request_id`, `status`, `method`, or `path`. Logs are single-line structured
records and must not include cards, bearer values, APNs tokens, or request
bodies.

## Rollback and backup/restore

Rollback means redeploying the previous image. Downgrade a migration only
after reviewing that migration's `downgrade()` data-loss risk and testing it
against a copy of the affected data.

Before production, require both a managed-backup policy and at least one
tested restore path that proves the selected PostgreSQL service can recover
the required data and service state. The local named volume is not a backup.

## Production blockers

Production activation remains blocked by TLS/domain, managed PostgreSQL,
hosting jurisdiction, processor terms, moderation operations, secret
management, monitoring, and approved installation authentication. It also
requires backup/restore evidence and a target-host review covering capacity,
incident response, and access control. Containerization alone does not make
the service production-ready.
