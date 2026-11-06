import SwiftUI

/// Monitor tab: chip, fans, CPU / GPU / memory / disk, a 10-minute summary with plain-language
/// advice, and the history charts. Observes LiveState, so it only does work while visible.
struct MonitorView: View {
    @ObservedObject var live: LiveState
    let config: FanConfig
    let unit: TempUnit
    let language: AppLanguage

    private let chip = ChipInfo.current
    private let columns = [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), spacing: 8, alignment: .top)]

    var body: some View {
        let h = live.history
        let stats = HistoryStats(h)
        VStack(alignment: .leading, spacing: 10) {
            Text(chip.name).font(.callout.bold())
            // Fans and system cards in separate grids, so an odd number of fans never pushes the
            // CPU / GPU / memory / disk cards out of their 2 × 2 layout.
            LazyVGrid(columns: columns, spacing: 8) {
                if Hardware.isFanless {
                    MetricCard(title: tr("팬", "Fan"), value: tr("없음", "None")) {
                        Text(tr("팬이 없는 Mac입니다", "This Mac has no fan")).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array((live.readings.fans ?? []).enumerated()), id: \.offset) { i, fan in
                    fanCard(i, fan, count: live.readings.fans?.count ?? 1)
                }
            }
            LazyVGrid(columns: columns, spacing: 8) {
                cpuCard
                gpuCard
                memoryCard
                diskCard
            }
            Divider()
            summary(stats)
            AdviceView(stats: stats, config: config, unit: unit, fanMin: live.readings.fanMin)
            // Charts redraw at most every 10 s: their input is the history snapshot keyed by a
            // 10-second bucket of the last sample's time.
            HistoryCharts(samples: h, bucket: Int((h.last?.time.timeIntervalSince1970 ?? 0) / 10),
                          unit: unit, fanMin: live.readings.fanMin, fanMax: live.readings.fanMax, language: language)
                .equatable()
        }
    }

    // MARK: Cards

    private func fanCard(_ i: Int, _ fan: FanReading, count: Int) -> some View {
        let span = max(1, fan.max - fan.min)
        return MetricCard(title: count > 1 ? tr("팬 \(i + 1)", "Fan \(i + 1)") : tr("팬", "Fan"),
                          detail: fan.manual ? "FanPilot" : tr("macOS", "macOS"),
                          value: Format.rpm(fan.rpm), unit: "RPM") {
            UsageBar(fraction: ((fan.rpm ?? fan.min) - fan.min) / span, color: .accentColor)
            HStack {
                Text(tr("최소 ", "Min ") + Format.rpm(fan.min))
                Spacer()
                Text(tr("최대 ", "Max ") + Format.rpm(fan.max))
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var cpuCard: some View {
        // Apple Silicon numbers efficiency cores first, then performance cores.
        let cores = live.coreUsage
        let e = min(chip.efficiencyCores, cores.count)
        var groups: [CoreBars.Group] = []
        if e > 0 { groups.append(.init(label: tr("효율 ×\(e)", "Eff ×\(e)"), values: Array(cores.prefix(e)))) }
        // Intel has one kind of core; calling them "performance" would be misleading.
        let rest = cores.count - e
        if rest > 0 { groups.append(.init(label: e > 0 ? tr("성능 ×\(rest)", "Perf ×\(rest)") : tr("코어 ×\(rest)", "Cores ×\(rest)"), values: Array(cores.dropFirst(e)))) }
        return MetricCard(title: "CPU", detail: tr("\(chip.performanceCores + chip.efficiencyCores)코어", "\(chip.performanceCores + chip.efficiencyCores) cores"),
                          value: Format.percent(live.cpuUsage)) {
            CoreBars(groups: groups)
        }
    }

    private var gpuCard: some View {
        MetricCard(title: "GPU", detail: chip.gpuCores.map { tr("\($0)코어", "\($0) cores") },
                   value: Format.percent(live.gpuUsage)) {
            UsageBar(fraction: (live.gpuUsage ?? 0) / 100, color: UsageBar.loadColor(live.gpuUsage ?? 0))
            Text(tr("온도 ", "Temp ") + unit.text(live.readings.gpuAverage, decimals: 1))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var memoryCard: some View {
        let m = live.memory
        let total = max(m?.total ?? 1, 1)
        let pct = (m?.used ?? 0) / total * 100
        return MetricCard(title: tr("메모리", "Memory"),
                          detail: m.map { Format.gigabytes($0.used) + " / " + Format.gigabytes($0.total) },
                          value: Format.percent(m == nil ? nil : pct)) {
            UsageBar([.init(fraction: (m?.app ?? 0) / total, color: .orange),
                      .init(fraction: (m?.wired ?? 0) / total, color: .brown),
                      .init(fraction: (m?.compressed ?? 0) / total, color: .gray)])
            HStack(spacing: 6) {
                LegendDot(color: .orange, label: tr("앱", "App"))
                LegendDot(color: .brown, label: tr("고정", "Wired"))
                LegendDot(color: .gray, label: tr("압축", "Comp."))
            }
        }
    }

    private var diskCard: some View {
        let d = live.disk
        let used = d.map { 1 - $0.available / max($0.total, 1) } ?? 0
        let low = (d?.available ?? .infinity) < 20 * 1_073_741_824
        return MetricCard(title: tr("디스크", "Disk"), detail: d.map { _ in tr("\(Int(used * 100))% 사용", "\(Int(used * 100))% used") },
                          value: d.map { Format.gigabytes($0.available) } ?? "--", unit: tr("남음", "free")) {
            UsageBar(fraction: used, color: low ? .orange : .accentColor)
            Text((low ? tr("공간 부족 · ", "Space low · ") : "") + tr("전체 ", "Total ") + (d.map { Format.gigabytes($0.total) } ?? "--"))
                .font(.system(size: 9)).foregroundStyle(low ? .orange : .secondary)
        }
    }

    // MARK: Summary

    private func summary(_ s: HistoryStats) -> some View {
        func temp(_ v: Double?) -> String { unit.text(v, symbol: false) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(tr("최근 \(s.minutes)분", "Last \(s.minutes) min")).font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("")
                    Text(tr("최고", "Peak")).foregroundStyle(.secondary)
                    Text(tr("평균", "Avg")).foregroundStyle(.secondary)
                    Text(tr("최고 사용률", "Peak load")).foregroundStyle(.secondary)
                }
                .font(.caption)
                GridRow { Text("CPU").font(.caption.bold()); Text(temp(s.cpuPeak)); Text(temp(s.cpuAvg)); Text(Format.percent(s.cpuUsagePeak)) }
                GridRow { Text("GPU").font(.caption.bold()); Text(temp(s.gpuPeak)); Text(temp(s.gpuAvg)); Text(Format.percent(s.gpuUsagePeak)) }
                if !Hardware.isFanless { GridRow {
                    Text(tr("팬", "Fan")).font(.caption.bold())
                    Text(Format.rpm(s.rpmPeak)); Text(Format.rpm(s.rpmAvg)); Text("RPM").foregroundStyle(.secondary)
                } }
            }
            .font(.callout.monospacedDigit())
        }
    }
}

/// Plain-language reading of the last few minutes.
struct AdviceView: View {
    let stats: HistoryStats
    let config: FanConfig
    let unit: TempUnit
    let fanMin: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines.indices, id: \.self) { i in
                Label { Text(lines[i].0).fixedSize(horizontal: false, vertical: true) } icon: {
                    Circle().fill(lines[i].1).frame(width: 6, height: 6)
                }
                .font(.caption)
            }
        }
    }

    private var lines: [(String, Color)] {
        let s = stats
        guard s.count >= 5, let peak = [s.cpuPeak, s.gpuPeak].compactMap({ $0 }).max() else {
            return [(tr("기록을 모으는 중입니다…", "Collecting history…"), .secondary)]
        }
        var out: [(String, Color)] = []
        let headroom = config.emergencyTemp - peak
        let room = "\(Int(unit.showDelta(headroom).rounded()))" + unit.symbol
        if headroom <= 10 {
            out.append((tr("비상 온도까지 \(room)밖에 남지 않았습니다. 익스트림 프리셋을 권장합니다.",
                           "Only \(room) below the emergency temperature. Extreme is recommended."), .red))
        } else if peak >= 85 {
            out.append((tr("온도가 꽤 올라갔습니다(비상 온도까지 \(room)). 성능 프리셋이 더 잘 식힙니다.",
                           "It ran warm (\(room) below emergency). Performance cools better."), .orange))
        } else if peak < 60, let rpm = s.rpmAvg, rpm > fanMin + 300, config.mode != .system {
            out.append((tr("온도는 낮은데 팬이 돌고 있습니다. 조용함 프리셋으로 소음을 줄일 수 있습니다.",
                           "Temperatures are low but the fan is busy. Quiet would cut the noise."), .blue))
        } else {
            out.append((tr("안정적입니다. 비상 온도까지 \(room) 여유가 있습니다.",
                           "Stable, with \(room) of headroom to the emergency temperature."), .green))
        }
        if let g = s.gpuUsagePeak, g >= 70, config.mode == .curve, !config.useGPU {
            out.append((tr("GPU 사용률이 높았는데 GPU 곡선이 꺼져 있습니다. 쿨링 탭에서 GPU를 켜 보세요.",
                           "The GPU was busy but its curve is off. Turn on GPU in Cooling."), .orange))
        }
        return out
    }
}

/// Peak / average over the history window.
struct HistoryStats {
    let count: Int
    let minutes: Int
    let cpuPeak, cpuAvg, gpuPeak, gpuAvg, rpmPeak, rpmAvg, cpuUsagePeak, gpuUsagePeak: Double?

    init(_ h: [HistorySample]) {
        func peak(_ k: KeyPath<HistorySample, Double?>) -> Double? { h.compactMap { $0[keyPath: k] }.max() }
        func avg(_ k: KeyPath<HistorySample, Double?>) -> Double? {
            let v = h.compactMap { $0[keyPath: k] }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        count = h.count
        minutes = max(1, Int(((h.last?.time.timeIntervalSince(h.first?.time ?? Date()) ?? 0) / 60).rounded(.up)))
        cpuPeak = peak(\.cpu); cpuAvg = avg(\.cpu)
        gpuPeak = peak(\.gpu); gpuAvg = avg(\.gpu)
        rpmPeak = peak(\.rpm); rpmAvg = avg(\.rpm)
        cpuUsagePeak = peak(\.cpuUsage); gpuUsagePeak = peak(\.gpuUsage)
    }
}
