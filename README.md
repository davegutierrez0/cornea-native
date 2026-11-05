# Cornea Native

A small, Apple Silicon-native macOS menu-bar app for screen warmth, software dimming, schedules, and break reminders. Built with Swift, AppKit, SwiftUI, and public Core Graphics APIs. No third-party packages, account, telemetry, or network requests.

## Features

- Approximate color temperature from 1200–6500 K and software brightness from 20–100%.
- Daylight, Evening, Reading, and Sleep presets.
- Fixed-time schedules or approximate sunrise/sunset from manually entered coordinates, with optional bedtime settings and gradual transitions.
- Per-display exclusions and fixed overrides, keyed by display UUID.
- Pause for 15 minutes, one hour, or until resumed within the current session.
- Configurable break reminders with postpone, skip, and pause controls.
- Global shortcuts, optional launch at login, and JSON settings import/export.
- Original calibration restoration on Disable, Pause, and Quit, plus a small crash-recovery helper.

## Requirements

- Apple Silicon Mac.
- macOS 14 or later (deployment target; runtime verification so far is on macOS 27).
- Full Xcode with a Swift 6-capable toolchain for building. Some Command Line Tools installations lack the SwiftUI compiler plugins needed by this project.

## Build and run

```sh
git clone https://github.com/davegutierrez0/cornea-native.git
cd cornea-native
bash scripts/build.sh
open "dist/Cornea Native.app"
```

The script builds ARM64 release code and creates an ad-hoc signed app bundle. It uses `/Applications/Xcode.app` when available unless `DEVELOPER_DIR` is already set. For another Xcode installation, set that variable to its `Contents/Developer` directory.

To install, copy `dist/Cornea Native.app` into your Applications folder. Quit any running copy before replacing it. Launch the installed copy before enabling **Open at login**; macOS may require approval in System Settings.

Display controls and break reminders start **off**. Choose a preset, then turn **Enable** on. Closing the settings window leaves the menu-bar app running. Use its sun menu to reopen settings or quit.

This project does not currently provide Developer ID-signed or notarized downloads. Local ad-hoc signing is not a substitute for notarization when distributing binaries. Do not disable Gatekeeper to run a redistributed build.

## Display safety and limits

**Software dimming does not change the backlight or PWM.** Kelvin values describe approximate RGB targets, not measured panel color temperature. This app makes no medical claims.

Keep Night Shift, True Tone, and other color-control apps off while using Cornea Native. They share the display pipeline and may overwrite each other. Cornea Native does not change those system settings or repeatedly overwrite competing apps. To change system calibration, pause Cornea Native, make the change, then use **Refresh displays** before resuming.

Each adjustment scales the calibration captured when a display connects. It never scales an already tinted table. A child process waits on a private pipe and restores armed calibration snapshots if the parent exits unexpectedly. It uses no polling timer or recovery file. Restoration cannot be guaranteed if both processes are killed or the OS/GPU fails.

Displays without readable gamma tables are reported as unsupported. A successful API write does not prove correct optical output on every panel or HDR configuration. Verify your display visually before relying on it. Mirrored displays share the source display's controls.

Sunrise/sunset uses a NOAA fractional-year approximation, not an astronomical ephemeris. Verify coordinates and the Mac's time zone. Polar day/night uses the corresponding day/night profile without a bedtime override. Transitions begin at each scheduled event and are capped by the next event.

## Shortcuts

Hold **Control–Option–Command**, then press:

| Key | Action |
| --- | --- |
| P | Pause or resume colors |
| Left / Right | Warmer / cooler by 100 K |
| Down / Up | Dimmer / brighter by five percentage points |

Temperature and brightness shortcuts switch to Manual mode. Shortcut conflicts are reported in the app. Global shortcuts can be disabled in General settings.

## Settings

Settings are stored at `~/Library/Application Support/Cornea Native/settings.json`. Writes are atomic and debounced. Invalid settings are not silently overwritten; **Back up and reset** preserves an unreadable file first.

Enable and profiles persist across launches. Pause state and break countdown progress are session-only. After sleep or session inactivity, breaks start a fresh work interval. Settings imports accept this app's validated JSON format; other apps' settings are not migrated or changed.

## Development and verification

Run the behavioral tests with the same toolchain used for the build:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The eight tests cover schedule boundaries and midnight transitions, short intervals, the repeated DST hour, solar edge cases, RGB gain bounds, settings validation/round-trip, and break-clock transitions.

Before the public rename, live checks on one external display verified requested gamma values and exact restoration of all 3072 calibration samples after Pause, exclusion, Disable, normal Quit, and a parent SIGKILL. The SIGKILL restoration was observed within 60 ms in that run; this is not a latency guarantee. Break reminders and settings import/export were exercised. Synthetic Carbon events reached all five shortcut handlers; physical global shortcut delivery remains unverified.

The renamed package passed a clean ARM64 release build, signature verification, and all eight tests. An executable smoke check verified startup, orderly termination, separate settings storage with controls off, and the recovery helper's empty-snapshot exit. The renamed interface was not visually rechecked because the test workstation was locked.

Login launch, actual sleep/hot-plug cycles, HDR, multiple physical monitors, older supported macOS versions, and long-duration stability remain unverified. Please report your macOS version, display configuration, and reproducible steps with compatibility issues. Remove coordinates, display UUIDs, and other personal details before sharing settings.

### Source layout

- `Sources/CorneaCore`: deterministic settings, schedules, solar calculation, and break clock.
- `Sources/CorneaNative`: AppKit lifecycle/menu, SwiftUI settings, display control, recovery helper, and shortcuts.
- `Tests/CorneaCoreTests`: behavioral tests.
- `Packaging` and `scripts/build.sh`: app metadata and local packaging.

## License and origin

[MIT](LICENSE), copyright 2026 David Gutierrez.

Cornea Native began as an independently written native alternative to daily Iris display controls. It is not affiliated with or endorsed by Iris and does not claim complete feature or visual parity. This repository contains no proprietary Iris binaries, extracted assets, decompiled source, or research dumps. The MIT license applies to the code and documentation distributed here, not to third-party products.
