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

    /// Rolling history so widgets can draw a graph rather than only a number.
    /// Most recent last; grows to `historyLength` then slides.
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    /// Slow movers, kept so the panel can draw every reading on one chart.
    private(set) var diskHistory: [Double] = []
    private(set) var batteryHistory: [Double] = []
    nonisolated static let historyLength = 60

    func history(for metric: String) -> [Double] {
        switch metric {
        case "cpu": cpuHistory
        case "memory": memoryHistory
        case "disk": diskHistory
        case "battery": batteryHistory
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
        Self.append(cpu, to: &cpuHistory)
        Self.append(memory, to: &memoryHistory)
        Self.append(disk, to: &diskHistory)
        // The Mac's own battery, off its sampler. A Mac with none keeps no
        // history rather than a line along zero.
        if let mac = BatteryMetrics.shared.device(.mac), mac.present {
            Self.append(mac.level, to: &batteryHistory)
        }
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst() }
    }

    @ObservationIgnored private var timer: Timer?
    /// CPU ticks are cumulative since boot; only the delta between two
    /// samples says anything about what the machine is doing now.
    @ObservationIgnored private var lastTicks: (busy: UInt64, total: UInt64)?
    @ObservationIgnored private var diskCountdown = 0

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
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
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
