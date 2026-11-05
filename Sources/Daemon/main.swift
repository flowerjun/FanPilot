import Foundation

// fanpilotd — runs as root via launchd and drives fan 0.
// Status errors are codes (config_parse, sensor_read, fan_write:<detail>); the app localizes them.
// `fanpilotd --reset` hands the fan back to the system and exits.
//
// Two processes from one binary: launchd runs the supervisor, which runs the controller
// (`--worker`) as its child. Each watches the other, so whichever dies — even by SIGKILL or a
// crash, which no in-process handler can catch — the survivor hands the fan back to macOS.

let smc: SMC
do { smc = try SMC() } catch { FileHandle.standardError.write("SMC open failed: \(error)\n".data(using: .utf8)!); exit(1) }

func log(_ s: String) { FileHandle.standardError.write("[fanpilotd] \(s)\n".data(using: .utf8)!) }

/// Number of fans (FNum), read once.
let fanCount = max(1, Int((try? smc.read("FNum").double) ?? 1))
/// Last RPM written to each fan's F{i}Tg while in manual mode; nil means "unknown, write it".
var writtenRPM = [Double?](repeating: nil, count: fanCount)
/// Ticks since the targets were last written; re-asserted periodically in case anything else touched them.
var ticksSinceWrite = 0
let reassertEvery = 15   // × 2 s = 30 s

/// Every fan back to macOS control. Tries all fans even if one write fails.
func setSystemMode() {
    for i in 0..<fanCount {
        do { try smc.write("F\(i)Md", bytes: [0]) } catch { log("restore auto failed on fan \(i): \(error)") }
    }
    writtenRPM = .init(repeating: nil, count: fanCount)
}

/// `rpm` is in fan 0's range; every other fan runs at the same fraction of its own range.
/// Only touches the SMC when something actually needs to change.
func setRPM(_ rpm: Double, fans: [FanReading]) throws {
    ticksSinceWrite += 1
    let reassert = ticksSinceWrite >= reassertEvery
    let f0 = fans[0]
    let fraction = f0.max > f0.min ? (rpm - f0.min) / (f0.max - f0.min) : 1
    for (i, fan) in fans.enumerated() {
        let target = i == 0 ? rpm : (fan.min + fraction * (fan.max - fan.min)).rounded()
        if !fan.manual { try smc.write("F\(i)Md", bytes: [1]); writtenRPM[i] = nil }
        if writtenRPM[i] != target || reassert {
            try smc.write("F\(i)Tg", float: Float(target))
            writtenRPM[i] = target
        }
    }
    if reassert { ticksSinceWrite = 0 }
}

if CommandLine.arguments.contains("--reset") { setSystemMode(); exit(0) }

/// Step-wise or smooth curve with hysteresis so the fan doesn't flap at a boundary.
struct CurveController {
    var lastIndex: Int?
    var heldTemp: Double?

    mutating func rpm(for temp: Double, steps unsorted: [CurveStep], base: Double, hysteresis: Double, smooth: Bool = false) -> Double {
        if smooth { return smoothRPM(for: temp, steps: unsorted, base: base, hysteresis: hysteresis) }
        let steps = unsorted.sorted { $0.minTemp > $1.minTemp }   // hottest first
        var idx = steps.firstIndex { temp >= $0.minTemp } ?? steps.count
        if let last = lastIndex, last < steps.count, idx > last, temp > steps[last].minTemp - hysteresis {
            idx = last
        }
        lastIndex = idx
        return idx < steps.count ? steps[idx].rpm : base
    }

    /// Linear interpolation between steps. Rising temperatures apply at once; falling ones are
    /// held until they drop more than `hysteresis`, so the fan eases off without hunting.
    private mutating func smoothRPM(for temp: Double, steps unsorted: [CurveStep], base: Double, hysteresis: Double) -> Double {
        var t = temp
        if let held = heldTemp, temp < held {
            t = held - temp > hysteresis ? temp + hysteresis : held
        }
        heldTemp = t
        return FanConfig.curveRPM(at: t, steps: unsorted, base: base, smooth: true)
    }
}

/// CPU and GPU curves, each with its own hysteresis state; the fan follows whichever
/// demands more, so a GPU-only load still spins it up.
struct DualCurve {
    private var controllers: [TempSource: CurveController] = [:]

    /// nil when no enabled curve has a readable temperature.
    mutating func target(_ r: Readings, config: FanConfig) -> (rpm: Double, driver: TempSource)? {
        var best: (rpm: Double, driver: TempSource)?
        for sensor in TempSource.allCases where config.uses(sensor) {
            guard let temp = r.temperature(for: sensor) else { continue }
            var controller = controllers[sensor] ?? CurveController()
            let rpm = controller.rpm(for: temp, steps: config.steps(for: sensor), base: config.baseRPM, hysteresis: config.hysteresis, smooth: config.smooth)
            controllers[sensor] = controller
            if best == nil || rpm > best!.rpm { best = (rpm, sensor) }
        }
        return best
    }
}


/// Re-parses config.json only when its modification date changes.
struct ConfigCache {
    private var stamp: Date??   // outer nil = never loaded; inner nil = file absent
    private var config: FanConfig?

    mutating func current() -> FanConfig? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: Paths.config.path))?[.modificationDate] as? Date
        if let stamp, stamp == mtime { return config }
        stamp = .some(mtime)
        config = ConfigStore.load()
        return config
    }
}

var sensors: Sensors!   // created in the controller only; the supervisor never reads sensors
var curves = DualCurve()
var configCache = ConfigCache()
var lastConfig: FanConfig?
var manualActive = false

