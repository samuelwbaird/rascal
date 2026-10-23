#!/bin/sh
# Install rascal from a GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/samuelwbaird/rascal/main/install.sh | sh
#
# Downloads the executable for this platform (macOS arm64 or x86_64, Linux
# x86_64 or aarch64), checks it against the release's SHA256SUMS, and
# installs it to $PREFIX/bin, with its licences in $PREFIX/share/doc/rascal.
# On a platform without a prebuilt executable it builds from source instead,
# which needs make, a C and C++ compiler, and tar.
#
# Settings, as environment variables (eg. curl ... | PREFIX=/opt/rascal sh):
#   RASCAL_VERSION       the version to install, eg. 0.1.0 (default the latest release)
#   PREFIX               where to install (default ~/.local, or /usr/local as root)
#   RASCAL_FROM_SOURCE   set to 1 to build from source even if there is an executable

set -eu

repository=samuelwbaird/rascal
# where release files and source archives are downloaded from, changeable for testing
releases=${RASCAL_RELEASES:-https://github.com/$repository/releases/download}
sources=${RASCAL_SOURCES:-https://github.com/$repository/archive/refs/tags}

fail() {
	echo "install.sh: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is needed, but was not found"
}

download() {
	curl -fsSL --retry 3 -o "$2" "$1"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# check a downloaded file against SHA256SUMS
verify() {
	expected=$(grep " $2\$" "$work/SHA256SUMS" | cut -d' ' -f1)
	[ -n "$expected" ] || fail "$2 is not listed in SHA256SUMS"
	[ "$(sha256_of "$1")" = "$expected" ] || fail "$2 does not match its checksum"
}

main() {
	need curl
	need tar

	# the platform, named as in the release files
	os=$(uname -s)
	arch=$(uname -m)
	case "$os-$arch" in
		Darwin-arm64) platform=darwin-arm64 ;;
		Darwin-x86_64) platform=darwin-x86_64 ;;
		Linux-x86_64) platform=linux-x86_64-static ;;
		Linux-aarch64 | Linux-arm64) platform=linux-aarch64-static ;;
		*) platform= ;;
	esac

	# the version, by default the latest release
	version=${RASCAL_VERSION:-}
	if [ -z "$version" ]; then
		latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repository/releases/latest")
		version=${latest##*/v}
		[ -n "$version" ] && [ "$version" != "$latest" ] || fail "could not find the latest release"
	fi
	version=${version#v}

	if [ "$(id -u)" = 0 ]; then
		prefix=${PREFIX:-/usr/local}
	else
		prefix=${PREFIX:-$HOME/.local}
	fi

	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT

	echo "installing rascal $version to $prefix"
	download "$releases/v$version/SHA256SUMS" "$work/SHA256SUMS" || fail "rascal $version was not found"

	archive=rascal-$version-$platform.tar.gz
	if [ -n "$platform" ] && [ "${RASCAL_FROM_SOURCE:-0}" != 1 ] && grep -q " $archive\$" "$work/SHA256SUMS"; then
		# a prebuilt executable
		download "$releases/v$version/$archive" "$work/$archive"
		verify "$work/$archive" "$archive"
		tar -xzf "$work/$archive" -C "$work"
		mkdir -p "$prefix/bin" "$prefix/share/doc/rascal"
		cp "$work/rascal-$version-$platform/rascal" "$prefix/bin/rascal.new"
		chmod 755 "$prefix/bin/rascal.new"
		mv -f "$prefix/bin/rascal.new" "$prefix/bin/rascal"
		cp "$work/rascal-$version-$platform/LICENSES.txt" "$prefix/share/doc/rascal/LICENSES.txt"
	else
		# build from source, with the dependencies from the release rather than their own sites
		echo "building from source"
		need make
		need cc
		need c++
		dependencies=rascal-$version-dependencies.tar
		download "$releases/v$version/$dependencies" "$work/$dependencies"
		verify "$work/$dependencies" "$dependencies"
		download "$sources/v$version.tar.gz" "$work/source.tar.gz" || fail "could not download the source of rascal $version"
		mkdir "$work/source"
		tar -xzf "$work/source.tar.gz" -C "$work/source"
		source_dir=$(find "$work/source" -mindepth 1 -maxdepth 1 -type d | head -n 1)
		mkdir -p "$source_dir/build"
		tar -xf "$work/$dependencies" -C "$source_dir/build"
		jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
		make -C "$source_dir" -j"$jobs" >"$work/build.log" 2>&1 || { tail -30 "$work/build.log"; fail "the build failed"; }
		make -C "$source_dir" install PREFIX="$prefix" >/dev/null
	fi

	"$prefix/bin/rascal" -e "print('installed rascal ' .. require('rascal.build').version .. ' at $prefix/bin/rascal')"
	case ":$PATH:" in
		*":$prefix/bin:"*) ;;
		*) echo "add $prefix/bin to your PATH to use it, eg. export PATH=\"$prefix/bin:\$PATH\"" ;;
	esac
}

main "$@"
