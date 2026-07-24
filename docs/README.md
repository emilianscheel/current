# Current

Current is a private, local-first dictation utility for recent Apple-silicon MacBooks. Hold `fn`, speak, and release: Current records into memory, transcribes with the Apple Neural Engine, and inserts the result into the field you were using.

It is a native menu-bar app. There is no account, cloud transcription, transcript history, or analytics service.

## Supported Macs

| Requirement | Supported configuration |
| --- | --- |
| Operating system | macOS 26 or newer |
| Architecture | Apple silicon (`arm64`) only |
| Chip | Apple M3, M4, M5, or newer |
| Unified memory | 16 GiB or more |
| Display | Notched MacBook displays receive the attached notch treatment; other displays use a top-center island |

Current checks these requirements before starting its capture and model services. Unsupported systems receive an explanatory window.

## How it works

1. Focus any editable field.
2. Hold `fn` for at least 180 ms. A quick tap is ignored.
3. Speak while the notch island shows the live waveform.
4. Release `fn` to transcribe and insert.
5. Press Escape while recording to cancel.

The event tap never suppresses `fn` events and abandons a pending recording if another key is pressed, preserving normal combinations such as `fn` + arrow keys. It suppresses only the configured fallback shortcut’s Space event. The menu bar also provides mouse-driven Start/Stop actions and recovery actions for the last result.

## On-device model

