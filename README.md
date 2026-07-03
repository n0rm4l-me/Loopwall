# Loopwall

Play a video as your desktop wallpaper on macOS — behind all windows, on every Space.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)

## Features

- Plays any `.mp4`, `.mov`, or `.m4v` file as a live desktop wallpaper
- Works across all Mission Control Spaces
- Supports multiple monitors
- Menu bar icon — change video, toggle mute, launch at login, quit
- Remembers the last chosen video across launches
- Drag & drop a video onto the Dock icon to switch
- Hardware-accelerated decoding — ~2% CPU, ~54 MB RAM

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`)

## Installation

### Download

Grab the latest `Loopwall.app.zip` from [Releases](../../releases) and move the app to `/Applications`.

### Build from source

```sh
git clone https://github.com/your-username/Loopwall.git
cd Loopwall
make app
```

This produces `Loopwall.app` in the project root. Move it to `/Applications` or run it in place.

## Usage

1. Launch `Loopwall.app`
2. Pick a video file in the dialog that appears
3. The video starts playing as your desktop wallpaper
4. Use the menu bar icon (▶︎) to change the video, mute, or quit

You can also pass a video path directly:

```sh
Loopwall.app/Contents/MacOS/Loopwall /path/to/video.mp4
```

## Limitations

- Does not affect the Lock Screen (macOS does not provide a public API for this)
- No audio by default (muted); unmute via the menu bar

## License

MIT
