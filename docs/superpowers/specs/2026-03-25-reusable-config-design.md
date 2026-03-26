# hypr-sticky-hdr: Reusable Configuration Design

## Problem

The script has hardcoded values specific to one user's setup (e.g., `HDR_SDR_BRIGHTNESS=1.35`), no config file support, and only manages a single monitor. This makes it unusable out-of-box for anyone else.

## Goals

- Work out-of-box with zero configuration for any Hyprland + HDR setup
- Auto-detect SDR baseline from the user's existing monitor state
- Provide layered configuration: sane defaults, config file, env var overrides
- Support multi-monitor setups with per-monitor config and enable/disable
- Keep it a single bash script with no new dependencies

## Design

### 1. SDR Baseline Detection

At daemon startup, read all monitors from `hyprctl monitors -j` and capture their current state as the SDR baseline. Store per-monitor in an associative array keyed by monitor name (e.g., `MON_SDR_BASELINE["DP-1"]`).

The baseline includes: resolution, refresh rate, scale, transform, VRR, bit depth, brightness, saturation, and color management preset.

**Assumption:** Monitor state at daemon startup is SDR. If `cm` is already `hdr` at startup, log a warning but proceed.

### 2. Configuration Hierarchy

Three layers, each overriding the previous:

**Layer 1 — App defaults (hardcoded in script):**

| Key | Default | Description |
|-----|---------|-------------|
| `hdr_cm` | `hdr` | Color management preset for HDR mode |
| `hdr_brightness` | `1.0` | SDR content brightness when in HDR mode |
| `hdr_bitdepth` | `10` | Bit depth in HDR mode |
| `sdr_cm` | `auto` | Color management preset for SDR mode |
| `sdr_brightness` | `1.0` | Brightness in SDR mode |
| `cooldown` | `2` | Seconds before switching back to SDR |
| `debounce` | `0.2` | Seconds to debounce window events |
| `enabled` | `1` | Whether to manage a monitor (per-monitor only) |

**Layer 2 — Config file (`~/.config/hypr-sticky-hdr/config`):**

```ini
# Global overrides
cooldown=3
debounce=0.3

# Per-monitor overrides
[DP-1]
hdr_brightness=1.35
enabled=1

[HDMI-A-1]
enabled=0
```

**Layer 3 — Environment variables (highest priority):**

```bash
# Global
HYPR_STICKY_HDR_COOLDOWN=5

# Per-monitor (name normalized: uppercase, hyphens to underscores)
HYPR_STICKY_HDR_DP_1_BRIGHTNESS=1.4
HYPR_STICKY_HDR_HDMI_A_1_ENABLED=0
```

**Escape hatch:** `hdr_monitor_conf` (per-monitor only) provides a raw Hyprland monitor string fragment used verbatim instead of the constructed one.

**Resolution order for a given monitor + key:**

1. Per-monitor env var (`HYPR_STICKY_HDR_<MONITOR>_<KEY>`)
2. Per-monitor config file section (`[monitor-name]` -> `key=value`)
3. Global env var (`HYPR_STICKY_HDR_<KEY>`)
4. Global config file value (`key=value` before any section)
5. App default

Config file and env vars are read at startup. A `reload` command re-reads both.

### 3. Config File Format

Simple INI-style parser in bash. Rules:

- Lines starting with `#` are comments
- Empty lines are ignored
- `[monitor-name]` starts a per-monitor section
- `key=value` pairs; whitespace around `=` is trimmed
- Keys before any section header are global
- Unknown keys produce a warning (stderr) but are not fatal
- Missing config file is not an error

Valid keys:

| Key | Scope | Description |
|-----|-------|-------------|
| `hdr_brightness` | global, per-monitor | SDR content brightness in HDR mode |
| `hdr_cm` | global, per-monitor | Color management preset for HDR |
| `sdr_cm` | global, per-monitor | Color management preset for SDR |
| `sdr_brightness` | global, per-monitor | Brightness in SDR mode |
| `hdr_bitdepth` | global, per-monitor | Bit depth in HDR mode (default: 10) |
| `cooldown` | global only | Seconds before switching back to SDR |
| `debounce` | global only | Seconds to debounce window events |
| `hdr_env_vars` | global only | Comma-separated env vars that trigger HDR detection |
| `enabled` | per-monitor only | `1` or `0`, whether to manage this monitor |
| `hdr_monitor_conf` | per-monitor only | Raw Hyprland monitor string escape hatch |

