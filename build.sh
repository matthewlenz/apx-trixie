#!/bin/sh
# Build apx and apx-stacks .debs for Debian 13 (trixie) from pinned
# upstream sources, using the packaging in debian-apx/ and debian-apx-stacks/.
set -eu

APX_TAG=v3.1.2
COMMUNITY_COMMIT=e0b022184dd3c70a27727741dfc988ae813fca2d
CONFIGS_COMMIT=1a37e751e7326da7b26ccf6c76dd46999efc2166
GO_MIN=1.25

here=$(cd "$(dirname "$0")" && pwd)
build=$here/build

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }

usage() {
    cat <<EOF
usage: $0 [--clean]

Builds apx and apx-stacks .debs from pinned upstream sources, inside a
podman container, so the host needs no compiler, debhelper or backports Go.

  --clean   delete the build/ directory first, so everything is fetched
            and built from scratch; without it, clones are reused
EOF
}

clean=false
IMAGE=localhost/apx-trixie-build
for arg in "$@"; do
    case $arg in
        --clean) clean=true ;;
        --container) printf 'note: container builds are the default now\n' >&2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $arg" ;;
    esac
done

# --- Before we touch anything ------------------------------------------

. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || die "this recipe targets Debian 13 (trixie), found ${PRETTY_NAME:-unknown}"
command -v git >/dev/null || die "missing git: sudo apt install git"
command -v podman >/dev/null || die "missing podman: sudo apt install podman"
command -v dpkg-deb >/dev/null || die "missing dpkg-deb"

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

step "Fetching vanilla-apx-configs $CONFIGS_COMMIT"
# The base distro stacks and the package managers live here now: this is
# what Vanilla OS ships, and apx-community has had no commits since 2025.
[ -d "$build/vanilla-apx-configs" ] || git clone https://github.com/Vanilla-OS/vanilla-apx-configs.git "$build/vanilla-apx-configs"
git -C "$build/vanilla-apx-configs" fetch --quiet
git -C "$build/vanilla-apx-configs" -c advice.detachedHead=false checkout --quiet "$CONFIGS_COMMIT"
[ "$(git -C "$build/vanilla-apx-configs" rev-parse HEAD)" = "$CONFIGS_COMMIT" ] \
    || die "vanilla-apx-configs is not checked out at $CONFIGS_COMMIT"
base_stacks=$(ls "$build"/vanilla-apx-configs/stacks/*.yaml 2>/dev/null | wc -l)
[ "$base_stacks" -gt 0 ] || die "no stack YAML files found in $build/vanilla-apx-configs/stacks"
ok "vanilla-apx-configs at $(git -C "$build/vanilla-apx-configs" rev-parse --short HEAD), $base_stacks base stacks"
# Overlaid into the apx-community tree, which is where apx-stacks is built.
cp -r "$build/vanilla-apx-configs/stacks" "$build/apx-community/debian/stacks-vanilla"
cp -r "$build/vanilla-apx-configs/package-managers" "$build/apx-community/debian/pkgmanagers-vanilla"

# --- Build environment -------------------------------------------------

step "Building the container image"
# Trixie plus the build dependencies, Go included. Layers are cached, so
# only the first run installs anything.
podman build -t "$IMAGE" -f "$here/Containerfile" "$here"
go_version=$(podman run --rm "$IMAGE" go version | awk '{print $3}' | sed 's/^go//')
[ -n "$go_version" ] || die "go is missing from the build image"
dpkg --compare-versions "$go_version" ge "$GO_MIN" \
    || die "the build image has go $go_version, older than $GO_MIN"
ok "go $go_version in $IMAGE"

# --- Build -------------------------------------------------------------

# Rootless podman maps the host user to root inside, so files written to the
# mounted build directory come back owned by the host user.
build_tree() {
    podman run --rm -v "$build:/build" -w "/build/$1" "$IMAGE" \
        dpkg-buildpackage -us -uc -b
}

step "Building apx"
build_tree apx

step "Building apx-stacks"
build_tree apx-community

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
yml=$(printf '%s\n' "$stacks_files" | grep -c 'stacks/.*\.ya\?ml$')
[ "$yml" -gt 0 ] || die "no stack YAML files in $stacks_deb"
printf '%s\n' "$stacks_files" | grep -q 'stacks/debian-testing.yml$' \
    || die "our own Debian stacks are missing from $stacks_deb"
printf '%s\n' "$stacks_files" | grep -q 'stacks/arch.yaml$' \
    || die "the vanilla-apx-configs base stacks are missing from $stacks_deb"
printf '%s\n' "$stacks_files" | grep -q 'stacks/ubuntu-go.yml$' \
    || die "the apx-community language stacks are missing from $stacks_deb"
# apx lists every file in the package-manager directory, so apt.yml beside
# apt.yaml would show "apt" twice. Exactly one definition per name.
dupes=$(printf '%s\n' "$stacks_files" | sed -n 's|.*/package-managers/\(.*\)\.ya\?ml$|\1|p' \
    | sort | uniq -d)
[ -z "$dupes" ] || die "duplicate package-manager definitions in $stacks_deb: $dupes"
ok "apx depends on: $deps"
ok "apx-stacks ships $yml stacks"

if command -v lintian >/dev/null; then
    lintian "$apx_deb" "$stacks_deb" || true
fi

step "Done"
ls -1 "$apx_deb" "$stacks_deb"
printf '\nInstall with:\n  sudo apt install %s %s\n' "$apx_deb" "$stacks_deb"
