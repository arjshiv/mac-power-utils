#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="$HOME/bin"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
SCRIPTS=(edge-mem-guard.sh zoom-guard.sh battery-throttle.sh ollama-guard.sh front-guard.sh mpuctl.sh thermal-sanity.sh)
PLISTS=(com.user.edge-mem-guard.plist com.user.zoom-guard.plist com.user.battery-throttle.plist com.user.ollama-guard.plist com.user.front-guard.plist)

echo "==> Uninstalling mac-power-utils"

echo "==> Unloading launchd agents"
for plist in "${PLISTS[@]}"; do
    if [[ -f "$LAUNCH_AGENTS_DIR/$plist" ]]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$plist" 2>/dev/null || true
        rm "$LAUNCH_AGENTS_DIR/$plist"
        echo "    Removed $plist"
    fi
done

echo "==> Removing scripts from $BIN_DIR"
for script in "${SCRIPTS[@]}"; do
    if [[ -f "$BIN_DIR/$script" ]]; then
        rm "$BIN_DIR/$script"
        echo "    Removed $script"
    fi
done

echo "==> Reverting Low Power Mode"
sudo pmset -b lowpowermode 0 2>/dev/null || true

echo "==> Cleaning up state files"
rm -f /tmp/zoom-guard.state /tmp/battery-throttle.state /tmp/ollama-guard.state /tmp/front-guard.state
rm -rf /tmp/edge-mem-guard.lock /tmp/zoom-guard.lock /tmp/battery-throttle.lock /tmp/ollama-guard.lock /tmp/front-guard.lock

echo ""
echo "==> Done. Logs were left at ~/Library/Logs/ — delete manually if desired."
echo ""
echo "    If you added a sudoers entry, remove it with:"
echo "    sudo rm /etc/sudoers.d/mac-power-utils"
