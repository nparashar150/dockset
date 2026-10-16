import AppKit
import SwiftUI

/// The panel behind both stock widgets: one symbol at length, or every symbol
/// on the watchlist at once.
///
/// One view for two kinds because it is the same readout at two lengths - a
/// Stock is a Watchlist of one with room for a name and a chart - and both read
/// the same cache through the same accessors as their tiles.
///
/// The day comes from the cache the tile is already keeping fresh. A longer
/// range is fetched once when it is picked, and only then.
struct StocksDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    @State private var range: StockRange = .day

    var body: some View {
        // Green or red before a number is read: the card is the day's move.
        DetailCard {
            MeshBackdrop(color: backdropColour)
        } content: {
            if instance.kind == .watchlist {
                watchlist
            } else {
                single
            }
        }
    }

    /// The single symbol's move, or the watchlist's on balance.
    private var backdropColour: Color {
        let rising: Bool
        if instance.kind == .watchlist {
            let moves = symbols.compactMap { quote($0)?.changePercent }
            rising = moves.reduce(0, +) >= 0
        } else {
            rising = quote(symbol)?.rising ?? true
        }
        return rising ? Color(red: 0.1, green: 0.55, blue: 0.35) : Color(red: 0.7, green: 0.18, blue: 0.2)
    }

    // MARK: Data
    //
    // The tiles' own accessors, key for key: the panel must never disagree with
    // the tile it grew out of about which symbol is on show.

    private var symbol: String {
        let raw = StockService.normalised(instance.config.string("symbol", default: "AAPL"))
        return raw.isEmpty ? "AAPL" : raw
    }

    private var symbols: [String] {
        let configured = instance.config
            .strings("symbols", default: ["AAPL", "MSFT", "NVDA"])
            .map(StockService.normalised)
            .filter { !$0.isEmpty }
        return configured.isEmpty ? ["AAPL", "MSFT", "NVDA"] : configured
    }

    private func quote(_ symbol: String) -> StockQuote? {
        context.isPreview ? .preview(symbol) : StockService.shared.quote(symbol)
    }

    /// Always the dark scheme's: everything here is on the card.
    private func accent(_ quote: StockQuote?) -> Color {
        StockInk.accent(rising: quote?.rising ?? true, scheme: .dark)
    }

    /// Infinities arrive in a half-populated intraday series and would poison
    /// the range labels the same way they poison the chart's min and max.
    private func series(_ quote: StockQuote) -> [Double] {
        quote.history.filter(\.isFinite)
    }

    private func signed(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))
            .sign(strategy: .always(includingZero: true)))
    }

    // MARK: One symbol

    private var single: some View {
        // The price is always the latest; the move and the chart are over
        // the range picked, once it has arrived.
        let ranged = range == .day ? quote(symbol)
            : context.isPreview ? quote(symbol) : StockService.shared.quote(symbol, range: range)
        return VStack(alignment: .leading, spacing: 10) {
            if let quote = quote(symbol) {
                HStack(alignment: .top) {
                    identity(quote)
                    Spacer(minLength: 8)
                    if let volume = (ranged ?? quote).volumeText {
                        Text("Vol \(volume)")
                            .font(WidgetStyle.caption(11))
                            .foregroundStyle(WidgetStyle.secondary)
                            .monospacedDigit()
                    }
                }
                price(quote)
                HStack {
                    change(ranged ?? quote)
                    Spacer(minLength: 8)
                    rangePicker
                }
                if let ranged { chart(ranged) } else { loadingChart }
                if quote.stale { staleNote }
            } else {
                unavailable(symbol)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: range) {
            guard !context.isPreview else { return }
            await StockService.shared.load(symbol, range: range)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(StockRange.allCases, id: \.self) { option in
                Button(option.title) { range = option }
                    .buttonStyle(.plain)
                    .font(WidgetStyle.label(10))
                    .foregroundStyle(option == range ? .white : Color.panelInk.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(option == range ? Color.panelInk.opacity(0.2) : .clear))
                    .accessibilityAddTraits(option == range ? .isSelected : [])
            }
        }
    }

    /// Holds the chart's place while a range loads, so the panel does not
    /// change height under the pointer.
    private var loadingChart: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .padding(.top, 6)
    }

    /// The ticker opens its Yahoo Finance page, which is where these numbers
    /// come from and where the rest of them are.
    private func identity(_ quote: StockQuote) -> some View {
        let label = StockSettings.label(quote.symbol, instance.config)
        return Button {
            guard !context.isPreview, let url = quote.pageURL else { return }
            NSWorkspace.shared.open(url)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(WidgetStyle.label(13))
                    .foregroundStyle(WidgetStyle.primary)
                // The ticker under a custom name; otherwise the company,
                // unless the endpoint sent none and it would repeat.
                let subtitle = label != quote.symbol ? quote.symbol : quote.name
                if subtitle != label {
                    Text(subtitle)
                        .font(WidgetStyle.caption(11))
                        .foregroundStyle(WidgetStyle.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open \(quote.symbol) on Yahoo Finance")
    }

    private func price(_ quote: StockQuote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(quote.priceText)
                .font(WidgetStyle.value(44))
                .foregroundStyle(WidgetStyle.primary)
                .monospacedDigit()
                .rollingValue(quote.price)
            // The tile has no room to name the currency, so a foreign listing
            // reads there as if it were dollars. The panel does have room.
            Text(quote.currency)
                .font(WidgetStyle.caption(11))
                .foregroundStyle(WidgetStyle.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private func change(_ quote: StockQuote) -> some View {
        HStack(spacing: 5) {
            Image(systemName: quote.rising ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .bold))
            // Both halves of the day's move: the tile shows only the
            // percentage, which says nothing about the size of the position.
            Text(signed(quote.change))
                .monospacedDigit()
                .rollingValue(quote.change)
            Text(quote.percentText)
                .monospacedDigit()
                .rollingValue(quote.changePercent)
        }
        .font(WidgetStyle.label(12))
        .foregroundStyle(Color.panelInk)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(accent(quote).opacity(0.45), in: .capsule)
    }

    /// Drawn whenever there is a series behind it, regardless of the tile's
    /// `chart` switch: that switch is about how dense the tile is, and a panel
    /// with the room to show the day and a number with no context is the thing
    /// the panel exists to fix. Two points are the minimum an intraday line can
    /// be drawn from; below that the whole block goes rather than leaving a
    /// flat line and an empty gap.
    @ViewBuilder
    private func chart(_ quote: StockQuote) -> some View {
        let samples = series(quote)
        if samples.count >= 2 {
            // To the card's edges and foot, as the ground the price stands
            // on rather than a figure boxed underneath it.
            ZStack(alignment: .bottom) {
                DitherChart(samples: samples, tint: Color.panelInk.opacity(0.85))
                    .frame(height: 72)
                // The ends of the plotted range, not a clock: the service keeps
                // closes without their timestamps, so a time axis here would be
                // guesswork.
                HStack(spacing: 8) {
                    rangeLabel(samples.first)
                    Spacer(minLength: 8)
                    rangeLabel(samples.last)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, -16)
            .padding(.bottom, -16)
            .padding(.top, 6)
        }
    }

    private func rangeLabel(_ value: Double?) -> some View {
        Text(value?.formatted(.number.precision(.fractionLength(2))) ?? "")
            .font(WidgetStyle.label(10))
            .foregroundStyle(Color.panelInk.opacity(0.85))
            .monospacedDigit()
            .shadow(color: .black.opacity(0.4), radius: 2)
    }

    // MARK: Watchlist

    private var watchlist: some View {
        let symbols = symbols
        let quotes = symbols.map { quote($0) }
        return VStack(alignment: .leading, spacing: 6) {
            // Configured order, and every row weighted the same: the panel
            // exists to show the whole list at once, so there is no one row it
            // should be leading with. Indexed rather than keyed on the ticker,
            // because nothing stops a watchlist from carrying the same symbol
            // twice.
            ForEach(symbols.indices, id: \.self) { index in
                row(symbols[index], quote: quotes[index])
            }
            if quotes.contains(where: { $0?.stale == true }) { staleNote }
        }
        // The card's full height, shared out between the rows: three short
        // rows at the top of a tall card left a third of it empty, and the
        // room is better spent on taller day lines.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DetailCard<EmptyView, EmptyView>.height - 32, alignment: .top)
    }

    /// A ticker as a watchlist app shows one: who it is on the left, how
    /// its day went as a line in the middle, and where it stands on the right.
    ///
    /// It was the ticker, a price and a pill on an otherwise empty pane, which
    /// said less than the tile it opened from. The name and the day's line are
    /// what the panel has the room for.
    private func row(_ symbol: String, quote: StockQuote?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(StockSettings.label(symbol, instance.config))
                    .font(WidgetStyle.label(14))
                    .foregroundStyle(WidgetStyle.primary)
                // The service falls back to the ticker when it has no name,
                // and repeating it would read as a rendering bug.
                if let name = quote?.name, name != symbol {
                    Text(name)
                        .font(WidgetStyle.caption(11))
                        .foregroundStyle(WidgetStyle.secondary)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(width: 92, alignment: .leading)

            DayLine(samples: quote.map(series) ?? [], tint: accent(quote))
                .frame(minHeight: 26, maxHeight: 48)
                .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 3) {
                Text(quote?.priceText ?? "-")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WidgetStyle.primary)
                    .monospacedDigit()
                    .rollingValue(quote?.price ?? 0)
                Text(quote?.percentText ?? "-")
                    .font(WidgetStyle.label(10))
                    .foregroundStyle(accent(quote))
                    .monospacedDigit()
                    .rollingValue(quote?.changePercent ?? 0)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxHeight: .infinity)
        .glassPane(cornerRadius: 10)
        .contentShape(.rect)
        .onTapGesture {
            guard !context.isPreview, let url = quote?.pageURL else { return }
            NSWorkspace.shared.open(url)
        }
        .help("Open \(symbol) on Yahoo Finance")
        // The tile's own weighting for a reading that has stopped arriving.
        .opacity(quote?.stale == true ? 0.55 : 1)
    }

    // MARK: Empty states

    /// A missing quote is either a first fetch that has not landed or one that
    /// failed with nothing cached behind it - the service cannot tell them
    /// apart, so neither does this.
    private func unavailable(_ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(symbol)
                .font(WidgetStyle.label(13))
                .foregroundStyle(WidgetStyle.primary)
            Text("No quote yet.")
                .font(WidgetStyle.caption(11))
                .foregroundStyle(WidgetStyle.secondary)
        }
    }

    private var staleNote: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
            Text("Last refresh failed - these are the previous good numbers.")
        }
        .font(WidgetStyle.caption(10))
        .foregroundStyle(WidgetStyle.secondary)
        .lineLimit(2)
    }
}

/// The day's closes as a thin line with a faint fill under it, for a row.
///
/// Not `DitherChart`: that is drawn to be the ground a single price stands
/// on, and three of them stacked in a list read as noise. A list wants a line.
private struct DayLine: View {
    var samples: [Double]
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            if samples.count >= 2, let low = samples.min(), let high = samples.max() {
                let span = max(high - low, .ulpOfOne)
                let points = samples.enumerated().map { index, value in
                    CGPoint(x: geo.size.width * CGFloat(index) / CGFloat(samples.count - 1),
                            y: geo.size.height * (1 - CGFloat((value - low) / span)))
                }
                let line = Path { $0.addLines(points) }
                ZStack {
                    Path { path in
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        path.addLine(to: CGPoint(x: 0, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    line.stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}
