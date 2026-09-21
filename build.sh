#!/bin/sh
# Build apx and apx-stacks .debs for Debian 13 (trixie) from pinned
# upstream sources, using the packaging in debian-apx/ and debian-apx-stacks/.
set -eu

APX_TAG=v3.1.2
COMMUNITY_COMMIT=e0b022184dd3c70a27727741dfc988ae813fca2d

here=$(cd "$(dirname "$0")" && pwd)
build=$here/build

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || die "this recipe targets Debian 13 (trixie), found ${PRETTY_NAME:-unknown}"
apt-cache policy golang-go | grep -q trixie-backports \
    || die "trixie-backports is not enabled; see README.md"
command -v git >/dev/null && command -v dpkg-buildpackage >/dev/null \
    || die "missing tools: sudo apt install git build-essential"

mkdir -p "$build"

step "Fetching apx $APX_TAG"
[ -d "$build/apx" ] || git clone https://github.com/Vanilla-OS/apx.git "$build/apx"
git -C "$build/apx" fetch --tags --quiet
git -C "$build/apx" -c advice.detachedHead=false checkout "$APX_TAG"
git -C "$build/apx" submodule update --init --recursive
rm -rf "$build/apx/debian" && cp -r "$here/debian-apx" "$build/apx/debian"

step "Fetching apx-community $COMMUNITY_COMMIT"
[ -d "$build/apx-community" ] || git clone https://github.com/Vanilla-OS/apx-community.git "$build/apx-community"
git -C "$build/apx-community" fetch --quiet
git -C "$build/apx-community" -c advice.detachedHead=false checkout "$COMMUNITY_COMMIT"
rm -rf "$build/apx-community/debian" && cp -r "$here/debian-apx-stacks" "$build/apx-community/debian"

step "Installing build dependencies (sudo)"
# Go >= 1.25 comes from backports; everything else from trixie main.
sudo apt install -y -t trixie-backports golang-go
sudo apt build-dep -y "$build/apx" "$build/apx-community"

step "Building apx"
(cd "$build/apx" && dpkg-buildpackage -us -uc -b)

step "Building apx-stacks"
(cd "$build/apx-community" && dpkg-buildpackage -us -uc -b)

step "Done"
ls -1 "$build"/*.deb
printf '\nInstall with:\n  sudo apt install %s/apx_*.deb %s/apx-stacks_*.deb\n' "$build" "$build"
