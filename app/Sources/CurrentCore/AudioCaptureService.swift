@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Observation

private final class ConverterInputBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            guard !supplied else { return nil }
            supplied = true
            return buffer
        }
    }
}

final class AudioSampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func reset() {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
    }

    func append(_ chunk: [Float]) {
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    func take() -> [Float] {
        lock.withLock {
            defer { samples.removeAll(keepingCapacity: true) }
            return samples
        }
    }
}

public struct AudioLevelEnvelope: Sendable, Equatable {
    public private(set) var value: Float = 0

    public init() {}

    public static func normalizedLevel(
        rms: Float,
        floorDecibels: Float = -50,
        ceilingDecibels: Float = -8
    ) -> Float {
        guard rms.isFinite, rms > 0, ceilingDecibels > floorDecibels else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floorDecibels) / (ceilingDecibels - floorDecibels)))
    }

    @discardableResult
    public mutating func update(rms: Float) -> Float {
        let target = Self.normalizedLevel(rms: rms)
        let coefficient: Float = target > value ? 0.55 : 0.14
        value += (target - value) * coefficient
        if value < 0.002 { value = 0 }
        return value
    }

    public mutating func reset() {
        value = 0
    }
}

private final class AudioLevelState: @unchecked Sendable {
    private let lock = NSLock()
    private var envelope = AudioLevelEnvelope()
    private var lastPublication: UInt64 = 0
    private let publicationInterval: UInt64 = 16_666_667

    func reset() {
        lock.withLock {
            envelope.reset()
            lastPublication = 0
        }
    }

    func consume(rms: Float, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Float? {
        lock.withLock {
            let value = envelope.update(rms: rms)
            guard lastPublication == 0 || now &- lastPublication >= publicationInterval else { return nil }
            lastPublication = now
            return value
        }
    }
}

@MainActor
@Observable
public final class AudioCaptureService {
    public struct InputDevice: Identifiable, Hashable, Sendable {
        public let id: AudioDeviceID
        public let name: String
        public init(id: AudioDeviceID, name: String) { self.id = id; self.name = name }
    }

    public private(set) var level: Float = 0
    public var selectedDeviceID: AudioDeviceID = 0
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let accumulator = AudioSampleAccumulator()
    @ObservationIgnored private let meterState = AudioLevelState()

    public init() {}

    public func availableInputDevices() -> [InputDevice] {
        inputDeviceIDs().map { id in
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let name else { return InputDevice(id: id, name: "Input \(id)") }
            return InputDevice(id: id, name: name.takeUnretainedValue() as String)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func start() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let resolvedDeviceID = selectedDeviceID == 0 ? automaticInputDeviceID() : selectedDeviceID
        if resolvedDeviceID != 0, let audioUnit = input.audioUnit {
            var device = resolvedDeviceID
            let result = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard result == noErr else { throw CurrentError.noMicrophone }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CurrentError.noMicrophone
        }
        accumulator.reset()
        meterState.reset()
        level = 0
        let tapHandler = Self.makeTapHandler(
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            converter: converter,
            accumulator: accumulator,
            meterState: meterState,
            service: self
        )
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat, block: tapHandler)
        engine.prepare()
        try engine.start()
    }

    nonisolated static func preferredAutomaticInputDeviceID(
        defaultDeviceID: AudioDeviceID,
        defaultTransport: UInt32?,
        builtInDeviceIDs: [AudioDeviceID]
    ) -> AudioDeviceID {
        let bluetoothTransports: Set<UInt32> = [
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
        ]
        guard let defaultTransport,
              bluetoothTransports.contains(defaultTransport),
              let builtIn = builtInDeviceIDs.first else {
            return defaultDeviceID
        }
        return builtIn
    }

    private func automaticInputDeviceID() -> AudioDeviceID {
        let defaultDeviceID = defaultInputDeviceID()
        let builtInDeviceIDs = inputDeviceIDs().filter {
            transportType(for: $0) == kAudioDeviceTransportTypeBuiltIn
        }
        return Self.preferredAutomaticInputDeviceID(
            defaultDeviceID: defaultDeviceID,
            defaultTransport: transportType(for: defaultDeviceID),
            builtInDeviceIDs: builtInDeviceIDs
        )
    }

    private func inputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }
        return ids.filter { id in
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(
                id,
                &streamsAddress,
                0,
                nil,
                &streamSize
            ) == noErr && streamSize > 0
        }
    }

    private func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else {
            return 0
        }
        return deviceID
    }

    private func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        guard deviceID != 0 else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transport
        ) == noErr else {
            return nil
        }
        return transport
    }

    private nonisolated static func makeTapHandler(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter,
        accumulator: AudioSampleAccumulator,
        meterState: AudioLevelState,
        service: AudioCaptureService
    ) -> AVAudioNodeTapBlock {
        { [weak service] buffer, _ in
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            let inputBox = ConverterInputBox(buffer)
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
                guard let input = inputBox.take() else {
                    outputStatus.pointee = .noDataNow
                    return nil
                }
                outputStatus.pointee = .haveData
                return input
            }
            guard status != .error,
                  let channel = converted.floatChannelData?.pointee else { return }
            let count = Int(converted.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            let rms = sqrt(chunk.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(1, count)))
            accumulator.append(chunk)
            guard let level = meterState.consume(rms: rms) else { return }
            Task { @MainActor [weak service] in
                guard let service, service.engine.isRunning else { return }
                service.level = level
            }
        }
    }

    public func stop() -> [Float] {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        meterState.reset()
        level = 0
        return accumulator.take()
    }

    public func cancel() {
        _ = stop()
    }
}
