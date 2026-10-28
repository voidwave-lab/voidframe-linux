#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 05-dotfiles.sh: Populate /etc/xdg, /etc/skel, and User ~/.config
# ==============================================================================
# Deploys the unified Voidframe configuration suite:
#   - /etc/xdg/foot/foot.ini
#   - ~/.config/foot/foot.ini
#   - ~/.config/tuios/config.toml
#   - ~/.config/yazi/{yazi.toml,theme.toml}
#   - ~/.config/bottom/bottom.toml
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DISTRO_NAME="${DISTRO_NAME:-voidframe}"
TARGET_USER="${TARGET_USER:-void}"

info()  { printf "\033[1;36m[%s][05-dotfiles]\033[0m %s\n" "${DISTRO_NAME}" "$*"; }
warn()  { printf "\033[1;33m[%s][05-dotfiles]\033[0m %s\n" "${DISTRO_NAME}" "$*" >&2; }
error() { printf "\033[1;31m[%s][05-dotfiles]\033[0m %s\n" "${DISTRO_NAME}" "$*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root."
fi

deploy_configs_to_root() {
    local dest_base="$1"
    info "Deploying unified configs to ${dest_base}/.config ..."

    mkdir -p \
        "${dest_base}/.config/foot" \
        "${dest_base}/.config/tuios" \
        "${dest_base}/.config/yazi" \
        "${dest_base}/.config/bottom"

    install -Dm0644 "${REPO_ROOT}/configs/foot/foot.ini"       "${dest_base}/.config/foot/foot.ini"
    install -Dm0644 "${REPO_ROOT}/configs/tuios/config.toml"   "${dest_base}/.config/tuios/config.toml"
    install -Dm0644 "${REPO_ROOT}/configs/yazi/yazi.toml"      "${dest_base}/.config/yazi/yazi.toml"
    install -Dm0644 "${REPO_ROOT}/configs/yazi/theme.toml"     "${dest_base}/.config/yazi/theme.toml"
    install -Dm0644 "${REPO_ROOT}/configs/bottom/bottom.toml"  "${dest_base}/.config/bottom/bottom.toml"
}

install_system_xdg_configs() {
    info "Installing system-wide /etc/xdg/foot/foot.ini..."
    install -Dm0644 "${REPO_ROOT}/configs/foot/foot.ini" /etc/xdg/foot/foot.ini

    info "Installing /etc/profile.d/${DISTRO_NAME}-env.sh..."
    mkdir -p /etc/profile.d
    cat > "/etc/profile.d/${DISTRO_NAME}-env.sh" <<'EOF'
# Voidframe TUI OS Environment & Ergonomic Shell Helpers
export EDITOR="nvim"
export VISUAL="nvim"
export PAGER="less -R"
export COLORTERM="truecolor"

# Yazi cwd-on-exit wrapper ('y')
y() {
    local tmp
    tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        builtin cd -- "$cwd" || return
    fi
    rm -f -- "$tmp"
}
EOF
    chmod 0644 "/etc/profile.d/${DISTRO_NAME}-env.sh"

    # Ensure interactive non-login bash shells (launched inside TUIOS panes) also source the helpers
    if [[ -f /etc/bash.bashrc ]] && ! grep -q "${DISTRO_NAME}-env.sh" /etc/bash.bashrc; then
        cat >> /etc/bash.bashrc <<EOF

# Source ${DISTRO_NAME} TUI helpers
if [ -f /etc/profile.d/${DISTRO_NAME}-env.sh ]; then
    . /etc/profile.d/${DISTRO_NAME}-env.sh
fi
EOF
    fi
}

main() {
    install_system_xdg_configs

    # Populate /etc/skel for any future users
    deploy_configs_to_root "/etc/skel"

    # Populate target user's home directory if present
    if id -u "${TARGET_USER}" >/dev/null 2>&1; then
        local user_home
        user_home="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
        if [[ -n "${user_home}" && -d "${user_home}" ]]; then
            deploy_configs_to_root "${user_home}"
            chown -R "${TARGET_USER}:${TARGET_USER}" "${user_home}/.config"
        fi
    else
        warn "User '${TARGET_USER}' not found; only /etc/skel and /etc/xdg were populated."
    fi

    info "Dotfiles and system XDG configs deployed."
}

main "$@"
