#!/usr/bin/env bash
# One-shot: create CA + server cert + leader/follower client packages,
# then print scp commands to copy client packages to your PC.
#
# Usage:
#   bash scripts/generate_server_client_cert.sh --ip YOUR.PUBLIC.IP
#   bash scripts/generate_server_client_cert.sh --ip YOUR.PUBLIC.IP --force
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CA_DIR="${REPO_DIR}/generated/ca"
SERVER_DIR="${REPO_DIR}/generated/server"
CLIENTS_DIR="${REPO_DIR}/generated/clients"
PACKAGE_DIR="${REPO_DIR}/generated/packages"
TEMPLATE="${REPO_DIR}/config/server.json5.template"
RENDERED_CONFIG="${REPO_DIR}/generated/config.json5"

# Private CA / leaf certs: long validity (≈100 years).
CERT_DAYS="${CERT_DAYS:-36500}"
KEY_BITS="${KEY_BITS:-4096}"

SERVER_IP=""
SERVER_DNS=""
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip) SERVER_IP="$2"; shift 2 ;;
        --dns) SERVER_DNS="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        -h|--help)
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${SERVER_IP}" ]]; then
    echo "ERROR: --ip <public-server-ipv4-address> is required" >&2
    exit 1
fi
if [[ ! -f "${TEMPLATE}" ]]; then
    echo "ERROR: missing template: ${TEMPLATE}" >&2
    exit 1
fi

SERVER_ENDPOINT="${SERVER_IP}:7449"
if [[ -n "${SERVER_DNS}" ]]; then
    SERVER_ENDPOINT="${SERVER_DNS}:7449"
fi

issue_client_package() {
    local name="$1"
    local out_dir="${CLIENTS_DIR}/${name}"
    mkdir -p "${out_dir}" "${PACKAGE_DIR}"

    local ext_file="${out_dir}/client_ext.cnf"
    cat > "${ext_file}" << EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

    openssl genrsa -out "${out_dir}/${name}.key.pem" "${KEY_BITS}"
    chmod 600 "${out_dir}/${name}.key.pem"

    openssl req -new -key "${out_dir}/${name}.key.pem" -out "${out_dir}/${name}.csr" \
        -subj "/CN=${name}"

    openssl x509 -req \
        -in "${out_dir}/${name}.csr" \
        -CA "${CA_DIR}/ca.pem" -CAkey "${CA_DIR}/ca.key" -CAcreateserial \
        -days "${CERT_DAYS}" \
        -extfile "${ext_file}" \
        -out "${out_dir}/${name}.cert.pem"

    rm -f "${out_dir}/${name}.csr" "${ext_file}"
    cp "${CA_DIR}/ca.pem" "${out_dir}/ca.pem"

    cat > "${out_dir}/client.conf" << EOF
# Auto-generated TDK client config.
# Paths are relative to this .conf file.
root_ca_certificate=ca.pem
client_certificate=${name}.cert.pem
client_private_key=${name}.key.pem
server=${SERVER_ENDPOINT}
EOF

    local staging="${PACKAGE_DIR}/${name}"
    rm -rf "${staging}"
    mkdir -p "${staging}"
    cp "${out_dir}/ca.pem" "${staging}/ca.pem"
    cp "${out_dir}/${name}.cert.pem" "${staging}/${name}.cert.pem"
    cp "${out_dir}/${name}.key.pem" "${staging}/${name}.key.pem"
    cp "${out_dir}/client.conf" "${staging}/client.conf"

    tar -czf "${PACKAGE_DIR}/${name}.tar.gz" -C "${PACKAGE_DIR}" "${name}"
    rm -rf "${staging}"
}

echo "════════════════════════════════════════"
echo "  TDK Server certificate generation"
echo "  validity: ${CERT_DAYS} days"
echo "════════════════════════════════════════"

# ── 1) CA ──────────────────────────────────────────────────────────
mkdir -p "${CA_DIR}"
chmod 700 "${CA_DIR}"

if [[ -f "${CA_DIR}/ca.key" || -f "${CA_DIR}/ca.pem" ]]; then
    if [[ "${FORCE}" -eq 1 ]]; then
        echo "[1/4] Recreating CA (--force)..."
        rm -f "${CA_DIR}/ca.key" "${CA_DIR}/ca.pem" "${CA_DIR}/ca.srl"
    else
        echo "[1/4] Reusing existing CA under ${CA_DIR}"
    fi
fi

if [[ ! -f "${CA_DIR}/ca.key" || ! -f "${CA_DIR}/ca.pem" ]]; then
    echo "[1/4] Creating CA..."
    openssl genrsa -out "${CA_DIR}/ca.key" "${KEY_BITS}"
    chmod 600 "${CA_DIR}/ca.key"
    openssl req -x509 -new -nodes -key "${CA_DIR}/ca.key" \
        -sha256 -days "${CERT_DAYS}" \
        -subj "/CN=TDK Server CA" \
        -out "${CA_DIR}/ca.pem"
