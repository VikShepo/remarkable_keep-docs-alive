#!/bin/sh
set -eu

NAME="remarkable-keepalive"
XOCHITL_DIR="${XOCHITL_DIR:-/home/root/.local/share/remarkable/xochitl}"
STATE_DIR="${STATE_DIR:-/home/root/.local/share/${NAME}}"
BACKUP_DIR="${BACKUP_DIR:-${STATE_DIR}/backups}"
LOG_FILE="${LOG_FILE:-${STATE_DIR}/${NAME}.log}"
LOCK_DIR="/tmp/${NAME}.lock"
THRESHOLD_DAYS="${THRESHOLD_DAYS:-30}"
SYNC_TIMEOUT_SEC="${SYNC_TIMEOUT_SEC:-900}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-10}"
RESTART_XOCHITL="${RESTART_XOCHITL:-1}"
DRY_RUN="${DRY_RUN:-0}"

if [ -f /etc/default/remarkable-keepalive ]; then
    # shellcheck disable=SC1091
    . /etc/default/remarkable-keepalive
fi

mkdir -p "${STATE_DIR}" "${BACKUP_DIR}"

log() {
    stamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s %s\n' "${stamp}" "$*" >> "${LOG_FILE}"
}

cleanup() {
    rm -rf "${LOCK_DIR}"
}

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    exit 0
fi
trap cleanup EXIT INT TERM

json_string() {
    key="$1"
    file="$2"
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${file}" | head -n 1
}

json_number() {
    key="$1"
    file="$2"
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "${file}" | head -n 1
}

json_bool() {
    key="$1"
    file="$2"
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" "${file}" | head -n 1
}

xochitl_running() {
    pidof xochitl >/dev/null 2>&1
}

wifi_connected() {
    if command -v iwgetid >/dev/null 2>&1; then
        ssid="$(iwgetid -r 2>/dev/null || true)"
        if [ -n "${ssid}" ]; then
            return 0
        fi
    fi

    for state_file in /sys/class/net/wlan0/operstate /sys/class/net/wlp1s0/operstate; do
        if [ -f "${state_file}" ]; then
            state="$(cat "${state_file}" 2>/dev/null || true)"
            case "${state}" in
                up|unknown)
                    return 0
                    ;;
            esac
        fi
    done

    if command -v ip >/dev/null 2>&1; then
        if ip route get 8.8.8.8 >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

metadata_due() {
    file="$1"
    now_s="$2"

    type_value="$(json_string type "${file}")"
    deleted_value="$(json_bool deleted "${file}")"

    if [ "${type_value}" != "DocumentType" ]; then
        return 1
    fi

    if [ "${deleted_value}" = "true" ]; then
        return 1
    fi

    last_opened_ms="$(json_string lastOpened "${file}")"
    if [ -z "${last_opened_ms}" ]; then
        last_opened_ms=0
    fi

    last_opened_s=$((last_opened_ms / 1000))
    age_limit_s=$((THRESHOLD_DAYS * 86400))

    if [ $((now_s - last_opened_s)) -ge "${age_limit_s}" ]; then
        return 0
    fi

    return 1
}

refresh_metadata() {
    file="$1"
    now_ms="$2"
    tmp_file="${file}.tmp.$$"

    awk -v now_ms="${now_ms}" '
        BEGIN {
            touched_last_opened = 0
            touched_last_modified = 0
            touched_synced = 0
            touched_metadata_modified = 0
            touched_modified = 0
        }
        /^[[:space:]]*"lastOpened"[[:space:]]*:/ {
            sub(/"[^"]*"[[:space:]]*,?[[:space:]]*$/, "\"" now_ms "\",")
            touched_last_opened = 1
            print
            next
        }
        /^[[:space:]]*"lastModified"[[:space:]]*:/ {
            sub(/"[^"]*"[[:space:]]*,?[[:space:]]*$/, "\"" now_ms "\",")
            touched_last_modified = 1
            print
            next
        }
        /^[[:space:]]*"synced"[[:space:]]*:/ {
            sub(/(true|false)[[:space:]]*,?[[:space:]]*$/, "false,")
            touched_synced = 1
            print
            next
        }
        /^[[:space:]]*"metadatamodified"[[:space:]]*:/ {
            sub(/(true|false)[[:space:]]*,?[[:space:]]*$/, "true,")
            touched_metadata_modified = 1
            print
            next
        }
        /^[[:space:]]*"modified"[[:space:]]*:/ {
            sub(/(true|false)[[:space:]]*,?[[:space:]]*$/, "true,")
            touched_modified = 1
            print
            next
        }
        {
            print
        }
        END {
            if (touched_last_opened && touched_last_modified && touched_synced && touched_metadata_modified && touched_modified) {
                exit 0
            }
            exit 3
        }
    ' "${file}" > "${tmp_file}" || {
        rm -f "${tmp_file}"
        return 1
    }

    mv "${tmp_file}" "${file}"
    return 0
}

