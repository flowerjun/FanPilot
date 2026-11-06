import Foundation
import IOKit

/// Minimal AppleSMC client. Reading works as a normal user; writing requires root.
public final class SMC {
    struct KeyDataVer { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct PLimitData { var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0, pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0 }
    typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    struct KeyData {
        var key: UInt32 = 0
        var vers = KeyDataVer()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    public struct Value {
        public let key: String
        public let type: String
        public let bytes: [UInt8]

        public var double: Double? {
            switch type {
            case "flt ": guard bytes.count >= 4 else { return nil }
                return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
            case "ui8 ": return bytes.first.map(Double.init)
            case "ui16": guard bytes.count >= 2 else { return nil }; return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            case "ui32": guard bytes.count >= 4 else { return nil }
                return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            case "fpe2": guard bytes.count >= 2 else { return nil }; return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
            case "sp78": guard bytes.count >= 2 else { return nil }; return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
            default: return nil
            }
        }
    }

    public enum SMCError: Error { case notFound, open(kern_return_t), call(kern_return_t), smc(UInt8), unsupportedType(String) }

    private var conn: io_connect_t = 0
    private var infoCache: [String: KeyInfo] = [:]   // key type/size never changes; halves IOKit calls

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.notFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess else { throw SMCError.open(kr) }
    }

    deinit { IOServiceClose(conn) }

    private func call(_ input: inout KeyData) throws -> KeyData {
        var output = KeyData()
        var outSize = MemoryLayout<KeyData>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &outSize)
        guard kr == kIOReturnSuccess else { throw SMCError.call(kr) }
        guard output.result == 0 else { throw SMCError.smc(output.result) }
        return output
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    static func string(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
    }

    private func info(_ key: String) throws -> KeyInfo {
        if let cached = infoCache[key] { return cached }
        var input = KeyData(); input.key = Self.fourCC(key); input.data8 = 9
        let ki = try call(&input).keyInfo
        infoCache[key] = ki
        return ki
    }

    public func read(_ key: String) throws -> Value {
        let ki = try info(key)
        var input = KeyData(); input.key = Self.fourCC(key); input.keyInfo.dataSize = ki.dataSize; input.data8 = 5
        let out = try call(&input)
        let all = withUnsafeBytes(of: out.bytes) { Array($0) }
        return Value(key: key, type: Self.string(ki.dataType), bytes: Array(all.prefix(Int(ki.dataSize))))
    }

    public func write(_ key: String, bytes: [UInt8]) throws {
        let ki = try info(key)
        var input = KeyData(); input.key = Self.fourCC(key); input.keyInfo.dataSize = ki.dataSize; input.data8 = 6
        withUnsafeMutableBytes(of: &input.bytes) { buf in
            for (i, b) in bytes.prefix(Int(ki.dataSize)).enumerated() { buf[i] = b }
        }
        _ = try call(&input)
    }

    /// Writes a number in whatever encoding the key uses, so the same call works on every Mac
    /// (Apple Silicon fan keys are `flt `, Intel ones `fpe2`, mode keys `ui8 `/`ui16`).
    public func write(_ key: String, value: Double) throws {
        let type = Self.string(try info(key).dataType)
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
        let bytes: [UInt8]
        switch type {
        case "flt ": bytes = withUnsafeBytes(of: Float(value)) { Array($0) }
        case "fpe2": bytes = be16(UInt16(clamping: Int((value * 4).rounded())))
        case "ui16": bytes = be16(UInt16(clamping: Int(value.rounded())))
        case "ui8 ": bytes = [UInt8(clamping: Int(value.rounded()))]
        default: throw SMCError.unsupportedType(type)
        }
        try write(key, bytes: bytes)
    }

    public func exists(_ key: String) -> Bool { (try? info(key)) != nil }

    public func keyCount() throws -> Int { Int(try read("#KEY").double ?? 0) }

    public func key(at index: Int) throws -> String {
        var input = KeyData(); input.data8 = 8; input.data32 = UInt32(index)
        return Self.string(try call(&input).key)
    }

    public func allKeys() -> [String] {
        guard let n = try? keyCount() else { return [] }
        return (0..<n).compactMap { try? key(at: $0) }
    }
}
