import SwiftUI

/// Charge for the Mac and whatever Apple accessories are paired with it.
struct BatteryTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        WidgetSurface {
            if context.position.isVertical {
                column
            } else {
                switch layout {
                case "icon": icons
                case "status" where devices.count == 1: status(devices[0])
                default: gauges
                }
            }
        }
        // ponytail: start-only; one sampler feeds every battery tile.
        .onAppear { if !context.isPreview { BatteryMetrics.shared.start() } }
    }

    // MARK: Layouts

    @ViewBuilder
    private func status(_ kind: BatteryDeviceKind) -> some View {
        let reading = reading(kind)
        let symbol = Image(systemName: kind.symbol)
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(reading.present ? WidgetStyle.primary : WidgetStyle.secondary)

        if context.position.isVertical {
            // A column has the height for the stacked card this was drawn as.
            VStack(spacing: 4) {
                symbol
                percent(reading, size: 30)
                Text(caption(reading))
                    .font(WidgetStyle.caption(12))
                    .foregroundStyle(WidgetStyle.secondary)
            }
            .lineLimit(1)
        } else {
            // A bottom shelf is a 62pt strip: three stacked rows overflow it
            // and the caption gets sliced off. Lay it out across instead, as
            // the shelf's badge and reading: the ring is the level, in white
            // unless the battery is low enough to earn a colour.
            HStack(spacing: 10) {
                TileBadge {
                    ZStack {
                        TileRing(progress: reading.present ? reading.level : 0,
                                 tint: ringTint(reading))
                        Image(systemName: kind.symbol)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(reading.present ? WidgetStyle.primary : WidgetStyle.secondary)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if reading.charging { bolt }
                }
                TileReading(value: percentText(reading), caption: caption(reading))
                Spacer(minLength: 0)
            }
        }
    }

    /// The same gauge the activity tile draws: the arc is the reading, and the
    /// middle says what it is of. No figure underneath - it restates the arc
    /// and is what made the ring look cramped next to the metric rings.
    private var gauges: some View {
        HStack(spacing: 0) {
            ForEach(devices, id: \.self) { kind in
                let reading = reading(kind)
                MetricProgressRing(progress: reading.present ? reading.level : 0,
                                   tint: tint(reading),
                                   track: reading.present
                                       ? tint(reading).opacity(0.16)
                                       : Color.primary.opacity(0.10),
                                   diameter: 42,
                                   lineWidth: 4.5) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(reading.present ? tint(reading) : WidgetStyle.secondary)
                }
                .overlay(alignment: .bottomTrailing) {
                    if reading.charging { bolt }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(kind.name)
                .accessibilityValue(caption(reading))
            }
        }
        .lineLimit(1)
    }

    /// Low batteries earn a colour. Everything else stays the neutral fill, so
    /// the tile is not a traffic light while nothing is wrong.
    private func tint(_ reading: Reading) -> Color {
        guard reading.present, !reading.charging else { return present }
        if reading.level <= 0.10 { return Color(hex: "#FF453A") }
        if reading.level <= 0.20 { return Color(hex: "#FF9F0A") }
        return present
    }

    /// White while nothing is wrong; the low-battery colours only when they
    /// mean something.
    private func ringTint(_ reading: Reading) -> Color {
        guard reading.present, !reading.charging else { return WidgetStyle.primary }
        if reading.level <= 0.10 { return Color(hex: "#FF453A") }
        if reading.level <= 0.20 { return Color(hex: "#FF9F0A") }
        return WidgetStyle.primary
    }

    private func percentText(_ reading: Reading) -> String {
        reading.present ? "\(Int((min(max(reading.level, 0), 1) * 100).rounded()))%" : "-"
    }

    private var icons: some View {
        HStack(spacing: 8) {
            ForEach(devices, id: \.self) { kind in
                let reading = reading(kind)
                Image(systemName: kind.symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(reading.present ? present : WidgetStyle.secondary)
                    .frame(width: 44)
                    .overlay(alignment: .topTrailing) {
                        if reading.charging { bolt }
                    }
            }
        }
    }

    /// One 62pt row per device - `WidgetCatalog.verticalHeight` hands out
    /// `devices * 62`. A lone device gets the bigger ring the room allows.
    private var column: some View {
        VStack(spacing: 0) {
            ForEach(devices, id: \.self) { kind in
                let reading = reading(kind)
                let single = devices.count == 1
                VStack(spacing: 3) {
                    // White, as on the wide card, and coloured only once the
                    // level is low enough to earn it: a green ring per device
                    // turned a side column into a traffic light.
                    MetricProgressRing(progress: reading.present ? reading.level : 0,
                                       tint: ringTint(reading).opacity(0.85),
                                       track: WidgetStyle.primary.opacity(0.1),
                                       diameter: single ? 42 : 34,
                                       lineWidth: 3) {
                        percent(reading, size: single ? 14 : 11)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if reading.charging { bolt }
                    }
                    Image(systemName: kind.symbol)
                        .font(.system(size: single ? 13 : 11, weight: .regular))
                        .foregroundStyle(reading.present ? WidgetStyle.primary : WidgetStyle.secondary)
                }
                .frame(height: 62)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private var bolt: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(WidgetStyle.primary)
            .padding(3)
            .background(Circle().fill(.background))
    }

    // MARK: Data

    private var present: Color { Color(hex: MetricColor.batteryPresent) }

    private var layout: String { instance.config.string("layout", default: "status") }

    private var devices: [BatteryDeviceKind] {
        let parsed = instance.config
            .strings("devices", default: ["mac"])
            .compactMap(BatteryDeviceKind.init(configValue:))
        // Accessories are opt-in, so anything listed here was explicitly
        // asked for: show it even when disconnected (as a dash, never an
        // invented percentage) rather than silently dropping it.
        return parsed.isEmpty ? [.mac] : parsed
    }

    /// What a tile needs to draw one device. An absent device keeps `level` at
    /// zero - a missing accessory must never show an invented percentage.
    private struct Reading {
        var level: Double
        var charging: Bool
        var present: Bool
    }

    private func reading(_ kind: BatteryDeviceKind) -> Reading {
        if context.isPreview {
            switch kind {
            case .mac: return Reading(level: 0.76, charging: false, present: true)
            case .pods: return Reading(level: 0.85, charging: false, present: true)
            case .podsCase: return Reading(level: 0.32, charging: true, present: true)
            case .keyboard: return Reading(level: 0.92, charging: false, present: true)
            }
        }
        guard let device = BatteryMetrics.shared.device(kind), device.present else {
            return Reading(level: 0, charging: false, present: false)
        }
        return Reading(level: device.level, charging: device.charging, present: true)
    }

    private func caption(_ reading: Reading) -> String {
        guard reading.present else { return "Not connected" }
        return reading.charging ? "Charging" : "On battery"
    }

    @ViewBuilder
    private func percent(_ reading: Reading, size: CGFloat) -> some View {
        if reading.present {
            HStack(spacing: 0) {
                Text("\(Int((min(max(reading.level, 0), 1) * 100).rounded()))")
                    .font(.system(size: size, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(WidgetStyle.primary)
                    .rollingValue(Int((min(max(reading.level, 0), 1) * 100).rounded()))
                Text("%")
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(WidgetStyle.secondary)
            }
        } else {
            Text("-")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(WidgetStyle.secondary)
        }
    }
}

extension BatteryDeviceKind {
    /// Config spells the AirPods case "case"; the service calls it `podsCase`.
    init?(configValue: String) {
        if configValue == "case" { self = .podsCase } else if let kind = BatteryDeviceKind(rawValue: configValue) {
            self = kind
        } else {
            return nil
        }
    }

    /// Spoken by the screen reader, since the gauge shows only a glyph.
    var name: String {
        switch self {
        case .mac: "Battery"
        case .pods: "AirPods"
        case .podsCase: "AirPods case"
        case .keyboard: "Keyboard"
        }
    }

    var symbol: String {
        switch self {
        case .mac: "laptopcomputer"
        case .pods: "airpods"
        case .podsCase: "airpodspro.chargingcase.wireless.fill"
        case .keyboard: "keyboard"
        }
    }
}
