import AppKit
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
    /// The hour picked in the strip, or nil for now.
    ///
    /// The strip was something to read; picking an hour puts it in the large
    /// reading above, so "what will it be like at five" is one click rather
    /// than a squint at a column of small figures.
    @State private var selected: Date?

    /// The place picked in this panel, ahead of the widget's stored one: the
    /// panel is handed the widget as it was when it opened, so a switch made
    /// here has to be remembered here as well as written back.
    @State private var picked: String?
    /// Places saved on this widget, likewise ahead of the stored list.
    @State private var savedPlaces: [String]?
    @State private var adding = false
    @State private var draft = ""
    @State private var notFound = false
    @FocusState private var typing: Bool

    var instance: WidgetInstance
    var context: WidgetContext

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
            // Opened afresh, it reads now, not whatever hour was last picked.
            selected = nil
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
        let stored = (picked ?? instance.config.string("city")).trimmingCharacters(in: .whitespaces)
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

    private func now(_ current: WeatherNow) -> some View {
        let hour = selected.flatMap { date in hours.first { $0.date == date } }
        let weather = hour.map {
            WeatherNow(temperatureC: $0.temperatureC, symbolName: $0.symbolName,
                       condition: Self.condition(for: $0.symbolName))
        } ?? current
        let when = hour.map { $0.date.formatted(.dateTime.hour().minute()) }
        let rain = hour.flatMap { $0.precipitationMM >= 0.1 ? String(format: "%.1f mm", $0.precipitationMM) : nil }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                // The city first, as the system's own weather does: the
                // number means nothing until you know where it is.
                placeMenu
                temperature(weather.temperatureC)
                // The hourly layout shows neither the condition nor the city,
                // so on the shelf this widget is a bare number; both are what
                // the panel is for, and the range rides with the condition.
                Text((hour == nil ? [weather.condition, range] : [when, weather.condition, rain])
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetStyle.caption(12))
                    .foregroundStyle(WidgetStyle.secondary)
            }
            // A city typed in full ("Thiruvananthapuram") truncates rather
            // than pushing the panel's fixed width around.
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
            // Still: the symbol changes when the sky does, with a replace
            // transition, and a constant breath on top only made it look
            // like a loading indicator.
            WeatherGlyph(symbol: weather.symbolName)
                .font(.system(size: 46))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .contentTransition(.symbolEffect(.replace))
        }
        .animation(.snappy(duration: 0.25), value: selected)
    }

    /// A condition named from an hour's symbol: the hourly series carries a
    /// symbol and rainfall but not MET's own words.
    private static func condition(for symbol: String) -> String {
        let rules: [(String, String)] = [
            ("bolt", "Thunder"), ("snow", "Snow"), ("sleet", "Sleet"),
            ("heavyrain", "Heavy Rain"), ("drizzle", "Drizzle"), ("rain", "Rain"),
            ("fog", "Fog"), ("cloud.sun", "Partly Cloudy"), ("cloud.moon", "Partly Cloudy"),
            ("cloud", "Cloudy"), ("sun", "Clear"), ("moon", "Clear"),
        ]
        return rules.first { symbol.contains($0.0) }?.1 ?? "Forecast"
    }

    // MARK: Places

    private var places: [String] {
        savedPlaces ?? instance.config.strings("places")
    }

    /// The city's name is the switch: every saved place, the Mac's own
    /// location, and adding or removing one, from the name being read.
    @ViewBuilder private var placeMenu: some View {
        if adding {
            HStack(spacing: 6) {
                TextField("City", text: $draft)
                    .textFieldStyle(.plain)
                    .font(WidgetStyle.label(13))
                    .focused($typing)
                    .onSubmit(add)
                    .onAppear { typing = true }
                if notFound {
                    Text("Not found")
                        .font(WidgetStyle.caption(11))
                        .foregroundStyle(WidgetStyle.secondary)
                }
                Button("Cancel") { adding = false; draft = ""; notFound = false }
                    .buttonStyle(.plain)
                    .font(WidgetStyle.caption(11))
                    .foregroundStyle(WidgetStyle.secondary)
            }
            .frame(maxWidth: 200, alignment: .leading)
        } else {
            Menu {
                Button {
                    choose("")
                } label: {
                    Label("Current Location", systemImage: "location")
                }
                if !places.isEmpty {
                    Divider()
                    ForEach(places, id: \.self) { place in
                        Button {
                            choose(place)
                        } label: {
                            if place.caseInsensitiveCompare(stored) == .orderedSame {
                                Label(place, systemImage: "checkmark")
                            } else {
                                Text(place)
                            }
                        }
                    }
                }
                Divider()
                Button {
                    draft = ""
                    notFound = false
                    adding = true
                } label: {
                    Label("Add a Place…", systemImage: "plus")
                }
                if !stored.isEmpty {
                    Button(role: .destructive) {
                        remove(stored)
                    } label: {
                        Label("Remove \(stored)", systemImage: "minus.circle")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(city.isEmpty ? "Current Location" : city)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WidgetStyle.secondary)
                }
                .font(WidgetStyle.label(13))
                .foregroundStyle(WidgetStyle.primary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(context.isPreview)
        }
    }

    /// The place stored on the widget, "" being the Mac's own location.
    private var stored: String {
        (picked ?? instance.config.string("city")).trimmingCharacters(in: .whitespaces)
    }

    private func choose(_ place: String) {
        picked = place
        selected = nil
        WidgetWriter.write(instance) { $0.set("city", .string(place)) }
        // The Mac's own location: start finding it if nothing has yet, and
        // point the forecast at it as soon as there is a name to point at.
        if place.isEmpty {
            LocationService.shared.start()
            Task {
                for _ in 0..<20 {
                    if let here = LocationService.shared.city {
                        await WeatherService.shared.setLocation(city: here)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            return
        }
        Task { await WeatherService.shared.setLocation(city: place) }
    }

    /// Saved only once the name is found as a place, so the list never holds
    /// a typo that shows nothing.
    private func add() {
        let place = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else { return }
        Task {
            guard await WeatherService.shared.resolves(city: place) else {
                notFound = true
                return
            }
            var list = places
            if !list.contains(where: { $0.caseInsensitiveCompare(place) == .orderedSame }) {
                list.append(place)
            }
            savedPlaces = list
            WidgetWriter.write(instance) { $0.set("places", .list(list.map { .string($0) })) }
            adding = false
            draft = ""
            notFound = false
            choose(place)
        }
    }

    private func remove(_ place: String) {
        let list = places.filter { $0.caseInsensitiveCompare(place) != .orderedSame }
        savedPlaces = list
        WidgetWriter.write(instance) { $0.set("places", .list(list.map { .string($0) })) }
        choose(list.first ?? "")
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
                pick(nil) {
                    column("Now", weather.symbolName, weather.temperatureC, lit: selected == nil)
                }
            }
            ForEach(hours.prefix(weather == nil ? 8 : 7), id: \.date) { hour in
                // The hour alone. Read together the columns are an axis
                // rather than a clock, and "2 PM" does not fit one.
                pick(hour.date) {
                    column(hour.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted))),
                           hour.symbolName, hour.temperatureC, lit: selected == hour.date)
                }
            }
        }
    }

    /// A column you can click to read that hour above.
    private func pick(_ date: Date?, @ViewBuilder _ label: () -> some View) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { selected = date }
        } label: {
            label().contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(context.isPreview)
        .accessibilityAddTraits(selected == date ? .isSelected : [])
    }

    private func column(_ label: String, _ symbol: String, _ celsius: Double, lit: Bool) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(WidgetStyle.caption(10))
                .foregroundStyle(lit ? WidgetStyle.primary : WidgetStyle.secondary)
                .monospacedDigit()
            WeatherGlyph(symbol: symbol)
                .font(.system(size: 14))
                .frame(height: 18)
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
                    .fill(Color.panelInk.opacity(0.1))
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
            .foregroundStyle(Color.panelInk.opacity(0.45))
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

/// A weather symbol in Apple's own colours: a yellow sun, blue rain, a white
/// moon. Only the cloud takes a colour from here, because multicolour leaves
/// it to the foreground and the foreground is white ink on the dark card and
/// near-black on the light one; a cloud wants to be cloud-coloured on both.
///
/// The filled variant where one exists: the outline symbols have no layers
/// for multicolour to paint, which is why the glyph was one flat grey.
private struct WeatherGlyph: View {
    var symbol: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: filled)
            .symbolRenderingMode(.multicolor)
            .foregroundStyle(scheme == .dark
                             ? Color(white: 0.92)
                             : Color(red: 0.6, green: 0.65, blue: 0.72))
            // Multicolour draws clouds white whatever the foreground, which
            // all but vanish on the light card; a tight shadow gives them an
            // edge there.
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.28), radius: 1, y: 0.5)
    }

    private var filled: String {
        guard !symbol.hasSuffix(".fill") else { return symbol }
        let candidate = symbol + ".fill"
        return NSImage(systemSymbolName: candidate, accessibilityDescription: nil) == nil ? symbol : candidate
    }
}
