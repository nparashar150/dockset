import Foundation
import MapKit
import Observation

/// Conditions right now.
struct WeatherNow: Sendable {
    var temperatureC: Double
    /// SF Symbol name, already mapped from MET's symbol code.
    var symbolName: String
    /// Human text, e.g. "Partly Cloudy".
    var condition: String
}

/// One point of the hourly forecast.
struct WeatherHour: Sendable {
    var date: Date
    var temperatureC: Double
    var symbolName: String
    /// Millimetres expected in this hour.
    ///
    /// The same request already carried it and nothing read it. Temperature
    /// across five hours is usually five near-identical numbers, which is a
    /// strip that costs width and says nothing; rain is the thing that
    /// actually changes and the thing anyone is looking for.
    var precipitationMM: Double = 0
}

/// Forecast for one city, from MET Norway's Locationforecast 2.0.
///
/// No API key, but the licence and the terms of service both ask for
/// something: a descriptive `User-Agent` on every request, and visible
/// attribution wherever the data is shown - see `attribution`.
///
/// ponytail: one shared location for every Weather tile - the last
/// `setLocation` wins. Key the cache by city if two tiles ever need two cities.
@MainActor @Observable
final class WeatherService {
    static let shared = WeatherService()

    /// CC BY 4.0 requires this to be visible in the UI.
    static let attribution = "Weather data from MET Norway"

    /// MET blocks requests without a real identifier. Replace the contact
    /// with the shipping app's own before release.
    private static let userAgent = "Docket/1.0 (macOS dock widget; https://github.com/nparashar150/docket)"

    /// MET asks for ~1 call per location per 15 minutes.
    private static let minimumInterval: TimeInterval = 15 * 60

    private(set) var current: WeatherNow?
    private(set) var hourly: [WeatherHour] = []
    /// When MET last confirmed what is shown, by a fresh forecast or by a 304
    /// saying nothing changed. What lets the panel say how old the reading
    /// is, which is most of what makes an hourly forecast feel alive.
    private(set) var updatedAt: Date?

    @ObservationIgnored private var coordinate: Coordinate?
    @ObservationIgnored private var city = ""
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var lastModified: String?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var geocoded: [String: Coordinate] = [:]

    private init() {}

    // MARK: - API

    /// Points the service at a city and refreshes. A failed lookup keeps the
    /// previous location rather than blanking the tile.
    func setLocation(city name: String) async {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty, wanted.caseInsensitiveCompare(city) != .orderedSame,
           let found = await coordinate(for: wanted) {
            city = wanted
            coordinate = found
            // A new place must not keep showing the old place's numbers.
            current = nil
            hourly = []
            updatedAt = nil
            lastAttempt = nil
            lastModified = nil
        }
        await refresh()
    }

