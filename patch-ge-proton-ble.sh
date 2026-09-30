#!/usr/bin/env bash
# Add Bluetooth LE support (for Zwift, Rouvy, etc.) to a GE-Proton install.
#
# Rebuilds wine's Bluetooth modules (winebth.sys, bluetoothapis, windows.devices.bluetooth,
# windows.devices.radios, wintypes) and ntoskrnl.exe from the exact source of your GE-Proton
# release: proton-ge-custom at that tag, with GE's own wine patches applied. The BLE code
# comes from pocker/wine (branch zwift-radios, based on evanjt/wine), and ntoskrnl.exe gets
# a fix for a crash of winedevice.exe when a Bluetooth device goes away. The results are
# installed into GE-Proton, and its `proton` script is patched so the driver can be enabled
# per game with PROTON_ENABLE_WINEBTH=1 (GE-Proton disables winebth.sys by default).
#
# Usage:
#   patch-ge-proton-ble.sh [options] <GE-Proton dir>
#
# Options:
#   --prefix DIR   Also update an existing wine prefix (repeatable): link the new modules
#                  into it and run `wineboot -u` to register the new WinRT classes.
#   --workdir DIR  Where to fetch and build (default: ~/.cache/ge-proton-ble).
#   --ble-repo URL Source of the BLE code (default: https://github.com/pocker/wine.git).
#   --ble-ref REF  Branch or tag in --ble-repo (default: zwift-radios).
#   --restore      Put back the original GE-Proton files saved by a previous run.
#   --install-deps Install missing build tools with sudo (pacman or apt only).
#
# Then, for each game that needs Bluetooth, set PROTON_ENABLE_WINEBTH=1 in its
# environment and pin the runner to this exact GE-Proton version.
#
# Only verified with GE-Proton11-7. Requirements: git, python3, perl, autoconf, make, gcc,
# flex, bison, mingw-w64 (x86_64 + i686), dbus development headers, BlueZ.

set -euo pipefail
trap 'echo "error: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

WORKDIR="${HOME}/.cache/ge-proton-ble"
GE_REPO="https://github.com/GloriousEggroll/proton-ge-custom.git"
WINE_REPO="https://github.com/ValveSoftware/wine.git"
STAGING_REPO="https://github.com/wine-staging/wine-staging.git"
BLE_REPO="https://github.com/pocker/wine.git"
BLE_REF="zwift-radios"
PREFIXES=()
RESTORE=0
INSTALL_DEPS=0
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
        --install-deps) INSTALL_DEPS=1; shift ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
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
    "ntoskrnl.exe:ntoskrnl.exe"
)
INSTALLED_FILES=("x86_64-unix/winebth.so")
for m in "${MODULES[@]}"; do
    INSTALLED_FILES+=("x86_64-windows/${m#*:}" "i386-windows/${m#*:}")
done

if [ "$RESTORE" = 1 ]; then
    [ -d "$BACKUP" ] || die "no backup found at $BACKUP"
    log "Restoring original files from $BACKUP"
    for f in "${INSTALLED_FILES[@]}"; do
        if [ -e "$BACKUP/$f.orig" ]; then
            rm -f "$LIBWINE/$f"
            cp -a "$BACKUP/$f.orig" "$LIBWINE/$f"
        elif [ -e "$BACKUP/$f.absent" ] || [ "${f#*/}" = "windows.devices.radios.dll" ]; then
            # Not part of GE-Proton. Backups from older versions of this script have no marker.
            rm -f "$LIBWINE/$f"
        fi
    done
    if [ -e "$BACKUP/proton.orig" ]; then cp -a "$BACKUP/proton.orig" "$GE/proton"; fi
    rm -rf "$BACKUP"
    log "Done. Prefixes updated with --prefix now point at the original files again."
    exit 0
fi

REQUIRED_TOOLS=(git python3 perl autoreconf make gcc strip flex bison pkg-config
                x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc
                x86_64-w64-mingw32-strip i686-w64-mingw32-strip
                x86_64-w64-mingw32-objdump i686-w64-mingw32-objdump)
PACMAN_PKGS=(git python perl autoconf make gcc binutils flex bison pkgconf mingw-w64-gcc mingw-w64-binutils dbus)
APT_PKGS=(git python3 perl autoconf make gcc binutils flex bison pkg-config gcc-mingw-w64 binutils-mingw-w64 libdbus-1-dev)

