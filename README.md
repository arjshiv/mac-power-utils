# mac-power-utils

Background daemons for Apple Silicon Macs that manage memory and thermals for Edge, Zoom, and general battery life.

## What's Included

| Script | Purpose |
|--------|---------|
| `edge-mem-guard.sh` | Kills Edge renderer processes when total memory exceeds a threshold |
| `zoom-guard.sh` | Quits idle Zoom after 5 minutes, throttles during calls on battery, cleans up orphaned processes |
| `battery-throttle.sh` | Enables Low Power Mode on battery, renices heavy processes, reverts on AC |
| `ollama-guard.sh` | Unloads idle Ollama models to reclaim GB of RAM |
| `front-guard.sh` | Restarts Front when backgrounded and bloated to reclaim leaked memory |
| `mpuctl.sh` | One command for service status/start/stop/restart/logs |

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- No Homebrew or third-party dependencies — pure bash using built-in macOS tools

## Install

```bash
./install.sh
```

This will:
1. Copy scripts to `~/bin/` and make them executable
2. Install default config at `~/.config/mac-power-utils/mac-power-utils.conf` (keeps existing file if present)
3. Install launchd agents to `~/Library/LaunchAgents/`
4. Load all agents immediately
5. Optionally configure passwordless `pmset` for battery throttling

## Uninstall

```bash
./uninstall.sh
```

## Components

### edge-mem-guard

Monitors Edge memory usage every 30 seconds. When total RSS exceeds the threshold (default 4096 MB), it gracefully kills renderer processes. Affected tabs show a reload prompt — no data loss.

### zoom-guard

- **Idle kill:** If Zoom has no active meeting for 5 minutes, quits the app and all helpers
- **Call throttling:** On battery, renices Zoom and CptHost to reduce thermal output
- **Stale cleanup:** Kills orphaned CptHost processes lingering after meetings

### battery-throttle

Detects battery/AC transitions and:
- Enables/disables macOS Low Power Mode (`pmset lowpowermode`)
- Renices Edge renderers and Zoom processes on battery
- Reverts everything when plugging back in

### ollama-guard

Watches for loaded Ollama models sitting idle (no active generation). After 10 minutes of inactivity, unloads models via the API to reclaim memory. A single loaded model can consume 4-24 GB depending on size. Models reload in seconds on the next query, so there's minimal cost to unloading.

### front-guard

Front (Electron email client) leaks memory over time — a single renderer can grow to 500 MB+ while backgrounded. This guard detects when Front has no visible windows, isn't frontmost, and has exceeded a memory threshold (default 512 MB) for 15 minutes, then quits and relaunches it in the background. Safe because Front reconnects and resyncs on launch. Won't restart if you're actively composing.

## Configuration

All daemon settings are centralized in:

```bash
~/.config/mac-power-utils/mac-power-utils.conf
```

You can tune thresholds/intervals per guard there without editing scripts. Example:

```bash
EDGE_MEM_GUARD_THRESHOLD_MB=6144
ZOOM_GUARD_IDLE_TIMEOUT_MIN=8
OLLAMA_GUARD_IDLE_TIMEOUT_MIN=5
```

After changing config, re-run:

```bash
./install.sh
```

## Service Control

Use `~/bin/mpuctl.sh` instead of manual `launchctl` commands:

```bash
# show all agents, load state, pid, and log path
mpuctl.sh status

# restart one daemon
mpuctl.sh restart edge

# stop or start everything
mpuctl.sh stop all
mpuctl.sh start all

# inspect logs
mpuctl.sh logs zoom 120
mpuctl.sh tail battery
```

## Logs

All daemons log to `~/Library/Logs/`:
- `edge-mem-guard.log`
- `zoom-guard.log`
- `battery-throttle.log`
- `ollama-guard.log`
- `front-guard.log`

## How They Interact

```
battery-throttle.sh ──┬── detects battery/AC transitions
                      ├── enables/disables Low Power Mode
                      ├── renices Edge + Zoom processes
                      │
edge-mem-guard.sh ────┴── monitors Edge memory independently
                           (runs on both battery and AC)

zoom-guard.sh ────────┬── kills idle Zoom (battery and AC)
                      └── extra renice during calls (battery only)

ollama-guard.sh ──────── unloads idle models (battery and AC)

front-guard.sh ───────── restarts bloated Front when backgrounded
```

## License

MIT
