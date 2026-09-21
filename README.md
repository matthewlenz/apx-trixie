# apx for Debian 13 (trixie)

Build recipe for [Vanilla OS apx](https://github.com/Vanilla-OS/apx) on
Debian 13. This repo contains only packaging and directions: the sources are
fetched from upstream at pinned versions, and you build the `.deb`s yourself.

It produces two packages:

- **`apx`**: the apx binary plus its bundled copy of distrobox. It depends
  only on `podman`, not on Go.
- **`apx-stacks`**: the stack and package-manager definitions from
  [apx-community](https://github.com/Vanilla-OS/apx-community) (Fedora, Arch,
  Ubuntu, Vanilla OS). apx has no stacks of its own, so you want this too.

| | Pinned version |
|---|---|
| apx | `v3.1.2` |
| apx-community | `e0b0221` (2025-06-14) |

## Requirements

- Debian 13 (trixie).
- `git` and `podman`. That's it — podman is what apx itself needs, and the
  build happens inside a container, so the host gets no compiler, no
  debhelper and no Go.
- Internet access during the build, for the base image, the build
  dependencies and the Go modules (verified against upstream's `go.sum`).

apx needs Go 1.25 while trixie ships 1.24, so the build image takes Go from
trixie-backports. That is the build container's business, not your system's.
Go is build-time only: the resulting `apx` is a static binary that depends on
nothing but a container engine.

## Build

```sh
git clone https://github.com/matthewlenz/apx-trixie.git && cd apx-trixie
./build.sh
sudo apt install ./build/apx_*.deb ./build/apx-stacks_*.deb
```

`build.sh` clones upstream into `build/`, overlays the packaging, builds an
image from the `Containerfile` (trixie plus the build dependencies), and runs
`dpkg-buildpackage` inside it for each package. It then checks what came out:
that both packages exist, that apx's runtime dependencies mention no Go, and
that the config, the bundled distrobox and the stacks are really inside.

Image layers are cached, so only the first run installs anything; a full
clean build takes well under a minute. Rootless podman maps you to root
inside the container, so the `.deb` files land in `build/` owned by you.

Re-running reuses the clones in `build/`. Pass `--clean` to delete that
directory and start from scratch.

apt may print a notice that the download was "performed unsandboxed as
root". That's harmless: apt couldn't read files inside your home directory as
its `_apt` user.

### By hand

```sh
# apx
git clone --recurse-submodules --branch v3.1.2 https://github.com/Vanilla-OS/apx.git build/apx
cp -r debian-apx build/apx/debian

# apx-stacks
git clone https://github.com/Vanilla-OS/apx-community.git build/apx-community
git -C build/apx-community checkout e0b022184dd3c70a27727741dfc988ae813fca2d
cp -r debian-apx-stacks build/apx-community/debian

# the build environment, then a build in it
podman build -t apx-trixie-build -f Containerfile .
podman run --rm -v "$PWD/build:/build" -w /build/apx apx-trixie-build \
    dpkg-buildpackage -us -uc -b
podman run --rm -v "$PWD/build:/build" -w /build/apx-community apx-trixie-build \
    dpkg-buildpackage -us -uc -b
```

Nothing stops you building on the host instead, if you would rather have the
tooling there: enable trixie-backports, `sudo apt install -t trixie-backports
golang-go`, `sudo apt build-dep ./build/apx ./build/apx-community`, then
`dpkg-buildpackage -us -uc -b` in each tree. Install Go explicitly first,
because a plain `apt build-dep` will not take it from backports and trixie's
1.24 is too old.

## Try it

```sh
apx stacks list
apx subsystems new -n test -s ubuntu-go
apx test run go version
apx subsystems rm -n test -f
```

The first `run` takes a couple of minutes while distrobox sets up the
container and installs the stack's packages; after that it's quick. Use
`apx test enter` for an interactive shell. Note that `run` doesn't accept a
`--` separator.

If Docker is installed as well, apx uses podman first.

## Debian testing and unstable

The bundled distrobox carries one backported fix
(`debian-apx/patches/distrobox-mask-tmpfiles.patch`). Without it, any image
with systemd 261 or newer fails to initialise under rootless podman:
systemd-tmpfiles tries to chown the bind-mounted /tmp, /dev and /sys, gets
EPERM, and package setup aborts. That covers Debian testing and unstable,
which are the images Debian users are most likely to want.

The fix is upstream's own, released so far only in distrobox 2.0.0-rc.4,
while apx bundles 1.8.1.2. It can be dropped once apx updates its submodule.

apx-community has no Debian stacks at all, so `apx-stacks` adds two of our
own (`debian-apx-stacks/stacks-debian/`):

```sh
apx subsystems new -n forky -s debian-testing   # or debian-sid
apx forky install ripgrep
```

That pulls from testing or unstable without touching the host. Note that a
stack is only a name, an image, a package list and a package manager, with
no hooks, so a "stable plus backports" stack is not expressible; enable
backports inside a container after creating it.

## Known upstream quirks

- apx reads `/etc/apx/config.json`, but upstream's `make install` writes
  `/etc/apx/apx.json`, which apx never reads. This packaging installs
  `config.json`.
- The "Built-in" column shows raw `apx.terminal.yes` / `apx.terminal.no`
  strings. Upstream's code and translation files disagree on these message
  names; it's cosmetic.
- `apx <name> run` parses flags itself, so `apx forky run rg --version` fails
  with "unknown flag". Use `apx <name> enter` for anything with flags.
- apx-community carries no license statement. This recipe fetches it straight
  from upstream rather than redistributing it.

## License

The packaging in this repo (`debian-apx/`, `debian-apx-stacks/`, `build.sh`)
is GPL-3, the same as apx.
