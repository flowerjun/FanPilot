import Foundation

/// One fan's live state.
public struct FanReading: Codable, Equatable {
    public var rpm: Double?
    public var min: Double
    public var max: Double
    public var manual: Bool
}

public struct Readings: Codable, Equatable {
    public var cpuAverage: Double?
    public var gpuAverage: Double?
    /// Average RPM over all fans (the single fan's RPM on one-fan Macs).
    public var fanRPM: Double?
    /// Fan 0's hardware range; curves and CONSTANT are expressed in fan 0's RPM.
    public var fanMin: Double = 1000
    public var fanMax: Double = 4900
    /// True if any fan is in manual mode.
    public var manual: Bool = false
    /// Every fan, in SMC order. Optional so status files from older daemons still decode.
    public var fans: [FanReading]?

    public init() {}

    public func temperature(for source: TempSource) -> Double? {
        source == .cpuAverage ? cpuAverage : gpuAverage
    }
}

/// Fan control keys differ by Mac, so they're discovered from what the SMC actually has:
/// - M1–M4 and Intel (T2): per-fan mode key F{i}Md.
/// - M5: the same key renamed F{i}md.
/// - Older Intel: no per-fan key; bit i of the `FS! ` mask puts fan i in manual mode.
/// - M3/M4 laptops also need `Ftst` = 1 before macOS lets go of the fans.
/// - Fanless Macs (MacBook Air) report no fans at all.
public struct FanKeys {
    public let count: Int
    /// Mode key per fan (0 = macOS, 1 = manual); nil means the fan is driven through `FS! `.
    public let mode: [String?]
    /// Present only on Macs that need it; written 1 before taking the fans, 0 when handing them back.
    public let unlock: String?
    static let forceMask = "FS! "

    public init(smc: SMC) {
        count = Int((try? smc.read("FNum").double) ?? 0)
        mode = (0..<count).map { i in ["F\(i)Md", "F\(i)md"].first(where: smc.exists) }
        unlock = smc.exists("Ftst") ? "Ftst" : nil
    }

    public var hasFans: Bool { count > 0 }

    public func isManual(_ smc: SMC, fan i: Int) -> Bool {
        if let key = mode[i] { return (try? smc.read(key).double) == 1 }
        return (Int((try? smc.read(Self.forceMask).double) ?? 0) >> i) & 1 == 1
    }

    public func setManual(_ smc: SMC, fan i: Int, _ on: Bool) throws {
        if let key = mode[i] { try smc.write(key, value: on ? 1 : 0); return }
        let mask = Int(try smc.read(Self.forceMask).double ?? 0)
        try smc.write(Self.forceMask, value: Double(on ? mask | 1 << i : mask & ~(1 << i)))
    }
}

/// Apple Silicon (M1–M5) sensor layout: Tp*/Te* = CPU performance/efficiency cores, Tg* = GPU.
/// Intel Macs use TC* (CPU) and TG* (GPU) instead; those are the fallback when the others are absent.
public final class Sensors {
    private let smc: SMC
    private let cpuKeys: [String]
    private let gpuKeys: [String]
    /// Per-fan hardware limits; they never change, so they're read once.
    public let fanLimits: [(min: Double, max: Double)]
    public let fanKeys: FanKeys
    // Idle cores occasionally report near-zero or very low values all at once, which drags a
    // single average down by 10 °C+ for one tick. A median of the last three averages removes
    // such one-tick spikes; a real change gets through one tick (2 s) later.
    private var cpuRecent: [Double] = []
    private var gpuRecent: [Double] = []

    public init(smc: SMC) {
        self.smc = smc
        let temps = smc.allKeys().filter { $0.hasPrefix("T") && ["flt ", "sp78"].contains((try? smc.read($0).type) ?? "") }
        func pick(_ primary: [String], _ fallback: [String]) -> [String] {
            let keys = temps.filter { k in primary.contains { k.hasPrefix($0) } }
            return keys.isEmpty ? temps.filter { k in fallback.contains { k.hasPrefix($0) } } : keys
        }
        cpuKeys = pick(["Tp", "Te"], ["TC"])
        gpuKeys = pick(["Tg"], ["TG"])
        fanKeys = FanKeys(smc: smc)
        fanLimits = (0..<fanKeys.count).map { i in
            ((try? smc.read("F\(i)Mn").double) ?? 1000, (try? smc.read("F\(i)Mx").double) ?? 4900)
        }
    }

    private func average(_ keys: [String]) -> Double? {
        // Unpopulated sensors report 0; ignore anything outside a plausible range.
        var sum = 0.0, count = 0
        for key in keys {
            guard let v = try? smc.read(key).double, v > 5, v < 150 else { continue }
            sum += v; count += 1
        }
        // 0.1 °C is all anything displays or decides on; rounding keeps readings stable so
        // consumers can skip work when nothing meaningful changed.
        return count == 0 ? nil : (sum / Double(count) * 10).rounded() / 10
    }

    private static func median3(_ recent: inout [Double], _ new: Double?) -> Double? {
        guard let new else { return nil }
        recent.append(new)
        if recent.count > 3 { recent.removeFirst() }
        return recent.count < 3 ? new : recent.sorted()[1]
    }

    public func read() -> Readings {
        var r = Readings()
        r.cpuAverage = Self.median3(&cpuRecent, average(cpuKeys))
        r.gpuAverage = Self.median3(&gpuRecent, average(gpuKeys))
        let fans = fanLimits.enumerated().map { i, lim in
            FanReading(rpm: (try? smc.read("F\(i)Ac").double)?.rounded(), min: lim.min, max: lim.max,
                       manual: fanKeys.isManual(smc, fan: i))
        }
        let rpms = fans.compactMap(\.rpm)
        r.fanRPM = rpms.isEmpty ? nil : (rpms.reduce(0, +) / Double(rpms.count)).rounded()
        if let first = fanLimits.first { r.fanMin = first.min; r.fanMax = first.max }
        r.manual = fans.contains { $0.manual }
        r.fans = fans   // empty on a fanless Mac
        return r
    }
}
