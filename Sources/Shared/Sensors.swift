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

/// Apple Silicon sensor layout: Tp*/Te* = CPU performance/efficiency cores, Tg* = GPU.
public final class Sensors {
    private let smc: SMC
    private let cpuKeys: [String]
    private let gpuKeys: [String]
    /// Per-fan hardware limits; they never change, so they're read once.
    public let fanLimits: [(min: Double, max: Double)]
    // Idle cores occasionally report near-zero or very low values all at once, which drags a
    // single average down by 10 °C+ for one tick. A median of the last three averages removes
    // such one-tick spikes; a real change gets through one tick (2 s) later.
    private var cpuRecent: [Double] = []
    private var gpuRecent: [Double] = []

    public init(smc: SMC) {
        self.smc = smc
        let temps = smc.allKeys().filter { $0.hasPrefix("T") && (try? smc.read($0).type) == "flt " }
        cpuKeys = temps.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }
        gpuKeys = temps.filter { $0.hasPrefix("Tg") }
        let count = max(1, Int((try? smc.read("FNum").double) ?? 1))
        fanLimits = (0..<count).map { i in
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
                       manual: (try? smc.read("F\(i)Md").double) == 1)
        }
        let rpms = fans.compactMap(\.rpm)
        r.fanRPM = rpms.isEmpty ? nil : (rpms.reduce(0, +) / Double(rpms.count)).rounded()
        r.fanMin = fanLimits[0].min
        r.fanMax = fanLimits[0].max
        r.manual = fans.contains { $0.manual }
        r.fans = fans
        return r
    }
}
