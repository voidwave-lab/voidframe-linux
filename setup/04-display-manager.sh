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
# - Ensures DRM framebuffer modules & console=tty0 are active on boot
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export DISTRO_NAME="${DISTRO_NAME:-voidframe}"

# shellcheck source=setup/ui.sh
. "${SCRIPT_DIR}/ui.sh"

info()  { ui_info "$*"; }
warn()  { ui_warn "$*"; }
error() { ui_error "$*"; }

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
-session   optional     pam_loginuid.so
session    include      common-session
-session   optional     pam_systemd.so
EOF
    chmod 0644 /etc/pam.d/lemurs
}

install_lemurs_configs() {
    info "Installing Lemurs configuration and Wayland kiosk session wrapper..."
    mkdir -p \
        /etc/lemurs/wayland \
        /etc/lemurs/wms \
        /usr/share/wayland-sessions \
        /usr/share/xsessions \
        /var/cache \
        /var/log

    # Note: cache_path (/var/cache/lemurs) in Lemurs is a regular file, NOT a directory!
    if [[ -d /var/cache/lemurs ]]; then
        rm -rf /var/cache/lemurs
    fi

    install -Dm0644 "${REPO_ROOT}/configs/lemurs/config.toml" /etc/lemurs/config.toml
    install -Dm0755 "${REPO_ROOT}/configs/lemurs/wayland/tuios-session" /etc/lemurs/wayland/tuios-session
}

configure_boot_framebuffer() {
    # 1. Ensure virtio_gpu & simpledrm load early in initramfs on ARM64/x86_64 VMs (UTM / QEMU)
    if [[ -f /etc/initramfs-tools/modules ]]; then
        local initramfs_changed="false"
        for mod in virtio_gpu simpledrm; do
            if ! grep -qx "${mod}" /etc/initramfs-tools/modules; then
                printf "%s\n" "${mod}" >> /etc/initramfs-tools/modules
                initramfs_changed="true"
            fi
        done
        if [[ "${initramfs_changed}" == "true" ]] && command -v update-initramfs >/dev/null 2>&1; then
            update-initramfs -u >/dev/null 2>&1 || true
        fi
    fi

    # 2. Ensure installed GRUB passes console=tty0 so ARM64 UEFI firmware (ACPI SPCR -> ttyAMA0)
    #    never hides boot/VT output on UTM / QEMU displays.
    if [[ -f /etc/default/grub ]]; then
        if ! grep -Eq '^GRUB_CMDLINE_LINUX=.*console=tty0' /etc/default/grub; then
            if grep -Eq '^GRUB_CMDLINE_LINUX="' /etc/default/grub; then
                sed -i 's/^GRUB_CMDLINE_LINUX="\([^"]*\)"/GRUB_CMDLINE_LINUX="\1 console=tty0"/' /etc/default/grub
                sed -i 's/GRUB_CMDLINE_LINUX=" console=tty0"/GRUB_CMDLINE_LINUX="console=tty0"/' /etc/default/grub
            else
                printf '\nGRUB_CMDLINE_LINUX="console=tty0"\n' >> /etc/default/grub
            fi
            if command -v update-grub >/dev/null 2>&1; then
                update-grub >/dev/null 2>&1 || true
            fi
        fi
    fi
}

install_systemd_service() {
    info "Configuring lemurs.service on tty2..."
    mkdir -p /etc/systemd/system

    # Note: Do NOT set PAMName= in lemurs.service — Lemurs opens its own PAM session
    # using pam_service="lemurs" when authenticating the user. Setting PAMName= here
    # causes systemd to lock /proc/self/loginuid=0 beforehand, triggering EPERM on login.
    cat > /etc/systemd/system/lemurs.service <<'EOF'
[Unit]
Description=Lemurs TUI Display & Login Manager (Voidframe)
Documentation=https://github.com/coastalwhite/lemurs
After=systemd-user-sessions.service plymouth-quit-wait.service getty@tty2.service seatd.service
Conflicts=getty@tty2.service
StartLimitIntervalSec=0

[Service]
Type=idle
ExecStart=/usr/bin/lemurs
StandardInput=tty
StandardOutput=tty
StandardError=journal
TTYPath=/dev/tty2
TTYReset=yes
TTYVHangup=yes
Restart=always
RestartSec=2

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
    ui_progress 86 "Installing PAM session rules (/etc/pam.d/lemurs)..."
    install_pam_config
    ui_progress 88 "Installing Lemurs TUI login config & Cage Wayland session..."
    install_lemurs_configs
    ui_progress 90 "Configuring initramfs DRM drivers & GRUB console=tty0..."
    configure_boot_framebuffer
    ui_progress 92 "Enabling lemurs.service (tty2) & seatd..."
    install_systemd_service
    ui_ok "Lemurs display manager and Cage Wayland kiosk configured on tty2."
}

main "$@"
