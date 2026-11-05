import Foundation

/// One point of the rolling history (one per 2 s tick).
struct HistorySample {
    let time: Date
    let cpu: Double?
    let gpu: Double?
    let rpm: Double?
    let cpuUsage: Double?
    let gpuUsage: Double?
}

/// Data that changes every tick (temperatures, RPM, daemon status), kept apart from the
/// settings model so a new reading only re-renders the views that show it.
@MainActor
final class LiveState: ObservableObject {
    @Published private(set) var readings = Readings()
    @Published private(set) var status: DaemonStatus?
    @Published private(set) var daemonAlive = false
    /// Latest utilization, percent. Not @Published: only the History tab shows it, and that tab
    /// re-renders with `readings` anyway; publishing would redraw the header every tick.
    private(set) var cpuUsage: Double?
    private(set) var gpuUsage: Double?
    /// Per-core CPU %, memory and disk. Same rule: plain values read by the Monitor tab.
    private(set) var coreUsage: [Double] = []
    private(set) var memory: MemoryUsage?
    private(set) var disk: DiskUsage?
    private var tick = 0

    /// Last 10 minutes (300 × 2 s). Not @Published: views that show it already re-render when
    /// `readings` changes, so publishing it too would only add redundant invalidations.
    private(set) var history: [HistorySample] = []
    static let historyLimit = 300

    /// Direct SMC access, only used while the daemon isn't publishing readings.
    /// Created lazily: enumerating the SMC keys is the most expensive thing the app does.
    private lazy var sensors: Sensors? = (try? SMC()).map(Sensors.init)
    private let usage = UsageSampler()
    private var timer: Timer?
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init() {
        history.reserveCapacity(Self.historyLimit)
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 0.5   // let macOS coalesce this wakeup with others
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let new = (try? Data(contentsOf: Paths.status)).flatMap { try? decoder.decode(DaemonStatus.self, from: $0) }
        let alive = new.map { Date().timeIntervalSince($0.updated) < 10 } ?? false

        // Publish only real changes. `updated` moves every tick, so compare without it.
        var a = new, b = status
        a?.updated = .distantPast; b?.updated = .distantPast
        if a != b { status = new }
        if alive != daemonAlive { daemonAlive = alive }

        let latest = (alive ? new?.readings : nil) ?? sensors?.read() ?? readings
        if latest != readings { readings = latest }

        // Whole percents: finer changes aren't worth a re-render.
        let cpu = usage.cpuPercent()?.rounded(), gpu = usage.gpuPercent()?.rounded()
        cpuUsage = cpu
        gpuUsage = gpu
        coreUsage = usage.perCore
        memory = MemoryUsage.current()
        // Free space barely moves; every 15th tick (30 s) is plenty.
        if tick % 15 == 0 { disk = DiskUsage.current() }
        tick &+= 1

        if history.count == Self.historyLimit { history.removeFirst() }
        history.append(HistorySample(time: Date(), cpu: latest.cpuAverage, gpu: latest.gpuAverage, rpm: latest.fanRPM,
                                     cpuUsage: cpu, gpuUsage: gpu))
    }
}
