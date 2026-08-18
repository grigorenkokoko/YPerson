# YPerson Python Backend and Deployment Design

Date: 2026-08-18

## Goal

Replace the temporary Node.js in-memory service with a maintainable Python backend that preserves the current iOS API contract and can later be deployed as a portable OCI container. The result must be suitable for staging deployment and structurally ready for production hardening without claiming that unresolved authentication, hosting, backup, or legal choices are complete.

## Non-goals

- Do not deploy the service or mutate a hosting account in this change.
- Do not change the iOS JSON field names or add endpoints beyond `GET /health`, `GET /config`, and `POST /sync`.
- Do not add APNs sending, media storage, a public people directory, login, or a new product feature.
- Do not claim production readiness while installation authentication, public URLs, hosting jurisdiction, managed backups, moderation operations, and processor terms remain unresolved.

## Chosen approach

Use Python 3.12, FastAPI, Pydantic, SQLAlchemy, Alembic, PostgreSQL, and Uvicorn. Package the service as a non-root OCI image and provide a local Docker Compose stack with PostgreSQL.

This is preferred over a standard-library HTTP server with SQLite because YPerson is expected to be deployed and stores profile data. PostgreSQL provides durable transactions, migrations, backup integration, and later horizontal scaling. It is preferred over a provider-specific serverless implementation because the deployment platform has not yet been selected and the service must remain portable.

Dependencies must be version-pinned in the implementation. Select supported versions from official project documentation at implementation time; do not copy an unverified stale version from this design.

## Repository layout

```text
backend/
  app/
    __init__.py
    main.py          # FastAPI routes, request IDs, response mapping
    settings.py      # validated environment configuration
    schemas.py       # strict request/response and public-config models
    storage.py       # SQLAlchemy models and transactional operations
  migrations/
    versions/
  tests/
    test_contract.py # backend-only API contract tests
  alembic.ini
  pyproject.toml
  Dockerfile
  compose.yaml
  .env.example
  README.md
.dockerignore
```

Remove `backend/server.mjs`. No live-data migration is required because the Node.js implementation stores all state only in process memory.

## API compatibility

The implemented wire format remains the current camelCase contract used by the iOS client.

### `GET /health`

- Return `200` with `{"status":"ok","version":"..."}` when the process and database are reachable.
- Return `503` when the database readiness check fails.
- Accept no request body or personal data.

### `GET /config`

- Remain public and accept no personal data.
- Return only the existing configuration fields: `version`, `minimumContract`, `maintenance`, `features`, `sponsoredTemplates`, `privacyURL`, `supportURL`, `moderationCategories`, and `analyticsKillSwitch`.
- Generate a stable SHA-256 ETag from canonical JSON.
- Return `304` for a matching `If-None-Match` value.
- Reject unsupported methods and never use remote configuration to expand permissions, tracking, collection, or retention.

### `POST /sync`

- Preserve the current top-level fields: `installationID`, `bearer`, `apnsToken`, `operation`, `card`, `exchangeToken`, and `moderationCategory`.
- Preserve the current operations: `refresh`, `publishCard`, `claimExchange`, `updatePushToken`, `removePushToken`, `deleteProfile`, `report`, and `block`.
- Reject unknown fields, bodies larger than 64 KiB, unsupported content types, invalid moderation categories, and prohibited nested fields.
- Continue to prohibit Contacts/address-book content, raw photos or camera frames, precise location, meeting notes, biometric data, and analytics content parameters.
- Return `updateCount: 0` for a new installation with no real updates.
- Keep error responses deterministic and include a generated `X-Request-ID` without echoing sensitive payloads.

## Persistent data

PostgreSQL stores only data needed by the approved contract:

- `profiles`: installation ID, published card JSON, APNs token, update count, creation/update timestamps.
- `exchange_tokens`: hashed token, owning installation, expiry, claim timestamp.
- `moderation_actions`: installation, operation, fixed category, status, timestamps; no raw local notes.
- `blocked_connections`: installation-scoped block identifiers and timestamps.

Use database transactions for every `/sync` operation. Expired exchange tokens are removed during claims and by a documented maintenance command. `deleteProfile` deletes the active profile, APNs token, exchange tokens, and connection state transactionally; backup-retention behavior remains a hosting-level production blocker.

