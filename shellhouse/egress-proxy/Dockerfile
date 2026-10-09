# Egress allowlist proxy: stdlib-only Python, no third-party packages.
FROM python:3.11-slim
RUN useradd -r -u 10001 -m egress && mkdir -p /data && chown egress /data
WORKDIR /app
COPY egress-proxy/egress_proxy/ /app/egress_proxy/
USER egress
ENV PYTHONUNBUFFERED=1
EXPOSE 3128 3129
CMD ["python", "-m", "egress_proxy"]
