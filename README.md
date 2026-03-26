# hypr-sticky-hdr

Sticky HDR daemon for [Hyprland](https://hyprland.org/). Auto-detects HDR windows by scanning process environment variables and keeps the monitor in HDR mode for the process's entire lifetime — no flickering on alt-tab.

## How it works

When a window opens, the daemon checks if its process has `PROTON_ENABLE_HDR=1` or `HYPR_STICKY_HDR=1` in its environment. If so, HDR is enabled on the monitor and stays on until all HDR windows close (plus a short cooldown to avoid flicker).

**Key behaviors:**
- Listens to Hyprland IPC events for window open/close
- Debounced scanning (200ms) to batch rapid events
- Cooldown (2s) before switching back to SDR after the last HDR window closes
- Periodic background scan (30s) as a safety net
- PID-based caching so `/proc` reads happen only once per process
- Manual override via `on`/`off` commands

## Dependencies

- `hyprctl` (comes with Hyprland)
- `socat` — for Hyprland IPC socket
- `jq` — JSON parsing
- `notify-send` — optional desktop notifications

## Installation

Copy the script somewhere on your `$PATH`:

```bash
install -m 755 hypr-sticky-hdr ~/.local/bin/
```

Or with chezmoi, add it as a managed file.

## Usage

```bash
# Start the daemon (add to your Hyprland autostart)
hypr-sticky-hdr daemon

# Manual control
hypr-sticky-hdr on        # Force HDR on
hypr-sticky-hdr off       # Release manual override
hypr-sticky-hdr status    # Show current state
```

### Hyprland autostart

Add to `~/.config/hypr/autostart.conf`:

```
exec-once = hypr-sticky-hdr daemon
```

## Configuration

Edit the variables at the top of the script:

| Variable | Default | Description |
|---|---|---|
| `MONITOR_NAME` | `""` (auto-detect first monitor) | Target monitor name |
| `HDR_CM` | `hdr` | Color management preset for HDR mode |
| `HDR_SDR_BRIGHTNESS` | `1.35` | SDR content brightness when in HDR mode |
| `SDR_CM` | `auto` | Color management preset for SDR mode |
| `SDR_SDR_BRIGHTNESS` | `1.0` | SDR brightness in SDR mode |
| `HDR_ENV_VARS` | `PROTON_ENABLE_HDR=1`, `HYPR_STICKY_HDR=1` | Env vars that trigger HDR |
| `COOLDOWN` | `2` | Seconds to wait before switching back to SDR |
| `DEBOUNCE` | `0.2` | Seconds to debounce window events |

## Triggering HDR for non-Proton apps

Set the environment variable before launching:

```bash
HYPR_STICKY_HDR=1 some-hdr-app
```

## License

MIT
