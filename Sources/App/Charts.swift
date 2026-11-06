import SwiftUI

// Charts are drawn with plain SwiftUI shapes and Text, not Swift Charts or Canvas: both of those
// set up a GPU rendering context on first draw that costs ~120 MB of memory, for a few lines.
// They are also Equatable views, so SwiftUI skips them unless their (coarse) inputs change.

/// A small line chart built from Path shapes and Text labels.
struct LineChart: View {
    struct Series { let points: [(x: Double, y: Double)]; let color: Color }

    let series: [Series]
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>
    var xLabels: [(Double, String)] = []
    var yLabels: [(Double, String)] = []
    /// Shaded x ranges (e.g. the emergency zone).
    var bands: [(ClosedRange<Double>, Color)] = []
    /// Dashed vertical marker with a label above it.
    var marker: (x: Double, label: String, color: Color)?
    /// Faint horizontal reference line (e.g. zero).
    var rule: Double?

    private static let left: CGFloat = 34, bottom: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let top: CGFloat = marker == nil ? 4 : 14
            let plot = CGRect(x: Self.left, y: top, width: max(1, geo.size.width - Self.left - 2),
                              height: max(1, geo.size.height - top - Self.bottom))
            let xs = xRange.upperBound - xRange.lowerBound, ys = yRange.upperBound - yRange.lowerBound
            let px = { (x: Double) -> CGFloat in plot.minX + CGFloat((x - xRange.lowerBound) / (xs == 0 ? 1 : xs)) * plot.width }
            let py = { (y: Double) -> CGFloat in
                plot.maxY - CGFloat((min(max(y, yRange.lowerBound), yRange.upperBound) - yRange.lowerBound) / (ys == 0 ? 1 : ys)) * plot.height
            }
            ZStack(alignment: .topLeading) {
                ForEach(bands.indices, id: \.self) { i in
                    Path(CGRect(x: px(bands[i].0.lowerBound), y: plot.minY,
                                width: px(bands[i].0.upperBound) - px(bands[i].0.lowerBound), height: plot.height))
                        .fill(bands[i].1)
                }
                Path { p in
                    for (y, _) in yLabels { p.move(to: CGPoint(x: plot.minX, y: py(y))); p.addLine(to: CGPoint(x: plot.maxX, y: py(y))) }
                }
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                if let rule {
                    Path { p in p.move(to: CGPoint(x: plot.minX, y: py(rule))); p.addLine(to: CGPoint(x: plot.maxX, y: py(rule))) }
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                }
                ForEach(series.indices, id: \.self) { i in
                    Path { p in
                        let pts = series[i].points
                        guard let first = pts.first, pts.count > 1 else { return }
                        p.move(to: CGPoint(x: px(first.x), y: py(first.y)))
                        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: px(q.x), y: py(q.y))) }
                    }
                    .stroke(series[i].color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                if let m = marker, xRange.contains(m.x) {
                    Path { p in p.move(to: CGPoint(x: px(m.x), y: plot.minY)); p.addLine(to: CGPoint(x: px(m.x), y: plot.maxY)) }
                        .stroke(m.color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    label(m.label, weight: .semibold, color: m.color).position(x: px(m.x), y: plot.minY - 7)
                }
                ForEach(yLabels.indices, id: \.self) { i in
                    label(yLabels[i].1).frame(width: Self.left - 4, alignment: .trailing).position(x: (Self.left - 4) / 2, y: py(yLabels[i].0))
                }
                ForEach(xLabels.indices, id: \.self) { i in
                    label(xLabels[i].1).position(x: px(xLabels[i].0), y: plot.maxY + 10)
                }
            }
        }
    }

    private func label(_ text: String, weight: Font.Weight = .regular, color: Color = .secondary) -> some View {
        Text(text).font(.system(size: 9, weight: weight)).foregroundColor(color).fixedSize()
    }
}

/// The fan curve being edited, with the current temperature and the emergency zone.
struct CurvePreview: View, Equatable {
    let steps: [CurveStep]
    let base: Double
    let smooth: Bool
    let emergency: Double
    let fanMin: Double
    let fanMax: Double
    let unit: TempUnit
    let marker: Int?   // current temperature, whole °C

