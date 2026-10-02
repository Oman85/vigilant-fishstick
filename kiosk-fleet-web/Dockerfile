# Kiosk Fleet Web - the dashboard, the kiosk actions and the collector, on Linux.
#
#   docker build -t kiosk-fleet-web .
#   docker run -p 8080:8080 -e KFW_DEMO=1 kiosk-fleet-web      # try it on a pretend fleet
#
# For real use see docker-compose.yml and the README.

FROM python:3.12-slim AS build
WORKDIR /src
COPY pyproject.toml README.md ./
COPY kfw ./kfw
RUN pip wheel --no-cache-dir --wheel-dir /wheels .

FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    KFW_DATA_DIR=/data \
    KFW_PORT=8080 \
    TZ=Europe/Prague

# ping for the reachability check, tzdata so the local-time columns of the
# events CSV are the site's, tini so a scan's child process is reaped.
RUN apt-get update \
 && apt-get install -y --no-install-recommends iputils-ping tzdata tini \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /wheels /wheels
RUN pip install --no-cache-dir /wheels/*.whl && rm -rf /wheels

RUN useradd --system --uid 10001 --user-group --home-dir /data --no-create-home kfw \
 && mkdir -p /data && chown kfw:kfw /data
USER kfw
WORKDIR /data
VOLUME ["/data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.environ.get('KFW_PORT', '8080'), timeout=4)" || exit 1

ENTRYPOINT ["tini", "--"]
CMD ["kfw", "serve"]
