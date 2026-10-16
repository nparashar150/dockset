import Foundation
import XCTest

final class HydrationLogTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(day: Int, hour: Int) -> Double {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
            .timeIntervalSince1970
    }

    func testRoundTripsThroughConfig() {
        var log = HydrationLog()
        log.add(.init(at: at(day: 10, hour: 9), millilitres: 250), calendar: calendar)
        var config = WidgetConfig()
        config.set(HydrationLog.key, log.value)
        XCTAssertEqual(HydrationLog(config), log)
    }

    func testDropsMalformedEntriesInsteadOfTheLog() {
        var config = WidgetConfig()
        config.set(HydrationLog.key, .list([.string("junk"),
                                            .list([.number(100), .number(300)]),
                                            .list([.number(1)])]))
        XCTAssertEqual(HydrationLog(config).drinks, [.init(at: 100, millilitres: 300)])
    }

    /// The log is a week; anything older goes on the next write.
    func testKeepsOnlyTheLastWeek() {
        var log = HydrationLog(drinks: [.init(at: at(day: 1, hour: 9), millilitres: 250),
                                        .init(at: at(day: 4, hour: 9), millilitres: 250)])
        log.add(.init(at: at(day: 10, hour: 9), millilitres: 250), calendar: calendar)
        XCTAssertEqual(log.drinks.map(\.at), [at(day: 4, hour: 9), at(day: 10, hour: 9)])
    }

    func testDailyTotalsOldestFirst() {
        var log = HydrationLog()
        for (day, hour, ml) in [(9, 8, 200.0), (10, 8, 250.0), (10, 15, 500.0)] {
            log.add(.init(at: at(day: day, hour: hour), millilitres: ml), calendar: calendar)
        }
        let today = Date(timeIntervalSince1970: at(day: 10, hour: 20))
        XCTAssertEqual(log.totals(endingOn: today, count: 3, calendar: calendar), [0, 200, 750])
        XCTAssertEqual(log.drinks(on: today, calendar: calendar).count, 2)
    }

    func testRemoveTakesOneMatchingDrink() {
        let drink = HydrationLog.Drink(at: 5, millilitres: 250)
        var log = HydrationLog(drinks: [drink, drink])
        log.remove(drink)
        XCTAssertEqual(log.drinks, [drink])
    }
}
