# Current

> Working title — replace `Current` once the final app name is selected.

Current is a private, local-first dictation app for Apple silicon Macs. Hold the `fn` key, speak naturally, and release it to transcribe the recording and insert the result into the currently focused text field.

Audio and transcription stay on the Mac. The speech model runs locally with Apple Metal acceleration, while a small animated overlay around the MacBook Pro notch provides immediate recording and processing feedback. The app otherwise lives quietly in the menu bar.

## Product goals

- Start listening as soon as the user holds `fn`.
- Transcribe speech locally with low latency and no required account or cloud service.
- Insert text into the active application with minimal interruption.
- Communicate recording state through a calm, unobtrusive notch animation.
- Keep the interface small: a menu bar icon, a compact settings window, and the notch overlay.
- Preserve user privacy by default and avoid retaining audio unless explicitly enabled.

## Core interaction

1. The user focuses a text field in any macOS application.
2. The user presses and holds `fn`.
3. Current begins capturing microphone audio and shows the recording animation around the notch.
4. The user speaks.
5. The user releases `fn`.
6. The overlay switches to a brief processing state while the local model transcribes the audio.
7. Current inserts the transcription at the current cursor position.
8. The overlay confirms success and disappears.

A quick tap of `fn` should not start a recording. Use a configurable hold threshold, with `180 ms` as the default. Pressing `Escape` while recording cancels the current capture.

## Functional requirements

### Global push-to-talk

- Detect `fn` key press and release while Current is in the background.
- Begin capture only after the configured hold threshold.
- Stop capture immediately on release.
- Ignore repeated modifier events generated while the key remains held.
- Support a configurable alternative shortcut for keyboards or workflows where `fn` is unavailable.
- Provide an option to disable the shortcut temporarily.
- Detect and explain conflicts with macOS Dictation or other shortcuts where possible.
- Do not intercept normal `fn` combinations such as `fn` + arrow keys unless the user explicitly enables exclusive behavior.

Implementation note: on macOS, `fn` is exposed as the `secondaryFn` modifier through `flagsChanged` events rather than as a normal character key. A global `CGEventTap` is the preferred low-level implementation. Shortcut handling must be tested with built-in and external keyboards.

### Audio capture

- Capture the selected microphone using `AVAudioEngine`.
- Default to the current macOS input device.
- Allow microphone selection in Settings.
- Convert audio into the model's expected mono PCM format, typically 16 kHz floating-point or 16-bit PCM.
- Buffer audio in memory and pass it to the transcription engine after release.
- Do not save recordings by default.
- Cancel cleanly when audio input is lost or the selected device changes.
- Show a clear error if microphone access is denied.

### Local transcription

- Run entirely on-device on Apple silicon.
- Use a speech-to-text/ASR model with Metal acceleration. A practical initial implementation is `whisper.cpp` with Metal enabled; an MLX-based engine may be evaluated later.
- Bundle a small default model or guide the user through an explicit first-run model download.
- Verify downloaded models with a checksum before loading them.
- Support at least one fast English model for the first release.
- Allow automatic language detection or selection of a fixed language.
- Keep the model warm in memory when practical to reduce startup latency.
- Expose model size, expected memory use, and speed/accuracy trade-offs in Settings.
- Work without an internet connection after installation and model setup.
- Return plain text plus basic punctuation.

Optional post-processing may use a separate local language model to remove filler words, correct punctuation, or apply a writing style. It must be disabled by default in the first release, clearly labeled, and never send text to a remote service.

### Text insertion

- Insert the completed transcription into the currently focused editable control.
- Use the macOS Accessibility API when the target control supports direct text insertion.
- Fall back to placing the text on the pasteboard and synthesizing `Command` + `V` when direct insertion is unavailable.
- Preserve existing text, selection, and cursor placement as the target application permits.
- Add a trailing space only when appropriate and make this behavior configurable.
- Avoid typing character-by-character because it is slower and less reliable.
- Optionally restore the previous pasteboard contents after a safe delay.
- Keep the last transcription available from the menu bar for recovery.
- Never insert partial or empty results.

Secure text fields, Terminal applications, remote desktops, games, and sandboxed apps may restrict insertion. Fail gracefully by copying the result and showing “Copied — paste manually.”

## Notch experience

The overlay should feel like the Mac is quietly listening, not like a separate window has appeared.

### Layout

- Place a borderless, non-activating, transparent panel at the top center of the active display.
- On a MacBook with a notch, wrap the visible animation around the notch rather than drawing over it.
- Begin as a thin, soft capsule that follows the notch's lower corners.
- Expand only a few points downward while recording so it does not cover menu bar content or steal attention.
- On displays without a notch, render the same design as a compact top-center pill.
- Follow the display containing the focused application, with a setting to keep the overlay on the built-in display.
- Respect screen changes, full-screen Spaces, multiple displays, and menu bar auto-hide.

### Animation states

