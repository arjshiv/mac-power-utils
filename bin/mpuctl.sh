#!/usr/bin/env bash
set -euo pipefail

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
AGENTS=(edge zoom battery ollama front)

usage() {
    cat <<'USAGE'
Usage:
  mpuctl.sh status
  mpuctl.sh start <agent|all>
  mpuctl.sh stop <agent|all>
  mpuctl.sh restart <agent|all>
  mpuctl.sh logs <agent> [lines]
  mpuctl.sh tail <agent>

Agents:
  edge | zoom | battery | ollama | front | all
USAGE
}

agent_to_plist() {
    case "$1" in
        edge) echo "com.user.edge-mem-guard.plist" ;;
        zoom) echo "com.user.zoom-guard.plist" ;;
        battery) echo "com.user.battery-throttle.plist" ;;
        ollama) echo "com.user.ollama-guard.plist" ;;
        front) echo "com.user.front-guard.plist" ;;
        *) return 1 ;;
    esac
}

agent_to_log() {
    case "$1" in
        edge) echo "$LOG_DIR/edge-mem-guard.log" ;;
        zoom) echo "$LOG_DIR/zoom-guard.log" ;;
        battery) echo "$LOG_DIR/battery-throttle.log" ;;
        ollama) echo "$LOG_DIR/ollama-guard.log" ;;
        front) echo "$LOG_DIR/front-guard.log" ;;
        *) return 1 ;;
    esac
}

list_labels() {
    launchctl list 2>/dev/null | awk 'NR>1 {print $3}' || true
}

pid_for_label() {
    local label="$1"
    launchctl list 2>/dev/null | awk -v target="$label" '$3 == target {print $1}' || true
}

is_loaded() {
    local label="$1"
    list_labels | grep -Fxq "$label"
}

load_agent() {
    local agent="$1"
    local plist
    plist="$(agent_to_plist "$agent")" || {
        echo "Unknown agent: $agent" >&2
        return 1
    }

    local path="$LAUNCH_AGENTS_DIR/$plist"
    if [[ ! -f "$path" ]]; then
        echo "Missing launch agent: $path" >&2
        return 1
    fi

    launchctl unload "$path" >/dev/null 2>&1 || true
    launchctl load "$path"
    echo "Started $agent"
}

unload_agent() {
    local agent="$1"
    local plist
    plist="$(agent_to_plist "$agent")" || {
        echo "Unknown agent: $agent" >&2
        return 1
    }

    local path="$LAUNCH_AGENTS_DIR/$plist"
    if [[ ! -f "$path" ]]; then
        echo "Missing launch agent: $path" >&2
        return 1
    fi

    launchctl unload "$path" >/dev/null 2>&1 || true
    echo "Stopped $agent"
}

start_agents() {
    local target="$1"
    if [[ "$target" == "all" ]]; then
        local agent
        for agent in "${AGENTS[@]}"; do
            load_agent "$agent"
        done
        return 0
    fi

    load_agent "$target"
}

stop_agents() {
    local target="$1"
    if [[ "$target" == "all" ]]; then
        local agent
        for agent in "${AGENTS[@]}"; do
            unload_agent "$agent"
        done
        return 0
    fi

    unload_agent "$target"
}

status_agents() {
    printf "%-8s %-8s %-8s %-s\n" "Agent" "Loaded" "PID" "Log"
    printf "%-8s %-8s %-8s %-s\n" "-----" "------" "---" "---"

    local agent
    for agent in "${AGENTS[@]}"; do
        local plist label pid loaded log_path
        plist="$(agent_to_plist "$agent")"
        label="${plist%.plist}"
        pid="$(pid_for_label "$label")"
        log_path="$(agent_to_log "$agent")"

        if is_loaded "$label"; then
            loaded="yes"
        else
            loaded="no"
            pid="-"
        fi

        if [[ -z "$pid" ]]; then
            pid="-"
        fi

        printf "%-8s %-8s %-8s %-s\n" "$agent" "$loaded" "$pid" "$log_path"
    done
}

print_logs() {
    local agent="$1"
    local lines="${2:-80}"
    local log_path

    log_path="$(agent_to_log "$agent")" || {
        echo "Unknown agent: $agent" >&2
        return 1
    }

    if [[ ! -f "$log_path" ]]; then
        echo "No log file yet: $log_path" >&2
        return 1
    fi

    tail -n "$lines" "$log_path"
}

tail_logs() {
    local agent="$1"
    local log_path

    log_path="$(agent_to_log "$agent")" || {
        echo "Unknown agent: $agent" >&2
        return 1
    }

    if [[ ! -f "$log_path" ]]; then
        echo "No log file yet: $log_path" >&2
        return 1
    fi

    tail -f "$log_path"
}

main() {
    local cmd="${1:-}"

    case "$cmd" in
        status)
            status_agents
            ;;
        start)
            [[ $# -ge 2 ]] || {
                usage
                exit 1
            }
            start_agents "$2"
            ;;
        stop)
            [[ $# -ge 2 ]] || {
                usage
                exit 1
            }
            stop_agents "$2"
            ;;
        restart)
            [[ $# -ge 2 ]] || {
                usage
                exit 1
            }
            stop_agents "$2"
            start_agents "$2"
            ;;
        logs)
            [[ $# -ge 2 ]] || {
                usage
                exit 1
            }
            print_logs "$2" "${3:-80}"
            ;;
        tail)
            [[ $# -ge 2 ]] || {
                usage
                exit 1
            }
            tail_logs "$2"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
