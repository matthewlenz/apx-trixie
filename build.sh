#!/bin/sh
# Build apx and apx-stacks .debs for Debian 13 (trixie) from pinned
# upstream sources, using the packaging in debian-apx/ and debian-apx-stacks/.
set -eu

APX_TAG=v3.1.2
COMMUNITY_COMMIT=e0b022184dd3c70a27727741dfc988ae813fca2d
GO_MIN=1.25

here=$(cd "$(dirname "$0")" && pwd)
build=$here/build

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }

usage() {
    cat <<EOF
usage: $0 [--clean]

Builds apx and apx-stacks .debs from pinned upstream sources.

  --clean   delete the build/ directory first, so everything is fetched
            and built from scratch; without it, clones are reused
EOF
}

clean=false
for arg in "$@"; do
    case $arg in
        --clean) clean=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $arg" ;;
    esac
done

# --- Before we touch anything ------------------------------------------

. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || die "this recipe targets Debian 13 (trixie), found ${PRETTY_NAME:-unknown}"
apt-cache policy golang-go | grep -q trixie-backports \
    || die "trixie-backports is not enabled (or 'apt update' has not run); see README.md"
for t in git dpkg-buildpackage dpkg-checkbuilddeps; do
    command -v "$t" >/dev/null || die "missing $t: sudo apt install git build-essential"
done
command -v sudo >/dev/null || die "sudo is needed to install build dependencies"

if $clean && [ -d "$build" ]; then
    step "Removing $build"
    rm -rf "$build"
fi
mkdir -p "$build"

# --- Upstream sources, pinned ------------------------------------------

step "Fetching apx $APX_TAG"
[ -d "$build/apx" ] || git clone https://github.com/Vanilla-OS/apx.git "$build/apx"
git -C "$build/apx" fetch --tags --quiet
git -C "$build/apx" -c advice.detachedHead=false checkout --quiet "$APX_TAG"
git -C "$build/apx" submodule update --init --recursive --quiet
[ "$(git -C "$build/apx" rev-parse HEAD)" = "$(git -C "$build/apx" rev-parse "$APX_TAG^{commit}")" ] \
    || die "apx is not checked out at $APX_TAG"
# apx bundles distrobox as a submodule and installs it; without it the
# package would build but apx would have nothing to drive.
[ -x "$build/apx/distrobox/distrobox" ] \
    || die "the distrobox submodule is empty; run: git -C $build/apx submodule update --init --recursive"
ok "apx at $APX_TAG, distrobox submodule present"
rm -rf "$build/apx/debian" && cp -r "$here/debian-apx" "$build/apx/debian"

step "Fetching apx-community $COMMUNITY_COMMIT"
[ -d "$build/apx-community" ] || git clone https://github.com/Vanilla-OS/apx-community.git "$build/apx-community"
git -C "$build/apx-community" fetch --quiet
git -C "$build/apx-community" -c advice.detachedHead=false checkout --quiet "$COMMUNITY_COMMIT"
[ "$(git -C "$build/apx-community" rev-parse HEAD)" = "$COMMUNITY_COMMIT" ] \
    || die "apx-community is not checked out at $COMMUNITY_COMMIT"
stacks=$(ls "$build"/apx-community/stacks/*/*.yml 2>/dev/null | wc -l)
[ "$stacks" -gt 0 ] || die "no stack YAML files found in $build/apx-community/stacks"
ok "apx-community at $(git -C "$build/apx-community" rev-parse --short HEAD), $stacks stacks"
rm -rf "$build/apx-community/debian" && cp -r "$here/debian-apx-stacks" "$build/apx-community/debian"

# --- Build dependencies ------------------------------------------------

step "Installing build dependencies (sudo)"
# Go >= 1.25 comes from backports; everything else from trixie main.
sudo apt install -y -t trixie-backports golang-go
sudo apt build-dep -y "$build/apx" "$build/apx-community"

go_version=$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
[ -n "$go_version" ] || die "go is not on PATH after installing golang-go"
dpkg --compare-versions "$go_version" ge "$GO_MIN" \
    || die "go $go_version is older than $GO_MIN; is trixie-backports really enabled?"
ok "go $go_version"

for tree in "$build/apx" "$build/apx-community"; do
    (cd "$tree" && dpkg-checkbuilddeps) \
        || die "build dependencies are still unsatisfied in $tree (see the list above)"
done
ok "build dependencies satisfied"

# --- Build -------------------------------------------------------------

step "Building apx"
(cd "$build/apx" && dpkg-buildpackage -us -uc -b)

step "Building apx-stacks"
(cd "$build/apx-community" && dpkg-buildpackage -us -uc -b)

# --- Check what came out -----------------------------------------------

step "Verifying the packages"
apx_deb=$(ls -t "$build"/apx_*.deb 2>/dev/null | head -1)
stacks_deb=$(ls -t "$build"/apx-stacks_*.deb 2>/dev/null | head -1)
[ -f "$apx_deb" ] || die "no apx .deb was produced"
[ -f "$stacks_deb" ] || die "no apx-stacks .deb was produced"

# The installed package must not need Go, only a container engine.
deps=$(dpkg-deb -f "$apx_deb" Depends)
case "$deps" in
    *golang*|*libc6*) die "unexpected runtime dependency in apx: $deps" ;;
esac
# Read each package's contents once: piping dpkg-deb into grep -q makes
# grep exit early and dpkg-deb die of SIGPIPE.
apx_files=$(dpkg-deb -c "$apx_deb")
stacks_files=$(dpkg-deb -c "$stacks_deb")
printf '%s\n' "$apx_files" | grep -q 'usr/share/apx/distrobox/distrobox$' \
    || die "the bundled distrobox is missing from $apx_deb"
printf '%s\n' "$apx_files" | grep -q 'etc/apx/config.json$' \
    || die "the config is missing from $apx_deb"
# The bundled distrobox carries a backported fix without which Debian
# testing and unstable subsystems cannot be created.
dpkg-deb --fsys-tarfile "$apx_deb" | tar xO ./usr/share/apx/distrobox/distrobox-init 2>/dev/null \
    | grep -q setup_tmpfiles_exceptions \
    || die "distrobox-init in $apx_deb is missing the tmpfiles patch"
yml=$(printf '%s\n' "$stacks_files" | grep -c '\.yml$')
[ "$yml" -gt 0 ] || die "no YAML files in $stacks_deb"
ok "apx depends on: $deps"
ok "apx-stacks ships $yml YAML files"

if command -v lintian >/dev/null; then
    lintian "$apx_deb" "$stacks_deb" || true
fi

step "Done"
ls -1 "$apx_deb" "$stacks_deb"
printf '\nInstall with:\n  sudo apt install %s %s\n' "$apx_deb" "$stacks_deb"
