#!/usr/bin/env bash
# Add Bluetooth LE support (for Zwift, Rouvy, etc.) to a GE-Proton install.
#
# Builds winebth.sys, bluetoothapis, windows.devices.bluetooth, windows.devices.radios
# and wintypes from the exact wine source that GE-Proton pins, with the BLE code from
# pocker/wine (branch zwift-radios, based on evanjt/wine) overlaid, then installs them
# into GE-Proton and patches its `proton` script so the driver can be enabled per game
# with PROTON_ENABLE_WINEBTH=1 (GE-Proton disables winebth.sys by default).
#
# Usage:
#   patch-ge-proton-ble.sh [options] <GE-Proton dir>
#
# Options:
#   --prefix DIR   Also update an existing wine prefix (repeatable). Proton copies builtin
#                  DLLs into the prefix as real files, so an existing prefix keeps the old
#                  ones until they are replaced. Also runs `wineboot -u` to register the
#                  new WinRT classes.
#   --workdir DIR  Where to fetch and build (default: ~/.cache/ge-proton-ble).
#   --ble-repo URL Source of the BLE code (default: https://github.com/pocker/wine.git).
#   --ble-ref REF  Branch or tag in --ble-repo (default: zwift-radios).
#   --restore      Put back the original GE-Proton files saved by a previous run.
#
# Then, for each game that needs Bluetooth, set PROTON_ENABLE_WINEBTH=1 in its
# environment and pin the runner to this exact GE-Proton version.
#
# Only verified with GE-Proton11-7. Requirements: git, curl, python3, autoconf, make,
# gcc, flex, bison, mingw-w64 (x86_64 + i686), dbus development headers, BlueZ.

set -euo pipefail
trap 'echo "error: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

WORKDIR="${HOME}/.cache/ge-proton-ble"
BLE_REPO="https://github.com/pocker/wine.git"
BLE_REF="zwift-radios"
PREFIXES=()
RESTORE=0
GE=""

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIXES+=("$(realpath "$2")"); shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --ble-repo) BLE_REPO="$2"; shift 2 ;;
        --ble-ref) BLE_REF="$2"; shift 2 ;;
        --restore) RESTORE=1; shift ;;
        -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) GE="$(realpath "$1")"; shift ;;
    esac
done

[ -n "$GE" ] || die "missing GE-Proton directory (see --help)"
[ -f "$GE/proton" ] && [ -f "$GE/version" ] && [ -d "$GE/files/lib/wine" ] || die "$GE does not look like a GE-Proton install"

LIBWINE="$GE/files/lib/wine"
BACKUP="$GE/ble-backup"

# module dir : installed file name
MODULES=(
    "winebth.sys:winebth.sys"
    "bluetoothapis:bluetoothapis.dll"
    "windows.devices.bluetooth:windows.devices.bluetooth.dll"
    "windows.devices.radios:windows.devices.radios.dll"
    "wintypes:wintypes.dll"
)
INSTALLED_FILES=("x86_64-unix/winebth.so")
for m in "${MODULES[@]}"; do
    INSTALLED_FILES+=("x86_64-windows/${m#*:}" "i386-windows/${m#*:}")
done

if [ "$RESTORE" = 1 ]; then
    [ -d "$BACKUP" ] || die "no backup found at $BACKUP"
    log "Restoring original files from $BACKUP"
    for f in "${INSTALLED_FILES[@]}"; do
        rm -f "$LIBWINE/$f"
        if [ -e "$BACKUP/$f.orig" ]; then cp -a "$BACKUP/$f.orig" "$LIBWINE/$f"; fi
    done
    if [ -e "$BACKUP/proton.orig" ]; then cp -a "$BACKUP/proton.orig" "$GE/proton"; fi
    rm -rf "$BACKUP"
    log "Done. Prefixes updated with --prefix still hold the patched copies; recreate or re-run wineboot."
    exit 0
fi

