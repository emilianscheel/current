# Privacy

Current records audio only while dictation is active. Audio is buffered in memory, transcribed on this Mac, and discarded. Transcripts are never uploaded.

Every successful dictation into another application is appended to a local Markdown document for that day under `~/Library/Application Support/Current/Context/`. This includes dictation into sensitive or secure fields. Context remains on this Mac until you edit it or move its document to Trash from the Context window. Dictation directly into Current is not appended a second time.

The last successful transcription also remains in memory for menu-bar recovery until it is cleared or Current quits.

When continuous context is enabled, Current uses macOS Accessibility and short-lived, on-device OCR screenshots. It captures each display every 30 seconds and captures the originating active window three seconds after typing settles or Current inserts text. Extracted visible text and application/window metadata are grouped into one Markdown document per application process and calendar day under `Context/App Sessions/`. Screenshots are held only long enough to detect changes and perform OCR and are never written to disk.

Current's own process is excluded from Accessibility collection, screenshots, and prompt context. Other secure fields, authentication windows, and applications are not intentionally excluded. Anything else visible that macOS exposes may therefore be retained in a context document, including sensitive information. Pause Current or disable continuous context in Settings to stop capture.

Language detection for German, French, Italian, Spanish, and English is performed by the on-device speech model. Apple's on-device Foundation Model classifies spoken intent, maintains app-session documents, and produces prompt-dictation responses from a bounded working set of visible context. No audio, screen context, or generated text is uploaded.

Current requests Microphone access for audio capture, Accessibility access for insertion and semantic context, Screen Recording access for OCR, and Input Monitoring access for the global fn gesture and typing-settled capture scheduling. macOS controls whether a screen-capture privacy indicator is shown. These permissions can be reviewed or revoked at any time in System Settings.
