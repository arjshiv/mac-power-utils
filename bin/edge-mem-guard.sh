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
KILL_AFTER_BREACHES="${EDGE_MEM_GUARD_KILL_AFTER_BREACHES:-2}"
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
    total_kb=$(ps -axo rss=,command= 2>/dev/null \
        | awk 'index($0, "Microsoft Edge") > 0 {sum += $1} END {print sum+0}')
    echo $(( total_kb / 1024 ))
}

get_renderer_pids() {
    ps -axo pid=,command= 2>/dev/null \
        | awk 'index($0, "Microsoft Edge") > 0 && index($0, "--type=renderer") > 0 {print $1}'
}

kill_renderers() {
    local pids
    pids="$(get_renderer_pids)"
    if [[ -z "$pids" ]]; then
        log "No renderer processes found to kill"
        return
    fi

    local count=0
    while IFS= read -r pid; do
        kill -15 "$pid" 2>/dev/null && count=$((count + 1))
    done <<< "$pids"

    if [[ "$count" -gt 0 ]]; then
        log "Sent SIGTERM to $count renderer processes"
        notify "Killed $count Edge tabs to free memory"
        sleep 5
    else
        log "Renderer processes were detected but no SIGTERM was delivered"
    fi
}

acquire_lock
log "Started with threshold=${THRESHOLD_MB}MB warn_pct=${WARN_PCT} check_interval=${CHECK_INTERVAL}s kill_after_breaches=${KILL_AFTER_BREACHES} config=${CONFIG_FILE}"

breach_count=0

while true; do
    mem_mb=$(get_edge_memory_mb)

    if [[ "$mem_mb" -eq 0 ]]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    warn_threshold=$(( THRESHOLD_MB * WARN_PCT / 100 ))

    if [[ "$mem_mb" -gt "$THRESHOLD_MB" ]]; then
        breach_count=$(( breach_count + 1 ))
        log "BREACH: Edge using ${mem_mb}MB (threshold: ${THRESHOLD_MB}MB, consecutive=${breach_count}/${KILL_AFTER_BREACHES})"

        if [[ "$breach_count" -ge "$KILL_AFTER_BREACHES" ]]; then
            kill_renderers
            breach_count=0
        fi
    elif [[ "$mem_mb" -gt "$warn_threshold" ]]; then
        breach_count=0
        log "WARN: Edge using ${mem_mb}MB (${WARN_PCT}% of ${THRESHOLD_MB}MB threshold)"
    else
        breach_count=0
    fi

    sleep "$CHECK_INTERVAL"
done
