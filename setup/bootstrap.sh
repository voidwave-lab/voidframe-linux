#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Voidframe Maintainers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
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

# shellcheck source=setup/ui.sh
. "${SCRIPT_DIR}/ui.sh"

# --- Logging Helpers ---
info()  { ui_info "$*"; }
warn()  { ui_warn "$*"; }
error() { ui_error "$*"; }

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
KEEP_EXISTING_NETWORK="${KEEP_EXISTING_NETWORK:-false}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --offline              Run in offline ISO installer mode (use bundled .debs & fonts)
  --online               Run in online post-install mode (fetch from local dist or GitHub Releases)
  --debs-dir <path>      Directory containing pre-built .deb packages
  --user <username>      Target non-root user to configure (default: ${TARGET_USER:-void})
  --distro <name>        Distro name override (default: ${DISTRO_NAME:-voidframe})
  --keep-network         Preserve existing /etc/network/interfaces configuration
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
        --keep-network)
            KEEP_EXISTING_NETWORK="true"
            shift
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
export KEEP_EXISTING_NETWORK

# Auto-detect GitHub repository slug from git remote if not overridden
if [[ -z "${GITHUB_REPO:-}" || "${GITHUB_REPO}" == "voidframe/voidframe" || "${GITHUB_REPO}" == "voidwave-lab/voidframe-linux" ]]; then
    if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        remote_url="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
        if [[ "${remote_url}" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
            GITHUB_REPO="${BASH_REMATCH[1]}"
        fi
    fi
fi
export GITHUB_REPO="${GITHUB_REPO:-voidwave-lab/voidframe-linux}"
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

BOOT_START_TS="$(date +%s)"

ui_banner "${DISTRO_VERSION}" "${DEBIAN_RELEASE}" "${ARCH}" "${BOOTSTRAP_MODE}" "${TARGET_USER}"
if [[ -n "${DEBS_SOURCE_DIR}" ]]; then
    ui_info "Offline/local .deb directory: ${DEBS_SOURCE_DIR}"
fi

STAGE_SCRIPTS=(
    "01-base-packages.sh"
    "02-install-tuis.sh"
    "03-network-audio.sh"
    "04-display-manager.sh"
    "05-dotfiles.sh"
)

STAGE_TITLES=(
    "Base Packages, Wayland Kiosk & Nerd Fonts"
    "Pre-Built Ratatui & TUIOS Suite (.deb)"
    "Network (iwd), Bluetooth (BlueZ) & PipeWire Audio"
    "Lemurs TUI Display Manager (tty2) & Cage Session"
    "Unified Voidframe Dotfiles & Shell Environment"
)

STAGE_PCTS=(10 45 70 84 93)

total_stages="${#STAGE_SCRIPTS[@]}"
for (( idx = 0; idx < total_stages; idx++ )); do
    step="${STAGE_SCRIPTS[$idx]}"
    title="${STAGE_TITLES[$idx]}"
    pct="${STAGE_PCTS[$idx]}"
    stage_num=$(( idx + 1 ))
    step_path="${SCRIPT_DIR}/${step}"

    if [[ ! -f "${step_path}" ]]; then
        error "Missing setup script: ${step_path}"
    fi

    ui_stage "${stage_num}" "${total_stages}" "${pct}" "${title}"
    stage_start="$(date +%s)"
    bash "${step_path}"
    stage_elapsed=$(( $(date +%s) - stage_start ))
    ui_ok "Stage ${stage_num}/${total_stages} (${step}) completed in ${stage_elapsed}s"
done

TOTAL_ELAPSED=$(( $(date +%s) - BOOT_START_TS ))
ui_summary "${TOTAL_ELAPSED}"
