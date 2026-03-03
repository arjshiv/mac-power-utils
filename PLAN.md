# macOS Power Utilities — Project Plan

## Overview
Background daemons for Apple Silicon Macs that manage memory and thermals for Edge, Zoom, and general battery life.

## Repository Structure
```
mac-power-utils/
├── bin/
│   ├── edge-mem-guard.sh         # Edge memory monitor daemon
│   ├── zoom-guard.sh             # Zoom idle killer + call throttler
│   └── battery-throttle.sh       # Battery-aware thermal throttler
├── launchd/
│   ├── com.user.edge-mem-guard.plist
│   ├── com.user.zoom-guard.plist
│   └── com.user.battery-throttle.plist
├── install.sh                    # Symlinks scripts, loads launchd agents
├── uninstall.sh                  # Reverses install
└── README.md
```

---

## Component 1: `edge-mem-guard.sh`

**Purpose:** Prevent Edge from consuming unbounded memory.

**Logic (loop every 30s):**
1. `ps -eo rss,comm` — sum RSS of all processes matching `Microsoft Edge`
2. If total > 80% of threshold → log warning
3. If total > threshold (default 4096 MB):
   - `pgrep -f "Microsoft Edge.*--type=renderer"` to find tab processes
   - `kill -15` each renderer PID (graceful kill)
   - Send macOS notification via `osascript -e 'display notification ...'`
   - Sleep 5s before resuming checks (let memory settle)
4. Log all events to `~/Library/Logs/edge-mem-guard.log`

**Config:** Threshold passed as argument: `edge-mem-guard.sh 4096`

**Edge behavior on renderer kill:** The tab shows "Aw, Snap!" / reload prompt. Browser stays open, other tabs unaffected. No data loss for forms (Edge auto-saves drafts).

---

## Component 2: `zoom-guard.sh`

**Purpose:** Prevent Zoom from wasting resources when idle and reduce thermal load during calls.

### Problem

Zoom's process model on macOS:
- `zoom.us` — main app process (always running when app is open)
- `zoom.us Helper` / `zoom.us Helper (Renderer)` — UI renderers
- `CptHost` — screen sharing capture (very CPU-heavy, sometimes lingers after sharing stops)
- `ZoomAutoUpdater` — polls for updates in background
- `airplayutil` / `zoom.us.airplay` — AirPlay features

Even when not in a meeting, Zoom keeps all of these alive, consuming 200-500MB RAM and periodic CPU spikes from telemetry/update checks.

### Logic (loop every 15s)

**Phase 1: Idle detection & kill**
1. Check if Zoom is running: `pgrep -x "zoom.us"`
2. If running, check if in an active meeting:
   - `lsof -i -n -P | grep zoom.us | grep -q ESTABLISHED` — active network connections indicate a call
   - Cross-reference with `CptHost` and audio device usage
3. If Zoom is open but **not in a meeting** for >5 minutes:
   - Send notification: "Zoom is idle — quitting to save resources"
   - `killall zoom.us` — quit the entire app
   - Also kill stragglers: `killall CptHost ZoomAutoUpdater 2>/dev/null`
4. Track idle start time in `/tmp/zoom-guard.state`

**Phase 2: In-call throttling (battery only)**
1. If in a meeting AND on battery:
   - `renice 10 -p $(pgrep -x "zoom.us")` — lower scheduler priority
   - `renice 15 -p $(pgrep -x "CptHost")` — deprioritize screen sharing even more
2. If on AC power: `renice 0` everything back to normal

**Phase 3: Stale process cleanup**
1. Check for orphaned `CptHost` processes (screen share host running with no active meeting)
2. Kill them — these are a common source of phantom CPU usage after meetings end

### Why kill idle Zoom entirely?

- Zoom has no meaningful "lightweight" state — even idle it runs multiple helpers
- Unlike Edge, there's no per-tab granularity; it's all-or-nothing
- Zoom launches fast on Apple Silicon (~2s), so killing it has minimal cost
- The 5-minute grace period avoids killing it between back-to-back meetings

### Config
- `IDLE_TIMEOUT_MIN=5` — minutes before killing idle Zoom
- `THROTTLE_ON_BATTERY=true` — whether to renice during calls on battery
- Passed as env vars or a simple config file

---

## Component 3: `battery-throttle.sh`

**Purpose:** Reduce thermal output and fan noise when on battery.

**Logic (loop every 60s):**