missing_deps() {
    local t
    for t in "${REQUIRED_TOOLS[@]}"; do command -v "$t" >/dev/null || echo "$t"; done
    if command -v pkg-config >/dev/null && ! pkg-config --exists dbus-1; then echo "dbus-1-headers"; fi
    return 0
}

install_hint() {
    if command -v pacman >/dev/null; then echo "sudo pacman -S --needed ${PACMAN_PKGS[*]}"
    elif command -v apt-get >/dev/null; then echo "sudo apt-get update && sudo apt-get install ${APT_PKGS[*]}"
    fi
}

install_deps() {
    if command -v pacman >/dev/null; then sudo pacman -S --needed "${PACMAN_PKGS[@]}"
    elif command -v apt-get >/dev/null; then sudo apt-get update && sudo apt-get install "${APT_PKGS[@]}"
    else die "--install-deps only knows pacman (Arch-based) and apt (Debian-based); install the missing tools yourself"
    fi
}

MISSING="$(missing_deps | tr '\n' ' ')"
if [ -n "$MISSING" ]; then
    if [ "$INSTALL_DEPS" = 1 ]; then
        log "Installing missing build dependencies: $MISSING"
        install_deps
        MISSING="$(missing_deps | tr '\n' ' ')"
        [ -z "$MISSING" ] || die "still missing after install: $MISSING"
    else
        echo "error: missing build dependencies: $MISSING" >&2
        HINT="$(install_hint)"
        if [ -n "$HINT" ]; then
            echo "install them with:  $HINT" >&2
            echo "or re-run this script with --install-deps" >&2
        fi
        exit 1
    fi
fi

TAG="$(awk '{print $2}' "$GE/version")"
log "GE-Proton version: $TAG"
[ "$TAG" = "GE-Proton11-7" ] || echo "warning: only verified with GE-Proton11-7; continuing with $TAG" >&2

GESRC="$WORKDIR/proton-ge-custom-$TAG"
SRC="$GESRC/wine"
BUILD="$WORKDIR/build-$TAG"
BLE="$WORKDIR/ble-src"
mkdir -p "$WORKDIR"

# GE-Proton builds wine from ValveSoftware/wine plus the patches in its own repo, so start
# from the same place. Anything built from plain Valve wine would drop GE's changes.
if [ ! -d "$GESRC/.git" ]; then
    log "Fetching proton-ge-custom @ $TAG"
    git init -q "$GESRC"
    git -C "$GESRC" fetch -q --depth 1 "$GE_REPO" "refs/tags/$TAG"
    git -C "$GESRC" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
WINE_SHA="$(git -C "$GESRC" ls-tree HEAD wine | awk '{print $3}')"
STAGING_SHA="$(git -C "$GESRC" ls-tree HEAD wine-staging | awk '{print $3}')"
[ -n "$WINE_SHA" ] && [ -n "$STAGING_SHA" ] || die "could not find the wine submodules of $TAG"
log "wine commit: $WINE_SHA, wine-staging commit: $STAGING_SHA"

fetch_commit() { # dir url sha
    if [ "$(git -C "$1" rev-parse -q --verify HEAD 2>/dev/null)" != "$3" ]; then
        rm -rf "$1"
        git init -q "$1"
        git -C "$1" fetch -q --depth 1 "$2" "$3"
        git -C "$1" checkout -q FETCH_HEAD
    fi
}
log "Fetching wine and wine-staging sources"
fetch_commit "$SRC" "$WINE_REPO" "$WINE_SHA"
fetch_commit "$GESRC/wine-staging" "$STAGING_REPO" "$STAGING_SHA"

PREP="$GESRC/patches/protonprep-valve-staging.sh"
[ -f "$PREP" ] || die "$TAG has no patches/protonprep-valve-staging.sh"
# GE reverts some upstream commits; a shallow clone needs them and their parents.
for c in $(grep -o -E 'git revert --no-commit [0-9a-f]{40}' "$PREP" | awk '{print $4}'); do
    git -C "$SRC" cat-file -e "$c^" 2>/dev/null || git -C "$SRC" fetch -q --depth 2 "$WINE_REPO" "$c"
done

