#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Voidframe Maintainers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
set -e

# ==============================================================================
# Voidframe Debian-Installer Late-Command Progress Runner (di-late-runner.sh)
# ==============================================================================
# Executed inside the Debian-Installer environment by preseed/late_command.
# Connects Voidframe's setup/bootstrap.sh stage & sub-step updates directly to:
#   1. Debian Installer's main GUI/TUI progress bar (cdebconf db_progress INFO)
#   2. Virtual console /dev/tty3 (live pretty ANSI progress bars & stage cards,
#      with automatic VT switch in text/TUI mode so output is front-and-center)
#   3. Syslog (/dev/tty4 via logger -t voidframe) & /target/var/log/voidframe-install.log
# ==============================================================================

DISTRO_NAME="${1:-voidframe}"
TARGET_USER="${2:-void}"

# Load debconf client library so we can update the visible d-i progress bar live
# shellcheck disable=SC1091
. /usr/share/debconf/confmodule

TEMPLATE_FILE="/tmp/voidframe-progress.templates"
cat > "${TEMPLATE_FILE}" <<'EOF'
Template: voidframe/progress/status
Type: text
Description: Voidframe [${BAR}] ${PCT}%: ${MSG} (Alt+F3 for full console)
EOF

debconf-loadtemplate voidframe "${TEMPLATE_FILE}" 2>/dev/null || true

make_mini_bar() {
    b_pct="$1"
    if [ "${b_pct}" -lt 0 ] 2>/dev/null; then
        b_pct=0
    fi
    if [ "${b_pct}" -gt 100 ] 2>/dev/null; then
        b_pct=100
    fi
    b_fill=$(( (b_pct * 16) / 100 ))
    b_empty=$(( 16 - b_fill ))
    b_out=""
    b_i=0
    while [ "${b_i}" -lt "${b_fill}" ]; do
        b_out="${b_out}#"
        b_i=$(( b_i + 1 ))
    done
    b_i=0
    while [ "${b_i}" -lt "${b_empty}" ]; do
        b_out="${b_out}-"
        b_i=$(( b_i + 1 ))
    done
    printf "%s" "${b_out}"
}

di_update_status() {
    pct="$1"
    msg="$2"
    bar="$(make_mini_bar "${pct}")"
    db_subst voidframe/progress/status BAR "${bar}" || true
    db_subst voidframe/progress/status PCT "${pct}" || true
    db_subst voidframe/progress/status MSG "${msg}" || true
    db_progress INFO voidframe/progress/status || true
    logger -t "${DISTRO_NAME}" "[${pct}%] ${msg}" 2>/dev/null || true
}

switch_vt() {
    vt_num="$1"
    if [ -z "${vt_num}" ]; then
        return 0
    fi
    if command -v chvt >/dev/null 2>&1; then
        chvt "${vt_num}" 2>/dev/null || true
    elif [ -x /target/usr/bin/chvt ]; then
        /target/usr/bin/chvt "${vt_num}" 2>/dev/null || true
    fi
}

di_update_status "2" "Copying Voidframe payload & offline .deb packages to /opt/${DISTRO_NAME}..."

mkdir -p "/target/opt/${DISTRO_NAME}" "/target/var/log"
cp -a "/cdrom/${DISTRO_NAME}/." "/target/opt/${DISTRO_NAME}/" 3>&- >/dev/null 2>&1
chmod +x "/target/opt/${DISTRO_NAME}/setup/"*.sh "/target/opt/${DISTRO_NAME}/configs/lemurs/wayland/tuios-session" 3>&- >/dev/null 2>&1

PROGRESS_FILE="/target/tmp/voidframe-progress.events"
RC_FILE="/target/tmp/voidframe-bootstrap.rc"
LOG_FILE="/target/var/log/${DISTRO_NAME}-install.log"
rm -f "${PROGRESS_FILE}" "${RC_FILE}"
: > "${PROGRESS_FILE}"
: > "${LOG_FILE}"

di_update_status "6" "Starting Voidframe TUI OS provisioning inside target system..."

# Detect current active VT (tty1 in newt TUI mode, tty5 in GTK Xorg mode)
ORIG_VT=""
if [ -r /sys/class/tty/tty0/active ]; then
    active_tty="$(cat /sys/class/tty/tty0/active 2>/dev/null || true)"
    ORIG_VT="${active_tty#tty}"
fi

