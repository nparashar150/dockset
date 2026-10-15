import Foundation
import Observation
import SystemConfiguration

/// Throughput across every non-loopback interface, in bytes per second.
///
/// The kernel only hands out cumulative byte counters, so the rate is a delta
/// between samples divided by the real elapsed time - the timer can fire late,
/// and dividing by a nominal 1s would over-report after a sleep.
@MainActor @Observable
final class NetworkMetrics {
    static let shared = NetworkMetrics()

    /// How many samples the sparkline widgets can draw.
    static let historyLength = 60

    private(set) var download: Double = 0
    private(set) var upload: Double = 0
    /// Most recent last, at most `historyLength` entries.
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previous: (rx: UInt64, tx: UInt64, at: TimeInterval)?

    private init() {}

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // Next start() re-baselines instead of charging the whole idle gap
        // to a single sample.
        previous = nil
    }

    private func sample() {
        guard let totals = Self.interfaceTotals() else { return }
        // systemUptime, not Date: a clock adjustment must not invent traffic.
        let at = ProcessInfo.processInfo.systemUptime
        defer { previous = (totals.rx, totals.tx, at) }

        guard let last = previous else { return }  // first sample is only a baseline
        let elapsed = at - last.at
        guard elapsed > 0 else { return }

        // Counters are 32-bit and wrap, and an interface coming back up resets
        // them; a negative delta is a reset, not 4GB of traffic in one second.
        download = Double(totals.rx >= last.rx ? totals.rx - last.rx : 0) / elapsed
        upload = Double(totals.tx >= last.tx ? totals.tx - last.tx : 0) / elapsed
        record(download, into: &downloadHistory)
        record(upload, into: &uploadHistory)
    }

    private func record(_ value: Double, into history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    /// Cumulative bytes in/out summed over every non-loopback link.
    private static func interfaceTotals() -> (rx: UInt64, tx: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0 else { continue }
            // Byte counters live on the link-layer entry, not the IP ones -
            // counting every address family would multiply the same traffic.
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            rx += UInt64(data.pointee.ifi_ibytes)
            tx += UInt64(data.pointee.ifi_obytes)
        }
        return (rx, tx)
    }
}

// MARK: - Interfaces

/// One active link, for the network panel.
struct NetworkInterface: Identifiable, Hashable, Sendable {
    /// The BSD name, en0 and the like.
    var id: String
    /// What System Settings calls it: "Wi-Fi", "Thunderbolt Ethernet".
    var name: String
    var ipv4: String?
    var ipv6: String?
    /// Carries the default route.
    var isPrimary: Bool

    /// Read once as the panel opens. Addresses change on a network switch,
    /// not by the second, so this is not on the sampler's clock.
    ///
    /// Only links that are up and hold an address: a Mac lists a dozen
    /// interfaces, bridges and Bluetooth PAN and inactive Thunderbolt ports
    /// among them, and naming those would bury the one that is in use.
    static func active() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var v4: [String: String] = [:]
        var v6: [String: String] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let address = entry.pointee.ifa_addr else { continue }
            let bsd = String(cString: entry.pointee.ifa_name)
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if family == AF_INET {
                v4[bsd] = v4[bsd] ?? text
            } else if !text.hasPrefix("fe80"), v6[bsd] == nil {
                // Link-local is on every interface and routes nowhere.
                v6[bsd] = text
            }
        }

        let names = displayNames()
        let primary = primaryInterface()
        return Set(v4.keys).union(v6.keys)
            // Tunnels and Apple's own peer-to-peer links carry addresses but
            // are not something the user connected to.
            .filter { names[$0] != nil || $0 == primary }
            .map { bsd in
                NetworkInterface(id: bsd, name: names[bsd] ?? bsd, ipv4: v4[bsd], ipv6: v6[bsd],
                                 isPrimary: bsd == primary)
            }
            .sorted { ($0.isPrimary ? 0 : 1, $0.id) < ($1.isPrimary ? 0 : 1, $1.id) }
    }

    private static func displayNames() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            else { continue }
            names[bsd] = name
        }
        return names
    }

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Docket" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }
}
