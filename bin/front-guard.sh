#!/usr/bin/env bash
set -euo pipefail

MEMORY_THRESHOLD_MB="${FRONT_MEMORY_THRESHOLD_MB:-512}"
BACKGROUND_TIMEOUT_MIN="${FRONT_BACKGROUND_TIMEOUT_MIN:-15}"
CHECK_INTERVAL=30
STATE_FILE="/tmp/front-guard.state"
LOG_FILE="$HOME/Library/Logs/front-guard.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [front-guard] $*" >> "$LOG_FILE"
}

notify() {
    osascript -e "display notification \"$1\" with title \"Front Guard\"" 2>/dev/null || true
}

is_front_running() {
    pgrep -x "Front" >/dev/null 2>&1
}

get_front_memory_mb() {
    ps -eo rss,comm 2>/dev/null \
        | grep "Front" \
        | awk '{sum += $1} END {printf "%d", sum/1024}'
}

is_frontmost() {
    local frontmost
    frontmost=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)
    [[ "$frontmost" == "Front" ]]
}

has_visible_windows() {
    local count
    count=$(osascript -e 'tell application "System Events" to count of windows of process "Front"' 2>/dev/null || echo "0")
    [[ "$count" -gt 0 ]]
}

is_composing() {
    local titles
    titles=$(osascript -e '
        tell application "System Events"
            tell process "Front"
                set windowNames to name of every window
            end tell
        end tell
        return windowNames as text
    ' 2>/dev/null || true)
    [[ "$titles" == *"New conversation"* ]] || [[ "$titles" == *"Reply"* ]] || [[ "$titles" == *"Compose"* ]]
}

get_background_start() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "0"
    fi
}

set_background_start() {
    echo "$1" > "$STATE_FILE"
}

clear_background_start() {
    echo "0" > "$STATE_FILE"
}

restart_front() {
    local mem_before="$1"
    log "Restarting Front (was using ${mem_before}MB backgrounded)"
    killall "Front" 2>/dev/null || true
    sleep 2
    open -g -a "Front"
    sleep 5
    local mem_after
    mem_after=$(get_front_memory_mb)
    log "Front restarted: ${mem_before}MB -> ${mem_after}MB"
    notify "Restarted Front: ${mem_before}MB -> ${mem_after}MB"
    clear_background_start
}

log "Started with memory_threshold=${MEMORY_THRESHOLD_MB}MB, background_timeout=${BACKGROUND_TIMEOUT_MIN}min"

while true; do
    if ! is_front_running; then
        clear_background_start
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if is_frontmost || has_visible_windows; then
        clear_background_start
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if is_composing; then
        clear_background_start
        sleep "$CHECK_INTERVAL"
        continue
    fi

    mem_mb=$(get_front_memory_mb)

    if [[ "$mem_mb" -lt "$MEMORY_THRESHOLD_MB" ]]; then
        clear_background_start
        sleep "$CHECK_INTERVAL"
        continue
    fi

    bg_start=$(get_background_start)
    now=$(date +%s)

    if [[ "$bg_start" -eq 0 ]]; then
        set_background_start "$now"
        log "Front backgrounded at ${mem_mb}MB, starting timer"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    bg_seconds=$(( now - bg_start ))
    bg_minutes=$(( bg_seconds / 60 ))

    if [[ "$bg_minutes" -ge "$BACKGROUND_TIMEOUT_MIN" ]]; then
        restart_front "$mem_mb"
    fi

    sleep "$CHECK_INTERVAL"
done
