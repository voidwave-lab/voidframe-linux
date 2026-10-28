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
# Voidframe Debian 13 (Trixie) Netinst ISO Patcher (xorriso)
# ==============================================================================
# Unpacks and patches an official Debian Trixie netinst ISO (amd64 or arm64),
# injects preseed.cfg, setup scripts, configs, Nerd Fonts, and offline .debs,
# configures BIOS (ISOLINUX) and UEFI (GRUB) boot menus, and repacks a bootable
# hybrid ISO image.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Logging Helpers ---
info()  { printf "\033[1;36m[ISO][INFO]\033[0m  %s\n" "$*"; }
warn()  { printf "\033[1;33m[ISO][WARN]\033[0m  %s\n" "$*" >&2; }
error() { printf "\033[1;31m[ISO][ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

# --- Load Defaults from config.mk ---
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

DISTRO_NAME="${DISTRO_NAME:-voidframe}"
DISTRO_VERSION="${DISTRO_VERSION:-0.1.0}"
DEBIAN_RELEASE="${DEBIAN_RELEASE:-trixie}"
ARCH="${ARCH:-amd64}"
DEBS_DIR="${DEBS_DIR:-${REPO_ROOT}/dist/debs/${ARCH}}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/dist/iso}"
SOURCE_ISO="${SOURCE_ISO:-}"
NERD_FONT_VERSION="${NERD_FONT_VERSION:-v3.3.0}"
NERD_FONT_NAME="${NERD_FONT_NAME:-JetBrainsMono}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --distro <name>        Distro name (default: ${DISTRO_NAME})
  --version <ver>        Distro version (default: ${DISTRO_VERSION})
  --release <suite>      Debian release suite (default: ${DEBIAN_RELEASE})
  --arch <amd64|arm64>   Target architecture (default: ${ARCH})
  --debs-dir <path>      Directory with built .deb packages (default: ${DEBS_DIR})
  --source-iso <path>    Path to existing Debian netinst ISO (downloads if omitted)
  --output-dir <path>    Directory for output ISO (default: ${OUTPUT_DIR})
  -h, --help             Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --distro)     DISTRO_NAME="$2"; shift 2 ;;
        --version)    DISTRO_VERSION="$2"; shift 2 ;;
        --release)    DEBIAN_RELEASE="$2"; shift 2 ;;
        --arch)       ARCH="$2"; shift 2 ;;
        --debs-dir)   DEBS_DIR="$2"; shift 2 ;;
        --source-iso) SOURCE_ISO="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            error "Unknown option: $1" ;;
    esac
done

# Ensure required host tools exist
for cmd in xorriso curl sed awk; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        error "Required tool '${cmd}' is not installed. Install xorriso, curl, coreutils."
    fi
done

mkdir -p "${OUTPUT_DIR}"

