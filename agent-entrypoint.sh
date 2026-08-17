#!/bin/sh
# Anyrest Agent entrypoint
# Installs the CA certificate (if mounted) so the agent trusts
# the self-signed HTTPS/WSS server, then starts the agent.
set -e

CA_PATH="/opt/anyrest/certs/ca.crt"

if [ -f "$CA_PATH" ]; then
    echo "[agent] Installing CA certificate..."
    cp "$CA_PATH" /usr/local/share/ca-certificates/anyrest-ca.crt
    update-ca-certificates -q 2>/dev/null || true
    echo "[agent] CA installed."
fi

exec /usr/local/bin/anyrest-agent "$@"
