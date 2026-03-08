#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${MAC_POWER_UTILS_CONFIG:-$HOME/.config/mac-power-utils/mac-power-utils.conf}"
LOG_FILE="$HOME/Library/Logs/edge-mem-guard.log"

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

THRESHOLD_MB="${1:-${EDGE_MEM_GUARD_THRESHOLD_MB:-4096}}"
WARN_PCT="${EDGE_MEM_GUARD_WARN_PCT:-80}"
CHECK_INTERVAL="${EDGE_MEM_GUARD_CHECK_INTERVAL_SEC:-30}"
LOCK_DIR="/tmp/edge-mem-guard.lock"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [edge-mem-guard] $*" >> "$LOG_FILE"
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

acquire_lock
log "Started with threshold=${THRESHOLD_MB}MB warn_pct=${WARN_PCT} check_interval=${CHECK_INTERVAL}s config=${CONFIG_FILE}"

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