- **Idle:** no overlay is visible.
- **Armed:** after the hold threshold, a soft highlight grows outward from both lower corners of the notch over approximately `120 ms`.
- **Listening:** a low-amplitude waveform or breathing gradient travels symmetrically along the notch edge. Motion responds gently to microphone level without becoming visually noisy.
- **Processing:** the waveform settles into a slow horizontal shimmer or orbiting highlight.
- **Success:** a brief inward pulse confirms insertion, then the overlay fades within approximately `250 ms`.
- **Cancelled:** the glow contracts quickly and fades without a success pulse.
- **Error:** a restrained warm-red pulse appears once, accompanied by a short readable message when action is required.

Use spring-based transitions, maintain stable geometry between states, and avoid sharp jumps. Target display-refresh-rate animation using Core Animation or SwiftUI backed by `CADisplayLink`/`CVDisplayLink` only where needed. Reduce waveform updates when audio levels are unchanged.

The visual treatment should use a dark translucent surface, subtle blur, and one configurable accent color. Avoid bright borders, large text, continuous bouncing, or animations that extend across the menu bar.

### Accessibility

- Honor **Reduce Motion** by replacing waves and shimmer with fades and static level changes.
- Honor **Reduce Transparency** with an opaque high-contrast surface.
- Never rely on color alone to communicate an error.
- Offer optional, quiet sounds for start, stop, success, and failure.
- Provide a setting to disable the overlay while preserving push-to-talk.

## Menu bar app

Current runs as a menu bar app without a persistent Dock icon by default. The menu bar icon should be a simple monochrome waveform, microphone, or speech mark that follows macOS template-image behavior.

The menu should remain compact:

- **Status** — `Ready`, `Listening…`, `Transcribing…`, `Paused`, or a short error state.
- **Start/Stop Listening** — mouse-accessible alternative to the keyboard shortcut.
- **Paste Last Transcription** — inserts or copies the most recent successful result.
- **Copy Last Transcription** — copies the most recent result explicitly.
- **Pause Current** — temporarily disables global shortcut capture.
- **Model** — displays the active model and language; opens model settings.
- **Settings…** — opens the settings window.
- **Permissions…** — shows microphone, Accessibility, and input-monitoring status with buttons to open the relevant System Settings pages.
- **About Current** — version, licenses, privacy statement, and diagnostics location.
- **Quit Current**.

The icon may subtly reflect state: normal when ready, filled/accented while listening, animated sparingly while processing, and crossed out while paused. It must remain legible in light and dark menu bars.

## Settings

Keep settings limited to useful controls:

### General

- Launch at login.
- Show or hide the Dock icon.
- Enable/disable Current.
- Hold threshold.
- Primary push-to-talk shortcut and fallback shortcut.
- Insert a trailing space.
- Restore previous clipboard contents.

### Audio

- Input device.
- Input-level meter.
- Optional start/stop sounds.
- Minimum and maximum recording duration.

### Transcription

- Installed model and model manager.
- Language or automatic detection.
- Accuracy/speed preset.
- Optional filler-word removal and punctuation cleanup when a local post-processor is available.

### Appearance

- Accent color.
- Notch overlay enabled.
- Animation intensity.
- Overlay display preference.

### Privacy

- Confirm that processing is local.
- Retain no audio by default.
- Clear last transcription.
- Clear local history if an optional history feature is enabled later.
- Remove downloaded models.

## macOS permissions

Current should request permissions only when the related feature is first used and explain why before macOS displays its system prompt.

- **Microphone:** required to record speech.
- **Accessibility:** required to insert text into other applications and synthesize paste as a fallback.
- **Input Monitoring:** may be required for reliable global `fn` detection, depending on the final event-tap implementation and distribution model.

The app must continue to open if a permission is denied. Its menu should show the missing permission and offer a direct path to the appropriate System Settings pane. Revoked permissions must be detected without requiring a reinstall.

## Technical direction

### Platform

- macOS 14 Sonoma or later.
- Apple silicon (`arm64`) only for the initial release.
- MacBook Pro with a display notch for the full visual experience; all other supported Macs use the top-center pill fallback.
- Native Swift implementation using SwiftUI for settings and AppKit where window level, event handling, or focus behavior requires it.

### Suggested components

| Component                | Responsibility                                                  |
| ------------------------ | --------------------------------------------------------------- |
| `AppCoordinator`         | App lifecycle, menu bar state, startup, and permissions         |
| `ShortcutMonitor`        | Global `fn` and fallback-shortcut press/release detection       |
| `AudioCaptureService`    | Microphone selection, level metering, buffering, and conversion |
| `TranscriptionService`   | Model lifecycle, Metal inference, language, and cancellation    |
| `InsertionService`       | Accessibility insertion, pasteboard fallback, and recovery      |
| `NotchOverlayController` | Screen geometry, overlay panel, and animation state             |
| `SettingsStore`          | Persisted preferences and defaults                              |
| `ModelManager`           | Model download/import, validation, storage, and removal         |
| `PermissionManager`      | Permission status, prompts, and System Settings links           |

