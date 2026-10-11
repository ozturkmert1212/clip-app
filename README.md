# ClipApp

<p align="center">
  <img src="docs/images/desktop.png" alt="ClipApp running in the menu bar, with its menu and settings window open on the desktop" width="900">
</p>

<p align="center">
  <img src="docs/images/menu.png" alt="ClipApp menu showing capture status and the Save Last 30 Seconds command" width="260">
</p>

<p align="center">
  <img src="docs/images/settings-top.png" alt="ClipApp settings: clip, video and audio options" width="300">
  <img src="docs/images/settings-bottom.png" alt="ClipApp settings: audio, saving and general options" width="300">
</p>

A menu bar "instant replay" clipping app for macOS (the Medal / ShadowPlay idea). It captures the screen in the background, keeps the last N seconds in memory and saves them as an mp4 when you press a global shortcut.

The interface is in English by default. Türkçe için: Settings > General > Language.

## Features

- Continuous screen capture (a display, a single window or a single application), hardware H.264 encoding, a 15–120 second buffer in memory.
- Save the last N seconds as an mp4 with a global shortcut (default ⌃⌥⌘R) or from the menu; capture keeps running while the clip is written.
- System audio and microphone, each with its own level. Mixed into one audio track by default; can be split into separate tracks in Settings.
- A system notification when a clip is saved or something goes wrong (the notification reveals the clip in Finder), plus a small on-screen message in a corner of the screen for a few seconds. The message never ends up in clips and also shows above full screen games; its corner is chosen in Settings (default top left) and it can be turned off.
- System notifications (banners) stay out of clips while a display is captured.
- Settings: buffer length, resolution, FPS, bitrate, source, audio, save folder, file name format, launch at login, language (English or Turkish).

## Requirements

- macOS 13+
- Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Download

Grab the latest dmg from [Releases](https://github.com/ozturkmert1212/clip-app/releases/latest). Requires an Apple Silicon Mac with macOS 13 or later.

The app is not notarized, so macOS blocks the first launch: open System Settings > Privacy & Security and click **Open Anyway** next to ClipApp (or run `xattr -dr com.apple.quarantine /Applications/ClipApp.app`). Then grant Screen Recording and restart the app.

## Build and install

```bash
xcodegen generate
xcodebuild -project ClipApp.xcodeproj -scheme ClipApp -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/ClipApp.app /Applications/
open /Applications/ClipApp.app
```

While developing, build with `-configuration Debug` and open `build/Build/Products/Debug/ClipApp.app` directly. "Launch at login" can only be turned on in the copy inside `/Applications`, because the login item is registered for wherever the app currently is.

## Permissions

- **Screen Recording (required):** Requested at first launch. After granting it under System Settings > Privacy & Security > Screen Recording, restart the app.
- **Microphone (optional):** Requested when the microphone is turned on in Settings. Without it, clips are saved with system audio only.
- **Notifications (optional):** Requested at first launch; also available from the "Permissions…" window in the menu. macOS hides notifications by default while the screen is shared or recorded; since ClipApp captures the screen all the time, turn on "Allow notifications when mirroring or sharing the display" under System Settings > Notifications if you want to see the banners. The "Open Notification Settings" button in the "Permissions…" window takes you there. That switch cannot be flipped from code, so the on-screen message works independently of it.

## Language

English is the default, regardless of the system language. Turkish can be selected under Settings > General > Language; the change applies after the restart offered there.

## Known limits

- To keep notifications out of clips, Notification Center is excluded from capture; desktop widgets belong to it too, so they do not appear in display clips. With a single window or application as the source, only that application is captured anyway.
- The global shortcut does not fire in full screen (exclusive) games; it works in borderless or windowed mode.
- With separate audio tracks, QuickTime plays both together; VLC, browsers and Discord only play the first one (system audio).
- On content that is very hard to compress (heavy noise, grainy footage) the encoder overshoots the target bitrate. Memory is capped at buffer length × bitrate × 3; once the cap is hit, clips come out shorter than configured and the menu shows an info line.
- If microphone and system audio arrive at different sample rates they cannot be mixed and are written as separate tracks.

## Troubleshooting

App logs: `/usr/bin/log show --predicate 'subsystem == "com.mertozturk.ClipApp"' --last 5m --info`

See `CLAUDE.md` for an architecture overview and development notes.

## Building from source

`project.yml` contains the author's `DEVELOPMENT_TEAM` and `bundleIdPrefix`. Replace both with your own before building (your Team ID is the `OU=` value of your "Apple Development" certificate, also shown in Xcode > Settings > Accounts). Without a stable signing identity, macOS may ask for the Screen Recording permission again after every rebuild.

If you would rather not build it yourself, a prebuilt dmg is available under [Releases](https://github.com/ozturkmert1212/clip-app/releases/latest), see "Download" above.

## License

MIT, see `LICENSE`.
