import Foundation

public enum FanMode: String, Codable, CaseIterable {
    case system   // macOS firmware controls the fan
    case curve    // temperature-based steps
    case fixed    // constant RPM
}

public enum TempSource: String, Codable, CaseIterable {
    case cpuAverage
    case gpuAverage
}

public struct CurveStep: Codable, Hashable {
    public var minTemp: Double   // applies when temperature >= minTemp
    public var rpm: Double
    public init(minTemp: Double, rpm: Double) { self.minTemp = minTemp; self.rpm = rpm }
}

public struct FanConfig: Codable, Equatable {
    public var mode: FanMode = .curve
    /// Which temperature the menu bar shows (and colors by). Fan control uses both curves.
    public var source: TempSource = .cpuAverage
    /// CPU curve. (Kept as `steps` so configs from before the GPU curve still load.)
    public var steps: [CurveStep] = FanConfig.defaultSteps
    public var gpuSteps: [CurveStep] = FanConfig.defaultSteps
    public var useCPU = true
    public var useGPU = true
    public var baseRPM: Double = 1500          // below the lowest step of every enabled curve
    public var fixedRPM: Double = 2500
    public var hysteresis: Double = 3          // °C to fall below a step before stepping down
    public var emergencyTemp: Double = 105     // any mode except system: go to max RPM
    /// Interpolate between steps instead of jumping from one step's RPM to the next.
    public var smooth = false
    /// When set, the daemon hands the fan back to macOS at this time (timed CUSTOM/CONSTANT).
    public var revertAt: Date?

    public static let defaultSteps = [
        CurveStep(minTemp: 100, rpm: 4000),
        CurveStep(minTemp: 90, rpm: 3000),
        CurveStep(minTemp: 80, rpm: 2500),
    ]

    public init() {}

    /// Missing keys take their defaults, so older config files keep working. (The synthesized
    /// decoder would reject them, and the daemon treats an unreadable config as "go to system".)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanConfig()
        mode = try c.decodeIfPresent(FanMode.self, forKey: .mode) ?? d.mode
        source = try c.decodeIfPresent(TempSource.self, forKey: .source) ?? d.source
        steps = try c.decodeIfPresent([CurveStep].self, forKey: .steps) ?? d.steps
        gpuSteps = try c.decodeIfPresent([CurveStep].self, forKey: .gpuSteps) ?? d.gpuSteps
        useCPU = try c.decodeIfPresent(Bool.self, forKey: .useCPU) ?? d.useCPU
        useGPU = try c.decodeIfPresent(Bool.self, forKey: .useGPU) ?? d.useGPU
        baseRPM = try c.decodeIfPresent(Double.self, forKey: .baseRPM) ?? d.baseRPM
        fixedRPM = try c.decodeIfPresent(Double.self, forKey: .fixedRPM) ?? d.fixedRPM
        hysteresis = try c.decodeIfPresent(Double.self, forKey: .hysteresis) ?? d.hysteresis
        emergencyTemp = try c.decodeIfPresent(Double.self, forKey: .emergencyTemp) ?? d.emergencyTemp
        smooth = try c.decodeIfPresent(Bool.self, forKey: .smooth) ?? d.smooth
        revertAt = try c.decodeIfPresent(Date.self, forKey: .revertAt)
    }

    /// How far below the first step the smooth curve starts ramping up from the base RPM.
    public static let smoothRamp = 10.0

    /// The curve's RPM at a temperature, without hysteresis. Shared by the daemon (control) and
    /// the app (chart), so what the chart shows is exactly what the fan does.
    /// Step: the hottest step reached, else base. Smooth: base until (first step − smoothRamp),
    /// straight lines between steps, the last step's RPM above.
    public static func curveRPM(at t: Double, steps unsorted: [CurveStep], base: Double, smooth: Bool) -> Double {
        let steps = unsorted.sorted { $0.minTemp < $1.minTemp }
        guard let first = steps.first else { return base }
        guard smooth else { return steps.last { t >= $0.minTemp }?.rpm ?? base }
        var points = [(first.minTemp - smoothRamp, base)] + steps.map { ($0.minTemp, $0.rpm) }
        if points.count > 1, points[0].0 >= points[1].0 { points.removeFirst() }
        if t <= points[0].0 { return points[0].1 }
        for (a, b) in zip(points, points.dropFirst()) where t <= b.0 {
            return a.1 + (b.1 - a.1) * (t - a.0) / (b.0 - a.0)
        }
        return points.last!.1
    }

    /// Steps of the CPU (`.cpuAverage`) or GPU (`.gpuAverage`) curve.
    public func steps(for sensor: TempSource) -> [CurveStep] { sensor == .cpuAverage ? steps : gpuSteps }
    public func uses(_ sensor: TempSource) -> Bool { sensor == .cpuAverage ? useCPU : useGPU }
}

public struct DaemonStatus: Codable, Equatable {
    public var updated: Date
    public var mode: FanMode
    public var temperature: Double?
    public var targetRPM: Double?
    /// Which curve set targetRPM in curve mode (the hotter demand wins).
    public var driver: TempSource?
    public var emergency: Bool
    public var error: String?
    /// revertAt has passed: the daemon is running the fan as AUTO; the app should save mode = system.
    public var restoredToAuto: Bool?
    /// Everything the daemon just read, so the app doesn't have to poll the SMC itself.
    public var readings: Readings?
}

public enum Paths {
    public static let configDir = URL(fileURLWithPath: "/Users/Shared/FanPilot")
    public static let config = configDir.appendingPathComponent("config.json")
    public static let status = URL(fileURLWithPath: "/var/run/fanpilot.json")
}

public enum ConfigStore {
    /// nil when the file exists but cannot be parsed.
    public static func load() -> FanConfig? {
        guard let data = try? Data(contentsOf: Paths.config) else { return FanConfig() }
        return try? JSONDecoder().decode(FanConfig.self, from: data)
    }

    public static func save(_ config: FanConfig) throws {
        try FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: Paths.config, options: .atomic)
    }
}
