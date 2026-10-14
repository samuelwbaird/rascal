#!/bin/sh
# Confirm an executable only links dynamically against system libraries.
#
#   check-linkage.sh <executable> [deps|full]

set -eu

exe=$1 mode=${2:-deps}

fail() { echo "linkage: $*" >&2; exit 1; }

case "$(uname -s)" in
	Darwin)
		libs=$(otool -L "$exe" | tail -n +2 | awk '{print $1}')
		for lib in $libs; do
			case "$lib" in
				/usr/lib/libSystem.B.dylib|/usr/lib/libc++.1.dylib|/usr/lib/libc++abi.dylib) ;;
				*) fail "unexpected dynamic library $lib" ;;
			esac
		done
		echo "linkage ok: system libraries only ($(echo $libs | tr ' ' ','))"
		;;
	Linux)
		if [ "$mode" = full ]; then
			if readelf -l "$exe" 2>/dev/null | grep -q 'INTERP'; then
				fail "expected a fully static executable, but it has a dynamic loader"
			fi
			if readelf -d "$exe" 2>/dev/null | grep -q 'NEEDED'; then
				fail "expected a fully static executable, but it needs shared libraries"
			fi
			echo "linkage ok: fully static"
		else
			libs=$(readelf -d "$exe" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
			for lib in $libs; do
				case "$lib" in
					libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|ld-linux*|libc.musl*|ld-musl*) ;;
					*) fail "unexpected dynamic library $lib" ;;
				esac
			done
			echo "linkage ok: system libraries only ($(echo $libs | tr ' ' ','))"
		fi
		;;
	*)
		echo "linkage: no check for $(uname -s)"
		;;
esac
