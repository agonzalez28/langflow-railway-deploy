#!/bin/sh
# Runs as root, hands Langflow a writable volume and a usable secret key, then
# drops to the image's own unprivileged user before exec'ing the app.
set -eu

APP_UID=1000
APP_GID=0

CONFIG_DIR="${LANGFLOW_CONFIG_DIR:-/app/langflow}"
KB_DIR="${LANGFLOW_KNOWLEDGE_BASES_DIR:-$CONFIG_DIR/knowledge_bases}"
FS_TOOL_DIR="${LANGFLOW_FS_TOOL_BASE_DIR:-$CONFIG_DIR/fs_tool/fs_sandbox}"

# A Railway volume arrives root:root, so the first boot needs a recursive pass.
# Later boots skip it — a knowledge base can hold a lot of files, and nothing in
# the container creates anything under these paths as root. Decide before the
# per-directory pass below, which would otherwise fix the top-level owner and
# hide the very state being tested.
needs_recursive_chown=no
if [ ! -e "$CONFIG_DIR/.railway-owned" ] || [ "$(stat -c %u "$CONFIG_DIR")" != "$APP_UID" ]; then
    needs_recursive_chown=yes
fi

# HOME and the npm cache live in the image layer, but a component that writes to
# either fails the same way if the layer ever loses its ownership, so they are
# fixed up alongside the volume.
for dir in "$CONFIG_DIR" "$KB_DIR" "$FS_TOOL_DIR" "$HOME" /app/.npm; do
    [ -n "$dir" ] || continue
    mkdir -p "$dir"
    chown "$APP_UID:$APP_GID" "$dir"
    chmod g+rwX "$dir"
done

if [ "$needs_recursive_chown" = yes ]; then
    echo "railway-entrypoint: taking ownership of $CONFIG_DIR for uid $APP_UID"
    chown -R "$APP_UID:$APP_GID" "$CONFIG_DIR"
    chmod -R g+rwX "$CONFIG_DIR"
    : > "$CONFIG_DIR/.railway-owned"
    chown "$APP_UID:$APP_GID" "$CONFIG_DIR/.railway-owned"
fi

# Langflow only SHA-256s LANGFLOW_SECRET_KEY when it is shorter than 32
# characters; at 32 or more it pads the string to a base64 multiple and feeds it
# to Fernet, which accepts exactly 32 decoded bytes. So 43 urlsafe-base64
# characters work, 32/48/64 do not, and the failure surfaces at the first
# credential write rather than at boot. Rewrite only the values that would
# break — anything Langflow already handles is passed through untouched, so an
# existing deployment's encrypted credentials stay readable across an upgrade.
if [ -n "${LANGFLOW_SECRET_KEY:-}" ]; then
    LANGFLOW_SECRET_KEY="$(
        printf '%s' "$LANGFLOW_SECRET_KEY" | python3 -c '
import base64
import hashlib
import sys

value = sys.stdin.read().strip()

def usable(candidate: str) -> bool:
    if len(candidate) < 32:
        return True  # Langflow derives these with SHA-256 itself
    padded = candidate + "=" * (-len(candidate) % 4)
    try:
        return len(base64.urlsafe_b64decode(padded)) == 32
    except Exception:
        return False

if usable(value):
    sys.stdout.write(value)
else:
    digest = hashlib.sha256(value.encode()).digest()
    sys.stdout.write(base64.urlsafe_b64encode(digest).decode())
'
    )"
    export LANGFLOW_SECRET_KEY
fi

exec /usr/local/bin/tini -s -- \
    setpriv --reuid="$APP_UID" --regid="$APP_GID" --init-groups "$@"
