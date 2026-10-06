# 64Voice

On-device dictation for macOS. Hold **Right Option**, talk, let go, and the text is pasted where
you're typing. The recording notch spawns at your mouse cursor and flies into the emptiest nearby
spot on screen, so it never covers what you're reading.

A small rewrite of the ideas in [FluidVoice](https://github.com/altic-dev/FluidVoice) (GPLv3):
same Parakeet speech models via [FluidAudio](https://github.com/FluidInference/FluidAudio), none of
the rest.

## Build and run

```bash
scripts/build-app.sh release --install
```

That builds `build/64Voice.app`, copies it to `/Applications` and launches it. It lives in the
menu bar. The first launch opens Settings so you can grant **Microphone** and **Accessibility**
(needed for the hotkey and pasting). **Screen Recording** is optional and powers smart placement.

macOS ties those permissions to the app's code signature. Set `SFV_SIGN_IDENTITY` to a code
signing identity from your keychain (`security find-identity -v -p codesigning`) so they survive
rebuilds; without one the script ad-hoc signs and macOS asks again after every build.

## Using it

| Do this | What happens |
| --- | --- |
| Hold Right Option, talk, release | Push-to-talk: transcribes and pastes on release |
| Tap Right Option | Hands-free: records until you tap again |
| Esc while recording | Cancel, nothing is pasted |
| Right Option + another key (⌥2 = @) | Treated as typing; the mic never opens |

Change the key (Right ⌘, Right ⌃, Fn) and mode in Settings → General.

## Microphone

Pick a mic once in the menu bar or Settings → Microphone. The choice is stored by the device's
stable UID and never reset: if it's unplugged, that one recording uses the system default and the
next one goes back to your mic as soon as it's connected. 64Voice routes its own capture to the
mic directly and never changes the system default input. On first launch it adopts the mic you
had selected in FluidVoice.

## Speech models

- **Parakeet v2** (default): English, best accuracy. Reuses FluidVoice's download if present.
- **Parakeet v3**: 25 European languages. Downloads ~450 MB on first use.

Models live in `~/Library/Application Support/FluidAudio/Models`. The first load after install
compiles for the Neural Engine (~20 s, once); after that it loads in well under a second.

## Smart placement

When you start dictating, 64Voice grabs a low-res capture of the area around the cursor (never
stored), runs edge detection and Vision text detection, and scores hundreds of candidate spots
with a summed-area table: empty space wins, text and the caret line lose, closer is better, and
it won't hop around unless a new spot is clearly better. Without Screen Recording permission it
falls back to below-right of the cursor, flipped near screen edges.

## Dev

```bash
swift build
.build/debug/SixtyFourVoice --transcribe clip.wav     # print a transcript and exit
.build/debug/SixtyFourVoice --demo-overlay            # play every notch state at the cursor
SFV_PLACEMENT_DEBUG=/tmp/placement .build/debug/SixtyFourVoice   # dump placement heatmaps
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the module layout.

License: GPLv3 (derived from FluidVoice).