# Discover and download the official Debian Trixie netinst ISO if not provided
download_debian_iso() {
    local cache_dir="${OUTPUT_DIR}/cache"
    mkdir -p "${cache_dir}"

    if [[ -n "${SOURCE_ISO}" && -f "${SOURCE_ISO}" ]]; then
        info "Using provided source ISO: ${SOURCE_ISO}"
        return 0
    fi

    local cached_iso="${cache_dir}/debian-${DEBIAN_RELEASE}-${ARCH}-netinst.iso"
    if [[ -f "${cached_iso}" ]]; then
        info "Using cached Debian netinst ISO: ${cached_iso}"
        SOURCE_ISO="${cached_iso}"
        return 0
    fi

    # Probe official Debian release & weekly build mirrors for Debian 13 (Trixie)
    local mirror_bases=(
        "https://cdimage.debian.org/debian-cd/current/${ARCH}/iso-cd"
        "https://cdimage.debian.org/cdimage/weekly-builds/${ARCH}/iso-cd"
        "https://cdimage.debian.org/cdimage/daily-builds/daily/arch-latest/${ARCH}/iso-cd"
    )

    local found_url=""
    for base in "${mirror_bases[@]}"; do
        info "Probing Debian ISO mirror: ${base}/ ..."
        local sums=""
        if sums="$(curl -fsSL "${base}/SHA512SUMS" 2>/dev/null)"; then
            local iso_from_sums
            iso_from_sums="$(printf "%s\n" "${sums}" | awk '{print $2}' | sed 's/^\*//' | grep -E "^debian-[0-9A-Za-z._-]+-${ARCH}-netinst\.iso$" | head -n1 || true)"
            if [[ -n "${iso_from_sums}" ]]; then
                found_url="${base}/${iso_from_sums}"
                break
            fi
        fi

        local listing=""
        if listing="$(curl -fsSL "${base}/" 2>/dev/null)"; then
            local iso_name
            iso_name="$(printf "%s" "${listing}" | grep -Eo 'href="debian-[^"]+-'"${ARCH}"'-netinst\.iso"' | head -n1 | sed -E 's/href="|"$//g' || true)"
            if [[ -n "${iso_name}" ]]; then
                found_url="${base}/${iso_name}"
                break
            fi
        fi
    done

    if [[ -z "${found_url}" ]]; then
        error "Could not automatically locate Debian ${DEBIAN_RELEASE} (${ARCH}) netinst ISO on cdimage.debian.org. Pass --source-iso <path>."
    fi

    info "Downloading official Debian netinst ISO from ${found_url}..."
    curl -fL --retry 3 -o "${cached_iso}.part" "${found_url}"
    mv "${cached_iso}.part" "${cached_iso}"
    SOURCE_ISO="${cached_iso}"
}

prepare_overlay() {
    local overlay_dir="$1"
    local payload_dir="${overlay_dir}/${DISTRO_NAME}"

    mkdir -p \
        "${payload_dir}/debs" \
        "${payload_dir}/setup" \
        "${payload_dir}/configs" \
        "${payload_dir}/fonts"

    # 1. Copy and brand preseed.cfg into root of ISO (/preseed.cfg)
    info "Injecting /preseed.cfg customized for DISTRO_NAME=${DISTRO_NAME}..."
    sed "s/voidframe/${DISTRO_NAME}/g" "${REPO_ROOT}/iso/preseed.cfg" > "${overlay_dir}/preseed.cfg"

    # 2. Copy LICENSE, config.mk, setup scripts, and configs
    if [[ -f "${REPO_ROOT}/LICENSE" ]]; then
        cp -a "${REPO_ROOT}/LICENSE" "${overlay_dir}/LICENSE"
        cp -a "${REPO_ROOT}/LICENSE" "${payload_dir}/LICENSE"
    fi
    cp -a "${REPO_ROOT}/config.mk" "${payload_dir}/config.mk"
    cp -a "${REPO_ROOT}/setup/." "${payload_dir}/setup/"
    cp -a "${REPO_ROOT}/configs/." "${payload_dir}/configs/"
    chmod +x "${payload_dir}/setup/"*.sh "${payload_dir}/configs/lemurs/wayland/tuios-session"

    # 3. Copy pre-built .deb packages
    if [[ -d "${DEBS_DIR}" ]] && compgen -G "${DEBS_DIR}/*.deb" >/dev/null; then
        info "Embedding .deb packages from ${DEBS_DIR} into /${DISTRO_NAME}/debs/..."
        cp -a "${DEBS_DIR}/"*.deb "${payload_dir}/debs/"
        for meta in Packages Packages.gz SHA256SUMS SOURCE_MANIFEST.txt; do
            [[ -f "${DEBS_DIR}/${meta}" ]] && cp -a "${DEBS_DIR}/${meta}" "${payload_dir}/debs/"
        done
    else
        warn "No .deb files found in ${DEBS_DIR}! The ISO will require network access during install to fetch .debs."
    fi

    # 4. Cache JetBrainsMono Nerd Font archive for 100% offline installation
    local font_cache="${OUTPUT_DIR}/cache/${NERD_FONT_NAME}.tar.xz"
    if [[ ! -f "${font_cache}" ]]; then
        local font_url="https://github.com/ryanoasis/nerd-fonts/releases/download/${NERD_FONT_VERSION}/${NERD_FONT_NAME}.tar.xz"
        info "Caching ${NERD_FONT_NAME} Nerd Font (${NERD_FONT_VERSION}) for offline ISO installation..."
        curl -fsSL --retry 3 -o "${font_cache}" "${font_url}" || warn "Could not cache Nerd Font archive."
    fi
    if [[ -f "${font_cache}" ]]; then
        cp -a "${font_cache}" "${payload_dir}/fonts/${NERD_FONT_NAME}.tar.xz"
    fi
}

patch_boot_configs() {
    local iso_extract_dir="$1"
    local overlay_dir="$2"

    # Extract existing boot configs from SOURCE_ISO so we can patch them cleanly
    xorriso -osirrox on -indev "${SOURCE_ISO}" \
        -extract /boot/grub/grub.cfg "${iso_extract_dir}/grub.cfg" 2>/dev/null || true

    # Patch UEFI GRUB config (/boot/grub/grub.cfg)
    if [[ -f "${iso_extract_dir}/grub.cfg" ]]; then
        info "Patching UEFI GRUB configuration (/boot/grub/grub.cfg)..."
        mkdir -p "${overlay_dir}/boot/grub"
        cat > "${overlay_dir}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

menuentry "${DISTRO_NAME} ${DISTRO_VERSION} Automated TUI OS Install (${ARCH})" {
    set background_color=black
    linux    /install.${ARCH/#amd64/amd}/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed.cfg hostname=${DISTRO_NAME} domain=local quiet ---
    initrd   /install.${ARCH/#amd64/amd}/initrd.gz
}

EOF
        # Fix kernel directory name for arm64 (install.a64) vs amd64 (install.amd)
        if [[ "${ARCH}" == "arm64" ]]; then
            sed -i.bak 's|/install\.arm64/|/install.a64/|g' "${overlay_dir}/boot/grub/grub.cfg"
            rm -f "${overlay_dir}/boot/grub/grub.cfg.bak"
        fi
        cat "${iso_extract_dir}/grub.cfg" >> "${overlay_dir}/boot/grub/grub.cfg"
    fi

    # Patch BIOS ISOLINUX config (amd64 only)
    if [[ "${ARCH}" == "amd64" ]]; then
        if xorriso -osirrox on -indev "${SOURCE_ISO}" -extract /isolinux/txt.cfg "${iso_extract_dir}/txt.cfg" 2>/dev/null; then
            if [[ -f "${iso_extract_dir}/txt.cfg" ]]; then
                info "Patching BIOS ISOLINUX configuration (/isolinux/txt.cfg)..."
                mkdir -p "${overlay_dir}/isolinux"
                cat > "${overlay_dir}/isolinux/txt.cfg" <<EOF
default ${DISTRO_NAME}
label ${DISTRO_NAME}
    menu label ^${DISTRO_NAME} ${DISTRO_VERSION} Automated TUI OS Install
    menu default
    kernel /install.amd/vmlinuz
    append vga=788 initrd=/install.amd/initrd.gz auto=true priority=critical preseed/file=/cdrom/preseed.cfg hostname=${DISTRO_NAME} domain=local --- quiet
EOF
                cat "${iso_extract_dir}/txt.cfg" >> "${overlay_dir}/isolinux/txt.cfg"
            fi
        fi

        if xorriso -osirrox on -indev "${SOURCE_ISO}" -extract /isolinux/isolinux.cfg "${iso_extract_dir}/isolinux.cfg" 2>/dev/null; then
            if [[ -f "${iso_extract_dir}/isolinux.cfg" ]]; then
                mkdir -p "${overlay_dir}/isolinux"
                sed 's/^timeout 0$/timeout 50/' "${iso_extract_dir}/isolinux.cfg" > "${overlay_dir}/isolinux/isolinux.cfg"
            fi
        fi
    fi
}

build_hybrid_iso() {
    local overlay_dir="$1"
    local output_iso="${OUTPUT_DIR}/${DISTRO_NAME}-${DISTRO_VERSION}-debian-${DEBIAN_RELEASE}-${ARCH}-netinst.iso"
    local volid
    volid="$(printf "%s_%s_%s" "${DISTRO_NAME}" "${DEBIAN_RELEASE}" "${ARCH}" | tr '[:lower:]' '[:upper:]' | cut -c1-32)"

    rm -f "${output_iso}"

    info "Repacking bootable hybrid ISO (BIOS + UEFI) with xorriso -> ${output_iso}..."
    local xorriso_args=(
        -indev "${SOURCE_ISO}"
        -outdev "${output_iso}"
        -volid "${volid}"
        -compliance joliet_long_names
        -boot_image any replay
        -map "${overlay_dir}/preseed.cfg" "/preseed.cfg"
        -map "${overlay_dir}/${DISTRO_NAME}" "/${DISTRO_NAME}"
    )

    if [[ -f "${overlay_dir}/LICENSE" ]]; then
        xorriso_args+=(-map "${overlay_dir}/LICENSE" "/LICENSE")
    fi
    if [[ -f "${overlay_dir}/boot/grub/grub.cfg" ]]; then
        xorriso_args+=(-map "${overlay_dir}/boot/grub/grub.cfg" "/boot/grub/grub.cfg")
    fi
    if [[ -f "${overlay_dir}/isolinux/txt.cfg" ]]; then
        xorriso_args+=(-map "${overlay_dir}/isolinux/txt.cfg" "/isolinux/txt.cfg")
    fi
    if [[ -f "${overlay_dir}/isolinux/isolinux.cfg" ]]; then
        xorriso_args+=(-map "${overlay_dir}/isolinux/isolinux.cfg" "/isolinux/isolinux.cfg")
    fi

    xorriso "${xorriso_args[@]}" -commit -eject all

    (
        cd "${OUTPUT_DIR}"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$(basename "${output_iso}")" > "$(basename "${output_iso}").sha256"
        else
            shasum -a 256 "$(basename "${output_iso}")" > "$(basename "${output_iso}").sha256"
        fi
    )

    info "Successfully generated bootable hybrid ISO:"
    ls -lh "${output_iso}" "${output_iso}.sha256"
}

TMP_WORK=""
cleanup() {
    if [[ -n "${TMP_WORK:-}" && -d "${TMP_WORK}" ]]; then
        rm -rf "${TMP_WORK}"
    fi
}
trap cleanup EXIT

main() {
    download_debian_iso

    TMP_WORK="$(mktemp -d -t "${DISTRO_NAME}-iso.XXXXXX")"

    local overlay_dir="${TMP_WORK}/overlay"
    local extract_dir="${TMP_WORK}/extract"
    mkdir -p "${overlay_dir}" "${extract_dir}"

    prepare_overlay "${overlay_dir}"
    patch_boot_configs "${extract_dir}" "${overlay_dir}"
    build_hybrid_iso "${overlay_dir}"
}

main "$@"
