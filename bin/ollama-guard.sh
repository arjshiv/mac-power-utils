#!/usr/bin/env bash
set -euo pipefail

IDLE_TIMEOUT_MIN="${OLLAMA_IDLE_TIMEOUT_MIN:-10}"
CHECK_INTERVAL=30
STATE_FILE="/tmp/ollama-guard.state"
LOG_FILE="$HOME/Library/Logs/ollama-guard.log"
API_URL="http://localhost:11434"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ollama-guard] $*" >> "$LOG_FILE"
}

notify() {
    osascript -e "display notification \"$1\" with title \"Ollama Guard\"" 2>/dev/null || true
}

get_loaded_models() {
    curl -sf "$API_URL/api/ps" 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('models', []):
    print(m['name'])
" 2>/dev/null || true
}

is_generating() {
    local runner_pids
    runner_pids=$(pgrep -f "ollama.*runner" 2>/dev/null || true)
    if [[ -z "$runner_pids" ]]; then
        return 1
    fi

    while IFS= read -r pid; do
        local cpu
        cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | awk '{printf "%d", $1}')
        if [[ "${cpu:-0}" -gt 5 ]]; then
            return 0
        fi
    done <<< "$runner_pids"
    return 1
}

stop_model() {
    local model="$1"
    local size_before
    size_before=$(curl -sf "$API_URL/api/ps" 2>/dev/null \
        | python3 -c "
import sys, json
total = sum(m.get('size_vram', 0) + m.get('size', 0) for m in json.load(sys.stdin).get('models', []))
print(total // (1024*1024))
" 2>/dev/null || echo "0")

    curl -sf "$API_URL/api/generate" \
        -d "{\"model\": \"$model\", \"keep_alive\": 0}" \
        >/dev/null 2>&1 || true

    log "Unloaded $model (was using ~${size_before}MB VRAM/RAM)"
    notify "Unloaded $model — freed ~${size_before}MB"
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

clear_idle() {
    echo "0" > "$STATE_FILE"
}

log "Started with idle_timeout=${IDLE_TIMEOUT_MIN}min"

while true; do
    models=$(get_loaded_models)

    if [[ -z "$models" ]]; then
        clear_idle
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if is_generating; then
        clear_idle
        sleep "$CHECK_INTERVAL"
        continue
    fi

    idle_start=$(get_idle_start)
    now=$(date +%s)

    if [[ "$idle_start" -eq 0 ]]; then
        set_idle_start "$now"
        log "Model(s) idle, starting timer: $models"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    idle_seconds=$(( now - idle_start ))
    idle_minutes=$(( idle_seconds / 60 ))

    if [[ "$idle_minutes" -ge "$IDLE_TIMEOUT_MIN" ]]; then
        log "Idle for ${idle_minutes}min (threshold: ${IDLE_TIMEOUT_MIN}min) — unloading"
        while IFS= read -r model; do
            [[ -n "$model" ]] && stop_model "$model"
        done <<< "$models"
        clear_idle
    fi

    sleep "$CHECK_INTERVAL"
done
