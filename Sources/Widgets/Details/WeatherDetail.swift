import SwiftUI

/// Weather said at length: the reading the tile leads with, the condition and
/// the city behind it, and every hour MET published rather than the five a
/// card has room for.
///
/// Nothing here fetches. The panel only ever opens from a tile that has
/// already pointed the service at a city and refreshed it, so this renders
/// whatever the service holds and admits it when that is nothing - a refresh
/// of its own would be refused by the 15-minute throttle anyway.
///
/// Only what `WeatherService` actually publishes: a temperature, a symbol, a
/// condition and the hourly series. No humidity, wind, sunrise or daily high
/// and low, because the compact endpoint the service calls carries none of
/// them and a panel is not worth a second request.
struct WeatherDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Graphite like every other panel. The tinted sky with a blurred
        // symbol behind it read as a wallpaper rather than a reading; the
        // condition is said by the symbol beside the figure instead, where it
        // can move.
        DetailCard {
            MeshBackdrop(color: Color(red: 0.3, green: 0.5, blue: 0.8))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if city.isEmpty {
                    noPlace
                } else if let weather {
                    now(weather)
                } else {
                    unavailable
                }

                if !hours.isEmpty {
                    strip
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .glassPane()
                }

                footer
            }
        }
        // MET publishes hourly, so this cannot tick the way CPU does, but it
        // can be current: opening the panel asks for a fresh forecast. The
        // service's own 15-minute throttle turns a recent one into a no-op,
        // so this never hammers MET however often the panel is opened.
        .onAppear {
            guard !context.isPreview else { return }
            Task { await WeatherService.shared.refresh() }
        }
    }

    // MARK: Data
    //
    // The tile's accessors, key for key: the panel must not disagree with the
    // card that opened it about which city it is reporting, or in which unit.

    /// An empty `city` means "wherever I am", same as on the tile.
    private var city: String {
        let stored = instance.config.string("city").trimmingCharacters(in: .whitespaces)
        if !stored.isEmpty { return stored }
        return context.isPreview ? Self.sampleCity : (LocationService.shared.city ?? "")
    }

    private var fahrenheit: Bool { instance.config.bool("fahrenheit") }

    private var weather: WeatherNow? {
        context.isPreview ? Self.sample : WeatherService.shared.current
    }

    private var hours: [WeatherHour] {
        context.isPreview ? Self.sampleHours(from: context.now) : WeatherService.shared.hourly
    }

    // MARK: Now

    private func now(_ weather: WeatherNow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                // The city first, as the system's own weather does: the
                // number means nothing until you know where it is.
                Text(city)
                    .font(WidgetStyle.label(13))
                    .foregroundStyle(WidgetStyle.primary)
                temperature(weather.temperatureC)
                // The hourly layout shows neither the condition nor the city,
                // so on the shelf this widget is a bare number; both are what
                // the panel is for, and the range rides with the condition.
                Text([weather.condition, range].compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetStyle.caption(12))
                    .foregroundStyle(WidgetStyle.secondary)
            }
            // A city typed in full ("Thiruvananthapuram") truncates rather
            // than pushing the panel's fixed width around.
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: weather.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .font(.system(size: 42))
                // A slow breath, so the reading looks alive without anything
                // in it pretending to change faster than MET publishes.
                .symbolEffect(.breathe, options: .repeating, isActive: !reduceMotion)
        }
    }

    /// Big figure with a lighter degree mark, as on the tile.
    private func temperature(_ celsius: Double) -> some View {
        let reading = Int(converted(celsius).rounded())
        return HStack(alignment: .top, spacing: 0) {
            Text("\(reading)")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(WidgetStyle.primary)
                .monospacedDigit()
                .rollingValue(reading)
            Text("°")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(WidgetStyle.primary)
        }
        .lineLimit(1)
    }

    // MARK: Hours

    /// Now, then the next seven hours. Eight columns, where twelve crowded a
    /// panel that is now shorter; "Now" leads, lit, so the strip reads from
    /// where you are.
    private var strip: some View {
        HStack(spacing: 0) {
            if let weather {
                column("Now", weather.symbolName, weather.temperatureC, lit: true)
            }
            ForEach(hours.prefix(weather == nil ? 8 : 7), id: \.date) { hour in
                // The hour alone. Read together the columns are an axis
                // rather than a clock, and "2 PM" does not fit one.
                column(hour.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted))),
                       hour.symbolName, hour.temperatureC, lit: false)
            }
        }
    }

    private func column(_ label: String, _ symbol: String, _ celsius: Double, lit: Bool) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(WidgetStyle.caption(10))
                .foregroundStyle(lit ? WidgetStyle.primary : WidgetStyle.secondary)
                .monospacedDigit()
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .font(.system(size: 13))
                .frame(height: 16)
            Text(degrees(celsius))
                .font(WidgetStyle.label(11))
                .foregroundStyle(WidgetStyle.primary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background {
            if lit {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.1))
            }
        }
    }

    /// The span of the hours the strip covers, or nil with none to cover.
    private var range: String? {
        let temperatures = hours.prefix(7).map(\.temperatureC)
        guard let low = temperatures.min(), let high = temperatures.max() else { return nil }
        return low == high ? degrees(low) : "\(degrees(low))–\(degrees(high))"
    }

    // MARK: Footer

    /// How old the reading is, counting up, and the credit MET asks for.
    /// The age is what makes an hourly forecast read as live: it moves.
    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tick in
            HStack(spacing: 8) {
                Text(updated(at: tick.date))
                Spacer(minLength: 4)
                // CC BY 4.0 asks for this wherever the data is shown, and
                // the tile is too small to carry it.
                Text(WeatherService.attribution)
            }
            .font(WidgetStyle.caption(10))
            .foregroundStyle(.white.opacity(0.45))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private func updated(at now: Date) -> String {
        guard !context.isPreview else { return "Updated just now" }
        guard let when = WeatherService.shared.updatedAt else { return "Updating…" }
        let minutes = Int(now.timeIntervalSince(when) / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        return "Updated \(minutes / 60) h ago"
    }

    // MARK: Empty states

    /// Nothing typed and nothing from CoreLocation - which, as the README
    /// records, is the usual outcome for an app that never becomes frontmost.
    /// Tell the two states apart the way the tile's caption does, and point at
    /// the field that settles both.
    private var noPlace: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(locating ? "Locating…" : "No city set")
                .font(WidgetStyle.label(13))
                .foregroundStyle(WidgetStyle.primary)
            Text(locating
                 ? "Waiting on your location. Typing a city in Settings ▸ Widgets skips it."
                 : "Type a city in Settings ▸ Widgets.")
                .font(WidgetStyle.caption(11))
                .foregroundStyle(WidgetStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var locating: Bool {
        guard !context.isPreview else { return false }
        let service = LocationService.shared
        return !service.denied && !service.unavailable
    }

    /// A missing reading is either a first fetch still in flight or one that
    /// failed with nothing cached behind it. The service keeps the last good
    /// values and reports no error, so it cannot tell those apart - and
    /// neither does this. The panel observes the service, so the number
    /// appears here the moment it lands.
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(city)
                .font(WidgetStyle.label(13))
                .foregroundStyle(WidgetStyle.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("No reading yet.")
                .font(WidgetStyle.caption(11))
                .foregroundStyle(WidgetStyle.secondary)
        }
    }

    // MARK: Units

    private func degrees(_ celsius: Double) -> String {
        "\(Int(converted(celsius).rounded()))°"
    }

    private func converted(_ celsius: Double) -> Double {
        fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    // MARK: Sample
    //
    // The library has no live data. The tile's own sample is private to it,
    // and these numbers only have to agree with it by eye.

    private static let sampleCity = "Oslo"

    private static let sample = WeatherNow(temperatureC: 18,
                                           symbolName: "cloud.sun.fill",
                                           condition: "Partly Cloudy")

    private static func sampleHours(from date: Date) -> [WeatherHour] {
        let temperatures: [Double] = [18, 19, 19, 17, 16, 16, 15, 14]
        let symbols = ["cloud.sun.fill", "sun.max.fill", "cloud.sun.fill", "cloud.rain.fill",
                       "cloud.fill", "cloud.fill", "cloud.moon.fill", "cloud.moon.fill"]
        return zip(temperatures, symbols).enumerated().map { index, pair in
            WeatherHour(date: date.addingTimeInterval(Double(index + 1) * 3600),
                        temperatureC: pair.0,
                        symbolName: pair.1)
        }
    }
}
