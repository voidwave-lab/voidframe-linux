#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Voidframe Maintainers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# ==============================================================================
# Voidframe Shared Console UI & Progress Bar Library (setup/ui.sh)
# ==============================================================================
# Provides structured ANSI stage banners, visual Unicode/ASCII progress bars,
# formatted status messages, and live hooks for Debian Installer (db_progress).
# ==============================================================================

UI_DISTRO="${DISTRO_NAME:-voidframe}"

# Detect whether UTF-8 box/block characters are safe on current terminal
if [[ "${LC_ALL:-${LANG:-}}" =~ [Uu][Tt][Ff]-?8 ]] && [[ "${TERM:-}" != "linux" ]]; then
    UI_BAR_FILL="█"
    UI_BAR_EMPTY="░"
    UI_BOX_TL="┌"
    UI_BOX_TR="┐"
    UI_BOX_BL="└"
    UI_BOX_BR="┘"
    UI_BOX_H="─"
    UI_BOX_V="│"
    UI_ARROW="▸"
    UI_OK="✓"
    UI_WARN="!"
    UI_ERR="✗"
else
    UI_BAR_FILL="#"
    UI_BAR_EMPTY="-"
    UI_BOX_TL="+"
    UI_BOX_TR="+"
    UI_BOX_BL="+"
    UI_BOX_BR="+"
    UI_BOX_H="-"
    UI_BOX_V="|"
    UI_ARROW=">"
    UI_OK="OK"
    UI_WARN="!!"
    UI_ERR="XX"
