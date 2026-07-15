# macOS Media Key Router

A UI-less macOS utility that routes hardware media keys between `cmus` and the active system media player. It also exposes `cmus` through macOS Now Playing, allowing play/pause buttons on Bluetooth headsets and other media remotes to control it.

## Behavior

The app supports play/pause, previous-track, and next-track media keys.

Routing priority:

1. If `cmus` is playing, control `cmus`.
2. Otherwise, if a browser or native macOS media app is playing, control that player.
3. If nothing is playing, control the last active player.
4. On first launch, default to `cmus`.

The app runs entirely in the background. It has no Dock icon, menu-bar item, or configuration window.

## Requirements

- macOS 10.13 or later
- Accessibility permission for keyboard media-key capture
- `cmus-remote` on `PATH` when using `cmus`

If a GUI-launched app cannot find `cmus-remote`, make it available in `/usr/local/bin`:

```sh
ln -s "$(command -v cmus-remote)" /usr/local/bin/cmus-remote
```

## Build

```sh
xcodebuild \
  -project cmusie.xcodeproj \
  -scheme cmusie \
  -configuration Release \
  -derivedDataPath .deriveddata \
  build
```

The built app is located at:

```text
.deriveddata/Build/Products/Release/cmusie.app
```

Move it to `/Applications`, open it, and grant Accessibility permission when macOS prompts.

## Attribution

Based on [nkanaev/cmusie](https://github.com/nkanaev/cmusie). The low-level media-key event-tap code is derived from [mpv](https://github.com/mpv-player/mpv).
