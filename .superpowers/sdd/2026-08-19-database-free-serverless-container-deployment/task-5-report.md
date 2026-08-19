# Task 5 report: GitHub Actions release workflow

## Delivered

- Added `.github/workflows/deploy-serverless.yml` for pushes to `main` and
  manual dispatch, with path filtering, minimal OIDC permissions, and
  non-cancelling production concurrency.
- The workflow installs Python 3.12 dependencies with the hashed dev lock,
  runs the backend test suite before any image push, exchanges the GitHub OIDC
  token through `yc-iam-token-fed:1.0.0`, and pushes the full-SHA amd64 image.
- It installs the official Yandex Cloud CLI into `RUNNER_TEMP`, verifies it,
  and calls the existing deployment script only after the image-push step.
- The workflow contains no database service, database/test database settings,
  GitHub secrets references, static authorized keys, Lockbox, migration, or
  VPC references.

## TDD evidence

1. Added the parsed YAML release-workflow contract in
   `backend/tests/test_serverless_deployment.py`.
2. RED: `cd backend && .venv/bin/python -m pytest
   tests/test_serverless_deployment.py -q -k workflow` failed with
   `FileNotFoundError` for `.github/workflows/deploy-serverless.yml`.
3. GREEN: the same command passed (`1 passed, 27 deselected`).

## Final verification

`cd backend && .venv/bin/python -m pytest tests/test_serverless_deployment.py -q`

Result: `28 passed in 2.40s`.

`git diff --check`

Result: no whitespace errors.
