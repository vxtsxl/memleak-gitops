# syntax=docker/dockerfile:1
# The app uses only the Python standard library, so no build stage or
# pip install is needed. Alpine keeps the image tiny; the Python version is a
# build-arg so CI can build one image per matrix entry (3.11 / 3.12 / 3.13).
ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-alpine

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# Pull in the latest Alpine security patches for the base packages
RUN apk upgrade --no-cache

# Dedicated unprivileged user (fixed UID so Kubernetes runAsNonRoot can verify it)
RUN addgroup -g 10001 -S app && adduser -u 10001 -S -G app -H -s /sbin/nologin app

WORKDIR /app
COPY --chown=10001:10001 app/app.py .

USER 10001:10001
EXPOSE 8080

# No curl/wget in the image: use Python itself for the health check
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthcheck', timeout=2).status == 200 else 1)"]

CMD ["python", "app.py"]
