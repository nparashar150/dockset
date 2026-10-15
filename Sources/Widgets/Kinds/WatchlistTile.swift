import SwiftUI

/// Several symbols at a glance, no charts (276×62 wide).
///
/// Wide, each symbol is its own centred column - ticker, price, signed
/// percentage - sharing the tile equally. In a 76pt column there is only room
/// for one line of figures per symbol, so each becomes a compact two-line row
/// with the ticker and the percentage on top and the price under them.
///
/// Click to open the panel, which lists every configured symbol with room for
/// the figures the tile has to crop - the tile itself is a readout.
struct WatchlistTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    @Environment(\.colorScheme) private var scheme

    private var symbols: [String] {
        let configured = instance.config
            .strings("symbols", default: ["AAPL", "MSFT", "NVDA"])
            .map(StockService.normalised)
            .filter { !$0.isEmpty }
        // An empty list would render an empty tile; fall back to the default
        // rather than to nothing.
        return configured.isEmpty ? ["AAPL", "MSFT", "NVDA"] : configured
    }

    private func quote(_ symbol: String) -> StockQuote? {
        context.isPreview ? .preview(symbol) : StockService.shared.quote(symbol)
    }

    var body: some View {
        let symbols = symbols
        WidgetSurface {
            Group {
                if context.position.isVertical { column(symbols) } else { wide(symbols) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: symbols) {
            guard !context.isPreview else { return }
            StockService.shared.track(symbols, every: StockSettings.interval(instance.config))
        }
    }

    // MARK: Layouts

    private func wide(_ symbols: [String]) -> some View {
        HStack(spacing: 0) {
            // Indexed rather than keyed on the ticker, because nothing stops a
            // watchlist from carrying the same symbol twice.
            ForEach(symbols.indices, id: \.self) { index in
                let symbol = symbols[index]
                let quote = quote(symbol)
                VStack(spacing: 1) {
                    Text(StockSettings.label(symbol, instance.config))
                        .font(WidgetStyle.label(11))
                        .foregroundStyle(WidgetStyle.primary)
                    // The shelf's value style, level with every other tile.
                    Text(quote?.priceText ?? "-")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(WidgetStyle.primary)
                        .monospacedDigit()
                    Text(quote?.percentText ?? "")
                        .font(WidgetStyle.label(11))
                        .foregroundStyle(accent(quote))
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .opacity(fade(quote))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func column(_ symbols: [String]) -> some View {
        VStack(spacing: 0) {
            ForEach(symbols.indices, id: \.self) { index in
                let symbol = symbols[index]
                let quote = quote(symbol)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(StockSettings.label(symbol, instance.config))
                            .font(WidgetStyle.label(9))
                            .foregroundStyle(WidgetStyle.secondary)
                        Spacer(minLength: 0)
                        // An arrow, not the percentage: "+0.2..." was all a
                        // 76pt column had room for, and the direction is the
                        // part that can be read at a glance.
                        if let quote {
                            Image(systemName: quote.rising ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(accent(quote))
                        }
                    }
                    Text(quote?.priceText ?? "-")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetStyle.primary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .opacity(fade(quote))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    /// A failed refresh keeps the last good numbers and admits it by fading,
    /// rather than blanking or showing a zero. The same fade as the Stock tile,
    /// applied per row because each symbol refreshes on its own.
    private func fade(_ quote: StockQuote?) -> Double {
        quote?.stale == true ? 0.55 : 1
    }

    private func accent(_ quote: StockQuote?) -> Color {
        StockInk.accent(rising: quote?.rising ?? true, scheme: scheme)
    }
}