Current uses **Parakeet TDT 0.6B v3 Multilingual Core ML** with the INT8 encoder through [FluidAudio](https://github.com/FluidInference/FluidAudio). It automatically detects German, French, Italian, Spanish, or English for each dictation and includes punctuation and capitalization. The underlying model supports 25 European languages; these five are Current's supported product languages.

The upstream model reports FLEURS WER of 5.04% German, 5.15% French, 3.00% Italian, 3.45% Spanish, and 4.85% English. FluidAudio's Core ML benchmark reports approximately 210× overall real-time throughput on an M4 Pro across the complete 25-language FLEURS evaluation. See the [NVIDIA model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and [FluidAudio benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md) for methodology. Real app latency depends on utterance length, model warmth, chip, and memory pressure.

The model downloads automatically during onboarding and is cached by FluidAudio. Current verifies local model files before use and keeps the loaded model warm while enabled. Dictation itself never requires the network.

Licensing:

- FluidAudio: Apache License 2.0
- Parakeet TDT 0.6B v3 Multilingual Core ML: CC BY 4.0

Attributions are included in `app/Licenses/NOTICE.md` and the app’s About panel.

## First launch and permissions

On first launch, or whenever a required permission is missing, Current opens a SwiftUI onboarding window. The model begins downloading immediately while the user completes these steps:

1. Local-processing and hardware overview
2. Microphone
3. Accessibility
4. Input Monitoring
5. One required restart
6. Model readiness
7. Practice dictation
8. Launch-at-login and sound preferences

Current polls permission state and automatically advances when a grant is detected. Permission pages link directly to the corresponding Privacy & Security pane.

| Permission | Why Current needs it | Runtime check |
| --- | --- | --- |
| Microphone | Capture speech while dictating | `AVCaptureDevice.authorizationStatus(for: .audio)` |
| Accessibility | Replace selected text or synthesize paste | `AXIsProcessTrusted()` |
| Input Monitoring | Receive global `secondaryFn` modifier events | `CGPreflightListenEventAccess()` |

macOS requires Current to restart after Input Monitoring is enabled. A bundled helper waits for the existing process to exit and reopens the same installed bundle. The onboarding step and model cache survive that restart.

Denied or revoked permissions never prevent the menu from opening. Choose **Permissions & Onboarding…** to repair access.

## Privacy

- Audio is buffered as 16 kHz mono Float32 in memory and discarded after transcription or cancellation.
- Audio and transcripts are not logged.
- No analytics, crash upload, account, update check, or cloud inference is included.
- The last successful result is held in memory for recovery and can be cleared from Settings.
- Accessibility insertion is attempted first. If the target rejects it, Current uses a temporary pasteboard and Command-V; when configured, it restores the previous pasteboard after a short delay.
- Secure or inaccessible controls fall back to **Copied — paste manually**.

## Tech stack

- Swift 6.2 and Swift Package Manager
- SwiftUI and Observation for onboarding/settings
- AppKit for menu-bar lifecycle, nonactivating panels, and focus behavior
- CoreGraphics `CGEventTap` for global `fn` events
- AVFoundation / `AVAudioEngine` / `AVAudioConverter` for capture and resampling
- macOS Accessibility API plus CoreGraphics paste fallback
- Core ML and Apple Neural Engine inference through FluidAudio 0.15.5
- ServiceManagement `SMAppService` for launch at login
- Swift Testing for core behavior
- Hardened Runtime with the audio-input entitlement; App Sandbox is intentionally not enabled because Current must manipulate focused controls in other applications

The coordinator owns a single session-tagged state flow:

```text
Idle → Armed → Recording → Transcribing → Inserting → Success → Idle
                    ↘ Cancelled / Error ───────────────→ Idle
```

Every asynchronous transcription is matched against its session UUID before insertion, so a cancelled or superseded result cannot type later.

## Repository layout

```text
README.md                        Product, setup, architecture, and troubleshooting guide
app/Package.swift                SwiftPM products and pinned FluidAudio dependency
app/Sources/CurrentCore/         Capture, shortcut, model, insertion, settings, coordinator
app/Sources/Current/             App lifecycle, menu, onboarding, settings, notch overlay
app/Sources/CurrentRelauncher/   Permission-restart helper
app/Packaging/                   Info.plist and signing entitlements
app/Assets/                      Editable SVG artwork and deterministic app-icon renditions
app/Tests/CurrentCoreTests/      State, hardware, permission, and insertion tests
app/build-install-restart.sh     Test, build, sign, install, and relaunch workflow
```

## Build, install, and restart

The supported development loop is:

```sh
./app/build-install-restart.sh
```

To validate compilation and bundle assembly without changing Keychain, installing, or launching anything:

```sh
./app/build-install-restart.sh --assemble-only
```

The script:

1. Validates arm64, macOS 26+, Swift, and code-signing tools.
2. Runs the test suite.
3. Builds optimized arm64 executables.
4. Deterministically renders the app icon and assembles `Current.app`.
5. Signs with Hardened Runtime.
6. Gracefully stops the old copy, installs to `~/Applications/Current.app`, verifies the signature, and relaunches it.

It never calls `tccutil`, resets UserDefaults, or removes model data.

### Stable local signing

macOS TCC permissions are tied to the responsible code’s signing identity, bundle identifier, and location. Rebuilding with ad-hoc signatures commonly makes macOS treat each build as a new app.

The script therefore prefers an existing **Apple Development** identity, including a Personal Team identity. If none exists, it creates a long-lived **Current Local Development** certificate in the login Keychain and limits its trust purpose to code signing. The first setup can display a Keychain confirmation. Later builds reuse that identity.

Changing the signing identity, `local.Current` bundle identifier, or installation path requires granting permissions once again. The script intentionally does not hide or work around that macOS security behavior.

## Manual development commands

```sh
cd app
swift test
swift build -c release --arch arm64
swift scripts/generate-icon.swift
```

Running the raw SwiftPM executable is not recommended for permission testing because it is not the consistently signed installed app bundle.

## Settings

- General: enable/pause, launch at login, Dock visibility, hold threshold, and configurable fallback shortcut
- Insertion: trailing space and clipboard restoration
- Audio: input-device selection, live microphone level, sounds, recording limits
- Transcription: model and engine status
- Appearance: notch overlay and animation intensity
- Privacy: local-processing summary and last-result clearing

The solid-black overlay follows Reduce Motion, joins all Spaces, can appear beside full-screen applications, ignores mouse input, and falls back to a centered island when a display has no notch safe area. All Current windows otherwise follow the active macOS light or dark appearance.

## Tests and acceptance checks

Automated tests cover:

- quick `fn` taps, held presses, repeats, chords, release, and Escape
- M3+/16 GiB hardware gating and future M-generation parsing
- permission snapshots and missing-permission ordering
- deterministic text trimming and trailing-space behavior
- session-safe coordinator boundaries and model-file SHA-256 support

Before release, manually test:

- Safari, Chromium, Notes, Mail, Messages, Xcode, Terminal, and secure fields
- built-in and external Apple keyboards
- a notched display plus a non-notched external display
- full-screen apps, Spaces, menu-bar auto-hide, sleep/wake, and microphone changes
- first request, denial, later approval, revocation, and Input Monitoring restart
- two consecutive runs of `app/build-install-restart.sh` with permissions and settings preserved
- offline dictation after model setup
- automatic detection and transcription of German, French, Italian, Spanish, and English
- consecutive dictations in different supported languages
- M3 Pro cold/warm model load, peak memory, and short-phrase release-to-result latency

Targets are feedback within 100 ms after the hold threshold, no sustained idle work beyond the event tap, and warm release-to-result below 1.5 seconds for a typical short phrase on the reference M3 Pro MacBook.

## Known platform limits

Some secure controls, Terminal configurations, games, remote desktops, and sandboxed applications restrict Accessibility replacement or synthetic paste. Current keeps the result on the clipboard when insertion is unavailable.

The first Core ML load can take longer while macOS compiles models for the Neural Engine. Later loads use the system cache.

## Out of scope for v1

- Mid-utterance code switching guarantees
- Cloud transcription or accounts
- Transcript history UI or synchronization
- Meeting transcription and speaker diarization
- Local LLM rewriting or filler-word removal
- Voice commands and automation
- Intel, Windows, Linux, or pre-M3 support

## Distribution

The current workflow is for direct local development. A public build should use a stable Developer ID Application certificate, include the same narrow entitlements, archive third-party license text, and be notarized. Switching from the local certificate to Developer ID is an intentional one-time signing-identity change and therefore requires permissions to be granted again.