    private static let range = 30.0...110.0

    var body: some View {
        let lo = unit.show(Self.range.lowerBound), hi = unit.show(Self.range.upperBound)
        let pts = stride(from: Self.range.lowerBound, through: Self.range.upperBound, by: 0.5).map {
            (x: unit.show($0), y: FanConfig.curveRPM(at: $0, steps: steps, base: base, smooth: smooth))
        }
        let xTicks = stride(from: 40.0, through: 100.0, by: 20).map { (unit.show($0), unit.text($0, symbol: false)) }
        let yTicks = Self.ticks(fanMin...fanMax, count: 4).map { ($0, "\(Int($0))") }
        LineChart(series: [.init(points: pts, color: .accentColor)], xRange: lo...hi, yRange: fanMin...fanMax,
                  xLabels: xTicks, yLabels: yTicks,
                  bands: [(min(unit.show(emergency), hi)...hi, Color.red.opacity(0.12))],
                  marker: marker.map { (x: unit.show(Double($0)), label: unit.text(Double($0), symbol: false), color: .orange) })
            .frame(height: 130)
    }

    /// Evenly spaced round values covering the range.
    static func ticks(_ r: ClosedRange<Double>, count: Int) -> [Double] {
        let raw = (r.upperBound - r.lowerBound) / Double(max(1, count - 1))
        let mag = pow(10, floor(log10(max(raw, 1))))
        let step = [1.0, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? raw
        return stride(from: (r.lowerBound / step).rounded(.up) * step, through: r.upperBound, by: step).map { $0 }
    }
}

/// Observes LiveState and feeds CurvePreview the current temperature in whole degrees, so the
/// chart itself only redraws when that degree (or the curve) changes.
struct LiveCurvePreview: View {
    @ObservedObject var live: LiveState
    let config: FanConfig
    let sensor: TempSource
    let unit: TempUnit

    var body: some View {
        CurvePreview(steps: config.steps(for: sensor), base: config.baseRPM, smooth: config.smooth,
                     emergency: config.emergencyTemp, fanMin: live.readings.fanMin, fanMax: live.readings.fanMax,
                     unit: unit, marker: live.readings.temperature(for: sensor).map { Int($0.rounded()) })
            .equatable()
    }
}

/// Mini curve for preset tiles: a plain Path, no Charts.
struct MiniCurve: Shape {
    let setup: QuickSetup

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let lo = 35.0, hi = 100.0
        func pt(_ t: Double, _ f: Double) -> CGPoint {
            CGPoint(x: rect.minX + (t - lo) / (hi - lo) * rect.width, y: rect.maxY - f * rect.height)
        }
        switch setup {
        case .auto:
            p.move(to: pt(lo, 0.1)); p.addCurve(to: pt(hi, 0.7), control1: pt(70, 0.1), control2: pt(80, 0.6))
        case .constant:
            p.move(to: pt(lo, 0.5)); p.addLine(to: pt(hi, 0.5))
        default:
            guard let c = setup.curve, let first = c.points.first else { return p }
            p.move(to: pt(lo, c.base))
            p.addLine(to: pt(max(lo, first.0 - FanConfig.smoothRamp), c.base))
            for (t, f) in c.points { p.addLine(to: pt(t, f)) }
            p.addLine(to: pt(hi, c.points.last!.1))
        }
        return p
    }
}

/// Temperature, rate of change, load and RPM over the last 10 minutes.
struct HistoryCharts: View, Equatable {
    let samples: [HistorySample]
    let bucket: Int
    let unit: TempUnit
    let fanMin: Double
    let fanMax: Double
    let language: AppLanguage

    static func == (a: Self, b: Self) -> Bool {
        a.bucket == b.bucket && a.unit == b.unit && a.language == b.language && a.samples.count == b.samples.count
    }