for t in git curl python3 autoreconf make gcc flex bison pkg-config x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
    command -v "$t" >/dev/null || die "missing build dependency: $t"
done
pkg-config --exists dbus-1 || die "missing dbus-1 development headers"

TAG="$(awk '{print $2}' "$GE/version")"
log "GE-Proton version: $TAG"
[ "$TAG" = "GE-Proton11-7" ] || echo "warning: only verified with GE-Proton11-7; continuing with $TAG" >&2

log "Looking up the wine commit pinned by $TAG"
WINE_SHA="$(curl -fsSL "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/contents/wine?ref=$TAG" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')" || die "could not find the wine submodule for $TAG"
log "wine commit: $WINE_SHA"

SRC="$WORKDIR/wine-$WINE_SHA"
BLE="$WORKDIR/ble-src"
mkdir -p "$WORKDIR"

if [ ! -d "$SRC/.git" ]; then
    log "Fetching ValveSoftware/wine @ $WINE_SHA"
    git init -q "$SRC"
    git -C "$SRC" fetch -q --depth 1 https://github.com/ValveSoftware/wine.git "$WINE_SHA"
    git -C "$SRC" checkout -q FETCH_HEAD
else
    log "Resetting $SRC"
    git -C "$SRC" reset -q --hard
    git -C "$SRC" clean -qfdx -e build
fi

log "Fetching BLE sources from $BLE_REPO ($BLE_REF)"
rm -rf "$BLE"
git clone -q --depth 1 --branch "$BLE_REF" "$BLE_REPO" "$BLE"

log "Overlaying BLE sources"
for d in winebth.sys bluetoothapis windows.devices.bluetooth windows.devices.radios wintypes; do
    rm -rf "$SRC/dlls/$d"
    cp -r "$BLE/dlls/$d" "$SRC/dlls/$d"
done
for f in bluetoothleapis.h bthledef.h wine/winebth.h ddk/bthguid.h windows.devices.bluetooth.idl \
         windows.devices.radios.idl windows.storage.streams.idl; do
    cp "$BLE/include/$f" "$SRC/include/$f"
done
if ! grep -q 'WINE_CONFIG_MAKEFILE(dlls/windows.devices.radios)' "$SRC/configure.ac"; then
    sed -i 's|^WINE_CONFIG_MAKEFILE(dlls/windows.devices.enumeration/tests)$|&\nWINE_CONFIG_MAKEFILE(dlls/windows.devices.radios)\nWINE_CONFIG_MAKEFILE(dlls/windows.devices.radios/tests)|' "$SRC/configure.ac"
    grep -q 'WINE_CONFIG_MAKEFILE(dlls/windows.devices.radios)' "$SRC/configure.ac" || die "could not register windows.devices.radios in configure.ac"
fi

# Valve's tree omits files that upstream commits or Proton's build generates.
log "Generating build files"
(cd "$SRC" && python3 dlls/winevulkan/make_vulkan && ./tools/make_specfiles && ./tools/make_requests && autoreconf -f) >/dev/null

log "Configuring"
mkdir -p "$SRC/build"
(cd "$SRC/build" && ../configure --enable-archs=i386,x86_64 --disable-tests --without-vulkan >configure.log 2>&1) \
    || die "configure failed, see $SRC/build/configure.log"
grep -q "checking for -ldbus-1... libdbus" "$SRC/build/configure.log" || die "configure did not find libdbus-1"

log "Building (a few minutes)"
TARGETS=()
for m in "${MODULES[@]}"; do TARGETS+=("dlls/${m%%:*}/all"); done
make -C "$SRC/build" -j"$(nproc)" "${TARGETS[@]}" >"$SRC/build/make.log" 2>&1 || die "build failed, see $SRC/build/make.log"

