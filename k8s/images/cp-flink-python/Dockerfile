# syntax=docker/dockerfile:1.7
#
# Confluent Platform Flink image extended with Python 3.11 + PyFlink, built
# reproducibly from the uv lockfile in examples/scalar_udf/python/.
#
# Build (into the minikube docker daemon so no push is needed):
#   eval $(minikube docker-env)
#   docker build \
#       -f k8s/images/cp-flink-python/Dockerfile \
#       -t cp-flink-python:2.1.1-cp1-java21 \
#       examples/scalar_udf/python
#
# The build context is examples/scalar_udf/python so that COPY can pick up
# pyproject.toml, uv.lock, .python-version, and the UDF source files.

ARG FLINK_IMAGE=confluentinc/cp-flink:2.1.1-cp1-java21
ARG UV_VERSION=0.9.10

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — build the PyFlink venv using uv against the committed lockfile.
# ─────────────────────────────────────────────────────────────────────────────
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM python:3.11-slim-bookworm AS builder

COPY --from=uv /uv /usr/local/bin/uv

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/flink/python-udf/.venv

WORKDIR /opt/flink/python-udf

# Copy only the files uv needs to resolve the environment first, so layer
# caching reuses the venv when only UDF source changes.
COPY pyproject.toml uv.lock .python-version ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# Copy the UDF package tree and install it into the venv as a proper Python
# package. Changes under src/ rebuild only this layer (not the deps layer
# above), and installing the package makes `import scalar_udf.X` resolve
# without needing PyFlink's `python.files` SET hint at SQL time.
COPY src/scalar_udf ./src/scalar_udf

RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --no-deps \
        --python /opt/flink/python-udf/.venv/bin/python \
        .

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — final image: cp-flink + Python 3.11 + prebuilt venv + UDF files.
# ─────────────────────────────────────────────────────────────────────────────
FROM ${FLINK_IMAGE}

USER root

# Install Python 3.11 runtime. The cp-flink base is Debian; python3.11 is not
# in the stock repos, so pull from deadsnakes-equivalent via apt if available,
# otherwise rely on the distro's python3 (3.11 on bookworm). Keep it minimal.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3.11 \
        python3.11-venv \
        libpython3.11 \
    && ln -sf /usr/bin/python3.11 /usr/local/bin/python3 \
    && ln -sf /usr/bin/python3.11 /usr/local/bin/python \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy the prebuilt venv and UDF source from the builder stage.
COPY --from=builder --chown=flink:flink /opt/flink/python-udf /opt/flink/python-udf

# Expose the venv's python on PATH so 'python.executable' resolution is simple.
ENV PYFLINK_PYTHON=/opt/flink/python-udf/.venv/bin/python \
    PYFLINK_UDF_DIR=/opt/flink/python-udf

USER flink
