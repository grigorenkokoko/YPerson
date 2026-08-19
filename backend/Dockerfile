# syntax=docker/dockerfile:1
FROM python:3.12-slim-bookworm@sha256:a116514e19457bcb7af7efe9c3dd0b9b71e85b317694e7882a1c52aa15a78134 AS builder

WORKDIR /build
COPY backend/requirements.lock ./requirements.lock
RUN python -m pip install --no-cache-dir --require-hashes --prefix=/install -r requirements.lock

FROM python:3.12-slim-bookworm@sha256:a116514e19457bcb7af7efe9c3dd0b9b71e85b317694e7882a1c52aa15a78134 AS runtime

RUN addgroup --gid 10001 yperson && adduser --uid 10001 --gid 10001 --disabled-password --gecos '' yperson
ENV HOST=0.0.0.0 PORT=8080 PYTHONUNBUFFERED=1
WORKDIR /app

COPY --from=builder /install /usr/local
COPY backend/app/ ./app/

USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["python", "-c", "import os, urllib.request; port=os.getenv('PORT', '8080'); urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=3).read()"]
CMD ["python", "-m", "app.serve"]
