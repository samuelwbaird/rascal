#!/bin/sh
# Download, verify and unpack one dependency.
#
#   fetch.sh <name> <url> <sha256> <download-dir> <dest-dir> [prune-paths...]
#
# Archives are cached in <download-dir> and always checked against the pinned
# sha256 before use. The archive's single top level directory is unpacked as
# <dest-dir>, any patches/<name>/*.patch are applied in order, and listed
# prune paths are deleted. A stamp file marks the directory as complete.

set -eu

name=$1 url=$2 sha256=$3 downloads=$4 dest=$5
shift 5

root=$(cd "$(dirname "$0")/.." && pwd)

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

download() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 -o "$2" "$1"
	else
		wget -q -O "$2" "$1"
	fi
}

case "$url" in
	*.tar.gz|*.tgz) ;;
	*) echo "fetch: $name: only .tar.gz archives are supported ($url)" >&2; exit 1 ;;
esac

mkdir -p "$downloads"
archive="$downloads/$name-$(echo "$sha256" | cut -c1-16).tar.gz"

if [ ! -f "$archive" ]; then
	echo "  FETCH $name  $url"
	download "$url" "$archive.part"
	actual=$(sha256_of "$archive.part")
	if [ "$actual" != "$sha256" ]; then
		rm -f "$archive.part"
		if [ -z "$sha256" ]; then
			echo "fetch: $name: no sha256 pinned, the downloaded archive has" >&2
			echo "  $actual" >&2
		else
			echo "fetch: $name: sha256 mismatch" >&2
			echo "  expected $sha256" >&2
			echo "  actual   $actual" >&2
		fi
		exit 1
	fi
	mv "$archive.part" "$archive"
else
	actual=$(sha256_of "$archive")
	if [ "$actual" != "$sha256" ]; then
		echo "fetch: $name: cached archive $archive does not match the pinned sha256, delete it to re-download" >&2
		exit 1
	fi
fi

echo "  UNPACK $name"
rm -rf "$dest" "$dest.tmp"
mkdir -p "$dest.tmp"
gzip -dc "$archive" | (cd "$dest.tmp" && tar -xf -)
top=$(ls -A "$dest.tmp")
if [ "$(echo "$top" | wc -l | tr -d ' ')" != 1 ] || [ ! -d "$dest.tmp/$top" ]; then
	echo "fetch: $name: expected a single top level directory in the archive" >&2
	exit 1
fi
mv "$dest.tmp/$top" "$dest"
rmdir "$dest.tmp"

for patch in "$root/patches/$name"/*.patch; do
	[ -f "$patch" ] || continue
	echo "  PATCH $name  $(basename "$patch")"
	patch -s -p1 -d "$dest" < "$patch"
done

for path in "$@"; do
	rm -rf "${dest:?}/$path"
done

touch "$dest/.rascal-fetched"
