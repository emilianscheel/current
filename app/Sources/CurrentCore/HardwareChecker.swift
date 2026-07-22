import Darwin
import Foundation

public protocol HardwareChecking: Sendable {
    func current() -> HardwareSupport
}

public struct HardwareChecker: HardwareChecking {
    public init() {}

    public func current() -> HardwareSupport {
        let brand = sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "Unknown Mac"
        let arm = sysctlInt("hw.optional.arm64") == 1
        let memory = UInt64(max(0, sysctlInt64("hw.memsize")))
        return HardwareSupport(
            isAppleSilicon: arm,
            generation: Self.appleSiliconGeneration(from: brand),
            memoryBytes: memory,
            modelName: brand
        )
    }

    public static func appleSiliconGeneration(from value: String) -> Int? {
        guard let range = value.range(of: #"\bM(\d+)\b"#, options: .regularExpression) else { return nil }
        return Int(value[range].dropFirst())
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func sysctlInt(_ name: String) -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        _ = sysctlbyname(name, &value, &size, nil, 0)
        return value
    }

    private func sysctlInt64(_ name: String) -> Int64 {
        var value: Int64 = 0
        var size = MemoryLayout.size(ofValue: value)
        _ = sysctlbyname(name, &value, &size, nil, 0)
        return value
    }
}
