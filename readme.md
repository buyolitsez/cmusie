# cmusie

control playback on macos with the media keys only.

![preview](https://raw.githubusercontent.com/nkanaev/cmusie/master/assets/preview.jpg)

## differences from upstream

Compared with the [original cmusie](https://github.com/nkanaev/cmusie), this fork:

- removes the menu-bar popover and runs as a media-key-only background app
- starts media-key capture automatically after Accessibility permission is granted
- controls either `cmus` or the active native macOS media player, with a playing `cmus` taking priority
- registers `cmus` with macOS Now Playing so headset play/pause controls work

The original tray-based build remains available from the [upstream releases](https://github.com/nkanaev/cmusie/releases/latest).

# usage

1. Open the app.
2. Grant Accessibility permission when macOS prompts for it.
3. If you want `cmus` support, make sure `cmus-remote` is on `PATH`:

        ln -s "$(which cmus-remote)" /usr/local/bin/cmus-remote
4. Media-key routing works like this:
   - if `cmus` is currently playing, `cmusie` controls `cmus`
   - otherwise, if a native macOS media player is currently playing, `cmusie` controls that player
   - if nothing is playing, `cmusie` controls the player that was active last
   - the default active player is `cmus`
5. (Optionally) follow the guide [here](https://support.apple.com/en-gb/guide/mac-help/mh15189/mac) to automatically start the app when you log in.

# credits

* [fontawesome]: for button icons
* [mpv]: for low-level media keys control code.

[fontawesome]: http://fontawesome.com/
[mpv]: https://github.com/mpv-player/mpv
