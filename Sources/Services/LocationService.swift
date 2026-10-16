import AppKit
import CoreLocation
import MapKit
import Observation

/// Where the user actually is, for the weather widget.
///
/// The widget previously took a city typed into its config, defaulting to the
/// reference shelf's "Oslo". Guessing from the system time zone is no better -
/// `Asia/Kolkata` covers the whole country, so it names a city most of its
/// users do not live in.
///
/// Asked for once, lazily, and only because a weather widget is on the shelf.
/// A refusal is remembered rather than re-prompted, and leaves the widget on
/// whatever city was configured.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    /// The nearest named place, once known.
    private(set) var city: String?
    private(set) var coordinate: CLLocationCoordinate2D?
    /// True once the user has said no, so nothing asks again.
    private(set) var denied = false
    /// True when no answer arrived at all - see `start()`.
    private(set) var unavailable = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var asked = false

    private override init() {
        super.init()
        manager.delegate = self
        // A city name needs kilometres, not metres, and the coarse setting
        // avoids waking the GPS.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Idempotent: the first weather widget to appear starts this, the rest
    /// find it already running.
    func start() {
        // Whatever Core Location does, an approximate city is asked for
        // once: see `approximate()`. It is replaced the moment a real fix
        // arrives, so it costs nothing when location works.
        if city == nil { Task { await approximate() } }
        guard !asked, !denied else { return }
        asked = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // Measured on this machine: the request returns with the status
            // still `notDetermined` and no prompt on screen, and promoting the
            // app to `.regular` first - which is what makes the automation
            // consent appear - does not change that. So the widget must not
            // wait on an answer that may never come: after a few seconds it
            // says so, and offers the city field instead.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if self.manager.authorizationStatus == .notDetermined { self.unavailable = true }
            }
        case .denied, .restricted:
            denied = true
        default:
            manager.requestLocation()
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            // `self.manager` rather than the parameter: the delegate argument
            // is not Sendable, so it cannot cross into this isolated body.
            switch self.manager.authorizationStatus {
            case .authorized, .authorizedAlways:
                self.manager.requestLocation()
            case .denied, .restricted:
                denied = true
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            coordinate = location.coordinate
            Task { await self.name(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: any Error) {
        // Nothing to do: the widget keeps whatever city it already had,
        // which the approximate lookup has usually supplied by now.
    }

    // MARK: Approximate

    @ObservationIgnored private var approximating = false
    @ObservationIgnored private var precise = false

    /// The city the connection appears to be in, from its address.
    ///
    /// Core Location's consent prompt is never shown to an app that never
    /// becomes frontmost (measured; see `start()`), so for most people
    /// "current location" never resolved and the widget said there was no
    /// location at all. A city from the network address is what plenty of
    /// weather apps fall back to, needs no permission, and is right at the
    /// scale a forecast is. One request, no key; a real fix replaces it.
    private func approximate() async {
        guard !approximating, city == nil else { return }
        approximating = true
        defer { approximating = false }
        guard let url = URL(string: "https://ipinfo.io/json") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = (object["city"] as? String)?.trimmingCharacters(in: .whitespaces),
              !found.isEmpty, !precise
        else { return }
        city = found
        // A city found this way still counts as an answer, so the widget
        // stops saying it is waiting for one.
        unavailable = false
        if let loc = (object["loc"] as? String)?.split(separator: ","), loc.count == 2,
           let lat = Double(loc[0]), let lon = Double(loc[1]) {
            coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    /// Reverse-geocodes to something a person would call the place.
    ///
    /// MapKit rather than `CLGeocoder`, which is deprecated on macOS 26. Its
    /// `cityWithContext` reads "Mumbai, Maharashtra"; the widget wants the
    /// city alone, and a map item's `name` is the nearest *street*.
    private func name(_ location: CLLocation) async {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first,
              let context = item.addressRepresentations?.cityWithContext
        else { return }
        let place = context.split(separator: ",").first.map(String.init) ?? context
        precise = true
        city = place.trimmingCharacters(in: .whitespaces)
    }
}
