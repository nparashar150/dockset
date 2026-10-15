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

// MARK: - Mac battery details

/// What the battery panel adds under the Mac's level: its condition, how worn
/// it is, how long it has left and how much power is moving.
///
/// Read only while the panel is open, off the smart-battery registry entry. It
/// is a larger read than the level, and nothing on the shelf needs it once a
/// second. Every field is optional: a desktop Mac has none of them, and a
/// laptop leaves some unreported while it settles after waking.
struct MacBatteryDetails: Sendable, Equatable {
    /// "Normal" or "Service Recommended", in the words System Settings uses.
    var condition: String?
    var cycles: Int?
    /// Full charge as a share of what the battery held new.
    var maximumCapacity: Int?
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    /// Into the battery when positive, out of it when negative.
    var watts: Double?
    var adapterWatts: Int?

    static func read() -> MacBatteryDetails? {
        var details = MacBatteryDetails()
        var isLaptop = false

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType
                else { continue }
                isLaptop = true
                // The power-source API calls a healthy battery "Good"; the
                // Battery pane calls it "Normal", and that is the word people
                // have seen.
                if let health = description[kIOPSBatteryHealthKey as String] as? String {
                    details.condition = health == "Good" ? "Normal" : "Service Recommended"
                }
                // -1 while macOS is still estimating; that is no estimate.
                if let empty = description[kIOPSTimeToEmptyKey as String] as? Int, empty > 0 {
                    details.minutesToEmpty = empty
                }
                if let full = description[kIOPSTimeToFullChargeKey as String] as? Int, full > 0 {
                    details.minutesToFull = full
                }
            }
        }
        guard isLaptop else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func int(_ key: String) -> Int? {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber)?.intValue
            }
            details.cycles = int("CycleCount")
            // Nominal over design, not MaxCapacity: on Apple silicon the
            // latter is already a percentage pinned near 100.
            if let nominal = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity"),
               let design = int("DesignCapacity"), design > 0 {
                details.maximumCapacity = min(100, Int((Double(nominal) / Double(design) * 100).rounded()))
            }
            // Amperage is signed (negative discharging) and both are in
            // milli-units. The registry stores a negative current as an
            // unsigned 64-bit pattern on some models, hence the conversion.
            if let amps = (IORegistryEntryCreateCFProperty(service, "Amperage" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.int64Value,
               let volts = int("Voltage") {
                let milliamps = Double(Int16(truncatingIfNeeded: amps))
                details.watts = milliamps * Double(volts) / 1_000_000
            }
        }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = adapter[kIOPSPowerAdapterWattsKey as String] as? Int, watts > 0 {
            details.adapterWatts = watts
        }
        return details
    }
}
