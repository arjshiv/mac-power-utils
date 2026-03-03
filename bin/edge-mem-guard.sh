#!/usr/bin/env bash
set -euo pipefail

THRESHOLD_MB="${1:-4096}"
WARN_PCT=80
CHECK_INTERVAL=30
LOG_FILE="$HOME/Library/Logs/edge-mem-guard.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [edge-mem-guard] $*" >> "$LOG_FILE"
}

notify() {
    osascript -e "display notification \"$1\" with title \"Edge Memory Guard\"" 2>/dev/null || true
}

get_edge_memory_mb() {
    local total_kb
    total_kb=$(ps -eo rss,comm 2>/dev/null \
        | grep "Microsoft Edge" \
        | awk '{sum += $1} END {print sum+0}')
    echo $(( total_kb / 1024 ))
}

kill_renderers() {
    local pids
    pids=$(pgrep -f "Microsoft Edge.*--type=renderer" 2>/dev/null || true)
    if [[ -z "$pids" ]]; then
        log "No renderer processes found to kill"
        return
    fi

    local count=0
    while IFS= read -r pid; do
        kill -15 "$pid" 2>/dev/null && count=$((count + 1))
    done <<< "$pids"

    log "Sent SIGTERM to $count renderer processes"
    notify "Killed $count Edge tabs to free memory"
    sleep 5
}

log "Started with threshold=${THRESHOLD_MB}MB"

while true; do
    mem_mb=$(get_edge_memory_mb)

    if [[ "$mem_mb" -eq 0 ]]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    warn_threshold=$(( THRESHOLD_MB * WARN_PCT / 100 ))

    if [[ "$mem_mb" -gt "$THRESHOLD_MB" ]]; then
        log "KILL: Edge using ${mem_mb}MB (threshold: ${THRESHOLD_MB}MB)"
        kill_renderers
    elif [[ "$mem_mb" -gt "$warn_threshold" ]]; then
        log "WARN: Edge using ${mem_mb}MB (${WARN_PCT}% of ${THRESHOLD_MB}MB threshold)"
    fi

    sleep "$CHECK_INTERVAL"
done
