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
# Voidframe Standalone Installer & Interactive Wizard (Debian 13 Trixie)
# ==============================================================================
# Transforms an existing minimal/headless Debian 13 (Trixie) installation into
# Voidframe (Lemurs on tty2 -> Cage Wayland Kiosk -> Foot -> TUIOS + Ratatui).
#
# Quick one-liner usage:
#   curl -fsSL https://raw.githubusercontent.com/voidwave-lab/voidframe-linux/main/install.sh -o install.sh
#   sudo bash install.sh
#
# Or piped directly (reads interactive input from /dev/tty):
#   curl -fsSL https://raw.githubusercontent.com/voidwave-lab/voidframe-linux/main/install.sh | sudo bash
#
# Unattended / non-interactive mode:
#   curl -fsSL https://raw.githubusercontent.com/voidwave-lab/voidframe-linux/main/install.sh | sudo bash -s -- --yes --user void
# ==============================================================================

DISTRO_NAME="${DISTRO_NAME:-voidframe}"
DISTRO_VERSION="${DISTRO_VERSION:-0.1.0}"
GITHUB_REPO="${GITHUB_REPO:-voidwave-lab/voidframe-linux}"
GIT_REF="${GIT_REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/voidframe}"
LOG_FILE="${LOG_FILE:-/var/log/voidframe-install.log}"

TARGET_USER="${TARGET_USER:-}"
DEBS_SOURCE_DIR="${DEBS_SOURCE_DIR:-}"
KEEP_EXISTING_NETWORK="${KEEP_EXISTING_NETWORK:-false}"
UPDATE_HOSTNAME="${UPDATE_HOSTNAME:-ask}" # ask | true | false
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
ASSUME_YES="false"
USE_TUI="true"
AUTO_REBOOT="ask" # ask | true | false

# --- Logging Helpers ---
info()  { printf "\033[1;36m[%s][INSTALL]\033[0m %s\n" "${DISTRO_NAME}" "$*"; }
warn()  { printf "\033[1;33m[%s][WARN]\033[0m    %s\n" "${DISTRO_NAME}" "$*" >&2; }
error() { printf "\033[1;31m[%s][ERROR]\033[0m   %s\n" "${DISTRO_NAME}" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Voidframe Standalone Installer & Wizard (v${DISTRO_VERSION})
Transforms a minimal headless Debian 13 (Trixie) system into Voidframe TUI OS.

Usage:
  sudo bash install.sh [OPTIONS]

Options:
  -y, --yes                  Unattended mode (skip interactive wizard, accept defaults)
  -u, --user <username>      Target non-root user to configure (auto-detected if omitted)
  -d, --distro <name>        Distro branding name (default: ${DISTRO_NAME})
  -r, --repo <owner/repo>    GitHub repository slug (default: ${GITHUB_REPO})
  -b, --branch <ref>         Git branch or tag to fetch (default: ${GIT_REF})
      --install-dir <path>   Destination path for Voidframe files (default: ${INSTALL_DIR})
      --debs-dir <path>      Optional local directory with pre-built .deb packages
      --keep-network         Keep existing /etc/network/interfaces instead of iwd/networkd
      --set-hostname <name>  Set system hostname to <name>
      --keep-hostname        Keep existing system hostname without prompting
      --no-tui               Use plain CLI prompts instead of whiptail TUI dialogs
      --reboot               Automatically reboot when installation finishes
      --no-reboot            Do not reboot or prompt for reboot at the end
  -h, --help                 Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            ASSUME_YES="true"
            shift
            ;;
        -u|--user)
            TARGET_USER="$2"
            shift 2
            ;;
        -d|--distro)
            DISTRO_NAME="$2"
            shift 2
            ;;
        -r|--repo)
            GITHUB_REPO="$2"
            shift 2
            ;;
        -b|--branch)
            GIT_REF="$2"
            shift 2
            ;;
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --debs-dir)
            DEBS_SOURCE_DIR="$2"
            shift 2
            ;;
        --keep-network)
            KEEP_EXISTING_NETWORK="true"
            shift
            ;;
        --set-hostname)
            UPDATE_HOSTNAME="true"
            NEW_HOSTNAME="$2"
            shift 2
            ;;
        --keep-hostname)
            UPDATE_HOSTNAME="false"
            shift
            ;;
        --no-tui)
            USE_TUI="false"
            shift
            ;;
        --reboot)
            AUTO_REBOOT="true"
            shift
            ;;
        --no-reboot)
            AUTO_REBOOT="false"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1 (run with --help for usage)"
            ;;
    esac
