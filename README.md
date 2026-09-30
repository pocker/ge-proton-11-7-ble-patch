# GE-Proton Bluetooth LE patch

Adds Bluetooth Low Energy support to [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom), so Windows apps that use the Windows Bluetooth APIs can talk to trainers and sensors through the Linux Bluetooth stack (BlueZ). It was made for Zwift's direct Bluetooth pairing, with no Zwift Companion or ANT+ dongle needed.

## Why this is needed

Stock Wine and Proton can't do this, for two reasons:

- **Missing Windows Bluetooth pieces.** Stock Wine lacks the parts these apps need: finding Bluetooth radios, GATT services and connections, and a few helpers such as `BluetoothUuidHelper` and `DataReader`/`DataWriter`. Zwift reports "Bluetooth Radio NOT Found" and fails its `HasBLE()` check.
- **GE-Proton turns the driver off.** It ships `winebth.sys`, the Bluetooth driver, but disables it: `"winebth.sys": "d"` in its `proton` script. A normal setting can't turn it back on, because Proton adds its own override after yours.

The script fixes both. It also fixes a Wine crash that the Bluetooth driver triggers (see [Known issues](#known-issues)).

## What the script does

1. Reads your GE-Proton version and downloads the exact source that version was built from: [proton-ge-custom](https://github.com/GloriousEggroll/proton-ge-custom) at that tag, plus the `ValveSoftware/wine` and `wine-staging` commits it pins.
2. Applies GE-Proton's own wine patches, using GE's `protonprep` script the same way GE's build does. It stops if any of them fails to apply.
3. Replaces the Bluetooth parts of that source with the BLE code from [pocker/wine](https://github.com/pocker/wine), branch `zwift-radios`, which builds on [evanjt/wine](https://github.com/evanjt/wine). The replaced parts are `winebth.sys`, `bluetoothapis`, `windows.devices.bluetooth`, `windows.devices.radios` and `wintypes`, plus their headers.
4. Applies a small fix to `ntoskrnl.exe`, so `winedevice.exe` no longer crashes when a Bluetooth device goes away.
5. Builds only those six modules. Before installing, it checks that the rebuilt `ntoskrnl.exe` still has every export of the shipped one, because GE patches that module too.
6. Installs them into your GE-Proton folder, without debug info. The originals are kept in `<GE-Proton>/ble-backup/`.
7. Patches GE-Proton's `proton` script so each game can turn the driver on with `PROTON_ENABLE_WINEBTH=1`. Games without that variable get the same Bluetooth DLLs, but the driver stays off. The `ntoskrnl.exe` fix applies to every game on that GE-Proton.
8. Optional, with `--prefix`: links the new modules into an existing wine prefix and registers the new components in it.

## Compatibility

| | Status |
|---|---|
| GE-Proton **11-7** | Tested |
| Other GE-Proton versions | Untested. The script shows a warning and continues. Newer versions may clash with the replaced Bluetooth code. |
| Zwift: Zwift Hub trainer (power, cadence, controllable trainer, HR) | Pairs, `status=ready` |
| Zwift: Zwift Play controllers | Pair, `status=ready` |
| Zwift: restarting the game from the still-open launcher | Works (needs the `ntoskrnl.exe` fix) |
| Zwift: ERG/resistance during a ride, Play buttons and steering | Not verified yet |
| Rouvy | The underlying BLE code was written for Rouvy, but hasn't been tested with this script |
| Lutris (via umu) | Tested |
| Steam | Should work with the launch option below; untested |
| Linux | Needs BlueZ running, a Bluetooth adapter that supports BLE, and a normal desktop session (system D-Bus access). |
| Arch-based (CachyOS, KDE) | Tested |
| Debian/Ubuntu | Should work, untested. Flatpak Steam keeps GE-Proton under `~/.var/app/com.valvesoftware.Steam/`, and `umu-run` (only used by `--prefix`) may not be packaged. |

Connecting a device takes roughly 15–30 seconds. Zwift may log a couple of `Timeout for GET` errors while connecting; it retries and carries on.

## Requirements to build

`git`, `python3`, `perl`, `autoconf`, `make`, `gcc`, `binutils`, `flex`, `bison`, `pkg-config`, mingw-w64 gcc and binutils (x86_64 and i686), and the D-Bus development headers.

The easiest way is to let the script install them. With `--install-deps` it uses `sudo pacman` on Arch-based systems or `sudo apt-get` on Debian-based ones, asks for your password, and shows what it will install before doing it:

```sh
./patch-ge-proton-ble.sh --install-deps ~/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-x86_64
```

Without `--install-deps`, the script stops and prints the command for anything that's missing. To install them yourself instead:

Arch/CachyOS:

```sh
sudo pacman -S --needed git python perl autoconf make gcc binutils flex bison pkgconf mingw-w64-gcc mingw-w64-binutils dbus
```

Debian/Ubuntu:

```sh
sudo apt install git python3 perl autoconf make gcc binutils flex bison pkg-config gcc-mingw-w64 binutils-mingw-w64 libdbus-1-dev
```

The build takes a few minutes and uses about 1.5 GB in `~/.cache/ge-proton-ble`.

## Usage

```sh
./patch-ge-proton-ble.sh ~/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-x86_64
```

If the game already has a prefix, pass it too. Close the game first.

```sh
./patch-ge-proton-ble.sh --prefix ~/Games/zwift ~/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-x86_64
```

Then configure the game:

- Set the environment variable `PROTON_ENABLE_WINEBTH=1`.
- Use this exact GE-Proton version, not "latest". A GE-Proton update replaces the patched files.

**Lutris**: *Configure → Runner options* → Wine version `GE-Proton11-7-x86_64`, and *System options → Environment variables* → `PROTON_ENABLE_WINEBTH` = `1`. In the game's YAML:

```yaml
system:
  env:
    PROTON_ENABLE_WINEBTH: '1'
wine:
  version: GE-Proton11-7-x86_64
```

**Steam** (untested): force the GE-Proton11-7 compatibility tool and set the launch options to `PROTON_ENABLE_WINEBTH=1 %command%`.

### Zwift extras

These aren't Bluetooth-specific, but Zwift needed them:

- `WINEDLLOVERRIDES=vccorlib140=n,b`. Wine's built-in `vccorlib140` is missing a function Zwift's Bluetooth library calls, and the game aborts without the native one from Zwift's VC++ redistributable.
- `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox --disable-gpu` for the launcher window.

### Checking it works

The game's own log should say the radio was found. For Zwift, that's `drive_c/users/<you>/AppData/Local/Zwift/Logs/Log.txt`:

```
[BLE] [BLEWinLib] Native BLE - Bluetooth Radio Found.
[BLE] [BLEWinLib] Native BLE - Bluetooth Radio is On.
```

If it still says "NOT Found", check that `PROTON_ENABLE_WINEBTH=1` actually reaches the game and that the runner is the patched GE-Proton.

## Undo

```sh
./patch-ge-proton-ble.sh --restore ~/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-x86_64
```

This puts the original GE-Proton files back. Prefixes you updated with `--prefix` link to the GE-Proton files, so they follow automatically. Prefixes updated by an older version of the script hold copies instead; recreate them, or re-run the script with `--prefix` once before restoring. Reinstalling GE-Proton also undoes everything.

## Known issues

- Valve disabled `winebth.sys` because it could crash `winedevice.exe`, which also runs the controller and HID drivers. The crash is a Wine bug that this script fixes in `ntoskrnl.exe`. When a device disconnected, BlueZ removed its GATT services one at a time, and a leftover update for the removed device made `winedevice.exe` read freed memory. Without the fix, Bluetooth stopped working after the game closed until the whole Wine session was restarted, for example by quitting Zwift's launcher from the tray.
- **The game doesn't see a device that's switched on and in range.** Rarely, a device's Wine registry entry is left half-registered, and Wine then never finishes adding the device. With `WINEDEBUG=err+plugplay` the log shows `IoSetDevicePropertyData Failed to open device, error 0xe000020b`. To fix it, close the game and quit its launcher. Then, in the prefix's `system.reg`, delete every key whose name contains the device's Bluetooth address (lowercase, without colons, for example `d44e4b8bdf9a`). Back up the file first.
- **Upgrading from an older version of this script:** run it again on the same GE-Proton. It keeps the original backups from the first run, and adds the `ntoskrnl.exe` fix. Pass `--prefix` again too, so the prefix links to the new files.
- The script only works with Proton builds that use GE-Proton's `proton` script, where the driver is disabled with `"winebth.sys": "d"`.

## Credits

- [evanjt/wine](https://github.com/evanjt/wine): BLE support in `winebth.sys` and `windows.devices.bluetooth`, made for Rouvy
- [pocker/wine](https://github.com/pocker/wine) `zwift-radios`: radio listing, `BluetoothUuidHelper`, `DataReader`/`DataWriter`, GATT session handling and faster reconnects, needed for Zwift, and the `ntoskrnl.exe` device removal fix
- [GloriousEggroll/proton-ge-custom](https://github.com/GloriousEggroll/proton-ge-custom)

## License

The script and this README are MIT licensed (see `LICENSE`). The wine code it downloads and builds stays under Wine's LGPL-2.1-or-later.
