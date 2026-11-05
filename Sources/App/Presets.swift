import Foundation

/// One-click setups for people who don't want to build a curve. Curve presets are defined as a
/// fraction of the fan's own RPM range, so they fit any Mac's min/max.
enum QuickSetup: String, CaseIterable, Identifiable {
    case auto, quiet, balanced, performance, extreme, constant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return tr("자동", "Auto")
        case .quiet: return tr("조용함", "Quiet")
        case .balanced: return tr("균형", "Balanced")
        case .performance: return tr("성능", "Performance")
        case .extreme: return tr("익스트림", "Extreme")
        case .constant: return tr("고정", "Constant")
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "a.circle"
        case .quiet: return "moon.zzz"
        case .balanced: return "circle.lefthalf.filled"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .extreme: return "bolt.fill"
        case .constant: return "equal.circle"
        }
    }

    var summary: String {
        switch self {
        case .auto: return tr("macOS가 조절", "macOS decides")
        case .quiet: return tr("소음 최소", "Least noise")
        case .balanced: return tr("일상 작업", "Everyday use")
        case .performance: return tr("오래 걸리는 작업", "Sustained loads")
        case .extreme: return tr("최대 냉각", "Max cooling")
        case .constant: return tr("RPM 고정", "Fixed RPM")
        }
    }

    /// (base fraction, [(°C, fraction)]) for curve presets; nil for auto/constant.
    var curve: (base: Double, points: [(Double, Double)])? {
        switch self {
        case .quiet: return (0.00, [(60, 0.10), (70, 0.25), (80, 0.45), (90, 0.75)])
        case .balanced: return (0.05, [(55, 0.15), (65, 0.30), (75, 0.50), (85, 0.70), (95, 0.90)])
        case .performance: return (0.15, [(50, 0.30), (60, 0.45), (70, 0.65), (80, 0.85), (90, 1.00)])
        case .extreme: return (0.35, [(45, 0.50), (55, 0.70), (65, 0.90), (75, 1.00)])
        case .auto, .constant: return nil
        }
    }

    /// Fraction of the fan range → RPM, rounded to 50.
    static func rpm(_ fraction: Double, min lo: Double, max hi: Double) -> Double {
        ((lo + fraction * (hi - lo)) / 50).rounded() * 50
    }

    /// The preset's curve as steps for this fan.
    func steps(min lo: Double, max hi: Double) -> (base: Double, steps: [CurveStep])? {
        guard let c = curve else { return nil }
        return (Self.rpm(c.base, min: lo, max: hi), c.points.map { CurveStep(minTemp: $0.0, rpm: Self.rpm($0.1, min: lo, max: hi)) })
    }

    /// Which preset (if any) the saved config currently is.
    static func matching(_ cfg: FanConfig, min lo: Double, max hi: Double) -> QuickSetup? {
        switch cfg.mode {
        case .system: return .auto
        case .fixed: return .constant
        case .curve:
            return allCases.first { s in
                guard let p = s.steps(min: lo, max: hi) else { return false }
                return cfg.smooth && cfg.baseRPM == p.base && cfg.steps == p.steps && cfg.gpuSteps == p.steps
            }
        }
    }
}

/// The user's own curve, kept separately so picking a preset never throws it away.
struct MyCurve: Codable, Equatable {
    var steps: [CurveStep]
    var gpuSteps: [CurveStep]
    var baseRPM: Double
    var useCPU: Bool
    var useGPU: Bool
    var smooth: Bool
    var hysteresis: Double

    init(_ c: FanConfig) {
        steps = c.steps; gpuSteps = c.gpuSteps; baseRPM = c.baseRPM
        useCPU = c.useCPU; useGPU = c.useGPU; smooth = c.smooth; hysteresis = c.hysteresis
    }

    func apply(to c: inout FanConfig) {
        c.steps = steps; c.gpuSteps = gpuSteps; c.baseRPM = baseRPM
        c.useCPU = useCPU; c.useGPU = useGPU; c.smooth = smooth; c.hysteresis = hysteresis
    }
}
