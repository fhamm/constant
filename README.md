<img src="Resources/icon.png" width="128" alt="Constant icon">

# Constant

A macOS menu bar host for virtual instruments. It keeps one Audio Unit instrument (Omnisphere, Keyscape, Arturia and so on) loaded and playable from your MIDI keyboard, without opening a DAW.

## Features

- Lives in the menu bar, with no Dock icon
- Left click shows or hides the plugin's own editor
- Audio keeps running while the editor is hidden
- The selected plugin and its patch are restored on launch
- Global hotkey or MIDI command (note, CC or program change) to show or hide the editor
- Listens on all MIDI inputs, or only the ones you pick
- Selectable output device, output channel pair and buffer size
- Start at Login

## Requirements

- macOS 13 or later
- Instruments installed as Audio Units. VST is not supported.
- To build from source: Xcode Command Line Tools (`xcode-select --install`)

## Install

1. Download `Constant-x.y.z.dmg` from the [latest release](https://github.com/fhamm/constant/releases/latest).
2. Open it and drag Constant to Applications.
3. Open Constant. The first launch is blocked, see below.

### "Apple could not verify Constant is free of malware"

macOS shows this warning on the first launch because the app is not notarized by Apple. To get past it, do one of these once:

- Click **Done** on the dialog, open System Settings > Privacy & Security, scroll down to the message about Constant and click **Open Anyway**.
- Or run this in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Constant.app
```

After that the app opens normally.

## Build

```sh
./build.sh
open build/Constant.app
```

The script builds with SwiftPM, assembles `build/Constant.app` and signs it ad hoc. Full Xcode is not needed.

For daily use, copy `build/Constant.app` to `/Applications`. Start at Login points at the app's location, so enable it from the copy you actually run.

## Release

```sh
./scripts/make-dmg.sh              # local disk image in build/
git tag v0.1.0 && git push origin v0.1.0
```

Pushing a `v*` tag runs the Release workflow, which builds a universal disk image, takes the version from the tag and publishes it as a GitHub release.

## Usage

| Action | Result |
| --- | --- |
| Left click the icon | Show or hide the plugin editor |
| Right click the icon | Instrument, Settings, About, Quit |

**Instrument** picks the plugin to host, grouped by manufacturer. Switching plugins discards the previous plugin's patch.

**Settings** has three tabs:

- **General** - Start at Login, where the editor appears (Top Right, Top Left, Center, Bottom Left or Bottom Right), and the show/hide shortcuts: a global hotkey or a learned MIDI command. The learned MIDI message is not passed on to the instrument.
- **Audio** - output device, output channel pair (on devices with more than two outputs) and buffer size.
- **MIDI** - all inputs, or individual devices.

## Notes

- Plugins load inside the app's process, so a plugin crash also quits Constant.
- The app is not sandboxed and is signed ad hoc, which is what lets third-party Audio Units load. It is meant to be built and run locally, not distributed through the Mac App Store.
- The session is saved to `~/Library/Application Support/Constant/session.plist`.

## Project layout

| File | Role |
| --- | --- |
| `InstrumentHost.swift` | Audio engine, plugin loading, session save and restore |
| `PluginPanelController.swift` | The panel that shows the plugin editor |
| `StatusItemController.swift` | Menu bar icon, context menu, Settings window |
| `MIDIInput.swift` | MIDI device handling and message forwarding |
| `ToggleShortcuts.swift` | Global hotkey and MIDI show/hide trigger |
| `AudioDevices.swift` | Output device listing and buffer size |
| `SettingsView.swift` | Settings UI |

All sources are in `Sources/Constant/`.