# Run GE's wine patching exactly as its build does: the helper functions at the top and the
# "WINE PATCHING" section (which starts by resetting the tree). Build files are generated
# below instead of by its autoreconf/make_requests lines.
log "Applying GE-Proton's wine patches"
FUNCS_END="$(grep -n '^### (1) PREP SECTION ###' "$PREP" | cut -d: -f1)"
WINE_START="$(grep -n '^### (2) WINE PATCHING ###' "$PREP" | cut -d: -f1)"
[ -n "$FUNCS_END" ] && [ -n "$WINE_START" ] || die "unexpected layout of $PREP"
{
    head -n "$((FUNCS_END - 1))" "$PREP"
    tail -n "+$WINE_START" "$PREP" | grep -v -E '^[[:space:]]*(autoreconf -f|\./tools/make_requests)[[:space:]]*$'
} >"$WORKDIR/prep-wine-$TAG.sh"
(cd "$GESRC" && bash "$WORKDIR/prep-wine-$TAG.sh") >"$WORKDIR/prep-$TAG.log" 2>&1 || true
if grep -q -E "FAILED|can't find file to patch|malformed patch|Reversed \(or previously applied\)|^fatal:|^error:" "$WORKDIR/prep-$TAG.log"; then
    die "some of GE-Proton's patches did not apply, see $WORKDIR/prep-$TAG.log"
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

# pocker/wine commit 7e426d5. When a Bluetooth device disconnects, winebth invalidates its
# relations once per GATT service that BlueZ drops, and then the device itself is removed.
# Without this, a leftover queued update runs on the deleted device and winedevice.exe
# crashes, taking the Bluetooth radio with it until the whole wine session is restarted.
log "Applying the ntoskrnl.exe device removal fix"
patch -d "$SRC" -p1 --forward --no-backup-if-mismatch -s <<'EOF' || die "the ntoskrnl.exe fix does not apply to $TAG"
--- a/dlls/ntoskrnl.exe/pnp.c
+++ b/dlls/ntoskrnl.exe/pnp.c
@@ -448,6 +448,24 @@ static void enumerate_new_device( DEVICE_OBJECT *device, HDEVINFO set, DEVICE_OB
     start_device( device, set, &sp_device );
 }

+/* Drop pending bus relation updates for a device that is going away. The queue holds bare
+ * pointers, so an update left behind would be handled after the driver deleted the device. */
+static void forget_invalidated_device( DEVICE_OBJECT *device )
+{
+    size_t i, j;
+
+    EnterCriticalSection( &invalidated_devices_cs );
+    for (i = j = 0; i < invalidated_devices_count; ++i)
+    {
+        if (invalidated_devices[i] != device)
+            invalidated_devices[j++] = invalidated_devices[i];
+    }
+    if (j != invalidated_devices_count)
+        TRACE( "Dropping %Iu pending relation updates for device %p.\n", invalidated_devices_count - j, device );
+    invalidated_devices_count = j;
+    LeaveCriticalSection( &invalidated_devices_cs );
+}
+
 static void send_remove_device_irp( DEVICE_OBJECT *device, UCHAR code )
 {
     struct wine_device *wine_device = CONTAINING_RECORD(device, struct wine_device, device_obj);
@@ -462,6 +480,11 @@ static void send_remove_device_irp( DEVICE_OBJECT *device, UCHAR code )
     }

     send_pnp_irp( device, code );
+
+    /* The driver may have deleted the device, and may have queued updates for it while removing it.
+     * Only the pointer value is compared from here on. */
+    if (code == IRP_MN_REMOVE_DEVICE)
+        forget_invalidated_device( device );
 }

 static void remove_device( DEVICE_OBJECT *device )
EOF

# Valve's tree omits files that upstream commits or Proton's build generates.
log "Generating build files"
(cd "$SRC" && python3 dlls/winevulkan/make_vulkan && ./tools/make_specfiles && ./tools/make_requests && autoreconf -f) \
    >"$WORKDIR/generate-$TAG.log" 2>&1 || die "generating build files failed, see $WORKDIR/generate-$TAG.log"

log "Configuring"
mkdir -p "$BUILD"
(cd "$BUILD" && "$SRC/configure" --enable-archs=i386,x86_64 --disable-tests --without-vulkan >configure.log 2>&1) \
    || die "configure failed, see $BUILD/configure.log"
