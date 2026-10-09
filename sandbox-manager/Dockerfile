FROM python:3.11-slim

# Deliberately minimal: this is the one privileged component, so its
# dependency surface stays as small as it can be. No agent code, no model
# client, no web framework beyond what serves the unix socket, nothing that
# parses untrusted web content.

WORKDIR /app

COPY sandbox-manager/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY sandbox-manager/app/ /app/

# Socket directory, owned by the group shared with the api container.
RUN mkdir -p /run/sandbox-manager /var/log/sandbox-manager

COPY sandbox-manager/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
