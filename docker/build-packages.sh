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
# Voidframe .deb Package Builder (Debian Trixie Container Entrypoint)
# ==============================================================================
# Compiles and packages the Ratatui system suite + TUIOS + Lemurs into standard
# Debian (.deb) packages with runtime dependency metadata in DEBIAN/control and
# Debian Policy / GNU GPLv3 compliant /usr/share/doc/<pkg>/copyright files.

# --- Logging Helpers ---
info()  { printf "\033[1;36m[INFO]\033[0m  %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m  %s\n" "$*" >&2; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This builder script must run as root inside the Debian builder container."
fi

# --- Load Configuration Defaults from config.mk ---
load_config_mk() {
    local cfg_file="${1:-/build/config.mk}"
    if [[ -f "${cfg_file}" ]]; then
        while IFS= read -r line; do
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            if [[ "${line}" =~ ^([A-Z0-9_]+)[[:space:]]*\?=[[:space:]]*(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local val="${BASH_REMATCH[2]}"
                # Resolve simple $(DISTRO_NAME) interpolation if present
                val="${val//\$(DISTRO_NAME)/${DISTRO_NAME:-voidframe}}"
                if [[ -z "${!key:-}" ]]; then
                    export "${key}=${val}"
                fi
            fi
        done < "${cfg_file}"
    fi
}

load_config_mk "/build/config.mk"

DISTRO_NAME="${DISTRO_NAME:-voidframe}"
DISTRO_VERSION="${DISTRO_VERSION:-0.1.0}"
DISTRO_MAINTAINER="${DISTRO_MAINTAINER:-Voidframe Maintainers <maintainers@voidframe.local>}"
DEBIAN_RELEASE="${DEBIAN_RELEASE:-trixie}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
OUTPUT_DIR="${OUTPUT_DIR:-/dist/debs}"
WORK_DIR="/tmp/pkg-build"
PREFER_UPSTREAM_FALLBACK="${PREFER_UPSTREAM_FALLBACK:-true}"

mkdir -p "${OUTPUT_DIR}" "${WORK_DIR}"

# Sanitize version string for Debian control (strip leading 'v')
deb_version() {
    local ver="${1#v}"
    printf "%s-1~%s1" "${ver}" "${DISTRO_NAME}"
}

# Build a standard .deb package from a staging directory
# Usage: package_deb <pkg_name> <version> <depends> <description> <staging_dir> <upstream_url> <upstream_license>
package_deb() {
    local pkg_name="$1"
    local raw_ver="$2"
    local depends="$3"
    local description="$4"
    local stage_dir="$5"
    local upstream_url="${6:-https://github.com/${GITHUB_REPO:-voidframe/voidframe}}"
    local upstream_license="${7:-GPL-3.0-or-later}"

    local deb_ver
    deb_ver="$(deb_version "${raw_ver}")"
    local deb_file="${OUTPUT_DIR}/${pkg_name}_${deb_ver}_${ARCH}.deb"

    mkdir -p "${stage_dir}/DEBIAN" "${stage_dir}/usr/share/doc/${pkg_name}"

    # Generate Debian Machine-Readable Copyright & GPLv3 compliance notice
    cat > "${stage_dir}/usr/share/doc/${pkg_name}/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: ${pkg_name}
Upstream-Version: ${raw_ver}
Source: ${upstream_url}

Files: *
Copyright: Upstream Authors (${upstream_url})
License: ${upstream_license}

Files: debian/*
Copyright: 2026 ${DISTRO_MAINTAINER}
License: GPL-3.0-or-later
 This package wrapper and build pipeline are free software: you can
 redistribute them and/or modify them under the terms of the GNU General
 Public License as published by the Free Software Foundation, either
 version 3 of the License, or (at your option) any later version.
 .
 On Debian systems, the complete text of the GNU General Public License
 Version 3 can be found in "/usr/share/common-licenses/GPL-3".
EOF

    cat > "${stage_dir}/usr/share/doc/${pkg_name}/SOURCE_MANIFEST" <<EOF
Package: ${pkg_name}
Version: ${deb_ver}
Upstream-Tag: ${raw_ver}
Upstream-Source: ${upstream_url}
Upstream-License: ${upstream_license}
Packaging-Source: https://github.com/${GITHUB_REPO:-voidframe/voidframe}
Packaging-License: GPL-3.0-or-later
EOF

    chmod 0644 "${stage_dir}/usr/share/doc/${pkg_name}/copyright" \
               "${stage_dir}/usr/share/doc/${pkg_name}/SOURCE_MANIFEST"

    # Record in global SOURCE_MANIFEST.txt for GPLv3 Section 6 Corresponding Source compliance
    printf "%-16s %-14s %-18s %s\n" "${pkg_name}" "${raw_ver}" "${upstream_license}" "${upstream_url}" \
        >> "${OUTPUT_DIR}/SOURCE_MANIFEST.txt"

    # Strip ELF binaries if possible
    if [[ -d "${stage_dir}/usr/bin" ]]; then
        find "${stage_dir}/usr/bin" -type f -executable -exec strip --strip-unneeded {} + 2>/dev/null || true
    fi

    local installed_size
    installed_size="$(du -sk "${stage_dir}" | awk '{print $1}')"

    cat > "${stage_dir}/DEBIAN/control" <<EOF
Package: ${pkg_name}
Version: ${deb_ver}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: ${DISTRO_MAINTAINER}
Installed-Size: ${installed_size}
Depends: ${depends}
Homepage: ${upstream_url}
Description: ${description}
 Packaged for ${DISTRO_NAME} (Debian ${DEBIAN_RELEASE} TUI OS) under GPL-3.0-or-later.
EOF

    chmod 0755 "${stage_dir}/DEBIAN"
    chmod 0644 "${stage_dir}/DEBIAN/control"

    dpkg-deb --root-owner-group -Zxz --build "${stage_dir}" "${deb_file}"
    info "Built package: ${deb_file}"
}

# Clone git repository at a specific tag (with fallback to latest default branch if tag was moved)
clone_repo() {
    local repo_url="$1"
    local tag="$2"
    local dest="$3"

    rm -rf "${dest}"
    info "Fetching ${repo_url} (${tag})..."
    if ! git clone --depth 1 --branch "${tag}" "${repo_url}" "${dest}" 2>/dev/null; then
        warn "Tag ${tag} not found directly on ${repo_url}; cloning default branch..."
        git clone --depth 1 "${repo_url}" "${dest}"
    fi
}

# Try cargo-binstall first when allowed, otherwise compile from source with LTO
install_or_compile_rust_bin() {
    local crate_name="$1"
    local repo_url="$2"
    local tag="$3"
    local bin_name="$4"
    local dest_bin_dir="$5"
    local allow_binstall="${6:-false}"

    mkdir -p "${dest_bin_dir}"
    local version_clean="${tag#v}"
    local src_dir="${WORK_DIR}/src-${crate_name}"

    if [[ "${allow_binstall}" == "true" && "${PREFER_UPSTREAM_FALLBACK}" == "true" ]]; then
        info "Attempting fast upstream binary fetch via cargo-binstall for ${crate_name}@${version_clean}..."
        local binstall_root="${WORK_DIR}/binstall-${crate_name}"
        rm -rf "${binstall_root}"
        mkdir -p "${binstall_root}"
        if cargo-binstall -y --no-symlinks --root "${binstall_root}" "${crate_name}@${version_clean}" 2>/dev/null \
           || cargo-binstall -y --no-symlinks --root "${binstall_root}" "${crate_name}" 2>/dev/null; then
            if [[ -f "${binstall_root}/bin/${bin_name}" ]]; then
                install -Dm0755 "${binstall_root}/bin/${bin_name}" "${dest_bin_dir}/${bin_name}"
                return 0
            fi
        fi
        warn "cargo-binstall fallback unavailable for ${crate_name}; compiling from source..."
    fi

    clone_repo "${repo_url}" "${tag}" "${src_dir}"
    (
        cd "${src_dir}"
        cargo build --release --locked --bin "${bin_name}" \
            || cargo build --release --bin "${bin_name}" \
            || cargo build --release --locked \
            || cargo build --release
        install -Dm0755 "target/release/${bin_name}" "${dest_bin_dir}/${bin_name}"
    )
}

# ==============================================================================
# 1. lemurs (TUI Display / Login Manager)
# ==============================================================================
build_lemurs() {
    info "--- Building lemurs (${LEMURS_VERSION}) ---"
    local stage="${WORK_DIR}/stage-lemurs"
    rm -rf "${stage}"
    mkdir -p "${stage}/usr/bin" "${stage}/etc/lemurs/wayland" "${stage}/etc/lemurs/wms"

    install_or_compile_rust_bin \
        "lemurs" \
        "https://github.com/coastalwhite/lemurs.git" \
        "${LEMURS_VERSION}" \
        "lemurs" \
        "${stage}/usr/bin" \
        "true"

    package_deb \
        "lemurs" \
        "${LEMURS_VERSION}" \
        "libc6, libpam0g, systemd" \
        "Customizable TUI display/login manager written in Rust" \
        "${stage}" \
        "https://github.com/coastalwhite/lemurs" \
        "MIT or Apache-2.0"
}

# ==============================================================================
# 2. tuios (Terminal Window Manager / Multiplexer in Go)
# ==============================================================================
build_tuios() {
    info "--- Building tuios (${TUIOS_VERSION}) ---"
    local stage="${WORK_DIR}/stage-tuios"
    local src="${WORK_DIR}/src-tuios"
    rm -rf "${stage}" "${src}"
    mkdir -p "${stage}/usr/bin"

    clone_repo "https://github.com/Gaurav-Gosain/tuios.git" "${TUIOS_VERSION}" "${src}"
    (
        cd "${src}"
        export GOTOOLCHAIN=auto
        if [[ -d "./cmd/tuios" ]]; then
            CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "${stage}/usr/bin/tuios" ./cmd/tuios
        else
            CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "${stage}/usr/bin/tuios" .
        fi
    )
    chmod 0755 "${stage}/usr/bin/tuios"

    package_deb \
        "tuios" \
        "${TUIOS_VERSION}" \
        "libc6" \
        "Terminal-based Operating System & Window Multiplexer (TUIOS)" \
        "${stage}" \
        "https://github.com/Gaurav-Gosain/tuios" \
        "MIT"
}

# ==============================================================================
# 3. yazi (Blazing fast terminal file manager + ya CLI)
# ==============================================================================
build_yazi() {
    info "--- Building yazi (${YAZI_VERSION}) ---"
    local stage="${WORK_DIR}/stage-yazi"
    local src="${WORK_DIR}/src-yazi"
    rm -rf "${stage}" "${src}"
    mkdir -p "${stage}/usr/bin"

    local binstall_ok="false"
    if [[ "${PREFER_UPSTREAM_FALLBACK}" == "true" ]]; then
        local binstall_root="${WORK_DIR}/binstall-yazi"
        rm -rf "${binstall_root}"
        mkdir -p "${binstall_root}"
        if cargo-binstall -y --no-symlinks --root "${binstall_root}" "yazi-fm" 2>/dev/null \
           && cargo-binstall -y --no-symlinks --root "${binstall_root}" "yazi-cli" 2>/dev/null; then
            if [[ -f "${binstall_root}/bin/yazi" && -f "${binstall_root}/bin/ya" ]]; then
                install -Dm0755 "${binstall_root}/bin/yazi" "${stage}/usr/bin/yazi"
                install -Dm0755 "${binstall_root}/bin/ya" "${stage}/usr/bin/ya"
                binstall_ok="true"
            fi
        fi
    fi

    if [[ "${binstall_ok}" != "true" ]]; then
        clone_repo "https://github.com/sxyazi/yazi.git" "${YAZI_VERSION}" "${src}"
        (
            cd "${src}"
            cargo build --release --locked || cargo build --release
            install -Dm0755 "target/release/yazi" "${stage}/usr/bin/yazi"
            install -Dm0755 "target/release/ya" "${stage}/usr/bin/ya"
        )
    fi

    package_deb \
        "yazi" \
        "${YAZI_VERSION}" \
        "libc6, file, ffmpeg, 7zip, jq, poppler-utils, fd-find, ripgrep, fzf, zoxide" \
        "Blazing fast terminal file manager written in Rust based on async I/O" \
        "${stage}" \
        "https://github.com/sxyazi/yazi" \
        "MIT"
}

# ==============================================================================
# 4. wiremix (PipeWire native TUI audio mixer)
# ==============================================================================
build_wiremix() {
    info "--- Building wiremix (${WIREMIX_VERSION}) ---"
    local stage="${WORK_DIR}/stage-wiremix"
    rm -rf "${stage}"
    mkdir -p "${stage}/usr/bin"

    install_or_compile_rust_bin \
        "wiremix" \
        "https://github.com/tsowell/wiremix.git" \
        "${WIREMIX_VERSION}" \
        "wiremix" \
        "${stage}/usr/bin" \
        "false"

    package_deb \
        "wiremix" \
        "${WIREMIX_VERSION}" \
        "libc6, libpipewire-0.3-0t64 | libpipewire-0.3-0, pipewire, wireplumber" \
        "Ratatui-based native PipeWire audio mixer TUI" \
        "${stage}" \
        "https://github.com/tsowell/wiremix" \
        "MIT or GPL-3.0-or-later"
}

# ==============================================================================
# 5. impala (Wi-Fi TUI manager over iwd)
# ==============================================================================
build_impala() {
    info "--- Building impala (${IMPALA_VERSION}) ---"
    local stage="${WORK_DIR}/stage-impala"
    rm -rf "${stage}"
    mkdir -p "${stage}/usr/bin"

    install_or_compile_rust_bin \
        "impala" \
        "https://github.com/pythops/impala.git" \
        "${IMPALA_VERSION}" \
        "impala" \
        "${stage}/usr/bin" \
        "true"

    package_deb \
        "impala" \
        "${IMPALA_VERSION}" \
        "libc6, iwd, dbus" \
        "TUI for managing Wi-Fi networks powered by iwd and Ratatui" \
        "${stage}" \
        "https://github.com/pythops/impala" \
        "GPL-3.0-only"
}

# ==============================================================================
# 6. bluetui (Bluetooth TUI manager over bluez)
# ==============================================================================
build_bluetui() {
    info "--- Building bluetui (${BLUETUI_VERSION}) ---"
    local stage="${WORK_DIR}/stage-bluetui"
    rm -rf "${stage}"
    mkdir -p "${stage}/usr/bin"

    install_or_compile_rust_bin \
        "bluetui" \
        "https://github.com/pythops/bluetui.git" \
        "${BLUETUI_VERSION}" \
        "bluetui" \
        "${stage}/usr/bin" \
        "true"

    package_deb \
        "bluetui" \
        "${BLUETUI_VERSION}" \
        "libc6, bluez, libdbus-1-3, dbus" \
        "TUI for managing Bluetooth devices over BlueZ D-Bus" \
        "${stage}" \
        "https://github.com/pythops/bluetui" \
        "GPL-3.0-only"
}

# ==============================================================================
# 7. bottom (System monitor TUI - btm)
# ==============================================================================
build_bottom() {
    info "--- Building bottom (${BOTTOM_VERSION}) ---"
    local stage="${WORK_DIR}/stage-bottom"
    rm -rf "${stage}"
    mkdir -p "${stage}/usr/bin"

    install_or_compile_rust_bin \
        "bottom" \
        "https://github.com/ClementTsang/bottom.git" \
        "${BOTTOM_VERSION}" \
        "btm" \
        "${stage}/usr/bin" \
        "true"

    package_deb \
        "bottom" \
        "${BOTTOM_VERSION}" \
        "libc6" \
        "Customizable graphical process/system monitor TUI (btm)" \
        "${stage}" \
        "https://github.com/ClementTsang/bottom" \
        "MIT"
}

# ==============================================================================
# 8. systemctl-tui (Systemd service & journal manager)
# ==============================================================================
build_systemctl_tui() {
    info "--- Building systemctl-tui (${SYSTEMCTL_TUI_VERSION}) ---"
    local stage="${WORK_DIR}/stage-systemctl-tui"
    rm -rf "${stage}"
    mkdir -p "${stage}/usr/bin"

    install_or_compile_rust_bin \
        "systemctl-tui" \
        "https://github.com/rgwood/systemctl-tui.git" \
        "${SYSTEMCTL_TUI_VERSION}" \
        "systemctl-tui" \
        "${stage}/usr/bin" \
        "true"

    package_deb \
        "systemctl-tui" \
        "${SYSTEMCTL_TUI_VERSION}" \
        "libc6, systemd" \
        "Fast, simple TUI for interacting with systemd services and journals" \
        "${stage}" \
        "https://github.com/rgwood/systemctl-tui" \
        "MIT"
}

# ==============================================================================
# 9. dua-cli (Disk Usage Analyzer - dua)
# ==============================================================================
build_dua_cli() {
    info "--- Building dua-cli (${DUA_CLI_VERSION}) ---"
    local stage="${WORK_DIR}/stage-dua-cli"
    rm -rf "${stage}"
    mkdir -p "${stage}/usr/bin"

    install_or_compile_rust_bin \
        "dua-cli" \
        "https://github.com/Byron/dua-cli.git" \
        "${DUA_CLI_VERSION}" \
        "dua" \
        "${stage}/usr/bin" \
        "true"

    package_deb \
        "dua-cli" \
        "${DUA_CLI_VERSION}" \
        "libc6" \
        "Disk Usage Analyzer TUI with fast parallel traversal (dua)" \
        "${stage}" \
        "https://github.com/Byron/dua-cli" \
        "MIT"
}

# ==============================================================================
# 10. gitui (Blazing fast terminal UI for git)
# ==============================================================================
build_gitui() {
    info "--- Building gitui (${GITUI_VERSION}) ---"
    local stage="${WORK_DIR}/stage-gitui"
    rm -rf "${stage}"
    mkdir -p "${stage}/usr/bin"

    install_or_compile_rust_bin \
        "gitui" \
        "https://github.com/extrawurst/gitui.git" \
        "${GITUI_VERSION}" \
        "gitui" \
        "${stage}/usr/bin" \
        "true"

    package_deb \
        "gitui" \
        "${GITUI_VERSION}" \
        "libc6, git" \
        "Blazing fast terminal-UI for Git written in Rust" \
        "${stage}" \
        "https://github.com/extrawurst/gitui" \
        "MIT"
}

# ==============================================================================
# Main Build Execution & APT Index Generation
# ==============================================================================
main() {
    info "Starting ${DISTRO_NAME} package build for Debian ${DEBIAN_RELEASE} (${ARCH})"
    cat > "${OUTPUT_DIR}/SOURCE_MANIFEST.txt" <<EOF
# ${DISTRO_NAME} (${DISTRO_VERSION}) Corresponding Source Manifest (GNU GPLv3 Section 6)
# Packaging & Build Pipeline License: GPL-3.0-or-later (https://github.com/${GITHUB_REPO:-voidframe/voidframe})
# ----------------------------------------------------------------------------------------
# PACKAGE        TAG            UPSTREAM_LICENSE   UPSTREAM_SOURCE_URL
EOF

    build_lemurs
    build_tuios
    build_yazi
    build_wiremix
    build_impala
    build_bluetui
    build_bottom
    build_systemctl_tui
    build_dua_cli
    build_gitui

    info "Generating APT repository index (Packages & Packages.gz) in ${OUTPUT_DIR}..."
    (
        cd "${OUTPUT_DIR}"
        dpkg-scanpackages --multiversion . /dev/null > Packages
        gzip -9c Packages > Packages.gz
        sha256sum ./*.deb Packages Packages.gz SOURCE_MANIFEST.txt > SHA256SUMS
    )

    info "All 10 .deb packages successfully built in ${OUTPUT_DIR}:"
    ls -lh "${OUTPUT_DIR}"/*.deb
}

main "$@"
