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
# 02-install-tuis.sh: Install Pre-Built Ratatui & TUIOS .deb Packages
# ==============================================================================
# Zero target-machine compilation: installs pre-packaged .deb files from:
#   1. DEBS_SOURCE_DIR / offline ISO mount (/cdrom/<distro>/debs)
#   2. Local workspace cache (./dist/debs/<arch>)
#   3. GitHub Releases of GITHUB_REPO
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DISTRO_NAME="${DISTRO_NAME:-voidframe}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
if [[ -z "${GITHUB_REPO:-}" || "${GITHUB_REPO}" == "voidframe/voidframe" ]]; then
    if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        remote_url="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
        if [[ "${remote_url}" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
            GITHUB_REPO="${BASH_REMATCH[1]}"
        fi
    fi
fi
GITHUB_REPO="${GITHUB_REPO:-voidframe/voidframe}"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-auto}"
DEBS_SOURCE_DIR="${DEBS_SOURCE_DIR:-}"

info()  { printf "\033[1;36m[%s][02-tuis]\033[0m %s\n" "${DISTRO_NAME}" "$*"; }
warn()  { printf "\033[1;33m[%s][02-tuis]\033[0m %s\n" "${DISTRO_NAME}" "$*" >&2; }
error() { printf "\033[1;31m[%s][02-tuis]\033[0m %s\n" "${DISTRO_NAME}" "$*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root."
fi

export DEBIAN_FRONTEND=noninteractive

REQUIRED_PACKAGES=(
    lemurs
    tuios
    yazi
    wiremix
    impala
    bluetui
    bottom
    systemctl-tui
    dua-cli
    gitui
)

EXPECTED_BINARIES=(
    lemurs
    tuios
    yazi
    ya
    wiremix
    impala
    bluetui
    btm
    systemctl-tui
    dua
    gitui
)

resolve_debs_directory() {
    # 1. Explicit DEBS_SOURCE_DIR
    if [[ -n "${DEBS_SOURCE_DIR}" && -d "${DEBS_SOURCE_DIR}" ]] && compgen -G "${DEBS_SOURCE_DIR}/*.deb" >/dev/null; then
        printf "%s\n" "${DEBS_SOURCE_DIR}"
        return 0
    fi

    # 2. Offline ISO locations & local workspace dist/debs
    local candidates=(
        "/cdrom/${DISTRO_NAME}/debs"
        "/media/cdrom/${DISTRO_NAME}/debs"
        "/tmp/${DISTRO_NAME}/debs"
        "${REPO_ROOT}/dist/debs/${ARCH}"
        "${REPO_ROOT}/dist/debs"
    )
    for dir in "${candidates[@]}"; do
        if [[ -d "${dir}" ]] && compgen -G "${dir}/*.deb" >/dev/null; then
            printf "%s\n" "${dir}"
            return 0
        fi
    done

    return 1
}

download_debs_from_github() {
    local dest_dir="/tmp/${DISTRO_NAME}-debs-${ARCH}"
    rm -rf "${dest_dir}"
    mkdir -p "${dest_dir}"

    info "No local .deb cache found; querying GitHub Releases (${GITHUB_REPO}) for ${ARCH} packages..."
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local release_json
    if ! release_json="$(curl -fsSL "${api_url}")"; then
        error "Failed to query GitHub Releases at ${api_url}. Build .debs locally with 'make build-debs-docker' or provide --debs-dir."
    fi

    local urls
    urls="$(printf "%s" "${release_json}" | jq -r ".assets[] | select(.name | endswith(\"_${ARCH}.deb\")) | .browser_download_url")"

    if [[ -z "${urls}" ]]; then
        error "No _${ARCH}.deb assets found in latest release of ${GITHUB_REPO}."
    fi

    while IFS= read -r url; do
        [[ -z "${url}" ]] && continue
        local fname
        fname="$(basename "${url}")"
        info "Downloading ${fname}..."
        curl -fsSL --retry 3 -o "${dest_dir}/${fname}" "${url}"
    done <<< "${urls}"

    printf "%s\n" "${dest_dir}"
}

install_debs_from_dir() {
    local deb_dir="$1"
    info "Installing TUI .deb packages from ${deb_dir}..."

    local deb_files=()
    while IFS= read -r -d '' f; do
        deb_files+=("$f")
    done < <(find "${deb_dir}" -maxdepth 1 -type f \( -name "*_${ARCH}.deb" -o -name "*_all.deb" \) -print0)

    if [[ "${#deb_files[@]}" -eq 0 ]]; then
        while IFS= read -r -d '' f; do
            deb_files+=("$f")
        done < <(find "${deb_dir}" -maxdepth 1 -type f -name "*.deb" -print0)
    fi

    if [[ "${#deb_files[@]}" -eq 0 ]]; then
        error "No .deb packages found in ${deb_dir}"
    fi

    # Install via apt-get or dpkg with dependency resolution
    if ! apt-get install -y --no-install-recommends "${deb_files[@]}"; then
        warn "apt-get direct local install returned non-zero; running dpkg -i + apt-get -f install..."
        dpkg -i "${deb_files[@]}" || apt-get install -f -y --no-install-recommends
    fi
}

verify_installed_binaries() {
    info "Verifying installed TUI binaries..."
    local missing=0
    for bin in "${EXPECTED_BINARIES[@]}"; do
        if command -v "${bin}" >/dev/null 2>&1; then
            info "  [OK] ${bin} -> $(command -v "${bin}")"
        else
            warn "  [MISSING] ${bin} not found in PATH"
            missing=$((missing + 1))
        fi
    done

    if [[ "${missing}" -gt 0 ]]; then
        error "${missing} required TUI binaries are missing after .deb installation."
    fi
}

main() {
    local target_deb_dir=""
    if target_deb_dir="$(resolve_debs_directory)"; then
        info "Using local/offline .deb directory: ${target_deb_dir}"
    else
        if [[ "${BOOTSTRAP_MODE}" == "offline" ]]; then
            error "Offline mode requested, but no .deb directory found in /cdrom/${DISTRO_NAME}/debs or DEBS_SOURCE_DIR."
        fi
        target_deb_dir="$(download_debs_from_github)"
    fi

    install_debs_from_dir "${target_deb_dir}"
    verify_installed_binaries
    info "All ${#REQUIRED_PACKAGES[@]} TUI packages installed and verified."
}

main "$@"
