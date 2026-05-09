# PTT Voice

A push-to-talk speech-to-text app for macOS that runs entirely on-device.

Hold a button — on a custom BLE puck or on the Mac itself — and the app
captures audio, transcribes it locally with Qwen3-ASR (via MLX), and pastes
the result into the focused application. No cloud round-trips, no API keys,
no per-minute billing.

> ⚠️  Early-stage personal project. Things may break, the UI changes often,
> and there is no installer yet.

---

## Features

* **Two input sources** — choose in Settings:
  * **BLE device** — a custom ESP32-based PTT puck streams SBC-encoded
    audio over GATT. Hardware button drives the session.
  * **System microphone** — built-in or external mic on the Mac, gated by
    a global "hold Control" hotkey. Works whether or not a BLE puck is
    around. Ctrl-only, with a 200 ms grace window so Ctrl+C and other
    keyboard shortcuts don't false-trigger PTT.
* **On-device ASR** — Qwen3-ASR via [MLX](https://github.com/ml-explore/mlx)
  on Apple Silicon. 1.7B 8-bit (default) or 0.6B 4-bit MLX-quantized
  variants. First-launch downloads ≈ 600 MB / 2.5 GB respectively.
* **Configurable model download source** — HF Mirror, HuggingFace official,
  or ModelScope (魔搭, default for CN networks).
* **Auto-paste into focused app** — Cmd+V driven via the Accessibility
  API. Restores the previous clipboard contents afterwards.
* **Per-scenario prompt profiles** — natural-language context prepended to
  each ASR call (technical terms, names, casing rules…). Persisted across
  launches; up to 10 profiles.
* **Floating compact panel** — small overlay window with a live waveform
  while you hold the button, transcript text otherwise.

---

## Requirements

* macOS 26 (Tahoe) or later, on Apple Silicon (M-series).
* Xcode 16+ if you build from source.
* (Optional) The custom ESP32 PTT puck — firmware lives in a separate
  (currently private) repo. The system-microphone mode works without it.

---

## Build & run

### Quick build (recommended)

```sh
bash scripts/build-ptt-voice-app.sh
```

Produces `dist/PTT Voice.app` (≈ 38 MB; model weights download on first
launch). Output streams quietly — full xcodebuild log goes to
`dist/xcodebuild.log`. See `--clean` and `--verbose` flags via
`scripts/build-ptt-voice-app.sh --help`.

### Run from Xcode

```sh
open PTTVoice/PTTVoice.xcodeproj
```

Pick your Apple ID team in the target's *Signing & Capabilities* tab, then
*Cmd-R*. The `.app` target depends on the SwiftPM library `PTTMacVoiceCore`,
so this builds the same code path as the script.

### `swift run` (CLI launcher)

```sh
swift run PTTMacVoiceApp
```

Faster debug loop, but: the CLI binary has no `Info.plist` or entitlements,
so the system-microphone mode will not work (the OS denies mic access). For
mic testing always run the proper `.app` from Xcode or the build script.

---

## First launch

1. **Grant Bluetooth** when prompted (only matters if you use the BLE puck).
2. **Grant Accessibility** in *Settings → Permissions* — needed to paste
   transcripts into other apps.
3. **Pick a model variant** in *Settings → Speech Model* and click
   *Download*. The 1.7B 8-bit model (≈ 2.5 GB) is the default; 0.6B 4-bit
   is half a gig but visibly worse on Chinese/English code-switching.
4. **Pick a download source** if you're outside reliable HuggingFace
   reach. ModelScope is the default and works fine in CN.
5. **Pick an input source** — *BLE device* or *系统麦克风*.
6. If you picked mic mode, **grant the microphone permission** when the
   system prompt appears.

Then hold your PTT trigger (puck button or Control), speak, release. The
transcript will be pasted into whatever app is focused.

---

## Settings overview

| Panel | What it does |
| --- | --- |
| Speech Model | Pick variant (0.6B 4-bit / 1.7B 8-bit), pick download source, kick off / re-do the download. |
| Audio Input | Pick BLE puck or system mic. Mic-mode subpicker chooses a specific input device (built-in mic, AirPods, USB mic, etc.). |
| ASR Prompt | Manage scenario profiles. Each profile is a natural-language context prepended to ASR. |
| Text Input | Read-only view of the most recent transcript. |
| Permissions | Accessibility (for paste) + Microphone (for mic mode). |

---

## Architecture (one minute)

```
┌──────────────┐  BLE GATT  ┌──────────────────┐  AVAudioEngine  ┌──────────┐
│  ESP32 puck  │──────────▶│ BLEVoiceClient    │                 │ Mac mic  │
│  (separate   │   SBC      │ + SBCFrameDecoder │ ◀──────────────│          │
│   repo)      │            └────────┬──────────┘                └─────┬────┘
└──────────────┘                     │                                  │
                                     ▼                                  ▼
                              ┌─────────────────────────────────────────┐
                              │ AppModel  ─►  sessionPCMBuffer            │
                              │              (Int16, mono, 16 kHz)       │
                              └────────┬─────────────────────────────────┘
                                       │
                                       ▼
                              ┌────────────────┐
                              │ LocalASRClient │  Qwen3-ASR via MLX
                              │ (in-process)   │  on Apple Silicon
                              └────────┬───────┘
                                       │
                                       ▼  Cmd+V via CGEvent
                              ┌────────────────┐
                              │  TextInjector  │  pastes into focused app
                              └────────────────┘
```

* **`PTTMacVoiceCore`** — SwiftPM library, all UI + state lives here.
* **`PTTMacVoiceApp`** — CLI executable wrapper for `swift run`.
* **`PTTVoice/PTTVoice.xcodeproj`** — Xcode app target that bundles the
  same library as a proper `.app`.
* **BLE protocol** — GATT service / characteristic UUIDs and packet layout
  are defined in `Sources/PTTMacVoiceCore/BLEVoiceProtocol.swift`. The
  ESP32 firmware that produces these frames is in a separate (currently
  private) repository.

---

## License

[MIT](LICENSE). See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for
included third-party software (notably the AOSP / Open Interface North
America Bluetooth SBC reference decoder, which is Apache 2.0 vendored
under `Sources/LTSBCDecoder/oi/`).

---

## Acknowledgments

* [MLX](https://github.com/ml-explore/mlx) — Apple ML Research's array
  framework that makes on-device LLM/ASR practical on M-series hardware.
* [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) — Alibaba DAMO
  Academy's open-source ASR model used as the recognition engine.
* [aufklarer](https://huggingface.co/aufklarer) — for the MLX-quantized
  Qwen3-ASR weight conversions used here.
* [speech-swift](https://github.com/soniqo/speech-swift) — Swift bindings
  that load and run Qwen3-ASR on MLX.
* [swift-transformers](https://github.com/huggingface/swift-transformers)
  — Hugging Face's tokenizers / Hub client for Swift.
