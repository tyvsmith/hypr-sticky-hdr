# hypr-sticky-hdr

Sticky HDR for [Hyprland](https://hyprland.org/)'s Lua config. Keeps a monitor
in HDR for as long as an HDR window lives, not just while it is fullscreen.
Hyprland's own `render:cm_auto_hdr` drops to SDR on every alt-tab. This module
disables that automation while it holds HDR, then restores it after the last
HDR window is gone plus a short cooldown.

One file, no daemon, and no extra runtime packages. Hyprland calls the module's
Lua callbacks directly, so the external process the old implementation needed
(socat, jq, IPC socket) is gone.

## Requirements

- Linux with `/proc` mounted so the module can inspect window processes
- Hyprland 0.56 with its Lua configuration API
- `hyprctl` for external `prewarm()`, reloads, and configuration-error checks

Source installation needs `make` and `install`; cloning needs `git`, while the
manual download needs `curl`.

## How it works

A window switches its monitor to the `hdr` spec when either:

- its process carries a marker env var (default: `DXVK_HDR=1` or
  `HYPR_STICKY_HDR=1`), read once per PID from `/proc/<pid>/environ`, or
- its window class is listed (default: `gamescope`).

When the last such window closes, the module waits `cooldown_sec` (default 2s)
and reverts to the `sdr` spec. The cooldown runs from the last close: a window
that opens and shuts during a pending cooldown restarts it at full length
rather than inheriting the nearly expired deadline.

The first managed output entering HDR applies the global HDR config before its
monitor spec. The config stays active while any managed output remains in HDR.
The last output queues its SDR monitor spec before restoring the global SDR
config. Hyprland applies queued monitor rules before `cm_auto_hdr` runs on the
next render.

A monitor that disconnects and returns gets its full current state re-applied
(Hyprland re-applies its own rules on reconnect, wiping fields like `bitdepth`
and `vrr` in both the HDR and SDR case), while other outputs' hotplugs are
ignored instead of modesetting this one. A repeating reconcile check
(`reconcile_sec`, default 30s) backstops any window event Hyprland drops.

## Installing

### Arch Linux

The `hypr-sticky-hdr` AUR package is the primary Arch installation:

```bash
paru -S hypr-sticky-hdr
```

- installs `sticky_hdr.lua` under `/usr/share/lua/<version>/hypr/`, on
  Hyprland's default `package.path`, plus the README and license; pacman owns
  every file
- depends on `hyprland>=0.56` and `lua`; the module directory follows the
  `lua` package version, which is the Lua that Hyprland links against
- remove any copy in `${XDG_CONFIG_HOME:-$HOME/.config}/hypr/` first; on
  Omarchy a user copy shadows the package
- any AUR helper works; Omarchy ships `yay`

### From source

Clone the repository and install for the current user:

```bash
git clone https://github.com/tyvsmith/hypr-sticky-hdr.git
cd hypr-sticky-hdr
make install-user
```

This installs `sticky_hdr.lua` under
`${XDG_CONFIG_HOME:-$HOME/.config}/hypr/`. Re-running `make install-user`
updates that copy. Remove it with `make uninstall-user` after unwiring the
module as described under [Uninstalling](#uninstalling). These targets only
copy or remove the module; they do not edit your Hyprland configuration.

For a direct system installation:

```bash
sudo make install
```

The default prefix is `/usr/local`. The target derives the Lua major.minor
version and installs under the standard
`$(prefix)/share/lua/$(LUA_VERSION)/hypr/sticky_hdr.lua` path, where
`require("hypr.sticky_hdr")` resolves without a `package.path` change. It also
installs the README and license.

Packagers can stage the same files with GNU-style variables:

```bash
make install DESTDIR=/tmp/hypr-sticky-hdr-package prefix=/usr
```

Set `LUA` or `LUA_VERSION` when the target runtime differs from the build host.
`luadir` and `moduledir` are available for package-specific layouts.

### Manual download

For a manual user install:

```bash
(
  set -eu
  module_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
  install -d "$module_dir"
  tmp=$(mktemp "$module_dir/.sticky_hdr.lua.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL https://raw.githubusercontent.com/tyvsmith/hypr-sticky-hdr/main/sticky_hdr.lua \
    -o "$tmp"
  test -s "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$module_dir/sticky_hdr.lua"
  trap - EXIT
)
```

### Release channels

- AUR: `hypr-sticky-hdr` tracks tagged releases. The release workflow
  regenerates and pushes its `PKGBUILD` and `.SRCINFO`.
- GitHub releases: each `vX.Y.Z` tag runs `distcheck` and publishes
  `hypr-sticky-hdr-X.Y.Z.tar.gz` with a `.sha256` file. The workflow does not
  create the tag.
- `main`: development branch and the manual download source. It can change;
  replace `main` in the URL with a commit SHA for a reproducible install.

A system installation (the Arch package, or `sudo make install` matching
Hyprland's Lua version) is on the stock `package.path`, so no prepend is
needed. On [Omarchy](https://omarchy.org/), `~/.config` is also on
`package.path`, so a user installation resolves as-is. For a user installation
with a plain Lua config, add the config home before requiring:

```lua
local config_home = os.getenv("XDG_CONFIG_HOME")
  or (os.getenv("HOME") .. "/.config")
package.path = config_home .. "/?.lua;" .. package.path
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

`setup()` applies `monitor` merged with the SDR monitor overlay at startup, then
swaps to the HDR monitor overlay while HDR demand exists. It also applies the
state's compositor-wide `hl.config` table. The defaults are:

```lua
sdr = {
  monitor = { cm = "srgb" },
  config = { render = { cm_auto_hdr = 1 } },
}
hdr = {
  monitor = { cm = "hdr" },
  config = { render = { cm_auto_hdr = 0 } },
}
```

Windows already open are adopted at startup, so a config reload mid-game does
not flash SDR.

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
| `sdr` | see above | SDR monitor overlay and global config |
| `hdr` | see above | HDR monitor overlay and global config |
| `env` | `{ "DXVK_HDR=1", "HYPR_STICKY_HDR=1" }` | Whole `NAME=value` environ entries that mark a process as HDR |
| `classes` | `{ "gamescope" }` | Window classes that always count as HDR |
| `cooldown_sec` | `2` | Seconds to linger in HDR after the last HDR window closes |
| `prewarm_sec` | `10` | Seconds a `prewarm()` hold lasts (see gamescope below) |
| `reconcile_sec` | `30` | Seconds between safety-net re-checks for missed events (`0` disables) |
| `environ_reader` | `/proc` reader | `function(pid) -> string\|nil` overriding how a process's environ is read (tests, exotic setups) |

State members inherit their defaults when omitted. A supplied `monitor` or
`config` member replaces that member's default instead of merging with it. A
custom monitor overlay must therefore restate `cm`, and a custom config must
include every global setting the state needs. Monitor overlays can change any
field that `hl.monitor` accepts.

State overrides must use the structured `monitor` and `config` members shown
above. For example, this keeps the default HDR global config but replaces the
HDR monitor overlay:

```lua
hdr = {
  monitor = {
    cm = "hdr",
    sdrbrightness = 1.2,
  },
}
```

List options replace their defaults. A custom `classes` list must restate
`"gamescope"` to keep it, and a custom `env` list must restate either default
marker you still use. Class matches and environment entries are exact.

`setup()` returns a handle with `wants_hdr()` (real window demand; prewarm
holds excluded), `in_hdr()`, and `prewarm()`. Multi-monitor: call `setup()`
once per output, each with its own named spec. Demand is scoped to the
instance's output, so a game on one monitor leaves the others in SDR. All calls
share one global config arbiter and must supply deeply equal SDR/HDR config
tables. Monitor overlays may differ per output.

## Prewarming for gamescope

gamescope probes the output's color state once at startup. If the monitor is
still in SDR at that instant, `--hdr-enabled` finds nothing to attach to, even
though gamescope's own window would flip the monitor to HDR a moment later.

Module-level `M.prewarm()` enters HDR on every configured output and holds each
one for `prewarm_sec` (default 10s). The handle returned by `setup()` exposes a
per-output `prewarm()` method for calls made inside the Lua config. The external
command below calls the module method, so it prewarms all managed outputs:

```bash
hyprctl eval "require('hypr.sticky_hdr').prewarm()"
```

A qualifying window arriving inside a hold takes over normal stickiness.
Otherwise the hold expires and the usual cooldown revert runs. Deadlines are
persisted per output in `$XDG_RUNTIME_DIR`, so a config reload that recreates
Hyprland's Lua VM resumes each output independently.

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

## Verifying

Run the repository checks before installing or updating:

```bash
make check
```

After installation, reload Hyprland and check its Lua configuration:

```bash
hyprctl reload
hyprctl configerrors
```

Then launch a window with `HYPR_STICKY_HDR=1` and inspect `hyprctl monitors`
while it is open and after the cooldown. This checks the real compositor path;
the repository test suite does not.

## Migrating

### From flat Lua state overrides

Current `sdr` and `hdr` overrides use structured `monitor` and `config` members.
Either may be omitted to inherit its default. Move fields from an older flat
overlay under `monitor`:

```lua
-- Before
hdr = { cm = "hdr", sdrbrightness = 1.2 }

-- After
hdr = {
  monitor = { cm = "hdr", sdrbrightness = 1.2 },
}
```

Omitting `config` inherits the state's default global config. Supplying it
replaces that default member.

### From the legacy daemon

Back up `${XDG_CONFIG_HOME:-$HOME/.config}/hypr-sticky-hdr/`, then translate
any settings you still need into `setup()` before deleting that directory.
Remove the `exec-once = hypr-sticky-hdr daemon` autostart entry, then stop the
running daemon or restart the Hyprland session before loading the Lua module.
Running both implementations makes them compete for monitor state. Remove
`~/.local/bin/hypr-sticky-hdr` after the migration. The old code remains on the
unmaintained
[`hyprlang-legacy`](https://github.com/tyvsmith/hypr-sticky-hdr/tree/hyprlang-legacy)
branch for reference.

The Lua defaults no longer match `PROTON_ENABLE_HDR=1` or `ENABLE_HDR_WSI=1`.
If a runner still needs them, include them alongside any defaults you want to
keep because `env` replaces the whole list.

## Updating

Arch package: `paru -Syu`, then review the migration notes above and reload.

For a source installation, fetch the cloned tree first:

```bash
git pull --ff-only
```

Review the migration notes above and adjust your config before replacing the
installed module. Then update a user installation:

```bash
make check
make install-user
```

For a direct system installation, run `make check`, then rerun
`sudo make install` with the original `prefix` and no `DESTDIR`. For a manual
user installation, repeat the atomic download above after reviewing the current
migration notes.

Use the package manager to update package-owned files. Packagers use `DESTDIR`
only to stage package contents; it is not a live installation root.

Reload after any update:

```bash
hyprctl reload
hyprctl configerrors
```

## Uninstalling

1. Replace each `setup()` call with the original `hl.monitor(...)` call, and
   restore the `render.cm_auto_hdr` setting you want Hyprland to own.
2. Remove external `prewarm()` calls, including ScopeBuddy launch hooks.
3. Remove the module with the same owner that installed it:
   - Arch package: `sudo pacman -Rns hypr-sticky-hdr`
   - other package installation: use the package manager
   - `make install-user`: run `make uninstall-user`
   - direct `sudo make install`: run `sudo make uninstall` with the original
     `prefix` and no `DESTDIR`
   - manual download: delete the installed `sticky_hdr.lua`
4. Remove `${XDG_RUNTIME_DIR:-/tmp}/hypr-sticky-hdr-prewarm-*` if you want to
   discard saved prewarm deadlines.
5. Run `hyprctl reload` and `hyprctl configerrors`.

## Hyprland API notes

Quirks the module works around, current as of 0.56 (details in the file
header): monitor rules are whole-record replacements; `window.close` skips
SIGKILLed processes and `window.destroy` carries no address, so teardown
recounts live windows; `HL.Monitor.cm` reports the configured preset, not
live state.

## Development and packaging

Behavior tests run the module against a mock `hl` — window and monitor events,
timers, cooldown and prewarm timing, per-output scoping — with plain Lua:

```bash
make check
```

The checks need Bash and a `lua5.4` or `lua` interpreter. They do not exercise a
real Hyprland session, GPU, display, or gamescope process; use the verification
steps above for that path.

Maintainers and packagers can build and inspect an archive without creating a
release:

```bash
make dist VERSION=X.Y.Z
make distcheck VERSION=X.Y.Z
```

`VERSION` must be numeric stable SemVer. `dist` writes
`dist/hypr-sticky-hdr-X.Y.Z.tar.gz` and its `.sha256` file. `distcheck` verifies
the checksum, runs the checks from the extracted archive, and tests staged
system installation and removal. These targets do not create a tag or GitHub
release. Archive builds also need GNU `tar`, `cp`, and `sha256sum`.

### Arch packaging

- `packaging/aur/PKGBUILD` is the template. `make pkgbuild VERSION=X.Y.Z
  [PKGREL=N]` renders `dist/aur/PKGBUILD` from
  `dist/hypr-sticky-hdr-X.Y.Z.tar.gz.sha256`: run `make dist` first, or drop
  the published `.sha256` there. `distcheck` also renders it.
- `packaging/aur/build.sh` builds, lints with `namcap`, installs, and
  smoke-tests the rendered package inside an `archlinux:base-devel` container.
  CI runs it on every pull request against a `0.0.0` archive, and weekly so a
  Lua major.minor bump on Arch shows up before users hit it.
- When Arch bumps `lua`, the installed module path changes with it. Republish
  the same version with a higher `PKGREL` so pacman rebuilds it.
- Run it locally with rootless podman (with docker, pass your own uid and gid
  as `HOST_UID` and `HOST_GID`):

```bash
make dist VERSION=0.0.0 && make pkgbuild VERSION=0.0.0
cp dist/hypr-sticky-hdr-0.0.0.tar.gz dist/aur/
podman run --rm -v "$PWD/dist/aur:/pkg" \
  -v "$PWD/packaging/aur/build.sh:/build.sh:ro" \
  -e HOST_UID=0 -e HOST_GID=0 \
  docker.io/library/archlinux:base-devel bash /build.sh /pkg
```

- Publishing: pushing `vX.Y.Z` runs the release workflow. After the GitHub
  release is public, its `publish-aur` job calls `aur.yml`, which downloads the
  asset, renders and builds the recipe, then pushes `PKGBUILD` and `.SRCINFO`
  with the `AUR_SSH_KEY` secret from the `aur` environment.
- Packaging-only republish of a released version:
  `gh workflow run aur.yml --ref main -f version=X.Y.Z -f pkgrel=2`
- Manual fallback from an AUR clone:

```bash
git clone ssh://aur@aur.archlinux.org/hypr-sticky-hdr.git
cp dist/aur/PKGBUILD hypr-sticky-hdr/ && cd hypr-sticky-hdr
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO && git commit -m "Update to vX.Y.Z" && git push
```

## License

MIT
