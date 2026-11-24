# AppleBeat

A macOS menu bar app that makes the glowing Apple logo on the lid of a MacBook Pro with PROLED XDR Display beat in time with the music your Mac is playing.

It listens to system audio, finds the beats, and flashes the logo on each one. When the music stops, the logo goes back to its normal steady glow.

## Requirements

- A MacBook Pro with PROLED XDR Display (the 2026 models with the illuminated lid logo, `Mac17,10` to `Mac17,13`). Developed and tested on a `Mac17,10` running macOS 27.3.
- macOS 15 or later, and Xcode to build it.

On a Mac without the logo light the app still runs, but only the menu bar icon beats.

## Build and run

Open `AppleBeat.xcodeproj` in Xcode and press Run, or build from the command line:

```sh
xcodebuild -project AppleBeat.xcodeproj -scheme AppleBeat -configuration Release -derivedDataPath build build
open build/Build/Products/Release/AppleBeat.app
```

The first time it runs, macOS asks for permission to capture system audio. If the logo doesn't react to music, allow AppleBeat under **System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only**.

The app is ad-hoc signed, so macOS may ask for that permission again after a rebuild.

## Using it

Click the apple in the menu bar:

| Control | What it does |
| --- | --- |
| Switch | Turns the beat on and off. Off hands the logo back to macOS. |
| Sensitivity | How small an accent counts as a beat. |
| Brightness | How bright each flash peaks. |
| Fade | How quickly each flash dies away. |

Quitting the app returns the logo to normal.

## How it works

- **Audio** ([SystemAudioTap.swift](AppleBeat/SystemAudioTap.swift)): a Core Audio process tap on everything the Mac plays. Each buffer is mixed to mono, analysed and dropped; nothing is recorded or saved.
- **Beats** ([BeatDetector.swift](AppleBeat/BeatDetector.swift)): the audio is cut into ~12 ms hops. A beat is a sudden rise in loudness, mostly in the bass below ~150 Hz, that stands out from the last second and a half. Loudness is compared in log units, so the volume setting doesn't matter. It works best on music with a clear kick drum.
- **Logo** ([LogoLight.swift](AppleBeat/LogoLight.swift)): Apple has no public API for the logo. `corebrightnessd` owns the LED and accepts a few keys through the private `BrightnessSystemClient` class in CoreBrightness. There is no brightness key; the logo follows a display state (blank fades it out, unblank fades it in) with a settable fade duration. A beat is a short fade up that is turned round into a longer fade down.

## Caveats

- This uses a private, undocumented interface. A macOS update can break it. Everything is looked up at runtime, so if it changes the app stops controlling the light instead of crashing.
- It can't be sandboxed, so it can't go on the Mac App Store.
- The keyboard backlight listens to the same display state. The app corrects for that after every fade, but the keyboard may dip very slightly while the logo is beating.
- If the app is killed mid-beat the logo can be left dark. Opening AppleBeat again resets it.

## Credits

The logo interface was worked out by others. This app relies on the research notes published with these projects:

- [Mac Logo Control](https://github.com/yanhuifair/MacLogoControler) (formerly LogoLight)
- [macbookpro-apple-logo-analysis](https://github.com/GOROman/macbookpro-apple-logo-analysis)

AppleBeat is not affiliated with or endorsed by Apple Inc.
