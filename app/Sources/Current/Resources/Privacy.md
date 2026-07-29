# Privacy

Current records audio only while dictation is active. Audio is buffered in memory, transcribed on this Mac, and discarded. Transcripts are never uploaded.

Every successful dictation into another application is appended to a local Markdown document for that day under `~/Library/Application Support/Current/Context/`. This includes dictation into sensitive or secure fields. Context remains on this Mac until you edit it or move its document to Trash from the Context window. Dictation directly into Current is not appended a second time.

The last successful transcription also remains in memory for menu-bar recovery until it is cleared or Current quits.

Current keeps daily estimates of its own CPU and memory usage, including its on-device context worker, and successful-transcription counts under `~/Library/Application Support/Current/Usage/`. These local aggregates are used only by the Usage Statistics window and are automatically removed after 30 days.

When continuous context is enabled, Current records activity only for applications used within the last five minutes. After the Mac has been idle for at least two seconds, it refreshes one application at a time with at least ten seconds between jobs. Current first reads semantic text exposed by macOS Accessibility and takes a short-lived screenshot only when the relevant window does not expose enough useful text. Typing and Current insertions become eligible after three seconds. Extracted visible text and application/window metadata are grouped into one Markdown document per application process and calendar day under `Context/App Sessions/`. Screenshots are held only long enough to detect changes and perform on-device OCR and are never written to disk.

Current, its context worker, Dock, Control Center, and SystemUIServer are excluded from activity tracking, Accessibility collection, screenshots, search, and prompt context. Other secure fields, authentication windows, and applications are not intentionally excluded. Anything else visible that macOS exposes may therefore be retained in a context document, including sensitive information. Pause Current or disable continuous context in Settings to stop capture.

Language detection for German, French, Italian, Spanish, and English is performed by the on-device Parakeet speech model. Vision OCR and Gemma structuring execute serially in Current's embedded context-worker process at background quality of service. Gemma 4 E2B IT 4-bit structures captured Accessibility and OCR text into concise app-session bullets through MLX Swift on the Apple GPU and unified memory. MLX Swift is distributed under Apache License 2.0; Gemma is provided under Google's Gemma Terms of Use. Apple's on-device Foundation Model classifies spoken intent and produces prompt-dictation responses from a bounded working set of visible context. Parakeet and Gemma are downloaded from their model hosts during setup; inference does not upload audio, screen context, or generated text.

Current requests Microphone access for audio capture, Accessibility access for insertion and semantic context, Screen Recording access for OCR, and Input Monitoring access for the global fn gesture and typing-settled capture scheduling. macOS controls whether a screen-capture privacy indicator is shown. These permissions can be reviewed or revoked at any time in System Settings.