else
    echo "[1/4] CA ready."
fi

# ── 2) Server cert + runtime config ────────────────────────────────
echo "[2/4] Issuing server certificate for ${SERVER_IP}..."
mkdir -p "${SERVER_DIR}"
chmod 700 "${SERVER_DIR}"

EXT_FILE="${SERVER_DIR}/server_ext.cnf"
{
    echo "basicConstraints = CA:FALSE"
    echo "keyUsage = digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = serverAuth, clientAuth"
    echo "subjectAltName = @alt_names"
    echo ""
    echo "[alt_names]"
    echo "IP.1 = ${SERVER_IP}"
    echo "DNS.1 = localhost"
    if [[ -n "${SERVER_DNS}" ]]; then
        echo "DNS.2 = ${SERVER_DNS}"
    fi
} > "${EXT_FILE}"

CN_VALUE="${SERVER_DNS:-${SERVER_IP}}"

openssl genrsa -out "${SERVER_DIR}/server.key.pem" "${KEY_BITS}"
chmod 600 "${SERVER_DIR}/server.key.pem"

openssl req -new -key "${SERVER_DIR}/server.key.pem" -out "${SERVER_DIR}/server.csr" \
    -subj "/CN=${CN_VALUE}"

openssl x509 -req \
    -in "${SERVER_DIR}/server.csr" \
    -CA "${CA_DIR}/ca.pem" -CAkey "${CA_DIR}/ca.key" -CAcreateserial \
    -days "${CERT_DAYS}" \
    -extfile "${EXT_FILE}" \
    -out "${SERVER_DIR}/server.cert.pem"

rm -f "${SERVER_DIR}/server.csr" "${EXT_FILE}"
cp "${CA_DIR}/ca.pem" "${SERVER_DIR}/ca.pem"

sed \
    -e "s|@CA_PEM@|/etc/tdk-server/certs/ca.pem|g" \
    -e "s|@SERVER_CERT@|/etc/tdk-server/certs/server.cert.pem|g" \
    -e "s|@SERVER_KEY@|/etc/tdk-server/certs/server.key.pem|g" \
    "${TEMPLATE}" > "${RENDERED_CONFIG}"

echo "${SERVER_ENDPOINT}" > "${SERVER_DIR}/public_endpoint.txt"

# ── 3) Leader + follower client packages ───────────────────────────
echo "[3/4] Issuing leader and follower client packages..."
issue_client_package "leader"
issue_client_package "follower"

SSH_USER="$(id -un)"
LEADER_REMOTE_PATH="${PACKAGE_DIR}/leader.tar.gz"
FOLLOWER_REMOTE_PATH="${PACKAGE_DIR}/follower.tar.gz"

echo "[4/4] Artifacts ready."
echo ""
echo "Server materials (for install_tdk_server.sh):"
echo "  ${SERVER_DIR}/ca.pem"
echo "  ${SERVER_DIR}/server.cert.pem"
echo "  ${SERVER_DIR}/server.key.pem"
echo "  ${RENDERED_CONFIG}"
echo "  endpoint: ${SERVER_ENDPOINT}"
echo ""
echo "Client packages on this server:"
echo "  ${LEADER_REMOTE_PATH}"
echo "  ${FOLLOWER_REMOTE_PATH}"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Copy client certificates to your PC with scp"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  Run the following on your LOCAL computer (not on this server)."
echo "  Replace /path/to/key.pem with your SSH private key if required."
echo ""
echo "  # Create a local folder"
echo "  mkdir -p ~/tdk-certs && cd ~/tdk-certs"
echo ""
echo "  # Download leader (operator PC) package"
echo "  scp -i /path/to/key.pem ${SSH_USER}@${SERVER_IP}:${LEADER_REMOTE_PATH} ."
echo ""
echo "  # Download follower (robot-side PC) package"
echo "  scp -i /path/to/key.pem ${SSH_USER}@${SERVER_IP}:${FOLLOWER_REMOTE_PATH} ."
echo ""
echo "  # If your SSH login uses a hostname instead of IP, e.g.:"
echo "  #   scp -i /path/to/key.pem ${SSH_USER}@your-server-hostname:${LEADER_REMOTE_PATH} ."
echo ""
echo "  # Extract and use with TDK"
echo "  tar -xzf leader.tar.gz"
echo "  tar -xzf follower.tar.gz"
echo "  # Pass leader/client.conf or follower/client.conf to TDK"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Next on this server:"
echo "  sudo bash scripts/install_tdk_server.sh"