wait_for_sync() {
    file="$1"
    deadline=$(( $(date +%s) + SYNC_TIMEOUT_SEC ))

    while [ "$(date +%s)" -lt "${deadline}" ]; do
        synced_value="$(json_bool synced "${file}")"
        if [ "${synced_value}" = "true" ]; then
            return 0
        fi
        sleep "${POLL_INTERVAL_SEC}"
    done

    return 1
}

if [ ! -d "${XOCHITL_DIR}" ]; then
    log "skip: missing xochitl directory at ${XOCHITL_DIR}"
    exit 0
fi

if ! xochitl_running; then
    log "skip: xochitl is not running"
    exit 0
fi

if ! wifi_connected; then
    log "skip: wifi is not connected"
    exit 0
fi

PENDING_FILE="${STATE_DIR}/pending.$$"
UPDATED_FILE="${STATE_DIR}/updated.$$"
touch "${PENDING_FILE}" "${UPDATED_FILE}"

now_s="$(date +%s)"
now_ms=$((now_s * 1000))

for metadata_file in "${XOCHITL_DIR}"/*.metadata; do
    [ -e "${metadata_file}" ] || continue
    if metadata_due "${metadata_file}" "${now_s}"; then
        printf '%s\n' "${metadata_file}" >> "${PENDING_FILE}"
    fi
done

pending_count="$(wc -l < "${PENDING_FILE}" | tr -d ' ')"
if [ "${pending_count}" -eq 0 ]; then
    log "ok: no documents older than ${THRESHOLD_DAYS} days"
    rm -f "${PENDING_FILE}" "${UPDATED_FILE}"
    exit 0
fi

log "refresh: found ${pending_count} document(s) due for keepalive"

while IFS= read -r metadata_file; do
    [ -n "${metadata_file}" ] || continue
    base_name="$(basename "${metadata_file}" .metadata)"
    backup_file="${BACKUP_DIR}/${base_name}.metadata.${now_s}.bak"

    if [ "${DRY_RUN}" = "1" ]; then
        log "dry-run: would refresh ${base_name}"
        printf '%s\n' "${metadata_file}" >> "${UPDATED_FILE}"
        continue
    fi

    cp "${metadata_file}" "${backup_file}"
    if refresh_metadata "${metadata_file}" "${now_ms}"; then
        printf '%s\n' "${metadata_file}" >> "${UPDATED_FILE}"
        log "refresh: updated ${base_name}"
    else
        log "failed: could not rewrite ${base_name}"
    fi
done < "${PENDING_FILE}"

updated_count="$(wc -l < "${UPDATED_FILE}" | tr -d ' ')"
if [ "${updated_count}" -eq 0 ]; then
    log "failed: nothing was updated"
    rm -f "${PENDING_FILE}" "${UPDATED_FILE}"
    exit 1
fi

if [ "${DRY_RUN}" != "1" ] && [ "${RESTART_XOCHITL}" = "1" ]; then
    log "refresh: restarting xochitl so it reloads refreshed metadata"
    systemctl restart xochitl
    sleep 20
fi

sync_failures=0
while IFS= read -r metadata_file; do
    [ -n "${metadata_file}" ] || continue
    base_name="$(basename "${metadata_file}" .metadata)"

    if [ "${DRY_RUN}" = "1" ]; then
        log "dry-run: skipping sync wait for ${base_name}"
        continue
    fi

    if wait_for_sync "${metadata_file}"; then
        log "sync: confirmed ${base_name}"
    else
        sync_failures=$((sync_failures + 1))
        log "failed: sync timeout for ${base_name}"
    fi
done < "${UPDATED_FILE}"

rm -f "${PENDING_FILE}" "${UPDATED_FILE}"

if [ "${sync_failures}" -gt 0 ]; then
    exit 1
fi

log "ok: keepalive refresh completed"
