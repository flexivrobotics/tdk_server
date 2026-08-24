#!/usr/bin/env bash
# Install the TDK Server package, config, certificates, and systemd unit.
#
# Prerequisites:
#   - Run generate_server_client_cert.sh first
#
# Usage:
#   sudo bash scripts/install_tdk_server.sh
#   sudo bash scripts/install_tdk_server.sh /path/to/tdk-server_<ver>_<arch>.deb
#   sudo bash scripts/install_tdk_server.sh [DEB_URL]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION_FILE="${REPO_DIR}/VERSION"
PKG_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}" 2>&1)" || {
    echo "ERROR: cannot read version from '${VERSION_FILE}'" >&2
    echo "DETAILS: ${PKG_VERSION}" >&2
    exit 1
}
if [ -z "${PKG_VERSION}" ]; then
    echo "ERROR: version file '${VERSION_FILE}' is empty" >&2
    exit 1
fi

PACKAGES_DIR="${REPO_DIR}/packages"
DEFAULT_DEB_URL="https://github.com/flexivrobotics/tdk_server/releases/download/v${PKG_VERSION}/tdk-server_${PKG_VERSION}_amd64.deb"

DEB_URL="${1:-${DEFAULT_DEB_URL}}"
CONFIG_SRC="${REPO_DIR}/generated/config.json5"
SERVER_DIR="${REPO_DIR}/generated/server"
LICENSES_DIR="${REPO_DIR}/licenses"
PACKAGE_NAME="tdk-server"
TDK_SERVER_BIN="/opt/tdk-server/bin/tdk-server"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_warn "Root privileges required; retrying with sudo..."
    exec sudo -E bash "$0" "$@"
fi

download_deb() {
    local url="$1"
    local dest="$2"
    local filename
    filename="$(basename "${url%%\?*}")"

    if [[ -z "${filename}" || "${filename}" != *.deb ]]; then
        log_err "URL must point to a .deb asset: ${url}"
        exit 1
    fi

    mkdir -p "$(dirname "${dest}")"
    log_info "Downloading ${filename}"
    echo "  from: ${url}"
    echo "  to  : ${dest}"

    if command -v curl &>/dev/null; then
        if ! curl -fL --progress-bar -o "${dest}" "${url}"; then
            log_err "Download failed: ${url}"
            rm -f "${dest}"
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if ! wget --show-progress -O "${dest}" "${url}"; then
            log_err "Download failed: ${url}"
            rm -f "${dest}"
            exit 1
        fi
    else
        log_err "Neither curl nor wget is available; install one and retry."
        exit 1
    fi

    if [[ ! -s "${dest}" ]]; then
        log_err "Downloaded file is empty: ${dest}"
        rm -f "${dest}"
        exit 1
    fi

    log_info "Download complete: ${dest}"
}

resolve_deb_path() {
    local path="$1"
    if [[ ! -f "${path}" ]]; then
        log_err "Package not found: ${path}"
        exit 1
    fi
    if [[ "${path}" != *.deb ]]; then
        log_err "Expected a .deb file: ${path}"
        exit 1
    fi
    if [[ ! -s "${path}" ]]; then
        log_err "Package is empty: ${path}"
        exit 1
    fi
    # Absolute path so later steps do not depend on cwd.
    echo "$(cd "$(dirname "${path}")" && pwd)/$(basename "${path}")"
}

USER_ARG="${1:-}"
if [[ -n "${USER_ARG}" && -f "${USER_ARG}" ]]; then
    DEB_PACKAGE="$(resolve_deb_path "${USER_ARG}")"
    log_info "Skipping GitHub download; using local package: ${DEB_PACKAGE}"
else
    if [[ -n "${USER_ARG}" && "${USER_ARG}" != http://* && "${USER_ARG}" != https://* ]]; then
        log_err "Not a local .deb path or http(s) URL: ${USER_ARG}"
        echo "Usage: sudo bash scripts/install_tdk_server.sh [/path/to/tdk-server.deb]" >&2
        exit 1
    fi
    DEB_FILENAME="$(basename "${DEB_URL%%\?*}")"
    DEB_PACKAGE="${PACKAGES_DIR}/${DEB_FILENAME}"
    download_deb "${DEB_URL}" "${DEB_PACKAGE}"
fi

if [[ ! -f "${CONFIG_SRC}" ]]; then
    log_err "Missing ${CONFIG_SRC}. Run scripts/generate_server_client_cert.sh first."
    exit 1
fi
for f in ca.pem server.cert.pem server.key.pem; do
    if [[ ! -f "${SERVER_DIR}/${f}" ]]; then
        log_err "Missing ${SERVER_DIR}/${f}. Run scripts/generate_server_client_cert.sh first."
        exit 1
    fi
done

log_info "Installing ${PACKAGE_NAME} from ${DEB_PACKAGE}"
dpkg -i "${DEB_PACKAGE}"

if [[ ! -x "${TDK_SERVER_BIN}" ]]; then
    log_err "TDK Server binary not found: ${TDK_SERVER_BIN}"
    exit 1
fi

log_info "Installing config and certificates under /etc/tdk-server"
install -d -m 0755 /etc/tdk-server
install -d -m 0750 /etc/tdk-server/certs
install -m 0644 "${CONFIG_SRC}" /etc/tdk-server/config.json5
install -m 0644 "${SERVER_DIR}/ca.pem" /etc/tdk-server/certs/ca.pem
install -m 0644 "${SERVER_DIR}/server.cert.pem" /etc/tdk-server/certs/server.cert.pem
install -m 0600 "${SERVER_DIR}/server.key.pem" /etc/tdk-server/certs/server.key.pem

# Ensure open-source notices are present even if the .deb was built without them.
if [[ -d "${LICENSES_DIR}" ]]; then
    log_info "Installing third-party notices under /usr/share/doc/tdk-server"
    install -d -m 0755 /usr/share/doc/tdk-server
    install -m 0644 "${LICENSES_DIR}/"* /usr/share/doc/tdk-server/
fi

LOG_DIR="/var/log/tdk-server"
LOG_FILE="${LOG_DIR}/tdk-server.log"
SERVICE_FILE="/etc/systemd/system/tdk-server.service"
install -d -m 0755 "${LOG_DIR}"
touch "${LOG_FILE}"
chmod 664 "${LOG_FILE}"

log_info "Creating systemd unit ${SERVICE_FILE}"
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Flexiv TDK Server
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5
Environment="RUST_LOG=info"
Environment="RUST_LOG_STYLE=never"
Environment="NO_COLOR=1"
ExecStart=${TDK_SERVER_BIN} -c /etc/tdk-server/config.json5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "${SERVICE_FILE}"

systemctl daemon-reload
systemctl enable tdk-server.service
systemctl restart tdk-server.service

if command -v ufw &>/dev/null; then
    log_info "Opening UDP/TCP 7449 in UFW"
    ufw allow 7449/tcp || true
    ufw allow 7449/udp || true
else
    log_warn "UFW not found; open TCP/UDP port 7449 on your cloud security group / firewall."
fi

log_info "TDK Server installed."
echo "  package : ${DEB_PACKAGE}"
echo "  status  : systemctl status tdk-server"
echo "  logs    : tail -f ${LOG_FILE}"
echo "  notices : /usr/share/doc/tdk-server/THIRD_PARTY_NOTICES.txt"
