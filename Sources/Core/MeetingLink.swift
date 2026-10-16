import Foundation

/// Finds the video-call link in a calendar event.
///
/// Invitations put it in different places - Google Calendar in the URL field,
/// Zoom and Teams in the notes, a hand-made event in the location - so every
/// field is searched, in that order, and the first link to a known meeting
/// service wins. Links to anything else are ignored: an event's notes are full
/// of agendas, docs and dial-in pages, and "Join" opening one of those would be
/// worse than no button.
public enum MeetingLink {
    public static func find(in fields: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        for case let text? in fields where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let url = match.url, isMeeting(url) { return url }
            }
        }
        return nil
    }

    /// Matched on the host and the path both, because the bare hosts also
    /// serve marketing pages and sign-in screens.
    static func isMeeting(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        if host == "meet.google.com" { return path.count > 1 }
        // Company subdomains too: acme.zoom.us/j/123.
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/w/")
        }
        if host == "teams.microsoft.com" { return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") }
        if host == "teams.live.com" { return path.hasPrefix("/meet/") }
        return false
    }
}
