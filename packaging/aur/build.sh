#!/usr/bin/env bash
# Build, lint, install, and smoke-test the hypr-sticky-hdr Arch package from a
# rendered PKGBUILD. Runs as root inside docker.io/library/archlinux:base-devel.
# The CI package gate and the AUR publish both call it. Leaves .SRCINFO and the
# built *.pkg.tar.zst in the package directory.
#
# Usage: build.sh <dir containing PKGBUILD>
# Env:   HOST_UID, HOST_GID  chown the package dir back to this owner on exit
#        (bind mounts); unset skips the chown.
set -euo pipefail

PKGNAME=hypr-sticky-hdr
PKGDIR="$(cd "${1:?usage: build.sh <dir containing PKGBUILD>}" && pwd)"
fail() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

[[ -f "$PKGDIR/PKGBUILD" ]] || fail "no PKGBUILD in $PKGDIR"
[[ $EUID -eq 0 ]] || fail "must run as root inside an Arch container"
grep -qx 'ID=arch' /etc/os-release || fail "not an Arch Linux system"

# The archlinux image ships NoExtract rules (docs, man, locale) to stay small.
# Drop them so `pacman -U` lays down every packaged file, as on a real system.
sed -i '/^NoExtract/d' /etc/pacman.conf

# The image ships a populated keyring but no local master key, which the
# archlinux-keyring install hook needs to repopulate. Create one, then refresh
# the keyring in its own transaction: pacman verifies every package in a
# transaction against the keyring present before it starts, so a single -Syu
# fails on anything signed with a key newer than the pinned image.
pacman-key --init
pacman -Sy --noconfirm --needed archlinux-keyring
pacman -Su --noconfirm --needed namcap

# makepkg refuses to run as root. --syncdeps installs depends via sudo pacman.
id builder >/dev/null 2>&1 || useradd -m builder
printf 'builder ALL=(root) NOPASSWD: /usr/bin/pacman\n' > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder
# Hand the bind mount back to the host owner on every exit, including failures.
restore_owner() {
  if [[ -n "${HOST_UID:-}" ]]; then
    chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$PKGDIR"
  fi
}
trap restore_owner EXIT
chown -R builder:builder "$PKGDIR"

cd "$PKGDIR"
rm -f ./*.pkg.tar.zst
runuser -u builder -- makepkg --syncdeps --noconfirm --cleanbuild --force

pkgfiles=( "$PKGNAME"-*.pkg.tar.zst )
[[ ${#pkgfiles[@]} -eq 1 && -f ${pkgfiles[0]} ]] || fail "expected one package, found: ${pkgfiles[*]}"
pkgfile="$PKGDIR/${pkgfiles[0]}"

# namcap exits 0 even when it reports errors, so fail on E: lines ourselves.
namcap_log="$(mktemp)"
namcap PKGBUILD "$pkgfile" 2>&1 | tee "$namcap_log"
! grep -qE '(^| )E: ' "$namcap_log" || fail "namcap reported errors"

pacman -U --noconfirm "$pkgfile"

# pacman must own exactly three files, at the Lua path Arch's lua package declares.
lmod="$(pkg-config --variable=INSTALL_LMOD lua)"
[[ -n "$lmod" ]] || fail "pkg-config could not resolve INSTALL_LMOD for lua"
expected="$(printf '%s\n' \
  "$lmod/hypr/sticky_hdr.lua" \
  "/usr/share/doc/$PKGNAME/README.md" \
  "/usr/share/licenses/$PKGNAME/LICENSE" | LC_ALL=C sort)"
actual="$(pacman -Qlq "$PKGNAME" | grep -v '/$' | LC_ALL=C sort)"
[[ "$actual" == "$expected" ]] || {
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
  fail "unexpected package file list"
}
while IFS= read -r f; do
  [[ -f "$f" ]] || fail "missing on disk: $f"
  pacman -Qo "$f" | grep -qF " is owned by $PKGNAME " || fail "not owned by $PKGNAME: $f"
done <<<"$expected"
pacman -Qk "$PKGNAME"

# Hyprland must link the Lua major.minor the module was installed under.
hypr_lua="$(readelf -d /usr/bin/Hyprland | sed -nE 's/.*NEEDED.*\[liblua\.so\.([0-9]+\.[0-9]+)\].*/\1/p' | head -n1)"
[[ -n "$hypr_lua" ]] || fail "could not determine the Lua version Hyprland links: no liblua.so.X.Y in NEEDED"
[[ "$lmod" == "/usr/share/lua/$hypr_lua" ]] || fail "Hyprland links Lua $hypr_lua but the module installed under $lmod"

# The module resolves from the stock package.path, with no user-local copy.
( cd / && lua -e 'assert(require("hypr.sticky_hdr"))' )

runuser -u builder -- makepkg --printsrcinfo > .SRCINFO
printf 'build.sh: OK %s\n' "$pkgfile"
