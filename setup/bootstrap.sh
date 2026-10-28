#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Voidframe Master Bootstrap Entrypoint
# ==============================================================================
# Supports two execution modes:
#   1. Online post-install mode:
#      sudo ./setup/bootstrap.sh [--user <username>] [--distro <name>]
#   2. Offline ISO preseed late_command mode:
#      ./setup/bootstrap.sh --offline --debs-dir /cdrom/voidframe/debs
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Logging Helpers ---
info()  { printf "\033[1;36m[%s][INFO]\033[0m  %s\n" "${DISTRO_NAME:-voidframe}" "$*"; }
warn()  { printf "\033[1;33m[%s][WARN]\033[0m  %s\n" "${DISTRO_NAME:-voidframe}" "$*" >&2; }
error() { printf "\033[1;31m[%s][ERROR]\033[0m %s\n" "${DISTRO_NAME:-voidframe}" "$*" >&2; exit 1; }

# --- Privilege Check ---
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "bootstrap.sh must be executed as root (e.g., sudo ./setup/bootstrap.sh)."
fi

# --- Load config.mk Defaults ---
load_config_mk() {
    local cfg_file="${REPO_ROOT}/config.mk"
    if [[ -f "${cfg_file}" ]]; then
        while IFS= read -r line; do
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            if [[ "${line}" =~ ^([A-Z0-9_]+)[[:space:]]*\?=[[:space:]]*(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local val="${BASH_REMATCH[2]}"
                val="${val//\$(DISTRO_NAME)/${DISTRO_NAME:-voidframe}}"
                if [[ -z "${!key:-}" ]]; then
                    export "${key}=${val}"
                fi
            fi
        done < "${cfg_file}"
    fi
}

load_config_mk

# --- CLI Argument Parsing ---
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-auto}" # auto | online | offline
DEBS_SOURCE_DIR="${DEBS_SOURCE_DIR:-}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --offline              Run in offline ISO installer mode (use bundled .debs & fonts)
  --online               Run in online post-install mode (fetch from local dist or GitHub Releases)
  --debs-dir <path>      Directory containing pre-built .deb packages
  --user <username>      Target non-root user to configure (default: ${TARGET_USER:-void})
  --distro <name>        Distro name override (default: ${DISTRO_NAME:-voidframe})
  -h, --help             Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline)
            BOOTSTRAP_MODE="offline"
            shift
            ;;
        --online)
            BOOTSTRAP_MODE="online"
            shift
            ;;
        --debs-dir)
            DEBS_SOURCE_DIR="$2"
            shift 2
            ;;
        --user)
            TARGET_USER="$2"
            shift 2
            ;;
        --distro)
            DISTRO_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
done

export DISTRO_NAME="${DISTRO_NAME:-voidframe}"
export DISTRO_VERSION="${DISTRO_VERSION:-0.1.0}"
export DEBIAN_RELEASE="${DEBIAN_RELEASE:-trixie}"
export ARCH="${ARCH:-$(dpkg --print-architecture)}"
export GITHUB_REPO="${GITHUB_REPO:-voidframe/voidframe}"
export NERD_FONT_VERSION="${NERD_FONT_VERSION:-v3.3.0}"
export NERD_FONT_NAME="${NERD_FONT_NAME:-JetBrainsMono}"
export REPO_ROOT
export SCRIPT_DIR

# Auto-detect target user if not explicitly specified or if default 'void' doesn't exist
detect_target_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        TARGET_USER="${SUDO_USER}"
    elif ! id -u "${TARGET_USER:-void}" >/dev/null 2>&1; then
        local first_human
        first_human="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd || true)"
        if [[ -n "${first_human}" ]]; then
            TARGET_USER="${first_human}"
        else
            TARGET_USER="${TARGET_USER:-void}"
        fi
    fi
    export TARGET_USER
}

detect_target_user

# Auto-detect offline media if BOOTSTRAP_MODE=auto
if [[ "${BOOTSTRAP_MODE}" == "auto" ]]; then
    for candidate in \
        "/cdrom/${DISTRO_NAME}/debs" \
        "/media/cdrom/${DISTRO_NAME}/debs" \
        "/target/tmp/${DISTRO_NAME}/debs"; do
        if [[ -d "${candidate}" ]] && compgen -G "${candidate}/*.deb" >/dev/null; then
            BOOTSTRAP_MODE="offline"
            DEBS_SOURCE_DIR="${candidate}"
            break
        fi
    done
    if [[ "${BOOTSTRAP_MODE}" == "auto" ]]; then
        BOOTSTRAP_MODE="online"
    fi
fi

export BOOTSTRAP_MODE
export DEBS_SOURCE_DIR

info "=================================================================="
info "Provisioning ${DISTRO_NAME} v${DISTRO_VERSION} on Debian ${DEBIAN_RELEASE} (${ARCH})"
info "Mode:        ${BOOTSTRAP_MODE}"
info "Target User: ${TARGET_USER}"
[[ -n "${DEBS_SOURCE_DIR}" ]] && info "Debs Source: ${DEBS_SOURCE_DIR}"
info "=================================================================="

STEPS=(
    "01-base-packages.sh"
    "02-install-tuis.sh"
    "03-network-audio.sh"
    "04-display-manager.sh"
    "05-dotfiles.sh"
)

for step in "${STEPS[@]}"; do
    step_path="${SCRIPT_DIR}/${step}"
    if [[ ! -f "${step_path}" ]]; then
        error "Missing setup script: ${step_path}"
    fi
    info ">>> Running ${step} ..."
    bash "${step_path}"
    info "<<< Completed ${step}"
done

info "=================================================================="
info "${DISTRO_NAME} provisioning completed successfully!"
info "Reboot the system to launch Lemurs on tty2 -> Cage -> Foot -> TUIOS."
info "=================================================================="
