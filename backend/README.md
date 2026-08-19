# YPerson Python backend

The database-free backend exposes five routes:

| Route | Contract |
| --- | --- |
| `GET /health` | `200` readiness JSON with `status` and configuration `version` |
| `GET /config` | `200` public application configuration with ETag/304 caching |
| `GET /privacy` | `200` technical privacy HTML page |
| `GET /support` | `200` technical support HTML page |
| `POST /sync` | `503` until installation authentication is approved and implemented |

`/config` contains no personal data. Do not log request bodies or secrets.

## Local startup

From the repository root, start the database-free local service and confirm it
is healthy:

```bash
cp backend/.env.example backend/.env
docker compose -f backend/compose.yaml up -d --build --wait
curl --fail --silent http://127.0.0.1:8080/health
docker compose -f backend/compose.yaml down
```

The API image runs as numeric UID/GID `10001`, has a Python standard-library
health check, and has no source-code mount. Do not commit `.env`, credentials,
APNs tokens, access tokens, or URLs that contain secrets.

## Tests

```bash
cd backend
python3.12 -m venv .venv
.venv/bin/python -m pip install --require-hashes -r requirements-dev.lock
.venv/bin/python -m pytest -q
.venv/bin/python -m ruff check app tests
.venv/bin/python -m ruff format --check app tests
```

## Production deployment

Follow the domainless Yandex Serverless Containers bootstrap and rollback
procedure in
[`deploy/yandex/serverless/README.md`](../deploy/yandex/serverless/README.md).
This release has no database, migration, custom-domain, certificate, DNS, or
VM procedure. Keep the deployed image digest in the release record and inspect
structured platform logs by `request_id`, `status`, `method`, or `path`; logs
must not contain cards, bearer values, APNs tokens, or request bodies.
