# Privacy

Current records audio only while dictation is active. Audio is buffered in memory, transcribed on this Mac, and discarded. Transcripts are never uploaded.

Every successful dictation into another application is appended to a local Markdown document for that day under `~/Library/Application Support/Current/Context/`. This includes dictation into sensitive or secure fields. Context remains on this Mac until you edit it or move its document to Trash from the Context window. Dictation directly into Current is not appended a second time.

The last successful transcription also remains in memory for menu-bar recovery until it is cleared or Current quits.

When continuous context is enabled, Current first reads semantic text exposed by macOS Accessibility. Every 30 seconds it refreshes visible windows and takes a short-lived screenshot only of windows that do not expose enough useful Accessibility text. It performs the same Accessibility-first check three seconds after typing settles or Current inserts text. Extracted visible text and application/window metadata are grouped into one Markdown document per application process and calendar day under `Context/App Sessions/`. Screenshots are held only long enough to detect changes and perform on-device OCR and are never written to disk.

Current's own process is excluded from Accessibility collection, screenshots, and prompt context. Other secure fields, authentication windows, and applications are not intentionally excluded. Anything else visible that macOS exposes may therefore be retained in a context document, including sensitive information. Pause Current or disable continuous context in Settings to stop capture.

Language detection for German, French, Italian, Spanish, and English is performed by the on-device Parakeet speech model. Gemma 4 E2B IT 4-bit structures captured Accessibility and OCR text into concise app-session bullets through MLX Swift on the Apple GPU and unified memory. MLX Swift is distributed under Apache License 2.0; Gemma is provided under Google's Gemma Terms of Use. Apple's on-device Foundation Model classifies spoken intent and produces prompt-dictation responses from a bounded working set of visible context. Parakeet and Gemma are downloaded from their model hosts during setup; inference does not upload audio, screen context, or generated text.

Current requests Microphone access for audio capture, Accessibility access for insertion and semantic context, Screen Recording access for OCR, and Input Monitoring access for the global fn gesture and typing-settled capture scheduling. macOS controls whether a screen-capture privacy indicator is shown. These permissions can be reviewed or revoked at any time in System Settings.
