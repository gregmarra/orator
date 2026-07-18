# Orator

Orator is a menu-bar dictation utility for macOS 26+ (Apple Silicon), built on Apple's on-device SpeechAnalyzer. Press your hotkey, speak, press again — your words land in the focused text field. Nothing you say leaves the Mac.

![Orator's indicator grows out of the camera notch, streams a live preview, then finalizes and inserts](assets/reel.gif)

First launch guides you through Microphone and Accessibility permissions and a one-time model download from Apple.

See [SPEC.md](SPEC.md) for the full product & engineering specification.

## Build & run

```sh
swift build
swift test
bash Scripts/bundle.sh    # assemble Orator.app (release); set SIGN_ID + NOTARY_PROFILE to sign + notarize
```

`bundle.sh` produces `Orator.app` — the menu-bar app you run (`swift build` alone yields just the executable).

## License

[MIT](LICENSE)
