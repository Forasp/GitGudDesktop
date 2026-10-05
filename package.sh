#!/usr/bin/env bash
# Builds the Linux packages, build/dist/gitgud-desktop_<version>_<arch>.deb
# and gitgud-desktop-<version>-1.<arch>.rpm, or on macOS the disk image
# build/dist/GitGud-macOS-arm64.dmg. The Unix counterpart of package.ps1.
#
#   1. Builds the release preset (setup.sh), unless --skip-build.
#   2. Downloads the GitHub CLI release named by GH_VERSION, checks it
#      against the release's published SHA-256, and bundles gh with the app
#      (browser sign-in to GitHub uses it).
#   3. Linux: runs CPack, a .deb always and an .rpm when rpmbuild is
#      installed. macOS: copies the built bundle to "GitGud Desktop.app",
#      adds gh, checks that it needs nothing but itself and the system,
#      signs it ad hoc, and makes the .dmg.
#
# Usage: ./package.sh [--skip-build]
# Needs what setup.sh needs, plus curl or wget, and rpmbuild for the .rpm.
# Build Linux packages on the oldest distribution you want to support: they
# need at least the glibc they were built against.

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

# SHA-256 of a file (macOS has shasum but no sha256sum).
sha256() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

case "$(uname -m)" in
    x86_64) gh_arch=amd64 ;;
    aarch64|arm64) gh_arch=arm64 ;;
    *) echo "no GitHub CLI build for $(uname -m)" >&2; exit 1 ;;
esac
if [ "$(uname -s)" = Darwin ]; then
    gh_name="gh_${GH_VERSION}_macOS_${gh_arch}"
    gh_archive="$gh_name.zip"
else
    gh_name="gh_${GH_VERSION}_linux_${gh_arch}"
    gh_archive="$gh_name.tar.gz"
fi

# ------------------------------------------------------------------ 1. Build --
if [ $skip_build -eq 0 ]; then
    "$root/setup.sh" --preset release
fi

# ------------------------------------------------------------ 2. GitHub CLI --
step "GitHub CLI $GH_VERSION"
gh_dir="$root/build/gh-bundle"
if [ ! -x "$gh_dir/out/gh" ] || [ "$(cat "$gh_dir/out/version" 2>/dev/null)" != "$gh_name" ]; then
    rm -rf "$gh_dir"
    mkdir -p "$gh_dir/out"
    base="https://github.com/cli/cli/releases/download/v$GH_VERSION"
    fetch "$base/$gh_archive" "$gh_dir/$gh_archive"
    fetch "$base/gh_${GH_VERSION}_checksums.txt" "$gh_dir/checksums.txt"
    expected=$(awk -v f="$gh_archive" '$2 == f {print $1}' "$gh_dir/checksums.txt")
    actual=$(sha256 "$gh_dir/$gh_archive")
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        echo "$gh_archive doesn't match its published checksum." >&2
        exit 1
    fi
    case "$gh_archive" in
        *.zip) (cd "$gh_dir" && unzip -q "$gh_archive") ;;
        *) tar -xzf "$gh_dir/$gh_archive" -C "$gh_dir" ;;
    esac
    cp "$gh_dir/$gh_name/bin/gh" "$gh_dir/$gh_name/LICENSE" "$gh_dir/out/"
    echo "$gh_name" > "$gh_dir/out/version"
    note "downloaded and verified"
else
    note "already downloaded"
fi

# ------------------------------------------------------- 3. macOS disk image --
if [ "$(uname -s)" = Darwin ]; then
    step "Disk image"
    stage="$build/dmg"
    app="$stage/GitGud Desktop.app"
    rm -rf "$stage"
    mkdir -p "$stage" "$dist"
    ditto "$build/bin/gitgud.app" "$app"
    mkdir -p "$app/Contents/Resources/gh"
    cp "$gh_dir/out/gh" "$gh_dir/out/LICENSE" "$app/Contents/Resources/gh/"
    cp "$root/LICENSE" "$root/THIRD_PARTY_NOTICES.txt" "$app/Contents/Resources/"

    # Every binary may use only the system's libraries and the bundle's own
    # (nothing from Homebrew or another build), with no absolute RPATH.
    status=0
    while IFS= read -r -d '' file; do
        file -b "$file" | grep -q Mach-O || continue
        bad=$(otool -L "$file" | tail -n +2 | awk '{print $1}' |
            grep -v -E '^(/System/|/usr/lib/|@rpath/|@executable_path/|@loader_path/)' || true)
        rpaths=$(otool -l "$file" | awk '$1 == "path" {print $2}' | grep '^/' || true)
        if [ -n "$bad$rpaths" ]; then
            echo "${file#"$stage/"} uses $bad $rpaths" >&2
            status=1
        fi
    done < <(find "$app" -type f -print0)
    if [ $status -ne 0 ]; then
        echo "The app needs libraries from outside the system and the bundle." >&2
        exit 1
    fi
    note "uses only the system and itself"

    # Ad hoc signatures (no Developer ID yet): the libraries, then the app.
    # gh keeps GitHub's own signature.
    for lib in "$app/Contents/Frameworks/"*.dylib; do
        codesign --force --sign - "$lib"
    done
    codesign --force --sign - "$app"
    codesign --verify --strict "$app"
    note "signed ad hoc"

    ln -s /Applications "$stage/Applications"
    rm -f "$dist/GitGud-macOS-arm64.dmg"
    hdiutil create -quiet -volname "GitGud Desktop" -srcfolder "$stage" -format UDZO \
        "$dist/GitGud-macOS-arm64.dmg"
    note "build/dist/GitGud-macOS-arm64.dmg"
    exit 0
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