Parser populates `GLOBAL_CONFIG` and per-monitor associative arrays. A `resolve_config(monitor, key)` function walks the priority chain.

### 4. Per-Monitor State

Scalar globals become per-monitor associative arrays:

```bash
declare -A MON_GAME_COUNT      # MON_GAME_COUNT["DP-1"]=2
declare -A MON_MANUAL_ON       # MON_MANUAL_ON["DP-1"]=0
declare -A MON_CURRENT_MODE    # MON_CURRENT_MODE["DP-1"]="sdr"
declare -A MON_COOLDOWN_PID    # MON_COOLDOWN_PID["DP-1"]=""
declare -A MON_ENABLED         # MON_ENABLED["DP-1"]=1
declare -A MON_SDR_BASELINE    # MON_SDR_BASELINE["DP-1"]="<monitor string>"
declare -A MON_HDR_CONFIG      # MON_HDR_CONFIG["DP-1"]="<resolved config>"
```

**Window-to-monitor mapping:** `hyprctl clients -j` includes a `monitor` field per window. HDR demand is tracked per-monitor — only monitors with HDR windows switch to HDR.

**Disabled monitors:** If `enabled=0`, the daemon ignores HDR windows on that monitor entirely.

### 5. HDR Mode Switching

**Switching to HDR for a monitor:**

1. Start from SDR baseline (`MON_SDR_BASELINE["DP-1"]`)
2. If `hdr_monitor_conf` escape hatch is set, use it verbatim (skip 3-4)
3. Override fields using resolved config: `cm`, `sdrbrightness`, `bitdepth`
4. Set `render:cm_auto_hdr=0`
5. Apply via `hyprctl keyword monitor <string>`

**Switching back to SDR:**

1. Restore exact SDR baseline string from startup
2. Set `render:cm_auto_hdr=2`
3. Apply via `hyprctl keyword monitor <string>`

SDR restoration is always exact — no drift from the user's original config.

### 6. CLI Commands

Existing commands keep working, with optional monitor argument:

| Command | Behavior |
|---------|----------|
| `hypr-sticky-hdr daemon` | Start the daemon (unchanged) |
| `hypr-sticky-hdr on [monitor]` | Force HDR on; no monitor = all enabled monitors |
| `hypr-sticky-hdr off [monitor]` | Release manual override; no monitor = all |
| `hypr-sticky-hdr status [monitor]` | Report state; no monitor = all monitors |
| `hypr-sticky-hdr reload` | Re-read config file and env vars, re-capture SDR baselines for monitors currently in SDR mode |

### 7. Install & First-Run

- Same install methods (curl one-liner, git clone)
- No config file needed for out-of-box use — all defaults apply, all monitors managed
- Installer prints: "Optional config: ~/.config/hypr-sticky-hdr/config"
- Repo ships a `config.example` with all options commented and documented
- README updated with config format, env var names, and common scenarios

### 8. What Changes From Current Implementation

| Aspect | Current | New |
|--------|---------|-----|
| SDR baseline | Read once, partially | Read all monitors, full capture |
| Config | Hardcoded vars at top of script | 3-layer hierarchy |
| Multi-monitor | First monitor only | All monitors, per-monitor state |
| Brightness default | 1.35 (personal) | 1.0 (universal) |
| Monitor name | Auto-detect first or manual | Auto-detect all |
| CLI commands | No monitor argument | Optional monitor argument |
| Config file | None | `~/.config/hypr-sticky-hdr/config` |
| Env var overrides | Only `HDR_SDR_BRIGHTNESS` pattern | Full `HYPR_STICKY_HDR_*` namespace |
