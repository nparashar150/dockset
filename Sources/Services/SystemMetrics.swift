import Foundation
import Observation

/// CPU / memory / disk pressure, sampled once a second off the main run loop.
///
/// Every reading is a cheap syscall, so there is no background queue here -
/// but every one of them can fail, and a failed sample leaves the previous
/// value in place rather than flashing a zero on the shelf.
@MainActor @Observable
final class SystemMetrics {
    static let shared = SystemMetrics()

    /// Busy fraction between the last two samples, 0...1.
    private(set) var cpu: Double = 0
    /// Used fraction of physical memory, 0...1.
    private(set) var memory: Double = 0
    /// Used fraction of the root volume, 0...1.
    private(set) var disk: Double = 0
    /// Bytes free and total on the root volume.
    ///
    /// The fraction alone leaves a panel with nothing to say that the gauge
    /// has not already said. These come from the same sample at no extra
    /// cost - they were being computed and thrown away.
    private(set) var diskFree: Int64 = 0
    private(set) var diskTotal: Int64 = 0
    /// Busy fraction of each logical core over the last second, in the
    /// kernel's order, which puts efficiency cores first on Apple silicon.
    private(set) var cores: [Double] = []
    /// What the kernel thinks of memory, which is what decides whether a
    /// high percentage matters: 80% used at normal pressure is a Mac doing
    /// its job, at critical it is swapping.
    private(set) var pressure: MemoryPressure = .normal
    private(set) var swapUsed: Int64 = 0
    private(set) var swapTotal: Int64 = 0

    enum MemoryPressure: String {
        case normal = "Normal", warning = "Elevated", critical = "Critical"
    }

    /// Rolling history so widgets can draw a graph rather than only a number.
    /// Most recent last; grows to `historyLength` then slides.
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    static let historyLength = 60

    func history(for metric: String) -> [Double] {
        switch metric {
        case "cpu": cpuHistory
        case "memory": memoryHistory
        default: []
        }
    }

    func value(for metric: String) -> Double {
        switch metric {
        case "cpu": cpu
        case "memory": memory
        case "disk": disk
        default: 0
        }
    }

    private func record() {
        cpuHistory.append(cpu)
        memoryHistory.append(memory)
        if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst() }
        if memoryHistory.count > Self.historyLength { memoryHistory.removeFirst() }
    }

    @ObservationIgnored private var timer: Timer?
    /// CPU ticks are cumulative since boot; only the delta between two
    /// samples says anything about what the machine is doing now.
    @ObservationIgnored private var lastTicks: (busy: UInt64, total: UInt64)?
    @ObservationIgnored private var diskCountdown = 0
    @ObservationIgnored private var lastCoreTicks: [(busy: UInt64, total: UInt64)] = []

    private init() {}

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so this is already the main actor.
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.2
        // .common so the numbers keep moving while a menu or drag is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // Drop the baseline: the next start() must measure a fresh interval,
        // not the whole idle gap since we were stopped.
        lastTicks = nil
        lastCoreTicks = []
    }

    private func sample() {
        sampleCPU()
        sampleCores()
        sampleMemory()
        sampleSwap()
        // Disk moves in megabytes-per-minute, not per-second. Every 30s is plenty.
        if diskCountdown <= 0 {
            sampleDisk()
            diskCountdown = 30
        }
        diskCountdown -= 1
        record()
    }

    // MARK: - CPU

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let ticks = info.cpu_ticks  // (user, system, idle, nice)
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        let total = busy + UInt64(ticks.2)
        defer { lastTicks = (busy, total) }

        guard let last = lastTicks else { return }  // first sample is only a baseline
        let deltaTotal = total >= last.total ? total - last.total : 0
        let deltaBusy = busy >= last.busy ? busy - last.busy : 0
        guard deltaTotal > 0 else { return }
        cpu = min(Double(deltaBusy) / Double(deltaTotal), 1)
    }

    /// The same tick arithmetic as `sampleCPU`, per core. The kernel hands
    /// back an array it allocated in our address space, which has to be
    /// given back on every path.
    private func sampleCores() {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        var ticks: [(busy: UInt64, total: UInt64)] = []
        for core in 0 ..< Int(count) {
            let base = core * stride
            func at(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            let busy = at(CPU_STATE_USER) + at(CPU_STATE_SYSTEM) + at(CPU_STATE_NICE)
            ticks.append((busy, busy + at(CPU_STATE_IDLE)))
        }
        defer { lastCoreTicks = ticks }
        // A first sample, or a core count that changed under us, is only a
        // baseline.
        guard lastCoreTicks.count == ticks.count else { return }
        cores = zip(ticks, lastCoreTicks).map { now, last in
            let total = now.total >= last.total ? now.total - last.total : 0
            let busy = now.busy >= last.busy ? now.busy - last.busy : 0
            return total > 0 ? min(Double(busy) / Double(total), 1) : 0
        }
    }

    // MARK: - Memory

    private func sampleMemory() {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        guard physical > 0 else { return }
        // Inactive pages are reclaimable, so macOS counts them as available -
        // including them would read ~100% on any machine that has been up a while.
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        memory = min(Double(pages * Self.pageSize) / physical, 1)
    }

    /// Pressure and swap both come from sysctl and both are optional: a
    /// failed read keeps the last answer.
    private func sampleSwap() {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            // 1, 2 and 4, as the kernel's DISPATCH_MEMORYPRESSURE_* flags.
            pressure = level >= 4 ? .critical : level >= 2 ? .warning : .normal
        }
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            swapUsed = Int64(swap.xsu_used)
            swapTotal = Int64(swap.xsu_total)
        }
    }

    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else { return 4096 }
        return UInt64(size)
    }()

    // MARK: - Disk

    private func sampleDisk() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              // "Important usage" is what Finder shows: purgeable space counts as free.
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return }
        disk = min(max(1 - Double(available) / Double(total), 0), 1)
        diskFree = Int64(available)
        diskTotal = Int64(total)
    }
}
