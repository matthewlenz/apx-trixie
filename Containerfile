# Build environment for the apx and apx-stacks packages: a trixie image with
# the build dependencies, and Go from trixie-backports because trixie's own
# Go 1.24 is too old for apx. Used by "build.sh --container", which keeps the
# host free of build tooling. Nothing here ends up in the packages.
FROM docker.io/library/debian:trixie

RUN echo 'deb http://deb.debian.org/debian trixie-backports main' \
        > /etc/apt/sources.list.d/backports.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential debhelper patch ca-certificates \
    && apt-get install -y --no-install-recommends -t trixie-backports \
        golang-go \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