Cards may remain JSON because the client contract is compact and versioned, but schema validation occurs before storage. Never log full cards, APNs tokens, bearer values, or request bodies.

## Configuration and secrets

Validate configuration once at process startup. Support at least:

- `YPERSON_ENV` (`development`, `staging`, or `production`)
- `HOST` and `PORT`
- `DATABASE_URL`
- `YPERSON_CONFIG_VERSION`
- `YPERSON_PRIVACY_URL` and `YPERSON_SUPPORT_URL`
- `YPERSON_ANALYTICS_KILL_SWITCH`
- database pool and shutdown timeout settings

Commit only `.env.example` with non-secret placeholders. Never commit database credentials, APNs keys, access tokens, or production URLs containing secrets.

The existing `bearer` field does not yet define safe installation authentication. Do not invent a shared application secret that would be recoverable from the iOS binary. Staging may preserve the current unauthenticated behavior, but `YPERSON_ENV=production` must fail startup until an approved installation-auth mode is implemented and configured.

## Container and deployment preparation

- Build from a pinned Python slim base image and run as a dedicated non-root user.
- Install only locked runtime dependencies; exclude tests, caches, local databases, `.env` files, and repository metadata from the final image.
- Bind to configurable `0.0.0.0:$PORT` inside the container.
- Include an OCI health check against `/health` using Python itself rather than assuming `curl` exists.
- Handle SIGTERM/SIGINT and stop accepting work before the platform timeout.
- Run Alembic migrations as an explicit release command before switching traffic; do not race automatic migrations across replicas.
- Provide `backend/compose.yaml` for local application plus PostgreSQL with a named volume.
- Document generic build, migration, run, smoke, backup, rollback, and log-inspection commands. Provider-specific deployment configuration waits until the target host is selected.

The image is deployable to a normal OCI platform, but production activation remains blocked by managed PostgreSQL, TLS/domain, installation authentication, backup/restore evidence, hosting jurisdiction, monitoring, moderation operations, and processor agreements.

## Error handling and observability

- Emit structured single-line logs with timestamp, severity, request ID, method, path, status, and duration.
- Do not log request/response bodies or secrets.
- Map validation failures to `400`, wrong content type to `415`, oversized body to `413`, unsupported method to `405`, unknown path to `404`, unavailable database to `503`, and unexpected failures to a generic `500`.
- Keep `/health` and `/config` free of user identifiers.

## Verification strategy

Backend tests are allowed and required even though the iOS workflow continues to forbid XCTest/UI-test targets and test-only app infrastructure.

1. Record RED evidence that the current implementation is Node.js, in-memory, bound to loopback, and lacks an OCI image, durable database, migrations, and deployment configuration.
2. Add backend contract tests first for `/health`, `/config` 200/304, `/sync`, strict unknown-field rejection, prohibited-field rejection, body limit, error status mapping, deletion, and new-install `updateCount: 0`.
3. Run tests against an isolated database.
4. Start the service directly and smoke all three endpoints.
5. Build the OCI image, start it with PostgreSQL, run migrations, smoke the API, restart the application container, and confirm persisted state remains.
6. Inspect the image user, health check, environment surface, ignored files, and graceful termination.
7. Rebuild the iOS application or run an equivalent client-contract check to confirm the JSON wire format did not change.
8. Update release evidence without advancing beyond `implementation-verified`.

## Skill contract update

Update `build-minimal-ios-app-for-app-store-review` so future projects:

- default to Python 3 for a new minimal backend unless an approved repository ecosystem dictates another runtime;
- always include the public `GET /config` endpoint alongside `/health` and `/sync`;
- distinguish a disposable in-memory prototype from a backend expected to be deployed;
- require an OCI image, non-root execution, environment configuration, durable storage, migrations, health/readiness, graceful shutdown, secret hygiene, and documented deployment blockers when future deployment is expected;
- allow backend contract tests while continuing to prohibit iOS XCTest/UI-test targets under this workflow;
- never label a containerized service production-ready merely because it starts locally.

Increment the installed skill patch version and extend its validator with stable wording for the new requirements. Baseline and forward-test the skill using independent agents before and after the edit.

## Handoff boundary

Completing this design and its implementation prepares the service for a later staging deployment. Actual hosting changes are an external action and require a separate target-specific design, account choice, exact payload summary, and explicit approval immediately before deployment.
