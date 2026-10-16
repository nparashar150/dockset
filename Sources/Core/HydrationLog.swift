import Foundation

/// The hydration widget's record of drinks: when each went in and how much.
///
/// Kept in the widget's own config under `log`, as a list of `[time, mL]`
/// pairs, so it travels with the widget through backups and duplicates like
/// everything else it stores. A week is kept, which is what the panel's chart
/// draws; anything older is dropped on the next write so the state file does
/// not grow for as long as the widget lives.
public struct HydrationLog: Equatable, Sendable {
    public struct Drink: Equatable, Hashable, Sendable {
        /// Seconds since 1970, the same clock `lastDrink` uses.
        public var at: Double
        /// Zero when amounts are not being logged.
        public var millilitres: Double

        public init(at: Double, millilitres: Double) {
            self.at = at
            self.millilitres = millilitres
        }
    }

    public static let key = "log"
    public static let keptDays = 7

    /// Oldest first.
    public private(set) var drinks: [Drink]

    public init(drinks: [Drink] = []) {
        self.drinks = drinks.sorted { $0.at < $1.at }
    }

    /// Entries that are not a pair of numbers are skipped rather than failing
    /// the whole log.
    public init(_ config: WidgetConfig) {
        guard case .list(let entries) = config.values[Self.key] else {
            self.init()
            return
        }
        self.init(drinks: entries.compactMap { entry in
            guard case .list(let pair) = entry, pair.count == 2,
                  case .number(let at) = pair[0], case .number(let ml) = pair[1] else { return nil }
            return Drink(at: at, millilitres: ml)
        })
    }

    public var value: WidgetConfig.Value {
        .list(drinks.map { .list([.number($0.at), .number($0.millilitres)]) })
    }

    /// Adds a drink and drops whatever has fallen out of the kept week.
    public mutating func add(_ drink: Drink, calendar: Calendar = .current) {
        drinks.append(drink)
        drinks.sort { $0.at < $1.at }
        let now = Date(timeIntervalSince1970: drink.at)
        guard let cutoff = calendar.date(byAdding: .day, value: -(Self.keptDays - 1),
                                         to: calendar.startOfDay(for: now)) else { return }
        drinks.removeAll { $0.at < cutoff.timeIntervalSince1970 }
    }

    public mutating func remove(_ drink: Drink) {
        guard let index = drinks.firstIndex(of: drink) else { return }
        drinks.remove(at: index)
    }

    public func drinks(on day: Date, calendar: Calendar = .current) -> [Drink] {
        drinks.filter { calendar.isDate(Date(timeIntervalSince1970: $0.at), inSameDayAs: day) }
    }

    /// Millilitres per day for the `count` days ending on `day`, oldest first.
    public func totals(endingOn day: Date, count: Int = keptDays,
                       calendar: Calendar = .current) -> [Double] {
        (0 ..< count).reversed().map { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: day) else { return 0 }
            return drinks(on: date, calendar: calendar).reduce(0) { $0 + $1.millilitres }
        }
    }
}
