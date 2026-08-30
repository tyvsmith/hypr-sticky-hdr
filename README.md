# hypr-sticky-hdr

Sticky HDR for [Hyprland](https://hyprland.org/)'s Lua config. Keeps a monitor
in HDR for as long as an HDR window lives, not just while it is fullscreen.
Hyprland's own `render:cm_auto_hdr` drops to SDR on every alt-tab; this module
holds HDR until the last HDR window is gone, plus a short cooldown.

One file, no daemon, no dependencies. Hyprland calls the module's Lua callbacks
directly, so the external process the old implementation needed (socat, jq, IPC
socket) is gone. Requires the Lua config introduced in Hyprland 0.55; written
and tested against 0.56.

## How it works

A window switches its monitor to the `hdr` spec when either:

- its process carries a marker env var (default: `DXVK_HDR=1` or
  `HYPR_STICKY_HDR=1`), read once per PID from `/proc/<pid>/environ`, or
- its window class is listed (default: `gamescope`).

When the last such window closes, the module waits `cooldown_sec` (default 2s)
and reverts to the `sdr` spec. The cooldown runs from the last close: a window
that opens and shuts during a pending cooldown restarts it at full length
rather than inheriting the nearly expired deadline.

A monitor that disconnects and returns gets its full current state re-applied
(Hyprland re-applies its own rules on reconnect, wiping fields like `bitdepth`
and `vrr` in both the HDR and SDR case), while other outputs' hotplugs are
ignored instead of modesetting this one. A repeating reconcile check
(`reconcile_sec`, default 30s) backstops any window event Hyprland drops.

## Installing

Drop the module into your Hyprland config directory:

```bash
curl -fsSL https://raw.githubusercontent.com/tyvsmith/hypr-sticky-hdr/main/sticky_hdr.lua \
  -o ~/.config/hypr/sticky_hdr.lua
```

On [Omarchy](https://omarchy.org/), `~/.config` is already on `package.path`,
so `require("hypr.sticky_hdr")` resolves as-is. On a plain Lua config, add the
path yourself before requiring:

```lua
package.path = os.getenv("HOME") .. "/.config/?.lua;" .. package.path
```

The require name is load-bearing: `hyprctl eval` prewarming (below) requires
the module by name, and a different name loads a second, empty instance that
prewarms nothing. Require it as `hypr.sticky_hdr` everywhere.

## Wiring it into monitors.lua

Replace your `hl.monitor(...)` call with `setup()`, passing the full spec:

```lua
-- ~/.config/hypr/monitors.lua
require("hypr.sticky_hdr").setup({
  monitor = {
    output        = "",          -- "" = wildcard; name it ("DP-3") on multi-monitor
    mode          = "preferred",
    position      = "auto",
    scale         = 1,
    bitdepth      = 10,
    vrr           = 2,
    sdrbrightness = 1.35,        -- only acts in HDR mode
    sdrsaturation = 1.0,
  },
})
```

`setup()` applies `monitor` merged with the `sdr` overlay (default
`{ cm = "srgb" }`) at startup, and swaps to `monitor` merged with the `hdr`
overlay (default `{ cm = "hdr" }`) while HDR demand exists. Windows already
open are adopted at startup, so a config reload mid-game does not flash SDR.

### Why the full spec

Hyprland monitor rules are whole-record replacements: any field left out
reverts to its default when the rule applies. The module therefore merges
`sdr`/`hdr` over your complete `monitor` spec instead of emitting a bare `cm`
change. State every field you care about.

The spec cannot be read back at runtime either. `HL.Monitor` exposes
`vrr_active`, whether VRR is engaged right now, not the configured mode, so
with `vrr = 2` (fullscreen-only) it reads false exactly when a game's window
opens. That is why the module takes a spec instead of inferring one.

### Options

| Key | Default | Description |
|---|---|---|
| `monitor` | required | Full `hl.monitor` spec, the base for both states |
| `sdr` | `{ cm = "srgb" }` | Overlay merged over `monitor` for the SDR state |
| `hdr` | `{ cm = "hdr" }` | Overlay merged over `monitor` for the HDR state |
| `env` | `{ "DXVK_HDR=1", "HYPR_STICKY_HDR=1" }` | Whole `NAME=value` environ entries that mark a process as HDR |
| `classes` | `{ "gamescope" }` | Window classes that always count as HDR |
| `cooldown_sec` | `2` | Seconds to linger in HDR after the last HDR window closes |
| `prewarm_sec` | `10` | Seconds a `prewarm()` hold lasts (see gamescope below) |
| `reconcile_sec` | `30` | Seconds between safety-net re-checks for missed events (`0` disables) |
| `environ_reader` | `/proc` reader | `function(pid) -> string\|nil` overriding how a process's environ is read (tests, exotic setups) |

The overlays can change any field, not just color: a lower refresh rate in HDR,
different brightness, anything `hl.monitor` accepts. Overlays and lists
**replace** their defaults rather than merging: a custom `hdr` must restate
`cm = "hdr"`, and a custom `classes` must restate `"gamescope"` if you still
want it.

Upgrading from the bash daemon: the defaults no longer match
`PROTON_ENABLE_HDR=1` (retired from current Proton builds) or
`ENABLE_HDR_WSI=1`. If your runner still uses either, pass the full list via
`env`.

`setup()` returns a handle with `wants_hdr()` (real window demand; prewarm
holds excluded), `in_hdr()`, and `prewarm()`. Multi-monitor: call `setup()`
once per output, each with its own named spec. Demand is scoped to the
instance's output, so a game on one monitor leaves the others in SDR.

## Prewarming for gamescope

gamescope probes the output's color state once at startup. If the monitor is
still in SDR at that instant, `--hdr-enabled` finds nothing to attach to, even
though gamescope's own window would flip the monitor to HDR a moment later.

`M.prewarm()` enters HDR ahead of any window and holds it for `prewarm_sec`
(default 10s). A qualifying window arriving inside the hold takes over normal
stickiness; otherwise the hold expires and the usual cooldown revert runs. The
hold's deadline is persisted to `$XDG_RUNTIME_DIR`, so a config reload that
recreates Hyprland's Lua VM mid-launch (Omarchy reloads on every file save)
resumes the hold instead of dropping to SDR right before gamescope's probe. It
is callable from outside the compositor:

```bash
hyprctl eval "require('hypr.sticky_hdr').prewarm()"
```

### With ScopeBuddy

How to deliver the prewarm from
[ScopeBuddy](https://github.com/HikariKnight/ScopeBuddy) depends on the launch
path, because scb only evals `SCB_PRE_COMMAND` on the gamescope path (verified
scopebuddy 1.5.0; the `SCB_NOSCOPE=1` branch never calls it). From a live
config:

```bash
# ~/.config/scopebuddy/scb.conf — shared piece
hdr_prewarm="hyprctl eval \"require('hypr.sticky_hdr').prewarm()\""
```

Gamescope titles: `SCB_PRE_COMMAND` runs right before gamescope execs, so the
one-shot color probe finds the monitor already in HDR. A `command=` prefix
would run inside gamescope, after the probe. gamescope supplies the game's HDR
itself (WSI layer), so `DXVK_HDR` stays unset and stickiness after the hold
rides the default `gamescope` class match:

```bash
SCB_PRE_COMMAND="$hdr_prewarm"
SCB_GAMESCOPE_ARGS="-w 5120 -h 2160 -W 5120 -H 2160 -r 165 -f --hdr-enabled --adaptive-sync"
unset DXVK_HDR
```

Native (no gamescope) titles: prefix the game command instead, and export
`DXVK_HDR=1` so the game renders HDR and its window matches the default `env`
markers once it appears:

```bash
export DXVK_HDR=1
command="$hdr_prewarm; $command"
```

Native titles rarely need the prewarm (the game's own window triggers HDR on
open), but it removes the SDR-to-HDR flash during loading screens.

## Triggering HDR for anything else

Launch with the marker env var:

```bash
HYPR_STICKY_HDR=1 some-hdr-app
```

Or add the app's window class to `classes`.

## Hyprland API notes

Quirks the module works around, current as of 0.56 (details in the file
header): monitor rules are whole-record replacements; `window.close` skips
SIGKILLed processes and `window.destroy` carries no address, so teardown
recounts live windows; `HL.Monitor.cm` reports the configured preset, not
live state.

## Tests

Behavior tests run the module against a mock `hl` — window and monitor events,
timers, cooldown and prewarm timing, per-output scoping — with plain Lua:

```bash
tests/run.sh
```

Needs bash and a `lua`/`lua5.4` interpreter, nothing else.

## Still on hyprlang?

The previous implementation, an external bash daemon doing the same detection
over Hyprland's IPC socket, lives on the
[`hyprlang-legacy`](https://github.com/tyvsmith/hypr-sticky-hdr/tree/hyprlang-legacy)
branch. It is unmaintained.

## License

MIT
