#!/usr/bin/env bash
# Anyrest — Certificate Generator
# Generates a local CA and a server TLS certificate with IP SANs so that
# browsers trust it without a domain name.
#
# Usage:
#   ./gen-certs.sh [--ip <extra-ip>] [--days <validity>] [--out <dir>]
#
# Defaults:
#   --days  3650  (10 years)
#   --out   ./    (directory of this script)
set -euo pipefail

VALIDITY_DAYS=3650
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTRA_IPS=""       # space-separated extras

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)    EXTRA_IPS="$EXTRA_IPS $2"; shift 2 ;;
    --days)  VALIDITY_DAYS="$2";        shift 2 ;;
    --out)   OUT_DIR="$2";              shift 2 ;;
    *)       echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

###############################################################################
# Collect IPs — no process substitution, works in any bash env
###############################################################################
collect_ips() {
  # Always include loopback
  echo "127.0.0.1"
  echo "::1"

  # Linux: ip command
  if command -v ip &>/dev/null; then
    ip -o -4 addr show scope global 2>/dev/null \
      | awk '{print $4}' | cut -d/ -f1 || true
  elif command -v ifconfig &>/dev/null; then
    ifconfig 2>/dev/null \
      | awk '/inet / {print $2}' | grep -v '^127\.' || true
  fi

  # Caller-supplied extras
  for ip in $EXTRA_IPS; do
    echo "$ip"
  done
}

###############################################################################
# Build openssl.cnf — avoids process substitution with a tmp file
###############################################################################
build_openssl_cnf() {
  # Collect unique IPs into a temp file
  local ip_file
  ip_file="$(mktemp)"
  collect_ips | sort -u > "$ip_file"

  # Build [alt_names] section
  local alt_names=""
  local idx=1
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    alt_names="${alt_names}IP.${idx} = ${ip}
"
    idx=$((idx + 1))
  done < "$ip_file"
  rm -f "$ip_file"

  cat > openssl.cnf << OPENSSLCNF
[ req ]
default_bits        = 4096
default_md          = sha256
prompt              = no
distinguished_name  = req_distinguished_name
x509_extensions     = v3_ca
req_extensions      = v3_req

[ req_distinguished_name ]
C  = RU
ST = Russia
L  = Moscow
O  = Anyrest Local CA
CN = Anyrest Root CA

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, keyCertSign, cRLSign

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment, keyAgreement
extendedKeyUsage = serverAuth, clientAuth
subjectAltName   = @alt_names

[ server_cert ]
basicConstraints       = CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment, keyAgreement
extendedKeyUsage       = serverAuth, clientAuth
subjectAltName         = @alt_names
authorityKeyIdentifier = keyid,issuer

[ alt_names ]
${alt_names}
OPENSSLCNF
}

###############################################################################
# Generate CA
###############################################################################
generate_ca() {
  echo "[certs] Generating CA key..."
  openssl genrsa -out ca.key 4096 2>/dev/null

  echo "[certs] Generating CA certificate..."
  openssl req -new -x509 \
    -key ca.key \
    -out ca.crt \
    -days "$VALIDITY_DAYS" \
    -config openssl.cnf \
    -extensions v3_ca \
    2>/dev/null

  echo "[certs] CA: $OUT_DIR/ca.crt"
}

###############################################################################
# Generate server certificate signed by our CA
###############################################################################
generate_server_cert() {
  echo "[certs] Generating server key..."
  openssl genrsa -out server.key 4096 2>/dev/null

  echo "[certs] Generating CSR..."
  openssl req -new \
    -key server.key \
    -out server.csr \
    -config openssl.cnf \
    -subj "/C=RU/ST=Russia/L=Moscow/O=Anyrest/CN=anyrest-server" \
    2>/dev/null

  echo "[certs] Signing server certificate with CA..."
  openssl x509 -req \
    -in server.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out server.crt \
    -days "$VALIDITY_DAYS" \
    -sha256 \
    -extfile openssl.cnf \
    -extensions server_cert \
    2>/dev/null

  rm -f server.csr ca.srl
  echo "[certs] Server cert: $OUT_DIR/server.crt"
}

###############################################################################
# Install CA into the system trust store
###############################################################################
install_ca() {
  local ca="$OUT_DIR/ca.crt"
  echo "[certs] Installing CA into system trust store..."

  # Choose sudo or run as root
  local S=""
  [[ "$(id -u)" -ne 0 ]] && command -v sudo &>/dev/null && S="sudo"

  if [[ "$(uname -s)" == "Linux" ]]; then
    if command -v update-ca-certificates &>/dev/null; then
      $S cp "$ca" /usr/local/share/ca-certificates/anyrest-ca.crt 2>/dev/null || \
        { echo "[certs] WARNING: cannot write to trust store (need sudo?). CA NOT installed."; return; }
      $S update-ca-certificates 2>/dev/null || true
    elif command -v update-ca-trust &>/dev/null; then
      $S cp "$ca" /etc/pki/ca-trust/source/anchors/anyrest-ca.crt 2>/dev/null || \
        { echo "[certs] WARNING: cannot write to trust store (need sudo?). CA NOT installed."; return; }
      $S update-ca-trust extract 2>/dev/null || true
    else
      echo "[certs] WARNING: cannot detect CA update tool. Add $ca manually."
    fi

    # NSS (Chrome / Firefox on Linux)
    if command -v certutil &>/dev/null; then
      for d in "$HOME/.pki/nssdb" "$HOME/.mozilla/firefox/"*; do
        [[ -d "$d" ]] && \
          certutil -A -d "sql:$d" -n "Anyrest Root CA" -t "CT,," -i "$ca" \
            2>/dev/null && echo "[certs] NSS installed: $d" || true
      done
    fi

  elif [[ "$(uname -s)" == "Darwin" ]]; then
    $S security add-trusted-cert -d -r trustRoot \
      -k /Library/Keychains/System.keychain "$ca" 2>/dev/null || true
    echo "[certs] Installed into macOS Keychain."
  fi
}

###############################################################################
# Summary
###############################################################################
print_summary() {
  echo ""
  echo "========================================="
  echo " Anyrest Certificates"
  echo "========================================="
  echo "CA fingerprint (SHA-256):"
  openssl x509 -in ca.crt -fingerprint -sha256 -noout 2>/dev/null | sed 's/^/  /' || true
  echo ""
  echo "Server SANs:"
  openssl x509 -in server.crt -text -noout 2>/dev/null \
    | grep -A5 "Subject Alternative Name" | head -6 | sed 's/^/  /' || true
  echo ""
  echo "Validity : $VALIDITY_DAYS days"
  echo "Output   : $OUT_DIR"
  echo "========================================="
}

###############################################################################
main() {
  echo "[certs] Starting..."
  build_openssl_cnf
  generate_ca
  generate_server_cert
  install_ca
  print_summary
  echo "[certs] Done."
}

main
