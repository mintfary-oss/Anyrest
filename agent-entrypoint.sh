#!/bin/sh
# Anyrest Agent entrypoint
# Installs the CA certificate (if mounted at /opt/anyrest/certs/ca.crt)
# so the agent trusts the self-signed HTTPS/WSS server, then starts.
set -e

CA_PATH="/opt/anyrest/certs/ca.crt"
CA_DEST="/usr/local/share/ca-certificates/anyrest-ca.crt"

if [ -f "$CA_PATH" ]; then
    echo "[agent] Installing CA certificate..."
    mkdir -p "$(dirname "$CA_DEST")"
    cp "$CA_PATH" "$CA_DEST"
    update-ca-certificates -q 2>/dev/null || true
    echo "[agent] CA installed."
fi

exec /usr/local/bin/anyrest-agent "$@"
