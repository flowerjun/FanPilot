import Foundation
import IOKit

/// Chip description, read once at launch.
struct ChipInfo {
    let name: String              // e.g. "Apple M4 Pro"
    let performanceCores: Int
    let efficiencyCores: Int
    let gpuCores: Int?

    static let current: ChipInfo = {
        func sysctlInt(_ key: String) -> Int {
            var v: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(key, &v, &size, nil, 0) == 0 ? Int(v) : 0
        }
        func sysctlString(_ key: String) -> String? {
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return nil }
            return String(cString: buf)
        }
        // perflevel0 = performance cores, perflevel1 = efficiency cores on Apple Silicon.
        var p = sysctlInt("hw.perflevel0.physicalcpu"), e = sysctlInt("hw.perflevel1.physicalcpu")
        if p == 0 && e == 0 { p = sysctlInt("hw.physicalcpu") }
        var gpu: Int?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        if service != 0 {
            gpu = (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
            IOObjectRelease(service)
        }
        return ChipInfo(name: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
                        performanceCores: p, efficiencyCores: e, gpuCores: gpu)
    }()
}

/// Fan hardware, read once at launch (a few SMC reads, no root needed).
enum Hardware {
    /// nil if the SMC couldn't be opened; then the fan controls stay available rather than
    /// wrongly calling the Mac fanless.
    static let fanCount: Int? = (try? SMC()).map { FanKeys(smc: $0).count }
    /// MacBook Air and other fanless Macs: FanPilot works as a temperature monitor only.
    static let isFanless = fanCount == 0
}

/// CPU and GPU utilization, sampled by LiveState on its existing 2 s tick. Each sample is one
/// kernel call for the CPU and one registry property read for the GPU (service found once).
final class UsageSampler {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastPerCore: [(busy: UInt64, total: UInt64)] = []
    /// Per-core busy percent from the last cpuPercent() call (same kernel call, no extra cost).
    private(set) var perCore: [Double] = []
    private var gpuService: io_registry_entry_t = 0

    init() {
        gpuService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    }
    deinit { if gpuService != 0 { IOObjectRelease(gpuService) } }

    /// Percent of all cores busy since the previous call (nil on the first call).
    func cpuPercent() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        var cores: [(busy: UInt64, total: UInt64)] = []
        cores.reserveCapacity(Int(count))
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
            cores.append((user + system + nice, user + system + nice + idle))
        }
        if lastPerCore.count == cores.count {
            perCore = zip(cores, lastPerCore).map { c, l in
                c.total > l.total ? (Double(c.busy - l.busy) / Double(c.total - l.total) * 100).rounded() : 0
            }
        }
        lastPerCore = cores
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return nil }
        return Double(busy - last.busy) / Double(total - last.total) * 100
    }

    /// GPU "Device Utilization %" from the accelerator's performance statistics.
    func gpuPercent() -> Double? {
        guard gpuService != 0,
              let stats = IORegistryEntryCreateCFProperty(gpuService, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let v = stats["Device Utilization %"] as? NSNumber else { return nil }
        return v.doubleValue
    }
}

/// Memory in use, like Activity Monitor: app + wired + compressed; cache is reclaimable.
struct MemoryUsage: Equatable {
    var total: Double = 0      // bytes
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var used: Double { app + wired + compressed }

    static let physical = Double(ProcessInfo.processInfo.physicalMemory)

    /// One host_statistics64 call.
    static func current() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        var m = MemoryUsage(total: physical)
        m.app = Double(stats.internal_page_count &- stats.purgeable_count) * page
        m.wired = Double(stats.wire_count) * page
        m.compressed = Double(stats.compressor_page_count) * page
        m.cached = Double(stats.external_page_count &+ stats.purgeable_count) * page
        return m
    }
}

/// Startup disk capacity (one resource-values lookup).
struct DiskUsage: Equatable {
    var total: Double
    var available: Double

    static func current() -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskUsage(total: Double(total), available: Double(avail))
    }
}