fi

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_CYAN="\033[1;36m"
C_MAG="\033[1;35m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_WHITE="\033[1;37m"

# Notify external progress listener (e.g., setup/di-late-runner.sh for cdebconf db_progress)
_ui_emit_hook() {
    local pct="$1"
    local msg="$2"
    if [[ -n "${VOIDFRAME_PROGRESS_LOG:-}" ]]; then
        printf "%s|%s\n" "${pct}" "${msg}" >> "${VOIDFRAME_PROGRESS_LOG}" 2>/dev/null || true
    fi
}

# Build a visual progress bar string of given width (default 32)
_ui_make_bar() {
    local pct="$1"
    local width="${2:-32}"
    if (( pct < 0 )); then
        pct=0
    fi
    if (( pct > 100 )); then
        pct=100
    fi

    local filled=$(( (pct * width) / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    local i
    for (( i = 0; i < filled; i++ )); do
        bar+="${UI_BAR_FILL}"
    done
    for (( i = 0; i < empty; i++ )); do
        bar+="${UI_BAR_EMPTY}"
    done
    printf "%s" "${bar}"
}

_ui_repeat() {
    local ch="$1"
    local count="$2"
    local out=""
    local i
    for (( i = 0; i < count; i++ )); do
        out+="${ch}"
    done
    printf "%s" "${out}"
}

ui_banner() {
    local version="${1:-0.1.0}"
    local release="${2:-trixie}"
    local arch="${3:-amd64}"
    local mode="${4:-online}"
    local target_user="${5:-void}"
    local distro_upper
    distro_upper="$(printf "%s" "${UI_DISTRO}" | tr '[:lower:]' '[:upper:]')"
    local line
    line="$(_ui_repeat "${UI_BOX_H}" 66)"

    printf "\n%b%s%s%s%b\n" "${C_CYAN}" "${UI_BOX_TL}" "${line}" "${UI_BOX_TR}" "${C_RESET}"
    printf "%b%s%b  %b%-62s%b  %b%s%b\n" \
        "${C_CYAN}" "${UI_BOX_V}" "${C_RESET}" \
        "${C_WHITE}" "${distro_upper} v${version} -- TUI Operating System Provisioner" "${C_RESET}" \
        "${C_CYAN}" "${UI_BOX_V}" "${C_RESET}"
    printf "%b%s%b  %-62s  %b%s%b\n" \
        "${C_CYAN}" "${UI_BOX_V}" "${C_RESET}" \
        "Target: Debian ${release} (${arch})  |  Mode: ${mode}  |  User: ${target_user}" \
        "${C_CYAN}" "${UI_BOX_V}" "${C_RESET}"
    printf "%b%s%s%s%b\n\n" "${C_CYAN}" "${UI_BOX_BL}" "${line}" "${UI_BOX_BR}" "${C_RESET}"
}

ui_stage() {
    local stage_num="$1"
    local stage_total="$2"
    local pct="$3"
    local title="$4"

    local bar
    bar="$(_ui_make_bar "${pct}" 36)"
    local line
    line="$(_ui_repeat "${UI_BOX_H}" 66)"
    local header="STAGE ${stage_num}/${stage_total}: ${title}"

    printf "\n%b%s%s%s%b\n" "${C_MAG}" "${UI_BOX_TL}" "${line}" "${UI_BOX_TR}" "${C_RESET}"
    printf "%b%s%b  %b%-62s%b  %b%s%b\n" \
        "${C_MAG}" "${UI_BOX_V}" "${C_RESET}" \
        "${C_WHITE}" "${header:0:62}" "${C_RESET}" \
        "${C_MAG}" "${UI_BOX_V}" "${C_RESET}"
    printf "%b%s%b  %b[%s]%b %b%3d%%%b%-19s  %b%s%b\n" \
        "${C_MAG}" "${UI_BOX_V}" "${C_RESET}" \
        "${C_CYAN}" "${bar}" "${C_RESET}" \
        "${C_BOLD}" "${pct}" "${C_RESET}" "" \
        "${C_MAG}" "${UI_BOX_V}" "${C_RESET}"
    printf "%b%s%s%s%b\n" "${C_MAG}" "${UI_BOX_BL}" "${line}" "${UI_BOX_BR}" "${C_RESET}"

    _ui_emit_hook "${pct}" "[Stage ${stage_num}/${stage_total}] ${title}"
}

ui_progress() {
    local pct="$1"
    local msg="$2"
    local bar
    bar="$(_ui_make_bar "${pct}" 24)"

    printf "  %b[%s]%b %b%3d%%%b  %b%s%b %s\n" \
        "${C_CYAN}" "${bar}" "${C_RESET}" \
        "${C_WHITE}" "${pct}" "${C_RESET}" \
        "${C_MAG}" "${UI_ARROW}" "${C_RESET}" \
        "${msg}"

    _ui_emit_hook "${pct}" "${msg}"
}

ui_info() {
    printf "  %b[%s]%b  %s\n" "${C_CYAN}" "${UI_DISTRO}" "${C_RESET}" "$*"
}

ui_step() {
    printf "  %b%s%b %b%s%b\n" "${C_CYAN}" "${UI_ARROW}" "${C_RESET}" "${C_WHITE}" "$*" "${C_RESET}"
}

ui_ok() {
    printf "  %b[%s]%b  %s\n" "${C_GREEN}" "${UI_OK}" "${C_RESET}" "$*"
}

ui_warn() {
    printf "  %b[%s]%b  %s\n" "${C_YELLOW}" "${UI_WARN}" "${C_RESET}" "$*" >&2
}

ui_error() {
    printf "  %b[%s]%b  %s\n" "${C_RED}" "${UI_ERR}" "${C_RESET}" "$*" >&2
    exit 1
}

ui_summary() {
    local total_secs="$1"
    local distro_upper
    distro_upper="$(printf "%s" "${UI_DISTRO}" | tr '[:lower:]' '[:upper:]')"
    local line
    line="$(_ui_repeat "${UI_BOX_H}" 66)"
    local bar
    bar="$(_ui_make_bar 100 36)"

    printf "\n%b%s%s%s%b\n" "${C_GREEN}" "${UI_BOX_TL}" "${line}" "${UI_BOX_TR}" "${C_RESET}"
    printf "%b%s%b  %b%-62s%b  %b%s%b\n" \
        "${C_GREEN}" "${UI_BOX_V}" "${C_RESET}" \
        "${C_WHITE}" "${distro_upper} PROVISIONING COMPLETED IN ${total_secs}s!" "${C_RESET}" \
        "${C_GREEN}" "${UI_BOX_V}" "${C_RESET}"
    printf "%b%s%b  %b[%s]%b %b100%%%b%-19s  %b%s%b\n" \
        "${C_GREEN}" "${UI_BOX_V}" "${C_RESET}" \
        "${C_GREEN}" "${bar}" "${C_RESET}" \
        "${C_BOLD}" "${C_RESET}" "" \
        "${C_GREEN}" "${UI_BOX_V}" "${C_RESET}"
    printf "%b%s%b  %-62s  %b%s%b\n" \
        "${C_GREEN}" "${UI_BOX_V}" "${C_RESET}" \
        "Session pipeline: tty2 (Lemurs) -> Cage -> Foot -> TUIOS" \
        "${C_GREEN}" "${UI_BOX_V}" "${C_RESET}"
    printf "%b%s%s%s%b\n\n" "${C_GREEN}" "${UI_BOX_BL}" "${line}" "${UI_BOX_BR}" "${C_RESET}"

    _ui_emit_hook "100" "${UI_DISTRO} provisioning completed (${total_secs}s)! Preparing reboot..."
}