let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

func writeStatus(_ s: DaemonStatus) {
    // Root's umask leaves the new file 0644, which is what the app needs to read it.
    try? encoder.encode(s).write(to: Paths.status, options: .atomic)
}

func tick() {
    let r = sensors.read()
    guard let loaded = configCache.current() else {
        // Unreadable config: never guess, give control back to the firmware.
        if manualActive || r.manual { setSystemMode(); manualActive = false }
        writeStatus(DaemonStatus(updated: Date(), mode: .system, temperature: nil, targetRPM: nil, driver: nil, emergency: false, error: "config_parse", restoredToAuto: nil, readings: r))
        return
    }
    if loaded != lastConfig { curves = DualCurve(); lastConfig = loaded }

    // Timed CUSTOM/CONSTANT: past revertAt the fan belongs to macOS again. The daemon can't
    // rewrite the user's config, so it runs AUTO and flags it; the app then saves mode = system.
    let restored = loaded.mode != .system && (loaded.revertAt.map { Date() >= $0 } ?? false)
    var config = loaded
    if restored { config.mode = .system }

    let temp = r.temperature(for: config.source)
    var target: Double?
    var driver: TempSource?
    var problem: String?
    switch config.mode {
    case .system:
        target = nil
    case .fixed:
        target = config.fixedRPM
    case .curve:
        if let t = curves.target(r, config: config) { target = t.rpm; driver = t.driver } else { problem = "sensor_read" }
    }

    let hottest = [r.cpuAverage, r.gpuAverage].compactMap { $0 }.max() ?? 0
    let emergency = config.mode != .system && hottest >= config.emergencyTemp
    if emergency { target = r.fanMax }

    if let t = target {
        let clamped = min(max(t, r.fanMin), r.fanMax)
        let fans = r.fans ?? [FanReading(rpm: r.fanRPM, min: r.fanMin, max: r.fanMax, manual: r.manual)]
        do { try setRPM(clamped, fans: fans); manualActive = true; target = clamped }
        catch { problem = "fan_write:\(error)"; setSystemMode(); manualActive = false; target = nil }
    } else if manualActive || r.manual {
        setSystemMode(); manualActive = false
    }

    writeStatus(DaemonStatus(updated: Date(), mode: config.mode, temperature: temp, targetRPM: target, driver: driver, emergency: emergency, error: problem, restoredToAuto: restored ? true : nil, readings: r))
}

// MARK: - Processes

var keepAlive: [AnyObject] = []   // dispatch sources must outlive the setup functions

/// SIGTERM/SIGINT/SIGHUP (shutdown, uninstall, launchctl stop) run `handler` and exit.
func onTerminationSignal(_ handler: @escaping (Int32) -> Void) {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { handler(sig); exit(0) }
        src.resume()
        keepAlive.append(src)
    }
}

func describe(_ status: Int32) -> String {
    let sig = status & 0x7f
    return sig == 0 ? "exit \((status >> 8) & 0xff)" : "signal \(sig)"
}

/// The controller: runs the fan loop and dies with its supervisor.
func runWorker() -> Never {
    let parent = getppid()
    let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    parentWatch.setEventHandler { setSystemMode(); log("supervisor gone, fan returned to system"); exit(0) }
    parentWatch.resume()
    keepAlive.append(parentWatch)
    if parent == 1 || getppid() != parent { setSystemMode(); exit(0) }   // orphaned before the watch was armed

    onTerminationSignal { sig in setSystemMode(); log("controller got signal \(sig), fan returned to system") }

    sensors = Sensors(smc: smc)
    let timer = DispatchSource.makeTimerSource(queue: .main)
    // Leeway lets the kernel coalesce our wakeups with other work.
    timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(300))
    timer.setEventHandler(handler: tick)
    timer.resume()
    keepAlive.append(timer)
    log("controller started (pid \(getpid()))")
    dispatchMain()
}

/// The supervisor: launchd's process. Starts the controller, resets the fan to macOS control the
/// moment it exits for any reason, and restarts it (backing off if it keeps crashing).
func runSupervisor() -> Never {
    let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var child: pid_t = 0
    var startedAt = Date()
    var restartDelay = 2.0

    func spawn() {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("--worker"), nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, path, nil, nil, &argv, environ)
        guard rc == 0 else {
            log("could not start controller (\(rc)); fan stays with macOS, retrying")
            setSystemMode()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { spawn() }
            return
        }
        child = pid
        startedAt = Date()

        var handled = false
        func exited(_ status: Int32) {
            guard !handled else { return }
            handled = true
            child = 0
            setSystemMode()
            // Quick deaths mean something is wrong: back off (2 → 4 → … → 30 s), staying in AUTO meanwhile.
            restartDelay = Date().timeIntervalSince(startedAt) < 30 ? min(restartDelay * 2, 30) : 2
            log("controller exited (\(describe(status))), fan returned to system; restarting in \(Int(restartDelay)) s")
            DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { spawn() }
        }
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            watch.cancel()
            exited(status)
        }
        watch.resume()
        keepAlive.append(watch)
        // It may have died before the watch was armed.
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { watch.cancel(); exited(status) }
    }

    onTerminationSignal { sig in
        if child > 0 { kill(child, SIGTERM) }
        setSystemMode()
        try? FileManager.default.removeItem(at: Paths.status)
        log("signal \(sig), fan returned to system")
    }
    log("supervisor started (pid \(getpid()))")
    spawn()
    dispatchMain()
}

if CommandLine.arguments.contains("--worker") { runWorker() } else { runSupervisor() }