# Prepare live pretty console output on /dev/tty3 if available
TTY_OUT="/dev/null"
SWITCHED_VT="false"
if [ -c /dev/tty3 ] && ( : > /dev/tty3 ) 2>/dev/null; then
    TTY_OUT="/dev/tty3"
    printf "\033c" > "${TTY_OUT}" 2>/dev/null || true
    # In text/TUI mode (tty1, where fbcon is active), switch directly to tty3
    # so the user watches full-screen colorful stage cards & progress bars live!
    if [ "${ORIG_VT}" = "1" ]; then
        switch_vt 3
        SWITCHED_VT="true"
    fi
fi

ESC="$(printf '\033')"

# Launch bootstrap.sh inside /target in the background:
# - Close debconf fd 3 and unset DEBIAN_HAS_FRONTEND so in-target does not invoke debconf-o-matic
# - Pass --pass-stdout and merge stderr->stdout inside /target so all console output streams live
(
    unset DEBIAN_HAS_FRONTEND DEBCONF_REDIR DEBCONF_OLD_FD_BASE
    in-target --pass-stdout /bin/bash -c "exec 2>&1; set -o pipefail; export TERM=linux LANG=C.UTF-8 DISTRO_NAME='${DISTRO_NAME}' TARGET_USER='${TARGET_USER}' VOIDFRAME_PROGRESS_LOG='/tmp/voidframe-progress.events'; /opt/${DISTRO_NAME}/setup/bootstrap.sh --offline --debs-dir '/opt/${DISTRO_NAME}/debs' --user '${TARGET_USER}' --distro '${DISTRO_NAME}'; printf '%s\n' \"\$?\" > /tmp/voidframe-bootstrap.rc" \
        </dev/null | while IFS= read -r line; do
            printf "%s\n" "${line}" > "${TTY_OUT}" 2>/dev/null || true
            clean_line="$(printf "%s" "${line}" | sed "s/${ESC}\[[0-9;]*m//g")"
            printf "%s\n" "${clean_line}" >> "${LOG_FILE}"
            if [ -n "${clean_line}" ]; then
                logger -t "${DISTRO_NAME}" "${clean_line}" 2>/dev/null || true
            fi
        done
) </dev/null 3>&- >/dev/null 2>&1 &
BOOTSTRAP_PID=$!

LAST_LINE_COUNT=0
while kill -0 "${BOOTSTRAP_PID}" 2>/dev/null; do
    if [ -s "${PROGRESS_FILE}" ]; then
        total_lines="$(wc -l < "${PROGRESS_FILE}" | tr -d ' ')"
        if [ "${total_lines}" -gt "${LAST_LINE_COUNT}" ]; then
            latest="$(tail -n 1 "${PROGRESS_FILE}")"
            ev_pct="${latest%%|*}"
            ev_msg="${latest#*|}"
            if [ -n "${ev_pct}" ] && [ -n "${ev_msg}" ]; then
                di_update_status "${ev_pct}" "${ev_msg}"
            fi
            LAST_LINE_COUNT="${total_lines}"
        fi
    fi
    sleep 1
done

wait "${BOOTSTRAP_PID}" || true
BOOT_RC="1"
if [ -f "${RC_FILE}" ]; then
    BOOT_RC="$(tr -d '[:space:]' < "${RC_FILE}")"
fi

# Verify bootstrap succeeded
if [ "${BOOT_RC}" != "0" ] || [ ! -x "/target/usr/bin/lemurs" ] || [ ! -x "/target/usr/bin/tuios" ]; then
    printf "\n\033[1;31m[XX] Voidframe provisioning failed (rc=%s). Full log: /var/log/%s-install.log\033[0m\n" "${BOOT_RC}" "${DISTRO_NAME}" > "${TTY_OUT}" 2>/dev/null || true
    if [ "${SWITCHED_VT}" = "true" ]; then
        sleep 4
        switch_vt "${ORIG_VT}"
    fi
    di_update_status "99" "ERROR: Voidframe provisioning failed! Check /var/log/${DISTRO_NAME}-install.log (Alt+F3)"
    exit 1
fi

rm -f "${PROGRESS_FILE}" "${RC_FILE}" "${TEMPLATE_FILE}"
di_update_status "100" "Voidframe TUI OS installed successfully! Finalizing boot loader..."
if [ "${SWITCHED_VT}" = "true" ]; then
    sleep 2
    switch_vt "${ORIG_VT}"
fi
exit 0
