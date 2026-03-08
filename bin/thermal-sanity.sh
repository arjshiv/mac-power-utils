#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${MAC_POWER_UTILS_CONFIG:-$HOME/.config/mac-power-utils/mac-power-utils.conf}"

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

EDGE_THRESHOLD_MB="${EDGE_MEM_GUARD_THRESHOLD_MB:-4096}"
EDGE_WARN_PCT="${EDGE_MEM_GUARD_WARN_PCT:-80}"

LAUNCH_LABEL_EDGE="com.user.edge-mem-guard"
LAUNCH_LABEL_ZOOM="com.user.zoom-guard"
LAUNCH_LABEL_BATTERY="com.user.battery-throttle"
LAUNCH_LABEL_OLLAMA="com.user.ollama-guard"
LAUNCH_LABEL_FRONT="com.user.front-guard"

agent_loaded() {
    local label="$1"
    launchctl list 2>/dev/null | awk 'NR>1 {print $3}' | grep -Fxq "$label"
}

power_source() {
    pmset -g batt 2>/dev/null | awk -F"'" 'NR==1 {if (NF >= 2) {print $2; exit}}'
}

battery_percent() {
    pmset -g batt 2>/dev/null | awk 'NR==2 {for (i=1; i<=NF; i++) if ($i ~ /%/) {gsub(/[^0-9]/, "", $i); print $i; exit}}'
}

battery_status() {
    pmset -g batt 2>/dev/null | awk -F';' 'NR==2 {if (NF >= 2) {gsub(/^[[:space:]]+/, "", $2); gsub(/[[:space:]]+$/, "", $2); print $2; exit}}'
}

thermal_value() {
    local key="$1"
    pmset -g therm 2>/dev/null | awk -F'=' -v target="$key" '
        {
            left=$1
            gsub(/[[:space:]]/, "", left)
            if (left == target) {
                right=$2
                gsub(/[[:space:]]/, "", right)
                print right
                exit
            }
        }
    '
}

get_edge_memory_mb() {
    local total_kb
    total_kb=$(ps -axo rss=,command= 2>/dev/null \
        | awk 'index($0, "Microsoft Edge") > 0 {sum += $1} END {print sum+0}')
    echo $(( total_kb / 1024 ))
}

zoom_running() {
    pgrep -x "zoom.us" >/dev/null 2>&1
}

ollama_loaded_model_count() {
    if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        echo "0"
        return
    fi

    curl -sf "http://localhost:11434/api/ps" 2>/dev/null \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("models", [])))' 2>/dev/null \
        || echo "0"
}

fan_status() {
    if ! command -v powermetrics >/dev/null 2>&1; then
        echo "unavailable (powermetrics missing)"
        return
    fi

    if ! sudo -n true >/dev/null 2>&1; then
        echo "unavailable (powermetrics needs sudo)"
        return
    fi

    local output fan_line
    output=$(sudo -n powermetrics -n 1 -i 1000 --show-all 2>/dev/null || true)
    fan_line=$(printf "%s\n" "$output" | awk 'tolower($0) ~ /fan/ && (tolower($0) ~ /rpm/ || $0 ~ /:/) {print; exit}')

    if [[ -n "$fan_line" ]]; then
        echo "$fan_line"
    else
        echo "not reported (fanless or unsupported model)"
    fi
}

print_bool() {
    if [[ "$1" == "true" ]]; then
        echo "yes"
    else
        echo "no"
    fi
}

