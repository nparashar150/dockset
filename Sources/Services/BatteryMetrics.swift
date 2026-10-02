import Foundation
import IOKit
import IOKit.ps
import Observation

enum BatteryDeviceKind: String, Sendable {
    case mac, pods, podsCase, keyboard
}

struct BatteryDevice: Identifiable, Sendable {
    var id: String
    var kind: BatteryDeviceKind
    /// 0...1. Meaningless unless `present`.
    var level: Double
    var charging: Bool
    /// On mains power. Not the same as charging: a full battery on the
    /// adapter reports not charging, and was shown as "On battery" while the
    /// menu bar beside it showed the plug.
    var pluggedIn = false
    /// False = nothing reported this battery; render it as unavailable rather
    /// than as an empty one.
    var present: Bool

    /// What the device is doing, in words, everywhere it is said.
    var status: String {
        if charging { return "Charging" }
        if pluggedIn { return level >= 0.99 ? "Charged" : "On power" }
        return "On battery"
    }

    static func absent(_ kind: BatteryDeviceKind) -> BatteryDevice {
        BatteryDevice(id: kind.rawValue, kind: kind, level: 0, charging: false, present: false)
    }
}

/// Battery levels for the Mac and whatever Apple accessories are connected.
///
/// The Mac comes from the power-source API; accessories publish a
/// `BatteryPercent` in the IO registry. Anything that does not answer is
/// reported absent - a desktop Mac and a missing pair of AirPods look the
/// same to this class, and both are honest.
@MainActor @Observable
final class BatteryMetrics {
    static let shared = BatteryMetrics()

    /// Always one entry per kind, in this order, so a view can lay out fixed slots.
    private(set) var devices: [BatteryDevice] = BatteryMetrics.order.map(BatteryDevice.absent)

    private static let order: [BatteryDeviceKind] = [.mac, .pods, .podsCase, .keyboard]

    @ObservationIgnored private var timer: Timer?

    private init() {}

    func device(_ kind: BatteryDeviceKind) -> BatteryDevice? {
        devices.first { $0.kind == kind }
    }

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
    }

    private func sample() {
        var found = Self.accessoryDevices()
        if let mac = Self.macDevice() { found[.mac] = mac }
        devices = Self.order.map { found[$0] ?? .absent($0) }
    }

    // MARK: - Mac

    private static func macDevice() -> BatteryDevice? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType else { continue }
            guard let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let capacity = description[kIOPSMaxCapacityKey as String] as? Int, capacity > 0
            else { continue }
            return BatteryDevice(
                id: BatteryDeviceKind.mac.rawValue,
                kind: .mac,
                level: min(Double(current) / Double(capacity), 1),
                charging: description[kIOPSIsChargingKey as String] as? Bool ?? false,
                pluggedIn: description[kIOPSPowerSourceStateKey as String] as? String == kIOPSACPowerValue,
                present: true
            )
        }
        return nil  // desktop Mac, or the API gave us nothing
    }

    // MARK: - Accessories

    /// AirPods, their case and a Magic Keyboard all hang off
    /// `AppleDeviceManagementHIDEventService` and publish battery percentages
    /// as plain registry properties.
    private static func accessoryDevices() -> [BatteryDeviceKind: BatteryDevice] {
        var found: [BatteryDeviceKind: BatteryDevice] = [:]
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return found
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let properties = properties(of: service) else { continue }
            let name = ((properties["Product"] as? String) ?? "").lowercased()

            if name.contains("pod") || name.contains("beats") {
                // Two buds, one reading: the emptier one is the one that dies first.
                let left = percent(properties["BatteryPercentLeft"])
                let right = percent(properties["BatteryPercentRight"])
                let combined = [left, right].compactMap(\.self).min() ?? percent(properties["BatteryPercent"])
                if let combined, found[.pods] == nil {
                    found[.pods] = BatteryDevice(id: "pods", kind: .pods, level: combined, charging: false, present: true)
                }
                if let caseLevel = percent(properties["BatteryPercentCase"]), found[.podsCase] == nil {
                    found[.podsCase] = BatteryDevice(id: "podsCase", kind: .podsCase, level: caseLevel, charging: false, present: true)
                }
            } else if name.contains("keyboard") {
                if let level = percent(properties["BatteryPercent"]), found[.keyboard] == nil {
                    found[.keyboard] = BatteryDevice(id: "keyboard", kind: .keyboard, level: level, charging: false, present: true)
                }
            }
        }
        return found
    }

    private static func properties(of service: io_service_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return properties
    }

    /// Registry percentages are 0...100 integers, and a disconnected accessory
    /// that still has a stale registry entry reports 0 - treat that as unknown.
    private static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw > 0, raw <= 100 else { return nil }
        return raw / 100
    }
}

extension BatteryMetrics {
    /// Config-string form, for callers that hold raw config values.
    func isPresent(configValue: String) -> Bool {
        let kind: BatteryDeviceKind? = switch configValue {
        case "mac": .mac
        case "pods": .pods
        case "case": .podsCase
        case "keyboard": .keyboard
        default: nil
        }
        guard let kind else { return false }
        return device(kind)?.present == true
    }
}
