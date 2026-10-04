#!/usr/bin/env bash
# Sets up the GitGud Desktop build on Linux (and macOS): fetches and patches
# CEGUI, builds it, then builds the app. The Unix twin of setup.ps1.
#
# Safe to run again at any time: every step checks what's already done.
#
#   1. Checks out the third_party/cegui submodule if it isn't yet.
#   2. Applies every patch in third_party/patches/cegui (in name order),
#      skipping the ones already applied.
#   3. Builds and installs CEGUI (Release; it serves every app preset here).
#      A stamp file remembers the submodule commit and the patches it was
#      built from, so CEGUI is only rebuilt when one of those changes (or
#      with --force).
#   4. Configures and builds the app with the chosen CMake preset, and
#      optionally runs the engine tests.
#
# Needs VCPKG_ROOT, a C++17 compiler, CMake, Ninja, and the dev packages
# SDL2 builds against (see docs/BUILDING.md).
#
# Usage: ./setup.sh [--preset release|full|nogui] [--skip-app] [--test] [--force]

set -euo pipefail

preset=release
skip_app=0
run_tests=0
force=0
while [ $# -gt 0 ]; do
    case "$1" in
        --preset) preset="$2"; shift 2 ;;
        --skip-app) skip_app=1; shift ;;
        --test) run_tests=1; shift ;;
        --force) force=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$preset" in
    release|full|nogui) ;;
    *) echo "unknown preset: $preset (release, full, or nogui)" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "$0")" && pwd)"
cegui_source="$root/third_party/cegui"
patch_dir="$root/third_party/patches/cegui"
started=$(date +%s)

step() { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

if [ -z "${VCPKG_ROOT:-}" ] || [ ! -f "$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" ]; then
    echo "Set VCPKG_ROOT to a vcpkg checkout (git clone https://github.com/microsoft/vcpkg && vcpkg/bootstrap-vcpkg.sh)." >&2
    exit 1
fi
for tool in cmake ninja git; do
    command -v "$tool" >/dev/null || { echo "'$tool' isn't installed." >&2; exit 1; }
done

# ------------------------------------------------------ 1. CEGUI submodule --
init_cegui() {
    step "CEGUI source (third_party/cegui)"
    if [ ! -d "$cegui_source/cegui/src" ]; then
        git -C "$root" submodule update --init third_party/cegui
        return
    fi
    local expected actual
    expected=$(git -C "$root" ls-tree HEAD third_party/cegui | awk '{print $3}')
    actual=$(git -C "$cegui_source" rev-parse HEAD)
    if [ "$expected" != "$actual" ]; then
        if [ -n "$(git -C "$cegui_source" status --porcelain --untracked-files=no)" ]; then
            echo "third_party/cegui is at ${actual:0:9} but this repository expects ${expected:0:9}, and it has local edits. Revert them (git -C third_party/cegui checkout -- .) and rerun." >&2
            exit 1
        fi
        git -C "$root" submodule update --init third_party/cegui
    fi
    note "checked out"
}

# ---------------------------------------------------------------- 2. Patches --
apply_patches() {
    step "CEGUI patches (third_party/patches/cegui)"
    local patch name
    for patch in "$patch_dir"/*.patch; do
        name=$(basename "$patch")
        if git -C "$cegui_source" apply --check --reverse --ignore-whitespace "$patch" 2>/dev/null; then
            note "$name: already applied"
            continue
        fi
        if ! git -C "$cegui_source" apply --check --ignore-whitespace "$patch" 2>/dev/null; then
            echo "$name doesn't apply to third_party/cegui (it has other local edits?). Revert them with 'git -C third_party/cegui checkout -- .' and rerun." >&2
            exit 1
        fi
        git -C "$cegui_source" apply --ignore-whitespace "$patch"
        note "$name: applied"
    done
}

# What a CEGUI install was built from: the submodule commit plus a hash of
# every patch. When it matches the install's stamp, nothing needs rebuilding.
cegui_fingerprint() {
    git -C "$cegui_source" rev-parse HEAD
    local patch
    for patch in "$patch_dir"/*.patch; do
        printf '%s %s\n' "$(basename "$patch")" "$(sha256sum "$patch" | awk '{print $1}')"
    done
}

# ------------------------------------------------------------ 3. Build CEGUI --
build_cegui() {
    local build_dir="$root/build/cegui-rel"
    local install_dir="$root/third_party/cegui-install-release"
    local stamp="$install_dir/.gitgud-stamp"
    local fingerprint
    fingerprint=$(cegui_fingerprint)

    step "CEGUI Release -> third_party/cegui-install-release"
    if [ $force -eq 0 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$fingerprint" ]; then
        note "up to date"
        return
    fi
    cmake -S "$cegui_source" -B "$build_dir" -G Ninja \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
        -DVCPKG_MANIFEST_DIR="$root/third_party/cegui-manifest" \
        -DCEGUI_BUILD_RENDERER_OPENGL3=ON -DCEGUI_BUILD_RENDERER_OPENGL=OFF \
        -DCEGUI_BUILD_RENDERER_OPENGLES=OFF -DCEGUI_BUILD_RENDERER_OPENGLES2_ALTERNATE=OFF \
        -DCEGUI_BUILD_RENDERER_OGRE=OFF -DCEGUI_BUILD_RENDERER_IRRLICHT=OFF \
        -DCEGUI_BUILD_XMLPARSER_PUGIXML=ON -DCEGUI_BUILD_XMLPARSER_EXPAT=OFF \
        -DCEGUI_BUILD_IMAGECODEC_STB=ON -DCEGUI_BUILD_IMAGECODEC_SILLY=OFF \
        -DCEGUI_USE_FREETYPE=ON -DCEGUI_BUILD_SAMPLES=OFF \
        -DCEGUI_BUILD_APPLICATION_TEMPLATES=OFF -DCEGUI_BUILD_LUA_MODULE=OFF \
        -DCEGUI_BUILD_PYTHON_MODULES_SWIG=OFF -DCEGUI_BUILD_PYTHON_MODULES_PYPLUSPLUS=OFF \
        -DCEGUI_STRING_CLASS=UTF-32
    cmake --build "$build_dir"
    cmake --install "$build_dir"
    printf '%s\n' "$fingerprint" > "$stamp"
}

# -------------------------------------------------------------------- 4. App --
build_app() {
    step "GitGud ($preset preset)"
    cmake --preset "$preset"
    cmake --build --preset "$preset"
    note "built: build/$preset/bin"
    if [ $run_tests -eq 1 ]; then
        step "Engine tests"
        "$root/build/$preset/bin/gitgud_tests"
    fi
}

cd "$root"
if [ "$preset" != "nogui" ]; then
    init_cegui
    apply_patches
    build_cegui
fi
if [ $skip_app -eq 0 ]; then
    build_app
fi
printf '\nDone in %s min.\n' "$(( ($(date +%s) - started + 30) / 60 ))"
