import SwiftUI

/// Live throughput, optionally over a small history chart.
struct NetworkActivityTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        WidgetSurface {
            if context.position.isVertical {
                column
            } else if showsChart {
                VStack(spacing: 6) {
                    rates
                    chart.frame(height: 26)
                }
            } else {
                rates
            }
        }
        // ponytail: start-only; the sampler is shared by every network tile.
        .onAppear { if !context.isPreview { NetworkMetrics.shared.start() } }
    }

    // MARK: Pieces

    private var rates: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsDownload {
                row("arrow.down", download, Color(hex: MetricColor.netDownload))
            }
            if showsUpload {
                row("arrow.up", upload, Color(hex: MetricColor.netUpload))
            }
        }
    }

    private func row(_ symbol: String, _ bytesPerSecond: Double, _ tint: Color) -> some View {
        let rate = formatted(bytesPerSecond)
        // One run of text, so the value and its unit shrink together. As two
        // views the unit was the one cut short, and "999 K..." said nothing.
        // No badge: 90pt of usable width holds the two rates or a badge, not
        // both, and the rates are the reading.
        return HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
            (Text(rate.value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WidgetStyle.primary)
             + Text(" \(rate.unit)")
                .font(.system(size: 11))
                .foregroundStyle(WidgetStyle.secondary))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private var chart: some View {
        // Both series share one scale, so the lines stay comparable.
        let peak = max(downloadHistory.max() ?? 0, uploadHistory.max() ?? 0, 1)
        return ZStack {
            if showsDownload {
                Sparkline(values: downloadHistory, peak: peak)
                    .stroke(Color(hex: MetricColor.netDownload), lineWidth: 1.5)
            }
            if showsUpload {
                Sparkline(values: uploadHistory, peak: peak)
                    .stroke(Color(hex: MetricColor.netUpload),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 2]))
            }
        }
    }

    // MARK: Column layout
    //
    // 76 × 76 for both directions, 76 × 46 for one. There is no room beside
    // the numbers in a column, so the chart goes behind them instead.

    private var column: some View {
        ZStack {
            if showsChart { chartFill }
            VStack(spacing: 8) {
                if showsDownload {
                    columnRow("arrow.down", download, Color(hex: MetricColor.netDownload))
                }
                if showsUpload {
                    columnRow("arrow.up", upload, Color(hex: MetricColor.netUpload))
                }
            }
        }
    }

    private func columnRow(_ symbol: String, _ bytesPerSecond: Double, _ tint: Color) -> some View {
        let rate = formatted(bytesPerSecond)
        return HStack(spacing: 3) {
            // Grey arrows, as on the wide card: direction is the arrow's
            // shape, and colour on it outshouted the figure beside it.
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WidgetStyle.secondary)
            // One run of text, as on the wide card, so the figure and its
            // unit shrink together instead of the figure being cut to "2...".
            (Text(rate.value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WidgetStyle.primary)
             + Text(" \(rate.unit)")
                .font(.system(size: 9))
                .foregroundStyle(WidgetStyle.secondary))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    private var chartFill: some View {
        let peak = max(downloadHistory.max() ?? 0, uploadHistory.max() ?? 0, 1)
        return ZStack {
            if showsDownload {
                Sparkline(values: downloadHistory, peak: peak, closed: true)
                    .fill(WidgetStyle.primary.opacity(0.08))
            }
            if showsUpload {
                Sparkline(values: uploadHistory, peak: peak, closed: true)
                    .fill(WidgetStyle.primary.opacity(0.05))
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Config & data

    private var showsChart: Bool { instance.config.bool("chart") }

    private var display: String { instance.config.string("display", default: "both") }
    private var showsDownload: Bool { display != "upload" }
    private var showsUpload: Bool { display != "download" }

    private var download: Double {
        context.isPreview ? 999 * 1024 : NetworkMetrics.shared.download
    }

    private var upload: Double {
        context.isPreview ? 292 * 1024 : NetworkMetrics.shared.upload
    }

    private var downloadHistory: [Double] {
        context.isPreview ? Self.sample(peak: 999 * 1024, phase: 0) : NetworkMetrics.shared.downloadHistory
    }

    private var uploadHistory: [Double] {
        context.isPreview ? Self.sample(peak: 292 * 1024, phase: 1.7) : NetworkMetrics.shared.uploadHistory
    }

    /// Deterministic, plausible-looking traffic for the library.
    private static func sample(peak: Double, phase: Double) -> [Double] {
        (0..<40).map { i in
            let t = Double(i) / 4 + phase
            return peak * (0.45 + 0.35 * sin(t) + 0.18 * sin(t * 2.3))
        }
    }

    /// KB/s until it no longer fits, then MB/s - matching how the menu bar reads.
    private func formatted(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let kb = max(bytesPerSecond, 0) / 1024
        if kb < 1024 { return ("\(Int(kb.rounded()))", "KB/s") }
        return (String(format: "%.1f", kb / 1024), "MB/s")
    }
}

/// A polyline over a fixed scale, optionally closed into an area fill.
struct Sparkline: Shape {
    var values: [Double]
    var peak: Double
    /// Value that sits on the floor of the chart.
    ///
    /// Without this the series is always normalised against zero, so a metric
    /// hovering at 77% fills almost the entire box - which reads as a solid
    /// colour block rather than a graph. Normalising over the range the series
    /// actually occupies is what makes the *shape* legible.
    var floor: Double = 0
    /// Closes the path down to the baseline so `.fill` reads as an area.
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let span = peak - floor
        guard values.count > 1, span > 0 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let ratio = min(max((value - floor) / span, 0), 1)
            let point = CGPoint(x: rect.minX + CGFloat(index) * step,
                                y: rect.maxY - CGFloat(ratio) * rect.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
