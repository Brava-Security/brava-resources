#!/bin/bash
# Brava Edge Collector - Install Script
#
# This script detects your architecture and downloads the appropriate 
# self-extracting installer from Brava's release repository.
#
# Usage:
#   curl -sSL https://github.com/Brava-Security/brava-resources/releases/latest/download/install.sh | sudo bash -s -- --api-key <KEY>
#
# Or with environment variables:
#   export BRAVA_API_KEY="your-key"
#   curl -sSL https://github.com/Brava-Security/brava-resources/releases/latest/download/install.sh | sudo bash
#
# To install a specific version:
#   BRAVA_VERSION=v1.0.0 curl -sSL https://github.com/Brava-Security/brava-resources/releases/latest/download/install.sh | sudo bash
#
# Environment variables (optional):
#   BRAVA_VERSION       - Version to install (default: latest)
#   BRAVA_API_KEY       - API key for authentication
#   BRAVA_ROUTER_HOST   - Router hostname (required)
#   BRAVA_ROUTER_PORT   - Router port (default: 443)
#   BRAVA_TLS           - Enable TLS true/false (default: true)
#   BRAVA_PORT          - Syslog listen port (default: 5514)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    arm64)   ARCH="arm64" ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Detect OS
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
if [[ "$OS" != "linux" ]]; then
    log_error "This installer only supports Linux. OS detected: $OS"
    exit 1
fi

# Version and download URL
VERSION="${BRAVA_VERSION:-latest}"
BASE_URL="${BRAVA_RELEASES_URL:-https://github.com/Brava-Security/brava-resources/releases}"
if [[ "$VERSION" == "latest" ]]; then
    DOWNLOAD_URL="${BASE_URL}/latest/download/install-linux-${ARCH}.sh"
else
    DOWNLOAD_URL="${BASE_URL}/download/collector-${VERSION}/install-linux-${ARCH}.sh"
fi
INSTALLER_PATH="/tmp/brava-install-$$.sh"

log_info "Brava Edge Collector Installer"
log_info "Version: ${VERSION}"
log_info "Architecture: ${ARCH}"
log_info "Downloading from: ${DOWNLOAD_URL}"

# Download the self-extracting installer
if command -v curl &> /dev/null; then
    if ! curl -fsSL "$DOWNLOAD_URL" -o "$INSTALLER_PATH"; then
        log_error "Failed to download installer from $DOWNLOAD_URL"
        log_error "Please check the version and try again"
        exit 1
    fi
elif command -v wget &> /dev/null; then
    if ! wget -q "$DOWNLOAD_URL" -O "$INSTALLER_PATH"; then
        log_error "Failed to download installer from $DOWNLOAD_URL"
        log_error "Please check the version and try again"
        exit 1
    fi
else
    log_error "Neither curl nor wget found. Please install one of them."
    exit 1
fi

chmod +x "$INSTALLER_PATH"

log_info "Running installer..."

# Execute the self-extracting installer with all arguments
# Environment variables are automatically passed through
"$INSTALLER_PATH" "$@"
EXIT_CODE=$?

# Cleanup
rm -f "$INSTALLER_PATH"

exit $EXIT_CODE
