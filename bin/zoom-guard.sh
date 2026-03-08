#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${MAC_POWER_UTILS_CONFIG:-$HOME/.config/mac-power-utils/mac-power-utils.conf}"
STATE_FILE="/tmp/zoom-guard.state"
LOG_FILE="$HOME/Library/Logs/zoom-guard.log"

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        local key="${line%%=*}"
        local value="${line#*=}"
        key="${key//[[:space:]]/}"

        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
            value="${value:1:${#value}-2}"
        fi

        if [[ -z "${!key+x}" ]]; then
            printf -v "$key" "%s" "$value"
        fi
    done < "$CONFIG_FILE"
}

load_config

IDLE_TIMEOUT_MIN="${IDLE_TIMEOUT_MIN:-${ZOOM_GUARD_IDLE_TIMEOUT_MIN:-5}}"
THROTTLE_ON_BATTERY="${THROTTLE_ON_BATTERY:-${ZOOM_GUARD_THROTTLE_ON_BATTERY:-true}}"
CHECK_INTERVAL="${ZOOM_GUARD_CHECK_INTERVAL_SEC:-15}"
LOCK_DIR="/tmp/zoom-guard.lock"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [zoom-guard] $*" >> "$LOG_FILE"
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid"
        trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
        return
    fi

    local existing_pid
    existing_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
        log "Another instance is already running (pid=$existing_pid), exiting"
        exit 0
    fi

    rm -rf "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid"
        trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
        return
    fi

    log "Failed to acquire lock at $LOCK_DIR"
    exit 1
}

notify() {
    osascript -e "display notification \"$1\" with title \"Zoom Guard\"" 2>/dev/null || true
}

is_zoom_running() {
    pgrep -x "zoom.us" >/dev/null 2>&1
}

is_in_meeting() {
    lsof -i -n -P 2>/dev/null | grep "zoom.us" | grep -q "ESTABLISHED"
}

is_on_battery() {
    pmset -g batt 2>/dev/null | grep -q "Battery Power"
}

get_idle_start() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "0"
    fi
}

set_idle_start() {
    echo "$1" > "$STATE_FILE"
}

clear_idle_start() {
    echo "0" > "$STATE_FILE"
}

kill_zoom() {
    log "Killing idle Zoom (idle for >${IDLE_TIMEOUT_MIN}min)"
    notify "Zoom is idle — quitting to save resources"
    killall "zoom.us" 2>/dev/null || true
    killall "CptHost" 2>/dev/null || true
    killall "ZoomAutoUpdater" 2>/dev/null || true
    clear_idle_start
}

throttle_zoom() {
    local zoom_pid
    zoom_pid=$(pgrep -x "zoom.us" 2>/dev/null || true)
    if [[ -n "$zoom_pid" ]]; then
        renice 10 -p "$zoom_pid" >/dev/null 2>&1 || true
    fi

    local cpthost_pid
    cpthost_pid=$(pgrep -x "CptHost" 2>/dev/null || true)
    if [[ -n "$cpthost_pid" ]]; then
        renice 15 -p "$cpthost_pid" >/dev/null 2>&1 || true
    fi
}

unthrottle_zoom() {
    local zoom_pid
    zoom_pid=$(pgrep -x "zoom.us" 2>/dev/null || true)
    if [[ -n "$zoom_pid" ]]; then
        renice 0 -p "$zoom_pid" >/dev/null 2>&1 || true
    fi

    local cpthost_pid
    cpthost_pid=$(pgrep -x "CptHost" 2>/dev/null || true)
    if [[ -n "$cpthost_pid" ]]; then
        renice 0 -p "$cpthost_pid" >/dev/null 2>&1 || true
    fi
}

cleanup_stale_cpthost() {
    if pgrep -x "CptHost" >/dev/null 2>&1 && ! is_in_meeting; then
        log "Killing orphaned CptHost (no active meeting)"
        killall "CptHost" 2>/dev/null || true
    fi
}

acquire_lock
log "Started with idle_timeout=${IDLE_TIMEOUT_MIN}min throttle_on_battery=${THROTTLE_ON_BATTERY} check_interval=${CHECK_INTERVAL}s config=${CONFIG_FILE}"

while true; do
    if ! is_zoom_running; then
        clear_idle_start
        cleanup_stale_cpthost
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if is_in_meeting; then
        clear_idle_start

        if [[ "$THROTTLE_ON_BATTERY" == "true" ]] && is_on_battery; then
            throttle_zoom
        else
            unthrottle_zoom
        fi
    else
        idle_start=$(get_idle_start)
        now=$(date +%s)

        if [[ "$idle_start" -eq 0 ]]; then
            set_idle_start "$now"
            log "Zoom idle detected, starting timer"
        else
            idle_seconds=$(( now - idle_start ))
            idle_minutes=$(( idle_seconds / 60 ))

            if [[ "$idle_minutes" -ge "$IDLE_TIMEOUT_MIN" ]]; then
                kill_zoom
            fi
        fi
    fi

    cleanup_stale_cpthost
    sleep "$CHECK_INTERVAL"
done
