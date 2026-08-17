#!/usr/bin/env bash
# Anyrest — Certificate Generator
# Generates a local CA and a server TLS certificate with IP SANs.
# The CA is then installed into the system trust store so every browser
# on this machine trusts the certificate without needing a domain name.
#
# Usage:
#   ./gen-certs.sh [--ip <extra-ip>] [--days <validity>] [--out <dir>]
#
# Defaults:
#   --days  3650  (10 years)
#   --out   ./    (same directory as this script)
set -euo pipefail

###############################################################################
# Defaults
###############################################################################
VALIDITY_DAYS=3650
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRA_IPS=()

###############################################################################
# Argument parsing
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)    EXTRA_IPS+=("$2"); shift 2 ;;
    --days)  VALIDITY_DAYS="$2"; shift 2 ;;
    --out)   OUT_DIR="$2"; shift 2 ;;
    *)       echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

###############################################################################
# Collect all local IPs automatically
###############################################################################
collect_ips() {
  local ips=("127.0.0.1" "::1")

  # Linux / macOS
  if command -v ip &>/dev/null; then
    while IFS= read -r line; do
      ips+=("$line")
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    while IFS= read -r line; do
      ips+=("$line")
    done < <(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  elif command -v ifconfig &>/dev/null; then
    while IFS= read -r line; do
      ips+=("$line")
    done < <(ifconfig 2>/dev/null | grep 'inet ' | awk '{print $2}' | grep -v '127.0.0.1')
  fi

  # Append caller-supplied extras
  for ip in "${EXTRA_IPS[@]}"; do
    ips+=("$ip")
  done

  # Deduplicate
  printf '%s\n' "${ips[@]}" | sort -u
}

###############################################################################
# Build openssl.cnf with all discovered IPs as SANs
###############################################################################
build_openssl_cnf() {
  local alt_names=""
  local idx=1
  while IFS= read -r ip; do
    alt_names+="IP.${idx} = ${ip}\n"
    ((idx++))
  done < <(collect_ips)

  cat > openssl.cnf <<EOF
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
$(echo -e "$alt_names")
EOF
}

###############################################################################
# Generate CA key + self-signed certificate
###############################################################################
generate_ca() {
  echo "[certs] Generating CA key and certificate..."

  openssl genrsa -out ca.key 4096 2>/dev/null

  openssl req -new -x509 \
    -key ca.key \
    -out ca.crt \
    -days "$VALIDITY_DAYS" \
    -config openssl.cnf \
    -extensions v3_ca \
    2>/dev/null

  echo "[certs] CA certificate: $OUT_DIR/ca.crt"
}

###############################################################################
# Generate server key + CSR + sign with our CA
###############################################################################
generate_server_cert() {
  echo "[certs] Generating server key and certificate..."

  openssl genrsa -out server.key 4096 2>/dev/null

  openssl req -new \
    -key server.key \
    -out server.csr \
    -config openssl.cnf \
    -subj "/C=RU/ST=Russia/L=Moscow/O=Anyrest/CN=anyrest-server" \
    2>/dev/null

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

  echo "[certs] Server certificate: $OUT_DIR/server.crt"
  echo "[certs] Server key:         $OUT_DIR/server.key"
}

###############################################################################
# Install CA into the system trust store
###############################################################################
install_ca() {
  echo "[certs] Installing CA certificate into system trust store..."

  if [[ "$(uname -s)" == "Linux" ]]; then
    # Detect distro
    if command -v update-ca-certificates &>/dev/null; then
      # Debian / Ubuntu / Alpine
      sudo cp ca.crt /usr/local/share/ca-certificates/anyrest-ca.crt
      sudo update-ca-certificates
    elif command -v update-ca-trust &>/dev/null; then
      # RHEL / CentOS / Fedora
      sudo cp ca.crt /etc/pki/ca-trust/source/anchors/anyrest-ca.crt
      sudo update-ca-trust extract
    else
      echo "[certs] WARNING: unknown distro, copy ca.crt manually to your trust store."
    fi

    # NSS databases used by Chrome / Firefox on Linux
    if command -v certutil &>/dev/null; then
      for nssdb in \
        "$HOME/.pki/nssdb" \
        "$HOME/.mozilla/firefox/"*"/cert9.db"; do
        dir="$(dirname "$nssdb")"
        if [[ -d "$dir" ]]; then
          certutil -A -d "sql:$dir" -n "Anyrest Root CA" -t "CT,," -i ca.crt \
            2>/dev/null && echo "[certs] Installed into NSS db: $dir"
        fi
      done
    else
      echo "[certs] NOTE: install 'libnss3-tools' (certutil) for Chrome/Firefox support."
    fi

  elif [[ "$(uname -s)" == "Darwin" ]]; then
    sudo security add-trusted-cert -d -r trustRoot \
      -k /Library/Keychains/System.keychain ca.crt
    echo "[certs] Installed into macOS System Keychain."

  elif [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == CYGWIN* ]]; then
    certutil.exe -addstore -f "ROOT" ca.crt
    echo "[certs] Installed into Windows Certificate Store."

  else
    echo "[certs] Unsupported OS. Install ca.crt manually into your trust store."
  fi
}

###############################################################################
# Print a summary with fingerprint and SANs
###############################################################################
print_summary() {
  echo ""
  echo "========================================="
  echo " Anyrest Certificate Summary"
  echo "========================================="
  echo "CA  fingerprint (SHA-256):"
  openssl x509 -in ca.crt -fingerprint -sha256 -noout 2>/dev/null | sed 's/^/  /'
  echo ""
  echo "Server certificate SANs:"
  openssl x509 -in server.crt -text -noout 2>/dev/null \
    | grep -A 20 "Subject Alternative Name" | head -5 | sed 's/^/  /'
  echo ""
  echo "Validity: $VALIDITY_DAYS days"
  echo "Output:   $OUT_DIR"
  echo "========================================="
}

###############################################################################
# Main
###############################################################################
main() {
  echo "[certs] Anyrest certificate generator starting..."
  build_openssl_cnf
  generate_ca
  generate_server_cert
  install_ca
  print_summary
  echo "[certs] Done."
}

main
