import SwiftUI

/// The panel behind Stripe, Paddle and Shopify.
///
/// One view rather than three near-copies: the three are the same widget with
/// different plumbing - an account, a metric, a period, an amount, a chart -
/// and the provider only decides which metrics and periods are on offer and
/// what the figure is called. Stripe's `revenue` is titled "Net revenue" on
/// Paddle; at this layer that is nearly the whole difference.
///
/// **No figure is drawn anywhere in here.** All three are network-backed (a
/// restricted Stripe key, Paddle's `metrics.read`, a Shopify custom app) and
/// this build ships no client for any of them: there is no series, no total
/// and no last refresh to report. A plausible amount under a real account name
/// is indistinguishable from a working widget, which is the one failure a
/// money readout cannot afford - so the panel states the connection instead,
/// and keeps only the labels that are genuinely knowable from the config.
struct RevenueDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        // The provider's own colour, so a Stripe panel is recognisably
        // Stripe's before a word is read.
        DetailCard {
            MeshBackdrop(color: brand)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    accountRow
                    metricRow
                    Text(caption)
                        .font(WidgetStyle.caption(12))
                        .foregroundStyle(Color.panelInk.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The empty state alone. An "About this metric" pane under it
                // restated the same absence, and pushed the panel past the
                // height every other one shares.
                unconnected
            }
        }
    }

    /// Stripe's blurple, Paddle's navy, Shopify's green.
    private var brand: Color {
        switch instance.kind {
        case .paddle: Color(hex: "#2B3A67")
        case .shopify: Color(hex: "#008060")
        default: Color(hex: "#635BFF")
        }
    }

    // MARK: Rows

    private var accountRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
            Text(account.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.panelInk.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var metricRow: some View {
        HStack(spacing: 8) {
            Text(metricTitle)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(WidgetStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Text(periodShort)
                .font(WidgetStyle.label(11))
                .foregroundStyle(Color.panelInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.panelInk.opacity(0.18)))
                .fixedSize()
        }
    }

    /// Where the amount and the chart belong. Dashed rather than filled: the
    /// box has to read as a slot nothing has arrived in, not as a card whose
    /// contents happen to be words.
    private var unconnected: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.panelInk.opacity(0.85))
            Text("Not connected")
                .font(WidgetStyle.value(20))
                .foregroundStyle(WidgetStyle.primary)
            Text("Docket holds no \(provider) credentials, so there is no amount to show and no history to chart.")
                .font(WidgetStyle.caption(12))
                .foregroundStyle(Color.panelInk.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.panelInk.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    // MARK: Provider

    /// Spelled here rather than read from the catalog: these three kinds have
    /// no catalog entry yet, so `WidgetCatalog.entry` is nil for all of them.
    private var provider: String {
        switch instance.kind {
        case .paddle: "Paddle"
        case .shopify: "Shopify"
        default: "Stripe"
        }
    }

    private var account: String {
        let name = instance.config.string("account").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? provider : name
    }

    /// The widget's own swatch when it has one, otherwise the colour the panel
    /// is already tinted with, so the dot and the glass agree.
    private var accent: Color {
        if let picked = PaletteColor(rawValue: instance.config.string("color")) {
            return Color(hex: picked.hex)
        }
        return WidgetCatalog.accentHex(instance.kind).map { Color(hex: $0) } ?? WidgetStyle.primary
    }

    // MARK: Metric

    private var metric: String {
        instance.config.string("metric", default: instance.kind == .shopify ? "sales" : "revenue")
    }

    private var metricTitle: String {
        // Paddle calls its `revenue` "Net revenue"; every other raw value
        // means the same on whichever provider offers it.
        if metric == "revenue", instance.kind == .paddle { return "Net revenue" }
        return switch metric {
        case "revenue": "Revenue"
        case "net": "Net revenue"
        case "mrr": "MRR"
        case "arr": "ARR"
        case "subscribers": "Subscribers"
        case "arpu": "ARPU"
        case "sales": "Sales"
        case "netSales": "Net sales"
        case "orders": "Orders"
        case "averageOrderValue": "Average order value"
        case "returns": "Returns"
        case "visitors": "Visitors"
        case "sessions": "Sessions"
        case "pageviews": "Pageviews"
        case "conversionRate": "Conversion rate"
        case "addedToCart": "Added to cart"
        case "reachedCheckout": "Reached checkout"
        case "completedCheckout": "Completed checkout"
        // A metric this build predates still deserves a readable name.
        default: WidgetCatalog.optionLabel(metric)
        }
    }

    /// Metrics that report a level rather than a total. They have no period to
    /// sum over, so they say "now" where the others name a window.
    private var isLevel: Bool {
        ["mrr", "arr", "subscribers", "arpu", "averageOrderValue", "conversionRate"]
            .contains(metric)
    }

    /// Stripe is the only provider that pins a currency in the widget; Paddle
    /// and Shopify report in the account's own, which is unknowable until one
    /// is connected. Head counts are not money on any of them.
    private var currency: String? {
        guard instance.kind == .stripe, metric != "subscribers" else { return nil }
        return instance.config.string("currency", default: "USD")
    }

    // MARK: Period

    private var period: String {
        instance.config.string("period", default: "month")
    }

    private var periodShort: String {
        if isLevel { return instance.kind == .paddle ? "Latest" : "Now" }
        return switch period {
        case "today": "Today"
        case "week": "L7"
        case "month": "MTD"
        case "thirtyDays": "L30"
        case "fourWeeks": "L4W"
        case "sixtyDays": "L60"
        case "ninetyDays": "L90"
        case "sixMonths": "L6M"
        case "twelveMonths": "L12M"
        case "quarter": "QTD"
        case "year": "YTD"
        case "lastYear": "L365"
        case "allTime": "All"
        default: "-"
        }
    }

    private var periodName: String {
        if isLevel { return instance.kind == .paddle ? "Latest reported" : "Current" }
        return switch period {
        case "today": "Today"
        case "week": "Last 7 days"
        case "month": "Month to date"
        case "thirtyDays": "Last 30 days"
        case "fourWeeks": "Last 4 weeks"
        case "sixtyDays": "Last 60 days"
        case "ninetyDays": "Last 90 days"
        case "sixMonths": "Last 6 months"
        case "twelveMonths": "Last 12 months"
        case "quarter": "Quarter to date"
        case "year": "Year to date"
        case "lastYear": "Last 365 days"
        case "allTime": "All time"
        default: "Custom period"
        }
    }

    /// The dates the period actually spans, off `context.now`. The window is
    /// real even when the figures inside it are missing, and it is the only
    /// way to tell "Last 30 days" from "Month to date" on the second of a
    /// month. A level metric has no window, and "all time" has no start.
    private var range: (start: Date, end: Date)? {
        guard !isLevel else { return nil }
        let calendar = Calendar.current
        let now = context.now
        // Inclusive of today, so a 7-point week starts six days back.
        func back(_ points: Int) -> Date? {
            calendar.date(byAdding: .day, value: -(points - 1), to: now)
        }
        let start: Date? = switch period {
        case "today": calendar.dateInterval(of: .day, for: now)?.start
        case "week": back(7)
        case "month": calendar.dateInterval(of: .month, for: now)?.start
        case "thirtyDays": back(30)
        case "fourWeeks": back(28)
        case "sixtyDays": back(60)
        case "ninetyDays": back(90)
        case "sixMonths": back(180)
        case "twelveMonths", "lastYear": back(365)
        case "quarter": calendar.dateInterval(of: .quarter, for: now)?.start
        case "year": calendar.dateInterval(of: .year, for: now)?.start
        default: nil
        }
        return start.map { (start: $0, end: now) }
    }

    // MARK: Copy

    private var caption: String {
        var parts = [periodName]
        if let range {
            let start = range.start.formatted(.dateTime.month(.abbreviated).day())
            let end = range.end.formatted(.dateTime.month(.abbreviated).day())
            // A period that begins today is one date, not a range of one.
            parts.append(start == end ? start : "\(start) – \(end)")
        }
        if let currency { parts.append(currency) }
        return parts.joined(separator: " · ")
    }

    private var explanation: String {
        // Stripe and Paddle break today down by the hour; everything else,
        // Shopify included, is a point per day.
        let grain = period == "today" && instance.kind != .shopify ? "hourly" : "daily"
        let headline = isLevel
            ? "\(metricTitle) is the latest point in the series rather than a total - the level as it stood at the last refresh."
            : "\(metricTitle) totals every \(grain) point across \(periodName.lowercased())."
        return headline + " A connected account refreshes every five minutes while the shelf is on screen."
    }
}
