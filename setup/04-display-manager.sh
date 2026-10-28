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
# 04-display-manager.sh: Configure Lemurs TUI Display Manager & Cage Kiosk
# ==============================================================================
# - Configures /etc/pam.d/lemurs for systemd-logind & PipeWire session creation
# - Installs /etc/systemd/system/lemurs.service on tty2
# - Installs /etc/lemurs/config.toml and /etc/lemurs/wayland/tuios-session
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISTRO_NAME="${DISTRO_NAME:-voidframe}"

info()  { printf "\033[1;36m[%s][04-dm]\033[0m %s\n" "${DISTRO_NAME}" "$*"; }
warn()  { printf "\033[1;33m[%s][04-dm]\033[0m %s\n" "${DISTRO_NAME}" "$*" >&2; }
error() { printf "\033[1;31m[%s][04-dm]\033[0m %s\n" "${DISTRO_NAME}" "$*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root."
fi

install_pam_config() {
    info "Installing PAM configuration (/etc/pam.d/lemurs)..."
    mkdir -p /etc/pam.d
    cat > /etc/pam.d/lemurs <<'EOF'
#%PAM-1.0
auth       include      common-auth
account    include      common-account
password   include      common-password
session    required     pam_loginuid.so
session    include      common-session
-session   optional     pam_systemd.so
EOF
    chmod 0644 /etc/pam.d/lemurs
}

install_lemurs_configs() {
    info "Installing Lemurs configuration and Wayland kiosk session wrapper..."
    mkdir -p /etc/lemurs/wayland /etc/lemurs/wms /var/cache/lemurs

    install -Dm0644 "${REPO_ROOT}/configs/lemurs/config.toml" /etc/lemurs/config.toml
    install -Dm0755 "${REPO_ROOT}/configs/lemurs/wayland/tuios-session" /etc/lemurs/wayland/tuios-session
}

install_systemd_service() {
    info "Configuring lemurs.service on tty2..."
    mkdir -p /etc/systemd/system

    cat > /etc/systemd/system/lemurs.service <<'EOF'
[Unit]
Description=Lemurs TUI Display & Login Manager (Voidframe)
After=systemd-user-sessions.service plymouth-quit-wait.service getty@tty2.service seatd.service
Conflicts=getty@tty2.service

[Service]
Type=idle
ExecStart=/usr/bin/lemurs
StandardInput=tty
TTYPath=/dev/tty2
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
PAMName=lemurs
Restart=always
RestartSec=1

[Install]
WantedBy=graphical.target
Alias=display-manager.service
EOF

    chmod 0644 /etc/systemd/system/lemurs.service

    # Disable getty@tty2 so lemurs owns tty2 cleanly
    systemctl disable getty@tty2.service 2>/dev/null || true

    # Enable seatd for rootless Wayland DRM/input access via cage
    systemctl enable seatd.service 2>/dev/null || warn "seatd.service enable deferred."

    # Enable lemurs as the system display manager
    ln -sf /etc/systemd/system/lemurs.service /etc/systemd/system/display-manager.service
    systemctl enable lemurs.service 2>/dev/null || warn "lemurs.service symlinked as display-manager.service."
    systemctl set-default graphical.target 2>/dev/null || true
}

main() {
    install_pam_config
    install_lemurs_configs
    install_systemd_service
    info "Lemurs display manager and Wayland kiosk session configured on tty2."
}

main "$@"