    var body: some View {
        // Every other sample (≤150 points per series) is plenty for a 350-pt-wide chart.
        let pts = samples.enumerated().filter { $0.offset % 2 == 0 || $0.offset == samples.count - 1 }.map(\.element)
        let now = samples.last?.time ?? Date()
        func x(_ d: Date) -> Double { d.timeIntervalSince(now) / 60 }   // minutes, ≤ 0
        func series(_ k: KeyPath<HistorySample, Double?>, _ color: Color, _ f: (Double) -> Double = { $0 }) -> LineChart.Series {
            .init(points: pts.compactMap { s in s[keyPath: k].map { (x: x(s.time), y: f($0)) } }, color: color)
        }
        let xr = -10.0...0.0
        let xl = [(-10.0, tr("10분 전", "-10m")), (-5.0, tr("5분 전", "-5m")), (0.0, tr("지금", "now"))]
        let temps = [series(\.cpu, .accentColor, unit.show), series(\.gpu, .purple, unit.show)]
        let tAll = temps.flatMap { $0.points.map(\.y) }
        let tr0 = Self.padded(tAll, minSpan: unit == .celsius ? 10 : 18)
        let rates = Self.rates(pts, unit: unit, x: x)
        let rMax = max(2, (rates.flatMap { $0.points.map { abs($0.y) } }.max() ?? 2).rounded(.up))
        return VStack(alignment: .leading, spacing: 8) {
            legend
            block(tr("온도", "Temperature"), unit.symbol,
                  LineChart(series: temps, xRange: xr, yRange: tr0, xLabels: xl, yLabels: CurvePreview.ticks(tr0, count: 3).map { ($0, "\(Int($0))") }))
            block(tr("온도 변화율", "Rate of change"), unit.symbol + tr("/분", "/min"),
                  LineChart(series: rates, xRange: xr, yRange: -rMax...rMax, xLabels: xl,
                            yLabels: [(-rMax, "\(Int(-rMax))"), (0, "0"), (rMax, "+\(Int(rMax))")], rule: 0))
            block(tr("사용률", "Load"), "%",
                  LineChart(series: [series(\.cpuUsage, .accentColor), series(\.gpuUsage, .purple)], xRange: xr, yRange: 0...100,
                            xLabels: xl, yLabels: [(0, "0"), (50, "50"), (100, "100")]))
            if !Hardware.isFanless {
                block(tr("팬", "Fan"), "RPM",
                      LineChart(series: [series(\.rpm, .accentColor)], xRange: xr, yRange: fanMin...fanMax,
                                xLabels: xl, yLabels: CurvePreview.ticks(fanMin...fanMax, count: 3).map { ($0, "\(Int($0))") }))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) { Circle().fill(Color.accentColor).frame(width: 7, height: 7); Text("CPU") }
            HStack(spacing: 4) { Circle().fill(Color.purple).frame(width: 7, height: 7); Text("GPU") }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func block(_ title: String, _ unitLabel: String, _ chart: LineChart) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(.caption.bold())
                Text(unitLabel).font(.caption2).foregroundStyle(.secondary)
            }
            chart.frame(height: 66)
        }
    }

    /// Data range with a little margin and at least `minSpan`, so flat lines don't fill the plot.
    static func padded(_ v: [Double], minSpan: Double) -> ClosedRange<Double> {
        guard let lo = v.min(), let hi = v.max() else { return 0...100 }
        let mid = (lo + hi) / 2, half = max(hi - lo, minSpan) / 2 + 2
        return (mid - half).rounded(.down)...(mid + half).rounded(.up)
    }

    /// °/min over a ~30-second window, so sensor noise doesn't look like a trend.
    static func rates(_ pts: [HistorySample], unit: TempUnit, x: (Date) -> Double) -> [LineChart.Series] {
        let span = 7   // points ≈ 28-30 s (points are every other 2 s sample)
        guard pts.count > span else { return [] }
        var cpu: [(x: Double, y: Double)] = [], gpu: [(x: Double, y: Double)] = []
        for i in span..<pts.count {
            let a = pts[i - span], b = pts[i]
            let minutes = b.time.timeIntervalSince(a.time) / 60
            guard minutes > 0 else { continue }
            if let p = a.cpu, let q = b.cpu { cpu.append((x(b.time), unit.showDelta(q - p) / minutes)) }
            if let p = a.gpu, let q = b.gpu { gpu.append((x(b.time), unit.showDelta(q - p) / minutes)) }
        }
        return [.init(points: cpu, color: .accentColor), .init(points: gpu, color: .purple)]
    }
}
