import AppKit
import CurrentCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var runtime: AppRuntime
    @State private var selection = SettingsSection.general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }.navigationSplitViewColumnWidth(180)
        } detail: {
            Form {
                switch selection {
                case .general: general
                case .audio: audio
                case .transcription: transcription
                case .appearance: appearance
                case .privacy: privacy
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selection.title)
        }
        .onChange(of: runtime.settings.showDockIcon) { _, _ in runtime.applyDockPolicy() }
        .onChange(of: runtime.settings.launchAtLogin) { _, _ in runtime.applyLaunchAtLogin() }
        .onChange(of: runtime.settings.isEnabled) { _, enabled in
            enabled ? runtime.coordinator.startMonitoring() : runtime.coordinator.stopMonitoring()
        }
        .onChange(of: runtime.settings.inputDeviceID) { _, device in runtime.coordinator.audio.selectedDeviceID = device }
        .onChange(of: runtime.settings.continuousContextEnabled) { _, enabled in
            Task {
                if enabled,
                   runtime.settings.isEnabled,
                   runtime.permissions.snapshot().screenRecording.isGranted {
                    try? await runtime.screenContext.start()
                } else {
                    await runtime.screenContext.stop()
                }
            }
        }
    }

    @ViewBuilder private var general: some View {
        Section("Behavior") {
            Toggle("Current enabled", isOn: $runtime.settings.isEnabled)
            Toggle("Launch at login", isOn: $runtime.settings.launchAtLogin)
            Toggle("Show Dock icon", isOn: $runtime.settings.showDockIcon)
            Picker("Fallback shortcut", selection: $runtime.settings.fallbackShortcut) {
                Text("Control–Option–Space").tag("control-option-space")
                Text("Command–Shift–Space").tag("command-shift-space")
                Text("Disabled").tag("disabled")
            }
        }
        Section("Automatic by design") {
            Label("Spacing, punctuation, formatting, and language detection adapt automatically", systemImage: "wand.and.sparkles")
                .foregroundStyle(.secondary)
        }
        Section { Button("Review onboarding and permissions") { runtime.onboarding.show() } }
    }

    @ViewBuilder private var audio: some View {
        Section("Input") {
            Picker("Microphone", selection: $runtime.settings.inputDeviceID) {
                Text("Automatic (preserve media playback)").tag(UInt32(0))
                ForEach(runtime.coordinator.audio.availableInputDevices()) { device in Text(device.name).tag(device.id) }
            }
            LabeledContent("Current level") { ProgressView(value: Double(runtime.coordinator.audio.level)).frame(width: 220) }
            Toggle("Start and stop sounds", isOn: $runtime.settings.soundsEnabled)
        }
    }

    @ViewBuilder private var transcription: some View {
        Section("Local model") {
            LabeledContent("Model", value: "Parakeet TDT 0.6B v3 Multilingual INT8")
            LabeledContent("Engine", value: "FluidAudio / Core ML / Apple Neural Engine")
            LabeledContent("State", value: modelState)
            if case .failed(let reason) = runtime.model.state { Text(reason).foregroundStyle(.red); Button("Retry") { runtime.model.retry() } }
            Button("Remove downloaded model", role: .destructive) {
                Task { try? await runtime.model.removeDownloadedModel() }
            }.disabled(!runtime.model.hasInstalledSnapshot)
        }
        Section {
            Text("German, French, Italian, Spanish, and English are detected automatically. Punctuation and capitalization are processed entirely on this Mac.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var appearance: some View {
        Section("Notch overlay") {
            Toggle("Show recording overlay", isOn: $runtime.settings.overlayEnabled)
            Text("Current follows Reduce Motion and Reduce Transparency automatically.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var privacy: some View {
        Section("Continuous context") {
            Toggle(
                "Keep per-app screen context",
                isOn: $runtime.settings.continuousContextEnabled
            )
            LabeledContent(
                "Capture schedule",
                value: "Every 30 seconds and 3 seconds after typing"
            )
            Label("Accessibility text and on-device OCR are grouped into one Markdown document per app process and day", systemImage: "text.viewfinder")
            Label("Current is excluded; other visible content may include sensitive information", systemImage: "exclamationmark.shield")
                .foregroundStyle(.orange)
            Label("macOS controls whether a screen-capture privacy indicator appears", systemImage: "record.circle")
                .foregroundStyle(.secondary)
        }
        Section("Local processing") {
            Label("Audio is held in memory only", systemImage: "memorychip")
            Label("No network requests occur during dictation", systemImage: "network.slash")
            Label("Successful dictations are saved as local daily context", systemImage: "text.page")
            Label("No analytics or context synchronization", systemImage: "eye.slash")
            Label("Screenshots are discarded after OCR; extracted text and metadata are retained", systemImage: "internaldrive")
            Button("Open Context Library…") { runtime.context.show() }
        }
        Section("Recovery") {
            LabeledContent("Last transcription", value: runtime.coordinator.lastTranscription.isEmpty ? "None" : runtime.coordinator.lastTranscription)
            Button("Clear last transcription", role: .destructive) { runtime.coordinator.clearLastTranscription() }
                .disabled(runtime.coordinator.lastTranscription.isEmpty)
            LabeledContent("Learned corrections", value: "\(runtime.coordinator.vocabulary.entries.count)")
            Button("Forget learned words", role: .destructive) {
                runtime.coordinator.forgetLearnedWords()
            }
            .disabled(runtime.coordinator.vocabulary.entries.isEmpty)
        }
    }

    private var modelState: String {
        switch runtime.model.state {
        case .notInstalled: "Not installed"
        case .downloading(let progress): "Downloading \(Int(progress * 100))%"
        case .verifying: "Verifying"
        case .loading: "Loading"
        case .ready: "Ready"
        case .failed: "Error"
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, audio, transcription, appearance, privacy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .general: "gear"; case .audio: "mic"; case .transcription: "waveform"; case .appearance: "sparkles"; case .privacy: "hand.raised" }
    }
}
