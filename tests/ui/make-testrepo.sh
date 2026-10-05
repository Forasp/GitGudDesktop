#!/usr/bin/env bash
# Builds a throwaway repository for tests/ui/walkthrough.lua (and for poking
# at the UI by hand): history, two branches, a tag, a bare "remote", an image,
# and a mix of working-tree changes. The Unix twin of make-testrepo.ps1.
#
#   tests/ui/make-testrepo.sh /tmp/gg-test
#
# The folder (and <dir>-remote.git) are deleted and recreated. Needs git and
# python3 (for the PNGs).

set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <dir>" >&2; exit 2; }
dir="$1"
remote="$dir-remote.git"
rm -rf "$dir" "$remote"
mkdir -p "$dir"
cd "$dir"
dir="$(pwd)"
remote="$dir-remote.git"

g() { git "$@" > /dev/null 2>&1 || { echo "git $* failed" >&2; exit 1; }; }

# A 96x64 PNG: dark background, a filled circle in r g b, and optionally a
# yellow square.
png() {
    python3 - "$@" <<'EOF'
import struct, sys, zlib
path, r, g, b, dot = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5] == "1"
w, h = 96, 64
rows = []
for y in range(h):
    row = bytearray([0])
    for x in range(w):
        px = (30, 20, 60, 255)
        if (x + 0.5 - 40) ** 2 + (y + 0.5 - 32) ** 2 <= 24 ** 2:
            px = (r, g, b, 255)
        if dot and 70 <= x < 84 and 20 <= y < 34:
            px = (255, 255, 0, 255)
        row += bytes(px)
    rows.append(bytes(row))
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
with open(path, "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n")
    f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
    f.write(chunk(b"IDAT", zlib.compress(b"".join(rows))))
    f.write(chunk(b"IEND", b""))
EOF
}

main_lines() {
    for i in $(seq 1 40); do
        case "$i" in
            2) [ "${1:-}" = changed ] && { echo "int line2 = 200;  // changed"; continue; } ;;
            35) [ "${1:-}" = changed ] && { echo "int line35 = 3500;  // changed"; continue; } ;;
        esac
        echo "int line$i = $i;"
    done
}

g init -b main
g config user.name "Test User"
g config user.email "test@example.com"
g config core.autocrlf false

mkdir -p src assets
printf '# Test project\n\nA scratch repository for GitGud testing.\n' > README.md
main_lines > src/main.cpp
printf 'old file\n' > obsolete.txt
png assets/logo.png 126 242 214 0
g add -A
g commit -m "Initial commit"

for i in 1 2 3 4 5 6; do
    printf 'change %s\n' "$i" >> README.md
    g commit -am "Update README ($i)" -m "Some body text for commit $i."
done
g tag v1.0

g checkout -b feature/login
printf 'login code\n' > src/login.cpp
g add -A
g commit -m "Add login module"
g checkout main
g checkout -b feature/theme
printf 'theme\n' > src/theme.cpp
g add -A
g commit -m "Add theme support"
g checkout main

g init --bare "$remote"
g remote add origin "$remote"
g push -u origin main
g push origin feature/login

# Working-tree changes: two hunks in main.cpp, a new file, an image edit, a deletion.
main_lines changed > src/main.cpp
printf 'brand new notes\nsecond line\n' > notes.txt
png assets/logo.png 255 94 196 1
rm obsolete.txt

echo "test repository ready: $dir"
