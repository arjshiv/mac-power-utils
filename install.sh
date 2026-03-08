#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/bin"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
CONFIG_DIR="$HOME/.config/mac-power-utils"
CONFIG_FILE="$CONFIG_DIR/mac-power-utils.conf"
SCRIPTS=(edge-mem-guard.sh zoom-guard.sh battery-throttle.sh ollama-guard.sh front-guard.sh mpuctl.sh mpuctl thermal-sanity.sh)
PLISTS=(com.user.edge-mem-guard.plist com.user.zoom-guard.plist com.user.battery-throttle.plist com.user.ollama-guard.plist com.user.front-guard.plist)
LOG_FILES=(edge-mem-guard.log zoom-guard.log battery-throttle.log ollama-guard.log front-guard.log)

echo "==> Installing mac-power-utils"

mkdir -p "$BIN_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$CONFIG_DIR"

echo "==> Copying scripts to $BIN_DIR"
for script in "${SCRIPTS[@]}"; do
    cp "$SCRIPT_DIR/bin/$script" "$BIN_DIR/$script"
    chmod +x "$BIN_DIR/$script"
    echo "    Installed $script"
done

echo "==> Installing default config"
if [[ -f "$CONFIG_FILE" ]]; then
    echo "    Keeping existing config: $CONFIG_FILE"
else
    cp "$SCRIPT_DIR/config/mac-power-utils.conf" "$CONFIG_FILE"
    echo "    Installed $CONFIG_FILE"
fi

echo "==> Ensuring log files exist"
for logfile in "${LOG_FILES[@]}"; do
    touch "$LOG_DIR/$logfile"
    chmod 600 "$LOG_DIR/$logfile"
    echo "    Ready $LOG_DIR/$logfile"
done

echo "==> Installing launchd agents"
for plist in "${PLISTS[@]}"; do
    sed -e "s|__BIN_DIR__|$BIN_DIR|g" \
        -e "s|__HOME__|$HOME|g" \
        "$SCRIPT_DIR/launchd/$plist" > "$LAUNCH_AGENTS_DIR/$plist"

    launchctl unload "$LAUNCH_AGENTS_DIR/$plist" 2>/dev/null || true
    launchctl load "$LAUNCH_AGENTS_DIR/$plist"
    echo "    Loaded $plist"
done

echo ""
echo "==> Sudoers setup for battery-throttle"
echo "    battery-throttle.sh needs passwordless sudo for 'pmset'."
echo "    To enable, run:"
echo ""
echo "    sudo visudo -f /etc/sudoers.d/mac-power-utils"
echo ""
echo "    And add this line:"
echo "    $(whoami) ALL=(ALL) NOPASSWD: /usr/bin/pmset"
echo ""

echo "==> Done. Config at $CONFIG_FILE"
echo "==> Logs at ~/Library/Logs/{edge-mem-guard,zoom-guard,battery-throttle,ollama-guard,front-guard}.log"
