import SwiftUI

/// Current conditions for one city: symbol, temperature and either the city
/// name, the condition text, or a short hourly strip.
struct WeatherTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Warm card. The weather tile is the one tinted widget in the shelf, and
    /// the tint is part of how it reads at a glance.
    private static let sample = WeatherNow(temperatureC: 18,
                                           symbolName: "cloud.sun.fill",
                                           condition: "Partly Cloudy")

    private var layout: String { instance.config.string("layout", default: "current") }
    private var fahrenheit: Bool { instance.config.bool("fahrenheit") }

    /// An empty `city` means "wherever I am".
    ///
    /// That is the default now. The shipped default was "Oslo" - the city in
    /// the reference screenshots - and a widget that confidently reports the
    /// weather somewhere the user has never been is worse than one that asks.
    private var city: String {
        let stored = instance.config.string("city").trimmingCharacters(in: .whitespaces)
        if !stored.isEmpty { return stored }
        return LocationService.shared.city ?? ""
    }

    /// What the tile says where the city goes.
    ///
    /// Never blank. This app is an accessory and never becomes frontmost, so
    /// a location prompt can go unseen the same way the automation one does -
    /// and a widget showing "--°" under no name at all gives the user nothing
    /// to act on. Say which of the two states it is in.
    private var placeCaption: String {
        if !city.isEmpty { return city }
        let service = LocationService.shared
        return (service.denied || service.unavailable) ? "Set a city…" : "Locating…"
    }

    /// The library has no live data, so it shows the reference sample.
    private var weather: WeatherNow? {
        context.isPreview ? Self.sample : WeatherService.shared.current
    }

    private var hours: [WeatherHour] {
        context.isPreview ? Self.sampleHours(from: context.now) : WeatherService.shared.hourly
    }

    var body: some View {
        // No tint of its own. Weather ran an orange card while the clock,
        // battery and activity tiles beside it used the neutral recess, which
        // is the inconsistency - the reference shelf tints only what is
        // genuinely coloured (a sticky note's paper), never a readout.
        WidgetSurface {
            if context.position.isVertical {
                column
            } else {
                switch layout {
                case "hourly": hourlyStrip
                case "conditions": wide(caption: weather?.condition ?? "-")
                default: wide(caption: placeCaption)
                }
            }
        }
        .onAppear { load() }
        .onChange(of: city) { load() }
        // `now` ticks every second; only act when the 15-minute bucket turns
        // over, which is the cadence MET asks for anyway.
        .onChange(of: Int(context.now.timeIntervalSince1970) / 900) {
            guard !context.isPreview else { return }
            Task { await WeatherService.shared.refresh() }
        }
    }

    private func load() {
        guard !context.isPreview else { return }
        // Asked for only because a weather widget is on the shelf, and only
        // when no city has been typed in.
        if instance.config.string("city").trimmingCharacters(in: .whitespaces).isEmpty {
            LocationService.shared.start()
        }
        let city = city
        guard !city.isEmpty else { return }
        Task { await WeatherService.shared.setLocation(city: city) }
    }

    // MARK: - Layouts

    /// The shelf's badge and reading: the condition's symbol in the square,
    /// the temperature over a caption beside it. The caption shrinks to one
    /// line like every other tile's, so a long condition reads smaller rather
    /// than pushing a second line out of the card.
    private func wide(caption: String) -> some View {
        HStack(spacing: 10) {
            TileBadge { icon(size: 19) }
            TileReading(value: weather.map { degrees($0.temperatureC) } ?? "--°", caption: caption)
            Spacer(minLength: 0)
        }
    }

    /// The next few hours, each a small symbol over its temperature. Falls
    /// back to the single reading while the forecast is still empty.
    @ViewBuilder private var hourlyStrip: some View {
        if hours.isEmpty {
            wide(caption: placeCaption)
        } else {
            // Four ahead, not five, because the first cell is now.
            //
            // The series is filtered to times after the present, so this
            // strip showed five future hours and not the temperature
            // outside, which is the number anybody looking at a weather
            // widget wants first. Leading with it costs one forecast hour,
            // which is the cheapest thing on the row.
            let shown = Array(hours.prefix(4))
            // Only when there is something to say. A dry afternoon would
            // otherwise get five empty gutters, which is chrome pretending to
            // be data and costs the strip height it needs for the figures.
            let wet = shown.contains { $0.precipitationMM >= 0.1 }
            // Scaled to the heaviest hour on screen rather than to a fixed
            // ceiling: 2mm against a 10mm scale is a stub that reads as none
            // at all, and what the strip is for is the shape of the next few
            // hours against each other.
            let peak = max(0.2, shown.map(\.precipitationMM).max() ?? 0)
            HStack(spacing: 0) {
                if let weather {
                    VStack(spacing: 1) {
                        Text("Now")
                            .font(WidgetStyle.caption(10))
                            .foregroundStyle(WidgetStyle.primary)
                            .monospacedDigit()
                        Image(systemName: weather.symbolName)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(WidgetStyle.primary)
                            .font(.system(size: 15))
                        Text(degrees(weather.temperatureC))
                            .font(WidgetStyle.label(12))
                            .foregroundStyle(WidgetStyle.primary)
                            .monospacedDigit()
                        // An empty gutter rather than none, so the row of
                        // figures keeps one baseline when the rest are wet.
                        if wet { rain(0, peak: peak) }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                }
                ForEach(shown, id: \.date) { hour in
                    VStack(spacing: 1) {
                        Text(hour.date.formatted(.dateTime.hour()))
                            .font(WidgetStyle.caption(10))
                            .foregroundStyle(WidgetStyle.secondary)
                            .monospacedDigit()
                        Image(systemName: hour.symbolName)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(WidgetStyle.primary)
                            .font(.system(size: 15))
                        Text(degrees(hour.temperatureC))
                            .font(WidgetStyle.label(12))
                            .foregroundStyle(WidgetStyle.primary)
                            .monospacedDigit()
                        if wet { rain(hour.precipitationMM, peak: peak) }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// How much rain this hour is bringing, against the heaviest on screen.
    ///
    /// A track behind the fill, so an hour with none still reads as an hour
    /// that was asked rather than as a gap in the row. Floored at a sliver
    /// once there is any at all: a hair of drizzle rounding away to nothing
    /// would say "dry" for an hour that is not.
    private func rain(_ mm: Double, peak: Double) -> some View {
        let height: CGFloat = 5
        return Capsule()
            .fill(WidgetStyle.secondary.opacity(0.22))
            .frame(width: 14, height: height)
            .overlay(alignment: .bottom) {
                if mm >= 0.05 {
                    Capsule()
                        .fill(Self.rainBlue)
                        .frame(width: 14, height: max(1.5, height * min(1, mm / peak)))
                }
            }
            .accessibilityLabel(mm >= 0.05
                                ? "\(mm.formatted(.number.precision(.fractionLength(1))))mm"
                                : "no rain")
    }

    private static let rainBlue = Color(hex: "#5AC8FA")

    /// 56pt of usable width: everything centred and stacked, the symbol
    /// smaller and the caption down to a single tight line.
    private var column: some View {
        // Badge, value, caption: the same column every side-shelf tile uses.
        VStack(spacing: 2) {
            TileBadge(size: 30) { icon(size: 15) }
            temperature(weather?.temperatureC, size: 16)
            Text(columnCaption)
                .font(.system(size: 11))
                .foregroundStyle(WidgetStyle.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    /// What the third line says on a 76pt column.
    ///
    /// Hourly used to fall through to the city, so on a side shelf it was
    /// indistinguishable from Current and the style picker appeared to do
    /// nothing. Eight columns of forecast genuinely do not fit here, so it
    /// shows the part of the forecast that does: the next hour.
    private var columnCaption: String {
        switch layout {
        case "conditions":
            return weather?.condition ?? "-"
        case "hourly":
            guard let next = hours.first else { return city }
            let hour = next.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)))
            return "\(hour)  \(degrees(next.temperatureC))"
        default:
            return city
        }
    }

    // MARK: - Pieces

    private func icon(size: CGFloat) -> some View {
        // Hierarchical white rather than multicolour: a yellow sun and blue
        // rain were the loudest marks on a neutral shelf.
        Image(systemName: weather?.symbolName ?? "cloud.sun.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(WidgetStyle.primary)
            .font(.system(size: size))
            .frame(height: size)
            // The same slow breath as the panel's, so the tile reads as live
            // beside CPU and Now Playing. Never in the library, where nothing
            // on the card is live.
            .symbolEffect(.breathe, options: .repeating, isActive: !reduceMotion && !context.isPreview)
    }

    /// Big figure with a lighter degree mark riding on top of it. A missing
    /// reading shows dashes - never a zero that could pass for real weather.
    private func temperature(_ celsius: Double?, size: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(celsius.map { String(Int(converted($0).rounded())) } ?? "--")
                .font(WidgetStyle.value(size))
                .foregroundStyle(WidgetStyle.primary)
                .monospacedDigit()
            Text("°")
                .font(WidgetStyle.value(size * 0.7))
                .foregroundStyle(WidgetStyle.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private func degrees(_ celsius: Double) -> String {
        "\(Int(converted(celsius).rounded()))°"
    }

    private func converted(_ celsius: Double) -> Double {
        fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    private static func sampleHours(from date: Date) -> [WeatherHour] {
        let temperatures: [Double] = [18, 19, 19, 17, 16]
        let symbols = ["cloud.sun.fill", "sun.max.fill", "cloud.sun.fill", "cloud.rain.fill", "cloud.fill"]
        return zip(temperatures, symbols).enumerated().map { index, pair in
            WeatherHour(date: date.addingTimeInterval(Double(index + 1) * 3600),
                        temperatureC: pair.0,
                        symbolName: pair.1)
        }
    }
}