**Detection:**
- `pmset -g batt | grep -c "Battery Power"` — returns 1 if on battery

**On battery (apply once on transition):**
1. **Enable Low Power Mode:** `sudo pmset -b lowpowermode 1`
   - This is the biggest lever on Apple Silicon. It:
     - Limits P-core (performance core) frequency
     - Biases scheduler toward E-cores (efficiency cores)
     - Reduces display brightness ceiling
     - Throttles background activity (App Nap, etc.)
   - Alone, this typically eliminates fan spin for normal browsing
2. **Renice Edge renderers:** `pgrep -f "Microsoft Edge.*--type=renderer" | xargs renice 10` — deprioritize tab processes
3. **Renice Zoom (if in call):** `pgrep -x "zoom.us" | xargs renice 10`
4. **Log transition**

**On AC power (revert once on transition):**
1. `sudo pmset -b lowpowermode 0`
2. Restore all renice'd processes to priority 0
3. **Log transition**

**State tracking:** Write current state (`battery` or `ac`) to `/tmp/battery-throttle.state` so actions only run on transitions, not every loop.

---

## Launchd Agents

### `com.user.edge-mem-guard.plist`
- **RunAtLoad:** true
- **KeepAlive:** true (restart on crash)
- **ProgramArguments:** `["/Users/.../bin/edge-mem-guard.sh", "4096"]`
- **StandardOutPath / StandardErrorPath:** `~/Library/Logs/edge-mem-guard.log`
- **ProcessType:** Background

### `com.user.zoom-guard.plist`
- **RunAtLoad:** true
- **KeepAlive:** true
- **ProgramArguments:** `["/Users/.../bin/zoom-guard.sh"]`
- **StandardOutPath / StandardErrorPath:** `~/Library/Logs/zoom-guard.log`
- **ProcessType:** Background

### `com.user.battery-throttle.plist`
- **RunAtLoad:** true
- **KeepAlive:** true
- **ProgramArguments:** `["/Users/.../bin/battery-throttle.sh"]`
- **StandardOutPath / StandardErrorPath:** `~/Library/Logs/battery-throttle.log`
- **ProcessType:** Background
- **Note:** Needs `sudo` for `pmset lowpowermode`. Options:
  - Add a sudoers entry: `user ALL=(ALL) NOPASSWD: /usr/bin/pmset` (recommended)
  - Or run the agent as root via `/Library/LaunchDaemons/` instead

---

## `install.sh`

1. `mkdir -p ~/bin`
2. Copy scripts to `~/bin/`, `chmod +x`
3. Substitute actual home directory path into plist files
4. Copy plists to `~/Library/LaunchAgents/`
5. `launchctl load` both agents
6. Prompt to add sudoers entry for `pmset` (with explanation)

## `uninstall.sh`

1. `launchctl unload` all agents
2. Remove plists from `~/Library/LaunchAgents/`
3. Remove scripts from `~/bin/`
4. Revert `pmset -b lowpowermode 0`
5. Remove sudoers entry if added

---

## Dependencies
- **None** — pure bash, uses only built-in macOS tools (`ps`, `pgrep`, `kill`, `pmset`, `osascript`, `renice`, `lsof`)
- No Homebrew packages needed

---

## Interaction Between Components

```
battery-throttle.sh ──┬── detects battery/AC transitions
                      ├── enables/disables Low Power Mode
                      ├── renices Edge + Zoom processes
                      │
edge-mem-guard.sh ────┴── monitors Edge memory independently
                           (runs on both battery and AC)

zoom-guard.sh ────────┬── kills idle Zoom (battery and AC)
                      └── extra renice during calls (battery only)
```

The battery-throttle and zoom-guard scripts both renice Zoom, but this is idempotent — calling `renice 10` twice is harmless. zoom-guard handles the Zoom-specific logic (idle kill, CptHost cleanup), while battery-throttle handles the system-wide knobs (Low Power Mode) and blanket renicing.

---

## Nice-to-haves (future)
- **Menu bar status** via SwiftUI/AppKit showing current memory usage, power state, and Zoom status
- **Configurable profiles** (e.g., "ultra quiet" vs "balanced" on battery)
- **Per-tab memory tracking** via Edge's `--enable-features=V8DetailedMemoryUsage` flag
- **Zoom settings automation** — toggle HD video off on battery via Zoom's plist (`~/Library/Preferences/us.zoom.xos.plist`)
- **SIGSTOP/SIGCONT duty cycling** for hard CPU caps without killing processes
