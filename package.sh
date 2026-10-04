#!/usr/bin/env bash
# Builds the Linux packages: build/dist/gitgud-desktop_<version>_<arch>.deb
# and gitgud-desktop-<version>-1.<arch>.rpm. The Unix counterpart of
# package.ps1.
#
#   1. Builds the release preset (setup.sh), unless --skip-build.
#   2. Downloads the GitHub CLI release named by GH_VERSION, checks it
#      against the release's published SHA-256, and bundles gh with the app
#      (browser sign-in to GitHub uses it).
#   3. Runs CPack: a .deb always, an .rpm when rpmbuild is installed.
#
# Usage: ./package.sh [--skip-build]
# Needs what setup.sh needs, plus curl or wget, and rpmbuild for the .rpm.
# Build on the oldest distribution you want to support: the packages need
# at least the glibc they were built against.

set -euo pipefail

GH_VERSION="${GH_VERSION:-2.102.0}"

skip_build=0
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) skip_build=1; shift ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

root="$(cd "$(dirname "$0")" && pwd)"
build="$root/build/release"
dist="$root/build/dist"

step() { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

fetch() {
    if command -v curl >/dev/null; then
        curl -fsSL --proto '=https' -o "$2" "$1"
    elif command -v wget >/dev/null; then
        wget -q -O "$2" "$1"
    else
        echo "curl or wget is needed to download the GitHub CLI." >&2
        exit 1
    fi
}

case "$(uname -m)" in
    x86_64) gh_arch=amd64 ;;
    aarch64) gh_arch=arm64 ;;
    *) echo "no GitHub CLI build for $(uname -m)" >&2; exit 1 ;;
esac

# ------------------------------------------------------------------ 1. Build --
if [ $skip_build -eq 0 ]; then
    "$root/setup.sh" --preset release
fi

# ------------------------------------------------------------ 2. GitHub CLI --
step "GitHub CLI $GH_VERSION"
gh_dir="$root/build/gh-bundle"
gh_name="gh_${GH_VERSION}_linux_${gh_arch}"
if [ ! -x "$gh_dir/out/gh" ] || [ "$(cat "$gh_dir/out/version" 2>/dev/null)" != "$gh_name" ]; then
    rm -rf "$gh_dir"
    mkdir -p "$gh_dir/out"
    base="https://github.com/cli/cli/releases/download/v$GH_VERSION"
    fetch "$base/$gh_name.tar.gz" "$gh_dir/$gh_name.tar.gz"
    fetch "$base/gh_${GH_VERSION}_checksums.txt" "$gh_dir/checksums.txt"
    expected=$(awk -v f="$gh_name.tar.gz" '$2 == f {print $1}' "$gh_dir/checksums.txt")
    actual=$(sha256sum "$gh_dir/$gh_name.tar.gz" | awk '{print $1}')
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        echo "$gh_name.tar.gz doesn't match its published checksum." >&2
        exit 1
    fi
    tar -xzf "$gh_dir/$gh_name.tar.gz" -C "$gh_dir"
    cp "$gh_dir/$gh_name/bin/gh" "$gh_dir/$gh_name/LICENSE" "$gh_dir/out/"
    echo "$gh_name" > "$gh_dir/out/version"
    note "downloaded and verified"
else
    note "already downloaded"
fi

# -------------------------------------------------------------- 3. Packages --
step "Packages"
cmake -S "$root" -B "$build" -DGITGUD_GH_DIR="$gh_dir/out" > /dev/null
cmake --build "$build"
generators="DEB"
if command -v rpmbuild >/dev/null; then
    generators="DEB;RPM"
else
    note "rpmbuild isn't installed: skipping the .rpm"
fi
mkdir -p "$dist"
(cd "$build" && cpack -G "$generators" -B "$dist" > "$dist/cpack.log")
rm -rf "$dist/_CPack_Packages"
ls -1 "$dist"/*.deb "$dist"/*.rpm 2>/dev/null | sed 's/^/    /'