grep -q "checking for -ldbus-1... libdbus" "$BUILD/configure.log" || die "configure did not find libdbus-1"

log "Building (a few minutes)"
TARGETS=()
for m in "${MODULES[@]}"; do TARGETS+=("dlls/${m%%:*}/all"); done
make -C "$BUILD" -j"$(nproc)" "${TARGETS[@]}" >"$BUILD/make.log" 2>&1 || die "build failed, see $BUILD/make.log"

built_path() { # installed-relative path -> build output
    case "$1" in
        x86_64-unix/winebth.so) echo "$BUILD/dlls/winebth.sys/winebth.so" ;;
        *) local arch="${1%%/*}" file="${1#*/}" m
           for m in "${MODULES[@]}"; do
               if [ "${m#*:}" = "$file" ]; then echo "$BUILD/dlls/${m%%:*}/$arch/$file"; fi
           done ;;
    esac
}

tool_for() { # installed-relative path, tool name -> tool for that architecture
    case "$1" in
        x86_64-windows/*) echo "x86_64-w64-mingw32-$2" ;;
        i386-windows/*) echo "i686-w64-mingw32-$2" ;;
        *) echo "$2" ;;
    esac
}

exports() { # objdump, PE file -> sorted export names
    "$1" -p "$2" | awk '/^\[Ordinal\/Name Pointer\] Table/ { f = 1; next }
                        f && /^[[:space:]]*\[/ { print $NF; next }
                        f && /^[[:space:]]*$/ { exit }' | sort
}

# ntoskrnl.exe is the one module GE-Proton patches itself. If the rebuilt one lacks any export
# of the shipped one, the source didn't match this release, and installing it would break
# other games; stop before touching anything.
for f in x86_64-windows/ntoskrnl.exe i386-windows/ntoskrnl.exe; do
    shipped="$LIBWINE/$f"; [ -e "$BACKUP/$f.orig" ] && shipped="$BACKUP/$f.orig"
    missing="$(comm -23 <(exports "$(tool_for "$f" objdump)" "$shipped") <(exports "$(tool_for "$f" objdump)" "$(built_path "$f")"))"
    [ -z "$missing" ] || die "rebuilt $f lacks exports of the shipped one: $(echo $missing | head -c 200)"
done

log "Installing into $GE"
[ -d "$BACKUP" ] && FIRST_RUN=0 || FIRST_RUN=1
mkdir -p "$BACKUP/x86_64-windows" "$BACKUP/i386-windows" "$BACKUP/x86_64-unix"
for f in "${INSTALLED_FILES[@]}"; do
    src="$(built_path "$f")"
    [ -f "$src" ] || die "missing build output for $f"
    # Save what GE-Proton shipped, once. A file it didn't ship gets an .absent marker instead,
    # so that a later run doesn't mistake our own build for the original. Older versions of
    # this script installed windows.devices.radios.dll without leaving a marker.
    if [ ! -e "$BACKUP/$f.orig" ] && [ ! -e "$BACKUP/$f.absent" ]; then
        if [ "${f#*/}" = "windows.devices.radios.dll" ] && [ "$FIRST_RUN" = 0 ]; then touch "$BACKUP/$f.absent"
        elif [ -e "$LIBWINE/$f" ]; then cp -a "$LIBWINE/$f" "$BACKUP/$f.orig"
        else touch "$BACKUP/$f.absent"
        fi
    fi
    # Write next to the target and rename, so running wine processes keep the old file.
    "$(tool_for "$f" strip)" --strip-debug -o "$LIBWINE/$f.new" "$src"
    chmod 755 "$LIBWINE/$f.new"
    mv -f "$LIBWINE/$f.new" "$LIBWINE/$f"
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
    # Link like Proton does for its own builtins, so a later run of this script updates the
    # prefix too. Older versions of this script copied the files instead.
    for f in "${INSTALLED_FILES[@]}"; do
        case "$f" in
            x86_64-windows/winebth.sys) dir="$win/system32/drivers" ;;
            x86_64-windows/*) dir="$win/system32" ;;
            i386-windows/winebth.sys) continue ;;
            i386-windows/*) dir="$win/syswow64" ;;
            *) continue ;;
        esac
        [ -d "$dir" ] || continue
        rm -f "$dir/${f#*/}"
        ln -s "$LIBWINE/$f" "$dir/${f#*/}"
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
