# cheapshot

A free, native screen capture app for macOS. It takes screenshots, annotates them, reads text from the screen and records video, all from the menu bar. It is written in Swift with no third-party dependencies.

The name is a pun. The app exists because its author did not want to pay for a screenshot tool.

## What it does

- Captures a region, a window or the whole screen. Every capture goes to the clipboard.
- After a screenshot it shows a thumbnail, opens the editor, asks where to save or saves straight to a folder. You choose which in Settings.
- Annotates with arrows, lines, rectangles, ellipses and a freehand brush, with color, thickness and fill.
- Hides things with blur, pixelate or a solid redaction block.
- Crops, with undo for every edit.
- Reads the text in a region of the screen into an editable box. The recognition runs on the device.
- Records a region, a window or the screen to MP4, with the system sound, the microphone or both.
- Cleans the microphone with voice isolation and mixes both sources into one audio track.

## Install

1. Download `cheapshot-<version>.zip` from the [latest release](https://github.com/andremorata/cheapshot/releases/latest) and unzip it.
2. Move `cheapshot.app` to Applications and open it.
3. The build is not notarized by Apple, so macOS blocks the first launch. Open System Settings, go to Privacy & Security, and click "Open Anyway".
4. Take a capture. macOS asks for Screen Recording permission the first time. Grant it, then quit and reopen cheapshot.

Recording with the microphone asks for Microphone permission the first time.

cheapshot needs macOS 15 or later on Apple silicon. It is built and tested on macOS 27. Earlier versions should work but have not been tried.

## Shortcuts

| Action | Default |
|---|---|
| Capture a region | ⌥⇧4 |
| Capture a window | ⌥⇧5 |
| Capture the screen | ⌥⇧3 |
| Capture text | ⌥⇧T |
| Annotate the last capture | ⌥⇧E |
| Record, and stop recording | ⌥⇧R |

All of them can be changed in Settings. While selecting, Esc or a right click cancels.

The menu bar icon can be hidden in Settings. Open cheapshot again from Applications or Spotlight to get the settings window back.

### Editor

| Key | Tool |
|---|---|
| A | Arrow |
| L | Line |
| R | Rectangle |
| O | Ellipse |
| D | Brush |
| B | Blur |
| P | Pixelate |
| X | Redact |
| C | Crop |

Hold Shift to keep a line horizontal or vertical, or a box square. Return copies the result and closes the editor. Esc cancels. ⌘S saves as PNG or JPEG, and ⌘Z undoes.

Blur and pixelate hide things from a casual look, but text under them can sometimes be recovered. Use redact for anything sensitive.

## Recording

The record shortcut opens a small panel. It asks what to record, which audio sources to include and how loud, and how long to count down. The panel remembers the last choice, so the usual flow is the shortcut followed by Return.

Stop from the red button in the menu bar or with the same shortcut. cheapshot then asks where to save the file.

Codec, resolution, frame rate and quality are in Settings. The defaults are HEVC, one pixel per point, 30 frames per second and medium quality. That comes to about 28 MB per minute for a 1920 × 1080 area, before audio.

## Build from source

You need the Swift 6 toolchain. The Command Line Tools are enough, and Xcode is not required.

```sh
make app    # builds build/cheapshot.app
make run    # builds it and opens it
make test
```

macOS ties the Screen Recording permission to the app's code signature. An ad-hoc build gets a new signature every time, so each rebuild loses the permission. To keep it, create a self-signed code signing certificate in Keychain Access and name it in a `local.mk` file, which git ignores:

```make
CODESIGN_IDENTITY := the name of your certificate
```

`make snapshots` renders the app's windows to `build/snapshots` without putting them on screen. It makes interface changes reviewable without Screen Recording permission.

Each recording appends a summary of its audio tracks to `~/Library/Logs/cheapshot.log`.

## License

MIT. See [LICENSE](LICENSE).
