FROM docker.io/denoland/deno:bin@sha256:0d1262facd139e815217c001945eb822c7a78584cf660142c34a6b53effec1aa AS deno-bin

# Statically linked ffmpeg/ffprobe (static-pie, zero runtime deps, multi-arch)
FROM docker.io/mwader/static-ffmpeg:9.0.1@sha256:54e55b0cb8f672870fc38ceb2e6c411855cb3b39c505f5f3b2505ee01ed5f2b7 AS ffmpeg

FROM ghcr.io/astral-sh/uv:python3.14-trixie-slim@sha256:d61b872404ed1a0774e2098b5af64c178b59c99be171db6631455262bb0750b4

# Build arguments for OCI annotations
ARG BUILD_DATE
ARG BUILD_VERSION

# OCI annotations (compatible with Docker, Podman, and Kubernetes)
LABEL org.opencontainers.image.title="Video Download API" \
    org.opencontainers.image.description="FastAPI server for downloading videos using yt-dlp" \
    org.opencontainers.image.vendor="mlshdev" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.source="https://github.com/mlshdev/universaldownloader-api" \
    org.opencontainers.image.documentation="https://github.com/mlshdev/universaldownloader-api/blob/main/README.md" \
    org.opencontainers.image.url="https://github.com/mlshdev/universaldownloader-api" \
    org.opencontainers.image.base.name="ghcr.io/astral-sh/uv:python3.14-trixie-slim" \
    org.opencontainers.image.created="${BUILD_DATE}" \
    org.opencontainers.image.version="${BUILD_VERSION}"

# Explicit shell for OCI compliance
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV PYTHONUNBUFFERED=1 \
    UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    PATH="/usr/local/bin:${PATH}" \
    HOME=/home/app

COPY --from=deno-bin /deno /usr/local/bin/deno
COPY --from=ffmpeg /ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg /ffprobe /usr/local/bin/ffprobe

# Create non-root user first for Podman rootless + SELinux
RUN useradd --create-home --uid 1000 --home-dir /home/app --shell /usr/sbin/nologin app && \
    mkdir -p /app /data && \
    chown -R 1000:1000 /app /data /home/app && \
    chmod 755 /data

WORKDIR /app

COPY --chown=1000:1000 pyproject.toml /app/
RUN uv pip install --system -r pyproject.toml

COPY --chown=1000:1000 main.py /app/
COPY --chown=1000:1000 entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

VOLUME /data

USER 1000

# Expose the API port
EXPOSE 8000

# OCI-compliant signal handling (SIGTERM for graceful shutdown)
STOPSIGNAL SIGTERM

# Healthcheck: verify the API is responding
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=5)"

ENTRYPOINT ["/app/entrypoint.sh"]