done

# --- Check Root Privileges ---
ensure_root() {
    local current_uid
    current_uid="$(id -u)"
    if [[ "${current_uid}" -ne 0 ]]; then
        error "This installer must be run as root (e.g., 'sudo bash install.sh')."
    fi
}

# --- Detect Interactive Terminal (/dev/tty) ---
has_tty() {
    if [[ "${ASSUME_YES}" == "true" ]]; then
        return 1
    fi
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        return 0
    fi
    return 1
}

can_use_whiptail() {
    if [[ "${USE_TUI}" != "true" ]] || ! has_tty; then
        return 1
    fi
    if command -v whiptail >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# --- Prompt Helpers (whiptail with /dev/tty CLI fallback) ---
prompt_input() {
    local title="$1"
    local prompt_text="$2"
    local default_val="$3"
    local result=""

    if can_use_whiptail; then
        if result="$(whiptail --title "${title}" --inputbox "${prompt_text}" 12 72 "${default_val}" 3>&1 1>&2 2>&3 </dev/tty >/dev/tty)"; then
            printf "%s\n" "${result:-${default_val}}"
            return 0
        else
            error "Installation cancelled by user."
        fi
    elif has_tty; then
        printf "\n\033[1;36m==> %s\033[0m\n" "${title}" >/dev/tty
        printf "%s [%s]: " "${prompt_text}" "${default_val}" >/dev/tty
        IFS= read -r result </dev/tty || true
        printf "%s\n" "${result:-${default_val}}"
        return 0
    else
        printf "%s\n" "${default_val}"
        return 0
    fi
}

prompt_yesno() {
    local title="$1"
    local prompt_text="$2"
    local default_yes="${3:-true}" # true | false

    if can_use_whiptail; then
        local wt_args=(--title "${title}")
        if [[ "${default_yes}" != "true" ]]; then
            wt_args+=(--defaultno)
        fi
        if whiptail "${wt_args[@]}" --yesno "${prompt_text}" 15 74 </dev/tty >/dev/tty; then
            return 0
        else
            return 1
        fi
    elif has_tty; then
        local hint="[Y/n]"
        [[ "${default_yes}" != "true" ]] && hint="[y/N]"
        printf "\n\033[1;36m==> %s\033[0m\n" "${title}" >/dev/tty
        printf "%s %s: " "${prompt_text}" "${hint}" >/dev/tty
        local ans=""
        IFS= read -r ans </dev/tty || true
        if [[ -z "${ans}" ]]; then
            if [[ "${default_yes}" == "true" ]]; then
                return 0
            else
                return 1
            fi
        fi
        case "${ans}" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            *) return 1 ;;
        esac
    else
        if [[ "${default_yes}" == "true" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

prompt_password() {
    local title="$1"
    local prompt_text="$2"
    local pass=""

    if can_use_whiptail; then
        if pass="$(whiptail --title "${title}" --passwordbox "${prompt_text}" 12 72 3>&1 1>&2 2>&3 </dev/tty >/dev/tty)"; then
            printf "%s\n" "${pass}"
            return 0
        else
            error "Password entry cancelled by user."
        fi
    elif has_tty; then
        printf "\n\033[1;36m==> %s\033[0m\n" "${title}" >/dev/tty
        printf "%s: " "${prompt_text}" >/dev/tty
        IFS= read -rs pass </dev/tty || true
        printf "\n" >/dev/tty
        printf "%s\n" "${pass}"
        return 0
    else
        printf "voidframe\n"
        return 0
    fi
}

# --- Step 1: Verify Debian 13 (Trixie) & Architecture ---
verify_environment() {
    info "Checking system compatibility..."

    if [[ ! -f /etc/os-release ]]; then
        error "/etc/os-release not found. This installer requires Debian 13 (Trixie)."
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    local os_id="${ID:-unknown}"
    local os_codename="${VERSION_CODENAME:-unknown}"
    local os_pretty="${PRETTY_NAME:-Debian}"

    if [[ "${os_id}" != "debian" ]]; then
        warn "Detected OS '${os_pretty}' (ID=${os_id}), expected Debian 13 (trixie)."
        if ! prompt_yesno "Unsupported Distribution Warning" \
            "Detected OS: ${os_pretty}\n\nVoidframe is designed for Debian 13 (Trixie). Continue anyway?" "false"; then
            error "Aborted due to distribution mismatch."
        fi
    elif [[ "${os_codename}" != "trixie" && "${os_codename}" != "forky" && "${os_codename}" != "sid" ]]; then
        warn "Detected Debian '${os_codename}', expected 'trixie' (Debian 13)."
        if ! prompt_yesno "Debian Release Warning" \
            "Detected Debian release: ${os_pretty} (${os_codename})\n\nVoidframe targets Debian 13 (Trixie). Continue anyway?" "false"; then
            error "Aborted due to Debian release mismatch."
        fi
    fi

    local arch
    arch="$(dpkg --print-architecture)"
    if [[ "${arch}" != "amd64" && "${arch}" != "arm64" ]]; then
        error "Unsupported architecture '${arch}'. Voidframe pre-built packages support 'amd64' and 'arm64'."
    fi

    export ARCH="${arch}"
    export OS_PRETTY="${os_pretty}"
    info "Detected compatible host: ${OS_PRETTY} (${ARCH})"
}

# --- Step 2: Install Minimal Bootstrap Prerequisites ---
install_bootstrap_prereqs() {
    local missing_pkgs=()
    for cmd_pkg in "curl:curl" "git:git" "jq:jq" "tar:tar" "xz:xz-utils" "whiptail:whiptail"; do
        local cmd="${cmd_pkg%%:*}"
        local pkg="${cmd_pkg##*:}"
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing_pkgs+=("${pkg}")
        fi
    done

    if [[ ! -d /etc/ssl/certs ]]; then
        missing_pkgs+=("ca-certificates")
    fi

    if [[ "${#missing_pkgs[@]}" -gt 0 ]]; then
        info "Installing bootstrap prerequisites (${missing_pkgs[*]})..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends ca-certificates "${missing_pkgs[@]}"
    fi
}

# --- Step 3: Detect or Prompt for Target User ---
detect_default_user() {
    if [[ -n "${TARGET_USER}" ]]; then
        printf "%s\n" "${TARGET_USER}"
        return 0
    fi
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf "%s\n" "${SUDO_USER}"
        return 0
    fi
    local first_human
    first_human="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd || true)"
    if [[ -n "${first_human}" ]]; then
        printf "%s\n" "${first_human}"
        return 0
    fi
    printf "void\n"
}

run_wizard() {
    local default_user
    default_user="$(detect_default_user)"

    local current_hostname
    current_hostname="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || printf "debian")"

    if [[ "${ASSUME_YES}" == "true" ]] || ! has_tty; then
        TARGET_USER="${TARGET_USER:-${default_user}}"
        if [[ "${UPDATE_HOSTNAME}" == "ask" ]]; then
            UPDATE_HOSTNAME="false"
        fi
        NEW_HOSTNAME="${NEW_HOSTNAME:-${DISTRO_NAME}}"
        return 0
    fi

    # 1. Operator Username
    TARGET_USER="$(prompt_input \
        "Voidframe Installer — Operator Account" \
        "Host: ${OS_PRETTY} (${ARCH})\n\nEnter the non-root username that will run the Voidframe TUI session (If the user does not exist yet, it will be created automatically):" \
        "${default_user}")"

    # 2. Network Stack Selection
    if [[ "${KEEP_EXISTING_NETWORK}" != "true" ]]; then
        if can_use_whiptail; then
            local net_choice=""
            if net_choice="$(whiptail --title "Voidframe Installer — Network Stack" \
                --menu "Choose how Voidframe should configure networking:" 15 76 2 \
                "voidframe" "Enable iwd + systemd-networkd (Required for Impala Wi-Fi TUI)" \
                "keep"      "Keep current /etc/network/interfaces (Safe for SSH / custom VMs)" \
                3>&1 1>&2 2>&3 </dev/tty >/dev/tty)"; then
                if [[ "${net_choice}" == "keep" ]]; then
                    KEEP_EXISTING_NETWORK="true"
                fi
            else
                error "Installation cancelled by user."
            fi
        else
            if ! prompt_yesno "Network Stack Configuration" \
                "Replace wpa_supplicant/ifupdown with iwd + systemd-networkd (recommended for Impala Wi-Fi TUI; choose 'No' if installing over remote SSH with custom network config)?" "true"; then
                KEEP_EXISTING_NETWORK="true"
            fi
        fi
    fi

    # 3. Hostname Configuration
    if [[ "${UPDATE_HOSTNAME}" == "ask" ]]; then
        if [[ "${current_hostname}" != "${DISTRO_NAME}" ]]; then
            if prompt_yesno "Voidframe Installer — System Hostname" \
                "Current hostname is '${current_hostname}'.\n\nWould you like to update the system hostname to '${DISTRO_NAME}'?" "true"; then
                UPDATE_HOSTNAME="true"
                NEW_HOSTNAME="${DISTRO_NAME}"
            else
                UPDATE_HOSTNAME="false"
            fi
        else
            UPDATE_HOSTNAME="false"
        fi
    fi

    # 4. Final Confirmation Summary
    local net_summary="iwd + systemd-networkd (Voidframe default)"
    [[ "${KEEP_EXISTING_NETWORK}" == "true" ]] && net_summary="Keep existing network configuration"

    local host_summary="${current_hostname} (unchanged)"
    [[ "${UPDATE_HOSTNAME}" == "true" ]] && host_summary="${NEW_HOSTNAME:-${DISTRO_NAME}}"

    local summary_text="Ready to transform this Debian system into Voidframe:\n\n"
    summary_text+="  • Target OS:       ${OS_PRETTY} (${ARCH})\n"
    summary_text+="  • Operator User:   ${TARGET_USER}\n"
    summary_text+="  • Network Stack:   ${net_summary}\n"
    summary_text+="  • Hostname:        ${host_summary}\n"
    summary_text+="  • Install Path:    ${INSTALL_DIR}\n"
    summary_text+="  • Log File:        ${LOG_FILE}\n\n"
    summary_text+="Proceed with installation?"

    if ! prompt_yesno "Voidframe Installer — Confirm Transformation" "${summary_text}" "true"; then
        error "Installation cancelled by user."
    fi
}

# --- Step 4: Ensure Target User Exists ---
ensure_target_user() {
    if id -u "${TARGET_USER}" >/dev/null 2>&1; then
        info "Target operator user '${TARGET_USER}' already exists."
        return 0
    fi

    info "Creating operator user '${TARGET_USER}'..."
    useradd -m -s /bin/bash "${TARGET_USER}"

    if has_tty; then
        local pass1=""
        local pass2=""
        while true; do
            pass1="$(prompt_password "Create User '${TARGET_USER}'" "Enter a password for new user '${TARGET_USER}':")"
            if [[ -z "${pass1}" ]]; then
                warn "Password cannot be empty."
                continue
            fi
            pass2="$(prompt_password "Confirm Password" "Re-enter password for '${TARGET_USER}':")"
            if [[ "${pass1}" == "${pass2}" ]]; then
                printf "%s:%s\n" "${TARGET_USER}" "${pass1}" | chpasswd
                break
            else
                warn "Passwords did not match. Please try again."
            fi
        done
    else
        info "Non-interactive mode: setting default password '${DISTRO_NAME}' for '${TARGET_USER}'."
        printf "%s:%s\n" "${TARGET_USER}" "${DISTRO_NAME}" | chpasswd
    fi
}

# --- Step 5: Apply Hostname Update (If Requested) ---
apply_hostname() {
    if [[ "${UPDATE_HOSTNAME}" != "true" ]]; then
        return 0
    fi
    local target_host="${NEW_HOSTNAME:-${DISTRO_NAME}}"
    info "Setting system hostname to '${target_host}'..."
    printf "%s\n" "${target_host}" > /etc/hostname
    hostname "${target_host}" 2>/dev/null || true

    if [[ -f /etc/hosts ]]; then
        if grep -qE '^127\.0\.1\.1' /etc/hosts; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${target_host}/" /etc/hosts
        else
            printf "127.0.1.1\t%s\n" "${target_host}" >> /etc/hosts
        fi
    fi
}

# --- Step 6: Fetch or Stage Voidframe Repository in /opt/voidframe ---
prepare_repository() {
    local script_source=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        script_source="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    # Check if we are already executing from a full local clone
    if [[ -n "${script_source}" && -f "${script_source}/setup/bootstrap.sh" && -d "${script_source}/configs" ]]; then
        if [[ "${script_source}" != "${INSTALL_DIR}" ]]; then
            info "Copying local Voidframe checkout from ${script_source} to ${INSTALL_DIR}..."
            mkdir -p "${INSTALL_DIR}"
            cp -a "${script_source}/." "${INSTALL_DIR}/"
        else
            info "Using existing Voidframe checkout in ${INSTALL_DIR}..."
        fi
    else
        local repo_url="https://github.com/${GITHUB_REPO}.git"
        info "Fetching Voidframe repository (${GITHUB_REPO}@${GIT_REF}) into ${INSTALL_DIR}..."

        if [[ -d "${INSTALL_DIR}/.git" ]]; then
            info "Updating existing git repository in ${INSTALL_DIR}..."
            git -C "${INSTALL_DIR}" fetch --depth 1 origin "${GIT_REF}"
            git -C "${INSTALL_DIR}" reset --hard FETCH_HEAD
        else
            rm -rf "${INSTALL_DIR}"
            mkdir -p "$(dirname "${INSTALL_DIR}")"
            if ! git clone --depth 1 --branch "${GIT_REF}" "${repo_url}" "${INSTALL_DIR}" 2>/dev/null; then
                info "Git clone fallback: downloading tarball from GitHub..."
                mkdir -p "${INSTALL_DIR}"
                local tarball_url="https://github.com/${GITHUB_REPO}/archive/refs/heads/${GIT_REF}.tar.gz"
                curl -fsSL "${tarball_url}" | tar -xz --strip-components=1 -C "${INSTALL_DIR}"
            fi
        fi
    fi

    chmod +x "${INSTALL_DIR}/setup/"*.sh "${INSTALL_DIR}/configs/lemurs/wayland/tuios-session"
}

# --- Step 7: Run Voidframe Provisioning Pipeline ---
run_bootstrap() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    info "Starting Voidframe provisioning (logging to ${LOG_FILE})..."

    local bootstrap_args=(
        --online
        --user "${TARGET_USER}"
        --distro "${DISTRO_NAME}"
    )

    if [[ -n "${DEBS_SOURCE_DIR}" ]]; then
        bootstrap_args+=(--debs-dir "${DEBS_SOURCE_DIR}")
    fi
    if [[ "${KEEP_EXISTING_NETWORK}" == "true" ]]; then
        bootstrap_args+=(--keep-network)
    fi

    GITHUB_REPO="${GITHUB_REPO}" \
    KEEP_EXISTING_NETWORK="${KEEP_EXISTING_NETWORK}" \
    "${INSTALL_DIR}/setup/bootstrap.sh" "${bootstrap_args[@]}" 2>&1 | tee "${LOG_FILE}"
}

# --- Step 8: Post-Install Summary & Reboot Prompt ---
finish_installation() {
    info "=================================================================="
    info "${DISTRO_NAME} v${DISTRO_VERSION} installation completed!"
    info "Log saved to: ${LOG_FILE}"
    info "=================================================================="

    if [[ "${AUTO_REBOOT}" == "true" ]]; then
        info "Rebooting now..."
        systemctl reboot || reboot
    elif [[ "${AUTO_REBOOT}" == "ask" ]] && has_tty; then
        if prompt_yesno "Voidframe Installation Complete" \
            "Voidframe has been installed and configured for user '${TARGET_USER}'!\n\nOn reboot, Lemurs will start on tty2 and launch Cage -> Foot -> TUIOS.\n\nWould you like to reboot the system now?" "true"; then
            info "Rebooting system..."
            systemctl reboot || reboot
        else
            info "Reboot skipped. Run 'sudo reboot' whenever you are ready."
        fi
    else
        info "Run 'sudo reboot' to launch into Lemurs on tty2 -> Cage -> Foot -> TUIOS."
    fi
}

main() {
    ensure_root
    verify_environment
    install_bootstrap_prereqs
    run_wizard
    ensure_target_user
    apply_hostname
    prepare_repository
    run_bootstrap
    finish_installation
}

main "$@"
