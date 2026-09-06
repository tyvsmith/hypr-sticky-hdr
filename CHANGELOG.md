# Changelog

Notable changes to hypr-sticky-hdr. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-06

First tagged release.

### Added

- `sticky_hdr.lua`, a Hyprland 0.56 Lua config module that keeps a monitor in
  HDR while a tagged window lives, then restores `render:cm_auto_hdr` after a
  cooldown; per-output scoping, prewarm, and a reconcile timer
- `make install-user`, `make install` with GNU `DESTDIR` and `prefix`, and
  `make dist` / `make distcheck` for reproducible source archives
- behavior tests against a mock `hl` API (`make check`), run in CI on Lua 5.4
  and, through the Arch package gate, on Lua 5.5
- AUR package `hypr-sticky-hdr`, published by the release workflow from the
  tagged archive

### Changed

- replaced the bash daemon (socat, jq, IPC socket polling) with the Lua module;
  the daemon lives on the `hyprlang-legacy` branch

[Unreleased]: https://github.com/tyvsmith/hypr-sticky-hdr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tyvsmith/hypr-sticky-hdr/releases/tag/v0.1.0
