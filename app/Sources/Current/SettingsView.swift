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
    }

    @ViewBuilder private var general: some View {
        Section("Behavior") {
            Toggle("Current enabled", isOn: $runtime.settings.isEnabled)
            Toggle("Launch at login", isOn: $runtime.settings.launchAtLogin)
            Toggle("Show Dock icon", isOn: $runtime.settings.showDockIcon)
            LabeledContent("Hold fn threshold") {
                HStack { Slider(value: $runtime.settings.holdThresholdMilliseconds, in: 100...500, step: 10); Text("\(Int(runtime.settings.holdThresholdMilliseconds)) ms").monospacedDigit() }.frame(width: 280)
            }
            Picker("Fallback shortcut", selection: $runtime.settings.fallbackShortcut) {
                Text("Control–Option–Space").tag("control-option-space")
                Text("Command–Shift–Space").tag("command-shift-space")
                Text("Disabled").tag("disabled")
            }
        }
        Section("Insertion") {
            Toggle("Add a trailing space", isOn: $runtime.settings.trailingSpace)
            Toggle("Restore previous clipboard", isOn: $runtime.settings.restoreClipboard)
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
        Section("Recording limits") {
            LabeledContent("Minimum") { TextField("Seconds", value: $runtime.settings.minimumRecordingDuration, format: .number).frame(width: 80) }
            LabeledContent("Maximum") { TextField("Seconds", value: $runtime.settings.maximumRecordingDuration, format: .number).frame(width: 80) }
        }
    }

    @ViewBuilder private var transcription: some View {
        Section("Local model") {
            LabeledContent("Model", value: "Parakeet Unified English 0.6B INT8")
            LabeledContent("Engine", value: "FluidAudio / Core ML / Apple Neural Engine")
            LabeledContent("State", value: modelState)
            if case .failed(let reason) = runtime.model.state { Text(reason).foregroundStyle(.red); Button("Retry") { runtime.model.retry() } }
            Button("Remove downloaded model", role: .destructive) {
                Task { try? await runtime.model.removeDownloadedModel() }
            }.disabled(!runtime.model.hasInstalledSnapshot)
        }
        Section { Text("English, punctuation, and capitalization are processed entirely on this Mac.").foregroundStyle(.secondary) }
    }

    @ViewBuilder private var appearance: some View {
        Section("Notch overlay") {
            Toggle("Show recording overlay", isOn: $runtime.settings.overlayEnabled)
            LabeledContent("Animation intensity") { Slider(value: $runtime.settings.animationIntensity, in: 0...1).frame(width: 240) }
            Text("Current follows Reduce Motion and Reduce Transparency automatically.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var privacy: some View {
        Section("Local by design") {
            Label("Audio is held in memory only", systemImage: "memorychip")
            Label("No network requests occur during dictation", systemImage: "network.slash")
            Label("No analytics or transcript logging", systemImage: "eye.slash")
        }
        Section("Recovery") {
            LabeledContent("Last transcription", value: runtime.coordinator.lastTranscription.isEmpty ? "None" : runtime.coordinator.lastTranscription)
            Button("Clear last transcription", role: .destructive) { runtime.coordinator.clearLastTranscription() }
                .disabled(runtime.coordinator.lastTranscription.isEmpty)
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
