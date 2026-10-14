#!/bin/sh
# Build rascal for Linux inside a container, using this checkout.
#
#   scripts/docker-build.sh [alpine|ubuntu] [make targets...]
#
# alpine (the default) builds a fully static musl executable, which runs on
# any Linux of the same architecture: build/linux-<arch>-static/bin/rascal
# ubuntu builds against glibc with everything else static:
# build/linux-<arch>/bin/rascal
#
# The make targets default to "all test". Set DOCKER_PLATFORM to build for
# another architecture, eg. DOCKER_PLATFORM=linux/amd64 (slow, emulated).

set -eu

distro=${1:-alpine}
[ $# -gt 0 ] && shift
targets=${*:-all test}

case "$distro" in
	alpine) static=full ;;
	ubuntu) static=deps ;;
	*) echo "usage: $0 [alpine|ubuntu] [make targets...]" >&2; exit 1 ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
image="rascal-build-$distro"

docker build ${DOCKER_PLATFORM:+--platform "$DOCKER_PLATFORM"} -q -t "$image" \
	-f "$root/docker/$distro.Dockerfile" "$root/docker" >/dev/null

docker run --rm ${DOCKER_PLATFORM:+--platform "$DOCKER_PLATFORM"} \
	-v "$root:/rascal" -w /rascal -u "$(id -u):$(id -g)" -e HOME=/tmp \
	"$image" sh -c "make -j\$(nproc) STATIC=$static $targets"
