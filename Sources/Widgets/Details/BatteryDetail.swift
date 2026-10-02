import SwiftUI

/// Every battery, one row each, where the tile had room for a row of glyphs.
///
/// The tile's gauge says how full a device is and nothing about which device
/// it is - a glyph inside a 42pt ring is all a shelf affords. A panel row is
/// wide enough to name the device, say whether it is charging, and still give
/// the percentage the size it deserves.
struct BatteryDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        let kinds = devices
        // The first device leads, large, and its charge colours the whole
        // card: green with room, amber getting low, red nearly out. The rest
        // follow as glass rows.
        let lead = kinds.first.map(device)
        DetailCard {
            MeshBackdrop(color: ground(lead))
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if let lead {
                    hero(lead)
                    TickMeter(fraction: lead.present ? lead.level : 0)
                }
                // Quiet rows rather than glass cards with rings: a name, how
                // it is doing and a number, one line each.
                if kinds.count > 1 {
                    VStack(spacing: 10) {
                        ForEach(kinds.dropFirst(), id: \.self) { kind in
                            row(device(kind))
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        // The panel can list accessories the tile was never configured to
        // show, so it cannot rely on a tile having started the sampler.
        .onAppear { if !context.isPreview { BatteryMetrics.shared.start() } }
    }

    /// The level as the card's colour. Charging reads as healthy whatever
    /// the level, since the level is on its way up.
    private func ground(_ device: BatteryDevice?) -> Color {
        guard let device, device.present else { return Color(white: 0.3) }
        if device.charging || device.level > 0.5 { return Color(red: 0.12, green: 0.55, blue: 0.3) }
        if device.level > 0.2 { return Color(red: 0.75, green: 0.48, blue: 0.08) }
        return Color(red: 0.72, green: 0.16, blue: 0.14)
    }

    private func hero(_ device: BatteryDevice) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(device.kind.name, systemImage: device.kind.symbol)
                    .font(WidgetStyle.label(14))
                    .foregroundStyle(WidgetStyle.primary)
                if device.present {
                    let value = Int((min(max(device.level, 0), 1) * 100).rounded())
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("\(value)")
                            .font(.system(size: 48, weight: .light))
                            .monospacedDigit()
                            .foregroundStyle(WidgetStyle.primary)
                            .rollingValue(value)
                        Text("%")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    // A dash, never a zero: a device that is not here has no
                    // level.
                    Text("-")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(caption(device))
                    .font(WidgetStyle.label(12))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
            if device.charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 6)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func row(_ device: BatteryDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 13))
                .foregroundStyle(WidgetStyle.secondary)
                .frame(width: 18)
            Text(device.kind.name)
                .font(WidgetStyle.label(13))
                .foregroundStyle(WidgetStyle.primary)
            Text(caption(device))
                .font(WidgetStyle.caption(11))
                .foregroundStyle(WidgetStyle.secondary)
            Spacer(minLength: 8)
            percent(device)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // One row is one fact; read as four labels it becomes a word salad.
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    private var present: Color { Color(hex: MetricColor.batteryPresent) }

    /// Configured devices always, plus anything else actually reporting.
    ///
    /// A device in the config was asked for, so "Not connected" is the answer
    /// it is owed rather than being dropped. The rest are here because the
    /// panel is where the widget says everything it knows - a tile left at the
    /// default lists the Mac alone, and a panel that did the same would only
    /// restate it. Slot order comes from the service so the rows do not
    /// reshuffle as accessories come and go.
    private var devices: [BatteryDeviceKind] {
        let parsed = Set(instance.config
            .strings("devices", default: ["mac"])
            .compactMap(BatteryDeviceKind.init(configValue:)))
        let configured = parsed.isEmpty ? Set([BatteryDeviceKind.mac]) : parsed
        return BatteryMetrics.shared.devices
            .map(\.kind)
            .filter { configured.contains($0) || device($0).present }
    }

    /// The service's own model rather than a second one: an absent device is
    /// `.absent`, whose zero level is never read because `present` is false.
    private func device(_ kind: BatteryDeviceKind) -> BatteryDevice {
        if context.isPreview {
            switch kind {
            case .mac: return BatteryDevice(id: "mac", kind: kind, level: 0.76, charging: false, present: true)
            case .pods: return BatteryDevice(id: "pods", kind: kind, level: 0.85, charging: false, present: true)
            case .podsCase: return BatteryDevice(id: "podsCase", kind: kind, level: 0.32, charging: true, present: true)
            case .keyboard: return BatteryDevice(id: "keyboard", kind: kind, level: 0.92, charging: false, present: true)
            }
        }
        guard let device = BatteryMetrics.shared.device(kind), device.present else {
            return .absent(kind)
        }
        return device
    }

    /// The tile's thresholds, so a battery does not change colour on its way
    /// from the shelf into the panel.
    private func tint(_ device: BatteryDevice) -> Color {
        guard device.present, !device.charging else { return present }
        if device.level <= 0.10 { return Color(hex: "#FF453A") }
        if device.level <= 0.20 { return Color(hex: "#FF9F0A") }
        return present
    }

    private func caption(_ device: BatteryDevice) -> String {
        guard device.present else { return "Not connected" }
        return device.charging ? "Charging" : "On battery"
    }

    @ViewBuilder
    private func percent(_ device: BatteryDevice) -> some View {
        if device.present {
            let value = Int((min(max(device.level, 0), 1) * 100).rounded())
            HStack(spacing: 0) {
                Text("\(value)")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(WidgetStyle.primary)
                    .rollingValue(value)
                Text("%")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WidgetStyle.secondary)
            }
        } else {
            // A dash, never a zero: an accessory that is not here has no level.
            Text("-")
                .font(WidgetStyle.value(20))
                .foregroundStyle(WidgetStyle.secondary)
        }
    }
}
