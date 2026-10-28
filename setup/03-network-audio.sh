#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 03-network-audio.sh: Configure iwd, systemd-networkd, BlueZ, and PipeWire
# ==============================================================================
# - Masks wpa_supplicant and enables iwd + systemd-networkd for impala
# - Configures BlueZ for bluetui
# - Configures PipeWire + WirePlumber user services for wiremix
# ==============================================================================

DISTRO_NAME="${DISTRO_NAME:-voidframe}"
TARGET_USER="${TARGET_USER:-void}"

info()  { printf "\033[1;36m[%s][03-net-audio]\033[0m %s\n" "${DISTRO_NAME}" "$*"; }
warn()  { printf "\033[1;33m[%s][03-net-audio]\033[0m %s\n" "${DISTRO_NAME}" "$*" >&2; }
error() { printf "\033[1;31m[%s][03-net-audio]\033[0m %s\n" "${DISTRO_NAME}" "$*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root."
fi

configure_iwd_and_networkd() {
    info "Replacing wpa_supplicant with iwd + systemd-networkd..."

    # Stop, disable, and mask wpa_supplicant so it never conflicts with iwd
    systemctl stop wpa_supplicant.service 2>/dev/null || true
    systemctl disable wpa_supplicant.service 2>/dev/null || true
    systemctl mask wpa_supplicant.service 2>/dev/null || true

    # Configure iwd daemon (/etc/iwd/main.conf)
    mkdir -p /etc/iwd
    cat > /etc/iwd/main.conf <<'EOF'
[General]
EnableNetworkConfiguration=true
UseDefaultInterface=true
AddressRandomization=network

[Network]
NameResolvingService=systemd
EnableIPv6=true

[Scan]
DisablePeriodicScan=false
EOF

    # Configure systemd-networkd wired and wireless profiles
    mkdir -p /etc/systemd/network

    cat > /etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
RouteMetric=100
UseDNS=yes

[IPv6AcceptRA]
RouteMetric=100
UseDNS=yes
EOF

    cat > /etc/systemd/network/25-wireless.network <<'EOF'
[Match]
Name=wl* wlan*

[Network]
DHCP=yes
IPv6AcceptRA=yes
IgnoreCarrierLoss=3s

[DHCPv4]
RouteMetric=600
UseDNS=yes

[IPv6AcceptRA]
RouteMetric=600
UseDNS=yes
EOF

    # Move aside /etc/network/interfaces definitions for en*/wl* if ifupdown was used by d-i
    if [[ -f /etc/network/interfaces ]]; then
        cp -a /etc/network/interfaces /etc/network/interfaces.bak."${DISTRO_NAME}"
        cat > /etc/network/interfaces <<'EOF'
# Managed by systemd-networkd and iwd (Voidframe)
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
EOF
    fi

    systemctl enable systemd-networkd.service || true
    systemctl enable systemd-resolved.service || true
    systemctl enable iwd.service || true
}

configure_bluetooth() {
    info "Configuring BlueZ daemon for bluetui..."
    mkdir -p /etc/bluetooth
    cat > /etc/bluetooth/main.conf <<'EOF'
[General]
ControllerMode = dual
FastConnectable = true
Privacy = device

[Policy]
AutoEnable = true
ReconnectAttempts = 7
EOF

    systemctl enable bluetooth.service || true
}

configure_pipewire() {
    info "Configuring PipeWire + WirePlumber user sockets & services for wiremix..."

    mkdir -p /etc/systemd/user/sockets.target.wants
    mkdir -p /etc/systemd/user/default.target.wants
    mkdir -p /etc/systemd/user/pipewire.service.wants

    if [[ -f /usr/lib/systemd/user/pipewire.socket ]]; then
        ln -sf /usr/lib/systemd/user/pipewire.socket \
            /etc/systemd/user/sockets.target.wants/pipewire.socket
    fi
    if [[ -f /usr/lib/systemd/user/pipewire-pulse.socket ]]; then
        ln -sf /usr/lib/systemd/user/pipewire-pulse.socket \
            /etc/systemd/user/sockets.target.wants/pipewire-pulse.socket
    fi
    if [[ -f /usr/lib/systemd/user/wireplumber.service ]]; then
        ln -sf /usr/lib/systemd/user/wireplumber.service \
            /etc/systemd/user/pipewire.service.wants/wireplumber.service
        ln -sf /usr/lib/systemd/user/wireplumber.service \
            /etc/systemd/user/default.target.wants/wireplumber.service
    fi

    # Enable user lingering so PipeWire user units start immediately at login
    mkdir -p /var/lib/systemd/linger
    touch "/var/lib/systemd/linger/${TARGET_USER}"
}

configure_user_groups() {
    if id -u "${TARGET_USER}" >/dev/null 2>&1; then
        info "Adding user '${TARGET_USER}' to hardware/session groups..."
        local groups=(audio video render input seat netdev bluetooth sudo)
        for grp in "${groups[@]}"; do
            if getent group "${grp}" >/dev/null 2>&1; then
                usermod -aG "${grp}" "${TARGET_USER}"
            fi
        done
    else
        warn "Target user '${TARGET_USER}' does not exist yet; skipping usermod group assignment."
    fi
}

main() {
    configure_iwd_and_networkd
    configure_bluetooth
    configure_pipewire
    configure_user_groups
    info "Networking (iwd/systemd-networkd), Bluetooth (bluez), and Audio (PipeWire) configured."
}

main "$@"