### State flow

```text
Idle → Armed → Recording → Transcribing → Inserting → Success → Idle
                    ↘ Cancelled/Error ─────────────────────────→ Idle
```

Only one dictation session may run at a time. Every session should have an identifier so stale transcription callbacks cannot insert text after a cancellation or a newer recording.

### Performance targets

- Recording feedback visible within `100 ms` after the hold threshold.
- Audio capture begins without waiting for the animation.
- Release-to-result latency below `1.5 s` for a typical short English phrase on a recent MacBook Pro using the recommended default model.
- UI remains responsive during inference.
- No sustained CPU use while idle beyond global event monitoring.
- No network requests during dictation.
- Memory use should be documented per model and released when the user pauses the engine or changes models.

These are product targets and must be measured on each supported chip generation rather than assumed.

## Privacy and security

- Audio, transcripts, and model inference remain on-device.
- No analytics, crash uploads, or update checks without explicit disclosure and consent.
- Recordings are memory-only by default and discarded after transcription or cancellation.
- The last transcription is held only as long as needed for recovery and can be cleared from the menu.
- Avoid logging audio, full transcripts, pasteboard contents, or names of target documents.
- Store preferences with `UserDefaults`; store secrets, if any are introduced, in Keychain.
- Display third-party model and library licenses in the app and repository.
- Sign and notarize release builds. Use Hardened Runtime and the narrowest practical entitlements.

## Error handling

Provide short, actionable messages for:

- Microphone, Accessibility, or Input Monitoring permission denied.
- No microphone or disconnected input device.
- Model missing, invalid, incompatible, or out of memory.
- Recording too short or no speech detected.
- Transcription cancelled or failed.
- No editable field available for insertion.
- Secure field or target application rejected insertion.

Errors must not leave the microphone active, the overlay visible, or the keyboard shortcut stuck in a pressed state.

## First-run experience

1. Briefly explain: “Hold `fn`, speak, release to type.”
2. Explain and request microphone access.
3. Explain and request Accessibility access.
4. Check whether Input Monitoring is required and request it only if necessary.
5. Install or select the local transcription model, showing download size and storage use.
6. Run a short practice dictation into a built-in sample text field.
7. Offer launch-at-login and sound preferences.

The user should always be able to revisit onboarding and permission checks from the menu bar.

## Acceptance criteria for the first release

- Holding and releasing `fn` reliably records one utterance across supported MacBook keyboards.
- A fallback shortcut works on external keyboards.
- Spoken English is transcribed locally with Metal acceleration and without a network connection.
- Results insert correctly into common native and web text fields in Safari, Notes, Mail, Messages, Xcode, and popular Chromium-based applications.
- The notch overlay accurately represents armed, listening, processing, success, cancellation, and error states.
- The fallback pill works on a non-notched or external display.
- The app requests only necessary permissions and remains usable enough to repair denied permissions.
- Cancelling never inserts text, and rapid repeated sessions never insert an older result.
- Audio is not written to disk under default settings.
- The menu bar exposes status, pause, last-result recovery, settings, permissions, and quit controls.
- Reduce Motion and Reduce Transparency settings are respected.
- The app recovers from sleep/wake, display changes, microphone changes, and model errors.

## Testing requirements

- Unit tests for shortcut state transitions, hold threshold, cancellation, text spacing, model state, and stale-session rejection.
- Integration tests for microphone capture and transcription with fixed local audio fixtures.
- Accessibility insertion tests against representative AppKit, SwiftUI, WebKit, and Chromium text controls.
- Manual keyboard tests on built-in MacBook keyboards and at least one external Apple keyboard.
- Multi-display tests with and without a notch, full-screen apps, Spaces, and menu bar auto-hide.
- Permission tests for first request, denial, later approval, and revocation.
- Performance benchmarks per supported Apple chip and model size.
- Offline tests with networking disabled.
- Long-session, rapid-repeat, sleep/wake, and memory-pressure tests.

## Out of scope for the first release

- Cloud transcription or account synchronization.
- Team accounts or shared dictionaries.
- A full transcript history interface.
- Continuous meeting transcription.
- Speaker diarization.
- Voice commands that control other applications.
- Windows, Linux, or Intel Mac support.
- Training or fine-tuning models inside the app.

## Suggested delivery phases

1. **Input prototype:** reliable `fn` lifecycle, audio capture, and permission flow.
2. **Local transcription:** integrate and benchmark the Metal-accelerated ASR engine.
3. **Insertion:** Accessibility-first insertion with pasteboard fallback.
4. **Notch UI:** implement screen geometry, animation states, and accessibility variants.
5. **Menu and settings:** add model, audio, shortcut, appearance, and privacy controls.
6. **Hardening:** test application compatibility, cancellation races, sleep/wake, packaging, signing, and notarization.

## License

License to be selected. Third-party code and model licenses must be reviewed before distribution.
