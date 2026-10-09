FROM python:3.11-slim

# Small on purpose: this service is reachable by other people's apps, so it
# carries no Docker access, no model client, no agent code, and runs as an
# unprivileged user with a read-only root filesystem (see docker-compose.yml).
RUN useradd --system --uid 10001 --home-dir /nonexistent --shell /usr/sbin/nologin relay \
    && mkdir -p /data /certs && chown relay:relay /data

WORKDIR /app
COPY group-relay/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY group-relay/app/ /app/
COPY group-relay/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER relay
EXPOSE 8443
ENTRYPOINT ["/entrypoint.sh"]
