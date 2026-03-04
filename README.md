# mac-power-utils

Background daemons for Apple Silicon Macs that manage memory and thermals for Edge, Zoom, and general battery life.

## What's Included

| Script | Purpose |
|--------|---------|
| `edge-mem-guard.sh` | Kills Edge renderer processes when total memory exceeds a threshold |
| `zoom-guard.sh` | Quits idle Zoom after 5 minutes, throttles during calls on battery, cleans up orphaned processes |
| `battery-throttle.sh` | Enables Low Power Mode on battery, renices heavy processes, reverts on AC |
| `ollama-guard.sh` | Unloads idle Ollama models to reclaim GB of RAM |

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- No Homebrew or third-party dependencies — pure bash using built-in macOS tools

## Install

```bash
./install.sh
```

This will:
1. Copy scripts to `~/bin/` and make them executable
2. Install launchd agents to `~/Library/LaunchAgents/`
3. Load all agents immediately
4. Optionally configure passwordless `pmset` for battery throttling

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

## Logs

All daemons log to `~/Library/Logs/`:
- `edge-mem-guard.log`
- `zoom-guard.log`
- `battery-throttle.log`
- `ollama-guard.log`

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
```

## License

MIT
