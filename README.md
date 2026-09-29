# GE-Proton Bluetooth LE patch

Adds Bluetooth Low Energy support to [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom), so Windows apps that use the Windows Bluetooth APIs can talk to trainers and sensors through the Linux Bluetooth stack (BlueZ). It was made for Zwift's direct Bluetooth pairing, with no Zwift Companion or ANT+ dongle needed.

## Why this is needed

Stock Wine and Proton can't do this, for two reasons:

- **Missing Windows Bluetooth pieces.** Stock Wine lacks the parts these apps need: finding Bluetooth radios, GATT services and connections, and a few helpers such as `BluetoothUuidHelper` and `DataReader`/`DataWriter`. Zwift reports "Bluetooth Radio NOT Found" and fails its `HasBLE()` check.
- **GE-Proton turns the driver off.** It ships `winebth.sys`, the Bluetooth driver, but disables it: `"winebth.sys": "d"` in its `proton` script. A normal setting can't turn it back on, because Proton adds its own override after yours.

The script fixes both.

## What the script does

1. Reads your GE-Proton version and downloads the exact wine source that version was built from (`ValveSoftware/wine` at the commit GE-Proton pins).
2. Replaces the Bluetooth parts of that source with the BLE code from [pocker/wine](https://github.com/pocker/wine), branch `zwift-radios`, which builds on [evanjt/wine](https://github.com/evanjt/wine). The replaced parts are `winebth.sys`, `bluetoothapis`, `windows.devices.bluetooth`, `windows.devices.radios` and `wintypes`, plus their headers.
3. Builds only those modules and installs them into your GE-Proton folder. The originals are kept in `<GE-Proton>/ble-backup/`.
4. Patches GE-Proton's `proton` script so each game can turn the driver on with `PROTON_ENABLE_WINEBTH=1`. Games without that variable behave exactly as before.
5. Optional, with `--prefix`: updates an existing wine prefix and registers the new components in it.

## Compatibility

| | Status |
|---|---|
| GE-Proton **11-7** | Tested |
| Other GE-Proton versions | Untested. The script shows a warning and continues. Newer versions may clash with the replaced Bluetooth code. |
| Zwift: Zwift Hub trainer (power, cadence, controllable trainer, HR) | Pairs, `status=ready` |
| Zwift: Zwift Play controllers | Pair, `status=ready` |
| Zwift: ERG/resistance during a ride, Play buttons and steering | Not verified yet |
| Rouvy | The underlying BLE code was written for Rouvy, but hasn't been tested with this script |
| Lutris (via umu) | Tested |
| Steam | Should work with the launch option below; untested |
| Linux | Needs BlueZ running, a Bluetooth adapter that supports BLE, and a normal desktop session (system D-Bus access). Tested on CachyOS with KDE. |

Connecting a device takes roughly 15–30 seconds.

## Requirements to build

`git`, `curl`, `python3`, `autoconf`, `make`, `gcc`, `flex`, `bison`, `pkg-config`, mingw-w64 (x86_64 and i686), and the D-Bus development headers.

Arch/CachyOS:

```sh
sudo pacman -S --needed git curl python autoconf make gcc flex bison pkgconf mingw-w64-gcc dbus
```

The build takes a few minutes and uses about 1 GB in `~/.cache/ge-proton-ble`.

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

This puts the original GE-Proton files back. Prefixes you updated with `--prefix` keep the patched copies until they are recreated. Reinstalling GE-Proton also undoes everything.

## Known issues

- Valve disabled `winebth.sys` because it could crash `winedevice.exe`. That process also runs the controller and HID drivers. It hasn't crashed with this build so far, but if controllers or Bluetooth suddenly stop working, this is the first thing to check.
- The script only works with Proton builds that use GE-Proton's `proton` script, where the driver is disabled with `"winebth.sys": "d"`.

## Credits

- [evanjt/wine](https://github.com/evanjt/wine): BLE support in `winebth.sys` and `windows.devices.bluetooth`, made for Rouvy
- [pocker/wine](https://github.com/pocker/wine) `zwift-radios`: radio listing, `BluetoothUuidHelper`, `DataReader`/`DataWriter`, GATT session handling and faster reconnects, needed for Zwift
- [GloriousEggroll/proton-ge-custom](https://github.com/GloriousEggroll/proton-ge-custom)

## License

The script and this README are MIT licensed (see `LICENSE`). The wine code it downloads and builds stays under Wine's LGPL-2.1-or-later.
