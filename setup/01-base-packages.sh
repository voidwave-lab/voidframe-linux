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
# 01-base-packages.sh: Base System Dependencies, Wayland Kiosk & Nerd Fonts
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export DISTRO_NAME="${DISTRO_NAME:-voidframe}"
NERD_FONT_VERSION="${NERD_FONT_VERSION:-v3.3.0}"
NERD_FONT_NAME="${NERD_FONT_NAME:-JetBrainsMono}"

# shellcheck source=setup/ui.sh
. "${SCRIPT_DIR}/ui.sh"

info()  { ui_info "$*"; }
warn()  { ui_warn "$*"; }
error() { ui_error "$*"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root."
fi

export DEBIAN_FRONTEND=noninteractive

BASE_PACKAGES=(
    # Wayland Kiosk & Terminal
    cage
    foot
    seatd
    xwayland
    wl-clipboard
    grim
    slurp
    brightnessctl
    libgl1-mesa-dri
    libegl-mesa0
    mesa-vulkan-drivers

    # Session, Auth & D-Bus
    dbus
    dbus-user-session
    libpam0g
    libpam-systemd
    polkitd
    systemd-resolved

    # Audio Stack (PipeWire + WirePlumber + Bluetooth Audio)
    pipewire
    pipewire-alsa
    pipewire-pulse
    pipewire-audio
    wireplumber
    libspa-0.2-bluetooth
    alsa-utils

    # Wireless & Bluetooth Daemons (for impala & bluetui)
    iwd
    bluez
    rfkill

    # Fonts & Rendering
    fontconfig
    fonts-noto-color-emoji
    fonts-dejavu-core

    # Core CLI & Yazi Preview / Navigation Helpers
    ca-certificates
    curl
    wget
    git
    jq
    file
    unzip
    xz-utils
    zstd
    7zip
    ripgrep
    fd-find
    fzf
    zoxide
    bat
    neovim
    poppler-utils
    ffmpeg
    less
     procps
    psmisc
    htop
    sudo
)

install_apt_packages() {
    # Ensure any residual 'deb cdrom:' lines in /etc/apt/sources.list are disabled
    if [[ -f /etc/apt/sources.list ]]; then
        sed -i '/^deb cdrom:/s/^/# /' /etc/apt/sources.list
        if ! grep -Eq '^deb https?://' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
            local codename="${DEBIAN_RELEASE:-trixie}"
            if [[ -f /etc/os-release ]]; then
                # shellcheck disable=SC1091
                codename="$(. /etc/os-release && printf "%s" "${VERSION_CODENAME:-trixie}")"
            fi
            info "No active HTTP APT mirror found in /etc/apt/sources.list; configuring deb.debian.org (${codename})..."
            cat >> /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${codename}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${codename}-security main contrib non-free non-free-firmware
EOF
        fi
    fi

    ui_progress 12 "Refreshing Debian APT package indices..."
    local apt_log="/var/log/${DISTRO_NAME}-apt.log"
    mkdir -p /var/log
    if ! apt-get update -y >> "${apt_log}" 2>&1; then
        tail -n 25 "${apt_log}" >&2 || true
        error "apt-get update failed (see ${apt_log})."
    fi
    ui_ok "APT package indices updated."

    ui_progress 16 "Installing ${#BASE_PACKAGES[@]} base packages (Wayland, PipeWire, iwd, BlueZ, CLI)..."
    local count=0
    local rc=0
    set +e
    apt-get install -y --no-install-recommends "${BASE_PACKAGES[@]}" 2>&1 | tee -a "${apt_log}" | while IFS= read -r line; do
        case "${line}" in
            Get:*|Unpacking*|Setting\ up*)
                count=$(( count + 1 ))
                if (( count % 6 == 1 )); then
                    local cur_pct=$(( 16 + (count * 22 / 140) ))
                    if (( cur_pct > 38 )); then
                        cur_pct=38
                    fi
                    local clean="${line%%$'\r'*}"
                    ui_progress "${cur_pct}" "${clean:0:64}"
                fi
                ;;
        esac
    done
    rc="${PIPESTATUS[0]}"
    set -e
    if [[ "${rc}" -ne 0 ]]; then
        tail -n 30 "${apt_log}" >&2 || true
        error "apt-get install failed with exit code ${rc} (see ${apt_log})."
    fi
    ui_ok "All ${#BASE_PACKAGES[@]} base system & Wayland packages installed."
}

install_nerd_font() {
    local font_dir="/usr/local/share/fonts/${NERD_FONT_NAME}NerdFont"
    if [[ -d "${font_dir}" ]] && compgen -G "${font_dir}/*.ttf" >/dev/null; then
        ui_ok "${NERD_FONT_NAME} Nerd Font already installed in ${font_dir}."
        return 0
    fi

    mkdir -p "${font_dir}"
    local tmp_archive="/tmp/${NERD_FONT_NAME}.tar.xz"

    # Check if an offline font archive was bundled on the ISO media or /opt/<distro>/fonts
    local offline_font=""
    for candidate in \
        "${REPO_ROOT}/fonts/${NERD_FONT_NAME}.tar.xz" \
        "/opt/${DISTRO_NAME}/fonts/${NERD_FONT_NAME}.tar.xz" \
        "/cdrom/${DISTRO_NAME}/fonts/${NERD_FONT_NAME}.tar.xz" \
        "/media/cdrom/${DISTRO_NAME}/fonts/${NERD_FONT_NAME}.tar.xz" \
        "${REPO_ROOT}/dist/fonts/${NERD_FONT_NAME}.tar.xz"; do
        if [[ -f "${candidate}" ]]; then
            offline_font="${candidate}"
            break
        fi
    done

    if [[ -n "${offline_font}" ]]; then
        ui_progress 40 "Extracting ${NERD_FONT_NAME} Nerd Font from local bundle..."
        tar -xJf "${offline_font}" -C "${font_dir}"
    else
        local url="https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONT_VERSION}/${NERD_FONT_NAME}.tar.xz"
        ui_progress 40 "Downloading ${NERD_FONT_NAME} Nerd Font (${NERD_FONT_VERSION})..."
        if curl -fsSL --retry 3 -o "${tmp_archive}" "${url}"; then
            tar -xJf "${tmp_archive}" -C "${font_dir}"
            rm -f "${tmp_archive}"
        else
            warn "Could not download ${NERD_FONT_NAME} Nerd Font (offline?). Falling back to system monospace fonts."
            return 0
        fi
    fi

    chmod 0644 "${font_dir}"/* 2>/dev/null || true
    ui_progress 43 "Rebuilding system fontconfig cache (fc-cache)..."
    fc-cache -fv >/dev/null
    ui_ok "${NERD_FONT_NAME} Nerd Font installed and indexed."
}

configure_debian_cli_symlinks() {
    # Debian installs fd-find as 'fdfind' and bat as 'batcat'; provide /usr/local/bin symlinks
    if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
        ln -sf "$(command -v fdfind)" /usr/local/bin/fd
    fi
    if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
        ln -sf "$(command -v batcat)" /usr/local/bin/bat
    fi
}

main() {
    install_apt_packages
    install_nerd_font
    configure_debian_cli_symlinks
    info "Base packages and fonts installed."
}

main "$@"
