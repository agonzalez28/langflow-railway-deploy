# Langflow on Railway.
#
# Upstream's published image is complete — it needs no rebuild. What it does not
# have is a boot-time step, and on Railway two are unavoidable:
#
#   1. The image runs as uid 1000 and pre-creates LANGFLOW_CONFIG_DIR so a Docker
#      named volume inherits that ownership. A Railway volume is mounted root:root
#      instead, so the first boot dies on
#      `PermissionError: [Errno 13] Permission denied: '/app/langflow/secret_key'`.
#   2. LANGFLOW_SECRET_KEY is handed straight to Fernet once it is 32 characters
#      or longer, which only accepts 32 decoded bytes of urlsafe base64. The
#      obvious operator value (`openssl rand -hex 32`, 64 characters) deploys
#      green and then raises the first time a credential is encrypted.
#
# Both are shell, so this is `FROM <published image>` plus one entrypoint rather
# than a fork of upstream's build.
FROM langflowai/langflow:latest

USER root

# Langflow's workers spawn stdio MCP servers (the image ships Node so components
# can `npx` them). A worker killed mid-flight reparents those onto PID 1, and the
# process that ends up there is CPython, which reaps nothing.
ARG TINI_VERSION=v0.19.0
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64)  tini_arch=amd64 ;; \
        aarch64) tini_arch=arm64 ;; \
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/tini \
        "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-${tini_arch}"; \
    curl -fsSL -o /tmp/tini.sha256sum \
        "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-${tini_arch}.sha256sum"; \
    sed "s#tini-static-${tini_arch}#tini#" /tmp/tini.sha256sum > /tmp/tini.check; \
    (cd /usr/local/bin && sha256sum -c /tmp/tini.check); \
    rm -f /tmp/tini.sha256sum /tmp/tini.check; \
    chmod 0755 /usr/local/bin/tini

COPY entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod 0755 /usr/local/bin/railway-entrypoint.sh

# The entrypoint needs root to chown the mounted volume and drops back to uid
# 1000 before exec'ing Langflow, so the app itself never runs as root.
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["langflow", "run"]