    /// Fetches unless the last attempt was under 15 minutes ago. Any failure
    /// leaves the last good forecast in place.
    func refresh() async {
        guard let coordinate, !loading else { return }
        if let lastAttempt, Date.now.timeIntervalSince(lastAttempt) < Self.minimumInterval { return }

        loading = true
        lastAttempt = .now
        defer { loading = false }

        var components = URLComponents(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact")
        // MET rejects more than 4 decimals and dedupes cache entries by them.
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", coordinate.lat)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", coordinate.lon)),
        ]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            // 304: what we already show is current.
            guard http.statusCode != 304 else {
                updatedAt = .now
                return
            }
            guard http.statusCode == 200 else { return }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            apply(try decoder.decode(Forecast.self, from: data))
            lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            updatedAt = .now
        } catch {
            // Offline, throttled or malformed - keep the last good values.
        }
    }

    // MARK: - Parsing

    private func apply(_ forecast: Forecast) {
        let series = forecast.properties.timeseries
        guard !series.isEmpty else { return }
        let now = Date.now

        // The first entry at or after the current hour; MET's series starts on
        // the hour, so "now" is usually a few minutes into the first one.
        let currentEntry = series.first { $0.time >= now.addingTimeInterval(-3600) } ?? series[0]
        if let celsius = currentEntry.data.instant.details.airTemperature,
           let code = currentEntry.data.symbolCode {
            current = WeatherNow(temperatureC: celsius,
                                 symbolName: Self.symbol(for: code),
                                 condition: Self.condition(for: code))
        }

        hourly = series.lazy
            .filter { $0.time > now }
            .prefix(12)
            .compactMap { entry in
                // No summary means the far end of the series, where MET only
                // publishes 12-hour buckets - nothing to draw an hour with.
                guard let celsius = entry.data.instant.details.airTemperature,
                      let code = entry.data.symbolCode else { return nil }
                return WeatherHour(date: entry.time, temperatureC: celsius,
                                   symbolName: Self.symbol(for: code),
                                   precipitationMM: entry.data.next1Hours?
                                       .details?.precipitationAmount ?? 0)
            }
    }

    /// MET symbol code (`partlycloudy_day`, `lightrainshowers_night`, …) to an
    /// SF Symbol. Unknown codes land on a neutral cloud rather than nothing.
    static func symbol(for code: String) -> String {
        let base = String(code.split(separator: "_").first ?? "")
        let night = code.hasSuffix("_night")
        let thunder = base.hasSuffix("andthunder")

        if base.contains("snow") { return thunder ? "cloud.bolt.fill" : "cloud.snow.fill" }
        if base.contains("sleet") { return "cloud.sleet.fill" }
        if base.contains("rain") || base.contains("drizzle") {
            return thunder ? "cloud.bolt.rain.fill" : "cloud.rain.fill"
        }
        if thunder { return "cloud.bolt.fill" }
        if base.contains("fog") { return "cloud.fog.fill" }
        if base.hasPrefix("partlycloudy") || base.hasPrefix("fair") {
            return night ? "cloud.moon.fill" : "cloud.sun.fill"
        }
        if base.hasPrefix("cloudy") { return "cloud.fill" }
        if base.hasPrefix("clearsky") { return night ? "moon.stars.fill" : "sun.max.fill" }
        return night ? "cloud.moon.fill" : "cloud.sun.fill"
    }

    private static let conditionNames: [String: String] = [
        "clearsky": "Clear", "fair": "Fair", "partlycloudy": "Partly Cloudy", "cloudy": "Cloudy",
        "fog": "Fog", "rain": "Rain", "rainshowers": "Showers", "drizzle": "Drizzle",
        "sleet": "Sleet", "sleetshowers": "Sleet", "snow": "Snow", "snowshowers": "Snow Showers",
    ]

    static func condition(for code: String) -> String {
        var base = String(code.split(separator: "_").first ?? "")
        var prefix = ""
        for intensity in ["light", "heavy"] where base.hasPrefix(intensity) {
            prefix = intensity.capitalized + " "
            base.removeFirst(intensity.count)
        }
        var suffix = ""
        if base.hasSuffix("andthunder") {
            suffix = " & Thunder"
            base.removeLast("andthunder".count)
        }
        return prefix + (conditionNames[base] ?? base.capitalized) + suffix
    }

    // MARK: - Geocoding

    struct Coordinate: Sendable, Hashable {
        var lat: Double
        var lon: Double
    }

    private func coordinate(for city: String) async -> Coordinate? {
        let key = city.lowercased()
        if let cached = geocoded[key] { return cached }
        guard let found = await Self.geocode(city) else { return nil }
        geocoded[key] = found
        return found
    }

    /// Forward geocoding needs no location permission. Only the two Doubles
    /// leave the lookup, so nothing non-Sendable crosses an isolation
    /// boundary.
    private static func geocode(_ city: String) async -> Coordinate? {
        guard let request = MKGeocodingRequest(addressString: city),
              let item = try? await request.mapItems.first
        else { return nil }
        let found = item.location.coordinate
        return Coordinate(lat: found.latitude, lon: found.longitude)
    }
}

// MARK: - Wire format

/// Only the handful of fields the widget draws; MET's payload is much larger.
private struct Forecast: Decodable {
    struct Properties: Decodable { var timeseries: [Entry] }
    struct Entry: Decodable {
        var time: Date
        var data: EntryData
    }
    struct EntryData: Decodable {
        struct Instant: Decodable {
            struct Details: Decodable { var airTemperature: Double? }
            var details: Details
        }
        struct Period: Decodable {
            struct Summary: Decodable { var symbolCode: String }
            struct Details: Decodable { var precipitationAmount: Double? }
            var summary: Summary
            /// Absent on the far end of the series, where MET publishes a
            /// summary without the numbers behind it.
            var details: Details?
        }
        var instant: Instant
        /// The last few days of the series only carry the 6-hour bucket.
        var next1Hours: Period?
        var next6Hours: Period?
        var next12Hours: Period?

        var symbolCode: String? {
            next1Hours?.summary.symbolCode
                ?? next6Hours?.summary.symbolCode
                ?? next12Hours?.summary.symbolCode
        }
    }
    var properties: Properties
}
