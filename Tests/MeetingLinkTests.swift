import Foundation
import XCTest

final class MeetingLinkTests: XCTestCase {
    func testFindsEachService() {
        for link in ["https://meet.google.com/abc-defg-hij",
                     "https://us02web.zoom.us/j/81234567890?pwd=xyz",
                     "https://zoom.us/my/someone",
                     "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0",
                     "https://teams.live.com/meet/9876543210"] {
            XCTAssertEqual(MeetingLink.find(in: ["Join: \(link)"])?.absoluteString, link, link)
        }
    }

    /// Notes carry agendas and docs; only a meeting link earns the button.
    func testIgnoresOtherLinksAndBareHosts() {
        XCTAssertNil(MeetingLink.find(in: ["Agenda https://docs.google.com/document/d/1"]))
        XCTAssertNil(MeetingLink.find(in: ["https://zoom.us/pricing", "https://meet.google.com/"]))
        XCTAssertNil(MeetingLink.find(in: [nil, "", "Room 4B"]))
    }

    /// The URL field comes first, so a call link there beats one in the notes.
    func testEarlierFieldWins() {
        let found = MeetingLink.find(in: ["https://meet.google.com/aaa-bbbb-ccc",
                                          "https://zoom.us/j/1"])
        XCTAssertEqual(found?.host, "meet.google.com")
    }

    func testFindsLinkAmongOtherText() {
        let notes = "Agenda: https://example.com/doc\n\nJoin Zoom Meeting\nhttps://acme.zoom.us/j/555"
        XCTAssertEqual(MeetingLink.find(in: [notes])?.host, "acme.zoom.us")
    }
}