main() {
    local p_source batt_pct batt_state thermal_level cpu_limit sched_limit edge_mem_mb
    local zoom_active ollama_models fan_line

    p_source="$(power_source)"
    batt_pct="$(battery_percent)"
    batt_state="$(battery_status)"
    thermal_level="$(thermal_value "ThermalLevel")"
    cpu_limit="$(thermal_value "CPU_Speed_Limit")"
    sched_limit="$(thermal_value "Scheduler_Limit")"
    edge_mem_mb="$(get_edge_memory_mb)"

    if zoom_running; then
        zoom_active="true"
    else
        zoom_active="false"
    fi

    ollama_models="$(ollama_loaded_model_count)"
    fan_line="$(fan_status)"

    echo "mac-power-utils sanity snapshot"
    echo "Power source: ${p_source:-unknown}"
    echo "Battery: ${batt_pct:-n/a}% (${batt_state:-unknown})"
    echo "Thermal level: ${thermal_level:-n/a}"
    echo "CPU speed limit: ${cpu_limit:-100}%"
    echo "Scheduler limit: ${sched_limit:-100}%"
    echo "Fan: $fan_line"
    echo "Edge memory: ${edge_mem_mb}MB (threshold ${EDGE_THRESHOLD_MB}MB, warn ${EDGE_WARN_PCT}%)"
    echo "Zoom running: $(print_bool "$zoom_active")"
    echo "Ollama loaded models: ${ollama_models}"
    echo ""

    local edge_loaded zoom_loaded battery_loaded ollama_loaded front_loaded
    edge_loaded="false"
    zoom_loaded="false"
    battery_loaded="false"
    ollama_loaded="false"
    front_loaded="false"

    agent_loaded "$LAUNCH_LABEL_EDGE" && edge_loaded="true"
    agent_loaded "$LAUNCH_LABEL_ZOOM" && zoom_loaded="true"
    agent_loaded "$LAUNCH_LABEL_BATTERY" && battery_loaded="true"
    agent_loaded "$LAUNCH_LABEL_OLLAMA" && ollama_loaded="true"
    agent_loaded "$LAUNCH_LABEL_FRONT" && front_loaded="true"

    echo "Loaded agents: edge=$(print_bool "$edge_loaded"), zoom=$(print_bool "$zoom_loaded"), battery=$(print_bool "$battery_loaded"), ollama=$(print_bool "$ollama_loaded"), front=$(print_bool "$front_loaded")"
    echo ""
    echo "Recommendations:"

    local rec_count=0
    local edge_warn_threshold
    edge_warn_threshold=$(( EDGE_THRESHOLD_MB * EDGE_WARN_PCT / 100 ))

    if [[ "${p_source:-}" == "Battery Power" ]] && [[ "$battery_loaded" != "true" ]]; then
        echo "- Start battery protections: mpuctl.sh start battery"
        rec_count=$((rec_count + 1))
    fi

    if [[ "$edge_loaded" != "true" ]] && [[ "$zoom_loaded" != "true" ]] && [[ "$battery_loaded" != "true" ]] && [[ "$ollama_loaded" != "true" ]] && [[ "$front_loaded" != "true" ]]; then
        echo "- Baseline automation is off; enable all guards: mpuctl.sh start all"
        rec_count=$((rec_count + 1))
    fi

    if [[ -n "${thermal_level:-}" && "${thermal_level}" =~ ^[0-9]+$ ]] && [[ "$thermal_level" -ge 1 ]]; then
        echo "- Thermal pressure detected (ThermalLevel=${thermal_level}); ensure battery throttle is active: mpuctl.sh start battery"
        rec_count=$((rec_count + 1))
    fi

    if [[ -n "${cpu_limit:-}" && "${cpu_limit}" =~ ^[0-9]+$ ]] && [[ "$cpu_limit" -lt 100 ]]; then
        echo "- CPU speed is limited (${cpu_limit}%); reduce active load and keep throttling on"
        rec_count=$((rec_count + 1))
    fi

    if [[ "$edge_mem_mb" -ge "$edge_warn_threshold" ]] && [[ "$edge_loaded" != "true" ]]; then
        echo "- Edge memory is high; enable guard: mpuctl.sh start edge"
        rec_count=$((rec_count + 1))
    fi

    if [[ "$zoom_active" == "true" ]] && [[ "$zoom_loaded" != "true" ]]; then
        echo "- Zoom is running without guard; enable cleanup/throttling: mpuctl.sh start zoom"
        rec_count=$((rec_count + 1))
    fi

    if [[ "$ollama_models" =~ ^[0-9]+$ ]] && [[ "$ollama_models" -gt 0 ]] && [[ "$ollama_loaded" != "true" ]]; then
        echo "- Ollama has loaded models; enable idle unloads: mpuctl.sh start ollama"
        rec_count=$((rec_count + 1))
    fi

    if [[ "$rec_count" -eq 0 ]]; then
        echo "- No immediate action needed. Current state looks healthy."
    fi
}

main "$@"
