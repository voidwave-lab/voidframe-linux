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

DISTRO_NAME="${DISTRO_NAME:-voidframe}"
NERD_FONT_VERSION="${NERD_FONT_VERSION:-v3.3.0}"
NERD_FONT_NAME="${NERD_FONT_NAME:-JetBrainsMono}"

info()  { printf "\033[1;36m[%s][01-base]\033[0m %s\n" "${DISTRO_NAME}" "$*"; }
warn()  { printf "\033[1;33m[%s][01-base]\033[0m %s\n" "${DISTRO_NAME}" "$*" >&2; }
error() { printf "\033[1;31m[%s][01-base]\033[0m %s\n" "${DISTRO_NAME}" "$*" >&2; exit 1; }

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
    info "Updating APT package indices..."
    apt-get update -y

    info "Installing core system, Wayland, PipeWire, iwd, bluez, and CLI packages..."
    apt-get install -y --no-install-recommends "${BASE_PACKAGES[@]}"
}

install_nerd_font() {
    local font_dir="/usr/local/share/fonts/${NERD_FONT_NAME}NerdFont"
    if [[ -d "${font_dir}" ]] && compgen -G "${font_dir}/*.ttf" >/dev/null; then
        info "${NERD_FONT_NAME} Nerd Font already installed in ${font_dir}."
        return 0
    fi

    mkdir -p "${font_dir}"
    local tmp_archive="/tmp/${NERD_FONT_NAME}.tar.xz"

    # Check if an offline font archive was bundled on the ISO media
    local offline_font=""
    for candidate in \
        "/cdrom/${DISTRO_NAME}/fonts/${NERD_FONT_NAME}.tar.xz" \
        "/media/cdrom/${DISTRO_NAME}/fonts/${NERD_FONT_NAME}.tar.xz" \
        "${REPO_ROOT:-.}/dist/fonts/${NERD_FONT_NAME}.tar.xz"; do
        if [[ -f "${candidate}" ]]; then
            offline_font="${candidate}"
            break
        fi
    done

    if [[ -n "${offline_font}" ]]; then
        info "Extracting ${NERD_FONT_NAME} Nerd Font from offline bundle: ${offline_font}..."
        tar -xJf "${offline_font}" -C "${font_dir}"
    else
        local url="https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONT_VERSION}/${NERD_FONT_NAME}.tar.xz"
        info "Downloading ${NERD_FONT_NAME} Nerd Font (${NERD_FONT_VERSION}) from ${url}..."
        if curl -fsSL --retry 3 -o "${tmp_archive}" "${url}"; then
            tar -xJf "${tmp_archive}" -C "${font_dir}"
            rm -f "${tmp_archive}"
        else
            warn "Could not download ${NERD_FONT_NAME} Nerd Font (offline?). Falling back to system monospace fonts."
            return 0
        fi
    fi

    chmod 0644 "${font_dir}"/* 2>/dev/null || true
    info "Rebuilding system font cache (fc-cache -fv)..."
    fc-cache -fv >/dev/null
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
