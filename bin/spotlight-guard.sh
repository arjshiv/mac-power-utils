#!/usr/bin/env bash
set -euo pipefail

USER_HOME="${MPU_USER_HOME:-$HOME}"
CONFIG_FILE="${MAC_POWER_UTILS_CONFIG:-$USER_HOME/.config/mac-power-utils/mac-power-utils.conf}"
LOG_FILE="$USER_HOME/Library/Logs/spotlight-guard.log"

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

WHITELIST_TOP="${SPOTLIGHT_GUARD_WHITELIST_TOP:-Downloads Applications}"
WHITELIST_LIB="${SPOTLIGHT_GUARD_WHITELIST_LIB:-CloudStorage}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [spotlight-guard] $*" >> "$LOG_FILE"
}

is_whitelisted() {
    local name="$1"
    shift
    local w
    for w in "$@"; do
        [[ "$name" == "$w" ]] && return 0
    done
    return 1
}

build_exclusions() {
    exclusions=()

    for item in "$USER_HOME"/*/; do
        [[ -d "$item" ]] || continue
        local name
        name="$(basename "$item")"
        [[ "$name" == "Library" ]] && continue
        # shellcheck disable=SC2086
        is_whitelisted "$name" $WHITELIST_TOP || exclusions+=("${item%/}")
    done

    for item in "$USER_HOME"/Library/*/; do
        [[ -d "$item" ]] || continue
        local name
        name="$(basename "$item")"
        # shellcheck disable=SC2086
        is_whitelisted "$name" $WHITELIST_LIB || exclusions+=("${item%/}")
    done

    for item in "$USER_HOME"/.[!.]*/; do
        [[ -d "$item" ]] || continue
        exclusions+=("${item%/}")
    done

    for item in "$USER_HOME"/*; do
        [[ -f "$item" ]] && exclusions+=("$item")
    done
    for item in "$USER_HOME"/.[!.]*; do
        [[ -f "$item" ]] && exclusions+=("$item")
    done
}

build_exclusions

if [[ "${1:-}" == "--init" ]]; then
    log "Init: enabling Spotlight indexing"
    mdutil -i on / 2>/dev/null || log "WARN: failed to enable indexing"
fi

log "Updating exclusions (${#exclusions[@]} entries, whitelist_top='$WHITELIST_TOP' whitelist_lib='$WHITELIST_LIB')"

if [[ ${#exclusions[@]} -gt 0 ]]; then
    defaults write /.Spotlight-V100/VolumeConfiguration Exclusions -array "${exclusions[@]}"
    log "Wrote ${#exclusions[@]} exclusions to Spotlight config"
else
    log "No exclusions to write"
fi

if [[ "${1:-}" == "--init" ]]; then
    log "Init: rebuilding Spotlight index"
    mdutil -E / 2>/dev/null || log "WARN: failed to rebuild index"
fi

log "Done"