built_path() { # installed-relative path -> build output
    case "$1" in
        x86_64-unix/winebth.so) echo "$SRC/build/dlls/winebth.sys/winebth.so" ;;
        *) local arch="${1%%/*}" file="${1#*/}" m
           for m in "${MODULES[@]}"; do
               if [ "${m#*:}" = "$file" ]; then echo "$SRC/build/dlls/${m%%:*}/$arch/$file"; fi
           done ;;
    esac
}

log "Installing into $GE"
mkdir -p "$BACKUP/x86_64-windows" "$BACKUP/i386-windows" "$BACKUP/x86_64-unix"
for f in "${INSTALLED_FILES[@]}"; do
    src="$(built_path "$f")"
    [ -f "$src" ] || die "missing build output for $f"
    if [ -e "$LIBWINE/$f" ] && [ ! -e "$BACKUP/$f.orig" ]; then cp -a "$LIBWINE/$f" "$BACKUP/$f.orig"; fi
    rm -f "$LIBWINE/$f"
    cp "$src" "$LIBWINE/$f"
done

log "Patching $GE/proton"
if [ ! -e "$BACKUP/proton.orig" ]; then
    grep -q PROTON_ENABLE_WINEBTH "$GE/proton" \
        && echo "warning: proton script was already patched before; no clean backup of it" >&2 \
        || cp -a "$GE/proton" "$BACKUP/proton.orig"
fi
chmod u+w "$GE/proton"
python3 - "$GE/proton" <<'EOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
if "PROTON_ENABLE_WINEBTH" in text:
    print("    already patched")
    sys.exit(0)
m = re.search(r'^(\s*)"winebth\.sys": "d",.*\n(?:.*\n)*?\s*\}\n', text, re.M)
if not m:
    sys.exit("could not find the winebth.sys override in the proton script")
indent = " " * 8
patch = (f"\n{indent}# BLE-capable winebth.sys installed by patch-ge-proton-ble.sh; opt in per game.\n"
         f"{indent}if os.environ.get(\"PROTON_ENABLE_WINEBTH\") == \"1\":\n"
         f"{indent}    del self.dlloverrides[\"winebth.sys\"]\n")
text = text[:m.end()] + patch + text[m.end():]
open(path, "w").write(text)
print("    patched")
EOF

for pfx in "${PREFIXES[@]}"; do
    win="$pfx/drive_c/windows"
    [ -d "$win/system32" ] || { echo "warning: $pfx is not a wine prefix, skipping" >&2; continue; }
    log "Updating prefix $pfx"
    mkdir -p "$win/system32/drivers"
    rm -f "$win/system32/drivers/winebth.sys"
    cp "$(built_path x86_64-windows/winebth.sys)" "$win/system32/drivers/winebth.sys"
    for m in "${MODULES[@]}"; do
        file="${m#*:}"; [ "$file" = "winebth.sys" ] && continue
        rm -f "$win/system32/$file"; cp "$(built_path "x86_64-windows/$file")" "$win/system32/$file"
        if [ -d "$win/syswow64" ]; then
            rm -f "$win/syswow64/$file"; cp "$(built_path "i386-windows/$file")" "$win/syswow64/$file"
        fi
    done
    if command -v umu-run >/dev/null; then
        log "Registering WinRT classes (wineboot -u) in $pfx"
        WINEPREFIX="$pfx" PROTONPATH="$GE" GAMEID=umu-default STORE=none umu-run wineboot -u >/dev/null 2>&1 \
            || echo "warning: wineboot -u failed for $pfx; run it yourself with this GE-Proton" >&2
    else
        echo "warning: umu-run not found; run 'wineboot -u' in $pfx with this GE-Proton to register the new classes" >&2
    fi
done

cat <<EOF

Done. Bluetooth LE support is installed in $TAG.
For each game that needs it:
  - set the environment variable PROTON_ENABLE_WINEBTH=1
  - pin the runner to $(basename "$GE") (not "latest"), since updates replace these files
Originals are saved in $BACKUP; undo with: $0 --restore "$GE"
EOF
