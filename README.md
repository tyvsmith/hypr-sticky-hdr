# hypr-sticky-hdr

Sticky HDR daemon for [Hyprland](https://hyprland.org/). Auto-detects HDR windows by scanning process environment variables and keeps the monitor in HDR mode for the process's entire lifetime — no flickering on alt-tab. Supports multi-monitor setups.

## How it works

When a window opens, the daemon checks if its process has `PROTON_ENABLE_HDR=1` or `HYPR_STICKY_HDR=1` in its environment. If so, HDR is enabled on that window's monitor and stays on until all HDR windows on that monitor close (plus a short cooldown to avoid flicker).

**Key behaviors:**
- Listens to Hyprland IPC events for window open/close
- Debounced scanning (200ms) to batch rapid events
- Cooldown (2s) before switching back to SDR after the last HDR window closes
- Periodic background scan (30s) as a safety net
- PID-based caching so `/proc` reads happen only once per process
- Per-monitor HDR tracking — only the monitor with HDR windows switches
- Auto-detects SDR baseline at startup — restores exact original settings

## Dependencies

- `hyprctl` (comes with Hyprland)
- `socat` — for Hyprland IPC socket
- `jq` — JSON parsing
- `notify-send` — optional desktop notifications

## Installation

One-liner (downloads the script and adds Hyprland autostart):

```bash
curl -fsSL https://raw.githubusercontent.com/tyvsmith/hypr-sticky-hdr/main/install.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/tyvsmith/hypr-sticky-hdr.git
cd hypr-sticky-hdr
./install.sh
```

This installs `hypr-sticky-hdr` to `~/.local/bin/` and adds `exec-once = hypr-sticky-hdr daemon` to `~/.config/hypr/autostart.conf`.

## Usage

```bash
hypr-sticky-hdr daemon           # Start the daemon
hypr-sticky-hdr on [monitor]     # Force HDR on (all monitors or specific)
hypr-sticky-hdr off [monitor]    # Release manual override
hypr-sticky-hdr status [monitor] # Show current state
hypr-sticky-hdr reload           # Reload config file
```

## Configuration

The daemon works out-of-box with zero configuration. All monitors are auto-detected and managed with sane defaults.

To customize, create `~/.config/hypr-sticky-hdr/config` (an example is installed at `config.example` in the same directory):

```ini
# Global settings
cooldown=3
hdr_brightness=1.2

# Per-monitor overrides
[DP-1]
hdr_brightness=1.35

[HDMI-A-1]
enabled=0
```

### Available options

| Key | Scope | Default | Description |
|-----|-------|---------|-------------|
| `hdr_brightness` | global, per-monitor | `1.0` | SDR content brightness when in HDR mode |
| `hdr_cm` | global, per-monitor | `hdr` | Color management preset for HDR mode |
| `hdr_bitdepth` | global, per-monitor | `10` | Bit depth in HDR mode |
| `cooldown` | global | `2` | Seconds before switching back to SDR |
| `debounce` | global | `0.2` | Seconds to debounce window events |
| `hdr_env_vars` | global | `PROTON_ENABLE_HDR=1,HYPR_STICKY_HDR=1` | Env vars that trigger HDR detection |
| `enabled` | per-monitor | `1` | Whether to manage this monitor (`0` to disable) |
| `hdr_monitor_conf` | per-monitor | — | Raw Hyprland monitor string (escape hatch) |

### Environment variable overrides

Environment variables take priority over the config file. Use the prefix `HYPR_STICKY_HDR_` followed by the key name in uppercase:

```bash
# Global override
export HYPR_STICKY_HDR_COOLDOWN=5

# Per-monitor override (monitor name: uppercase, hyphens become underscores)
export HYPR_STICKY_HDR_DP_1_HDR_BRIGHTNESS=1.35
export HYPR_STICKY_HDR_HDMI_A_1_ENABLED=0
```

### Priority order (highest to lowest)

1. Per-monitor environment variable
2. Per-monitor config file section
3. Global environment variable
4. Global config file value
5. App default

## Triggering HDR for non-Proton apps

Set the environment variable before launching:

```bash
HYPR_STICKY_HDR=1 some-hdr-app
```

## License

MIT
