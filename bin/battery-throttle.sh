#!/usr/bin/env bash
set -euo pipefail

CHECK_INTERVAL=60
STATE_FILE="/tmp/battery-throttle.state"
LOG_FILE="$HOME/Library/Logs/battery-throttle.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [battery-throttle] $*" >> "$LOG_FILE"
}

notify() {
    osascript -e "display notification \"$1\" with title \"Battery Throttle\"" 2>/dev/null || true
}

is_on_battery() {
    pmset -g batt 2>/dev/null | grep -q "Battery Power"
}

get_last_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "unknown"
    fi
}

set_state() {
    echo "$1" > "$STATE_FILE"
}

renice_pids() {
    local priority="$1"
    shift
    for pid in "$@"; do
        renice "$priority" -p "$pid" >/dev/null 2>&1 || true
    done
}

apply_battery_mode() {
    log "Transition to BATTERY — applying throttle"

    sudo pmset -b lowpowermode 1 2>/dev/null && \
        log "Enabled Low Power Mode" || \
        log "Failed to enable Low Power Mode (sudo needed)"

    local edge_pids
    edge_pids=$(pgrep -f "Microsoft Edge.*--type=renderer" 2>/dev/null || true)
    if [[ -n "$edge_pids" ]]; then
        renice_pids 10 $edge_pids
        log "Reniced Edge renderer processes to 10"
    fi

    local zoom_pid
    zoom_pid=$(pgrep -x "zoom.us" 2>/dev/null || true)
    if [[ -n "$zoom_pid" ]]; then
        renice_pids 10 $zoom_pid
        log "Reniced Zoom to 10"
    fi

    notify "On battery — throttling enabled"
    set_state "battery"
}

apply_ac_mode() {
    log "Transition to AC — reverting throttle"

    sudo pmset -b lowpowermode 0 2>/dev/null && \
        log "Disabled Low Power Mode" || \
        log "Failed to disable Low Power Mode (sudo needed)"

    local edge_pids
    edge_pids=$(pgrep -f "Microsoft Edge.*--type=renderer" 2>/dev/null || true)
    if [[ -n "$edge_pids" ]]; then
        renice_pids 0 $edge_pids
        log "Restored Edge renderer processes to priority 0"
    fi

    local zoom_pid
    zoom_pid=$(pgrep -x "zoom.us" 2>/dev/null || true)
    if [[ -n "$zoom_pid" ]]; then
        renice_pids 0 $zoom_pid
        log "Restored Zoom to priority 0"
    fi

    notify "On AC power — full performance restored"
    set_state "ac"
}

log "Started"

while true; do
    last_state=$(get_last_state)

    if is_on_battery; then
        if [[ "$last_state" != "battery" ]]; then
            apply_battery_mode
        fi
    else
        if [[ "$last_state" != "ac" ]]; then
            apply_ac_mode
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
