import SwiftUI

/// Network said at length: the two rates the tile leads with, and under them
/// the minute they came out of.
///
/// The tile answers "how fast, right now" - a figure that is already stale by
/// the time it is read. What a card cannot hold is the *shape*: whether this
/// second is a spike in an idle minute or the tail of a long download, and how
/// the two directions relate. That is the whole reason this panel exists.
///
/// Only what `NetworkMetrics` publishes: instantaneous rates and the last
/// sixty one-second samples of each. The sampler sums every non-loopback link,
/// so there is no interface to name, and it keeps rates rather than counters,
/// so there is no session total to report. The averages and peaks below are
/// read off the same history the chart draws - nothing here is a second
/// source.
struct NetworkDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        // Deep teal, the colour of a line carrying something, with the
        // minute's traffic as the ground along its foot.
        DetailCard {
            MeshBackdrop(color: Color(red: 0.05, green: 0.45, blue: 0.5))
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                headline

                // Two samples is the minimum a line can be drawn from, and
                // the sampler's first tick is only a baseline - so a panel
                // opened in the first seconds of the shelf's life honestly
                // shows the rates alone until the history catches up.
                if window >= 2 { history }
            }
        }
    }

    // MARK: Now

    private var headline: some View {
        HStack(spacing: 12) {
            if showsDownload { reading("arrow.down", "Down", download, downloadHistory) }
            if showsUpload { reading("arrow.up", "Up", upload, uploadHistory) }
        }
    }

    /// A rate in light figures, with the minute's average and peak as one
    /// quiet line under it.
    ///
    /// The average and peak were four boxed chips with capitalised labels,
    /// a dashboard where the figures above wanted room. Said once, softly,
    /// under the number they qualify, they read as part of it.
    private func reading(_ symbol: String, _ name: String, _ rate: Double, _ series: [Double]) -> some View {
        let value = formatted(rate)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WidgetStyle.secondary)
                Text(value.value)
                    .font(.system(size: 40, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(WidgetStyle.primary)
                    .rollingValue(value.value)
                Text(value.unit)
                    .font(WidgetStyle.caption(12))
                    .foregroundStyle(WidgetStyle.secondary)
            }
            Text(window >= 2 ? "\(name), avg \(text(average(series))) · peak \(text(peak(series)))" : name)
                .font(WidgetStyle.caption(11))
                .foregroundStyle(WidgetStyle.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue("\(value.value) \(value.unit)")
    }

    // MARK: History

    /// Both directions over one shared minute.
    ///
    /// Throughput has no natural ceiling the way a percentage does, so the
    /// scale is the larger of the two series' own peaks - the same choice the
    /// tile's sparkline makes, and the only one under which the lines can be
    /// read against each other. Let each auto-scale and a 2 KB/s keepalive
    /// would draw exactly as tall as a 40 MB/s download sitting beside it.
    ///
    /// Floored at 1 KB/s so an idle minute stays pinned to the bottom of the
    /// frame: without a floor the scale collapses onto the noise and a few
    /// stray bytes are drawn as a mountain range.
    /// The minute as one mirrored row of bars: download rising from a centre
    /// line, upload falling from it, a bar a second.
    ///
    /// Two lines on one chart were two shapes to compare; one mirrored shape
    /// is the traffic itself, with its direction as up and down.
    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(window >= NetworkMetrics.historyLength ? "Last minute" : "Last \(window)s")
                .font(WidgetStyle.caption(10))
                .foregroundStyle(.white.opacity(0.45))
            TickHistory(samples: showsDownload ? downloadHistory : uploadHistory,
                        mirror: showsDownload && showsUpload ? uploadHistory : nil,
                        range: scale)
                .frame(height: 64)
        }
    }

    private var scale: ClosedRange<Double> {
        let peaks = [showsDownload ? peak(downloadHistory) : 0, showsUpload ? peak(uploadHistory) : 0]
        return 0...max(peaks.max() ?? 0, 1024)
    }

    private func text(_ rate: Double) -> String {
        let value = formatted(rate)
        return "\(value.value) \(value.unit)"
    }

    private func average(_ series: [Double]) -> Double {
        series.isEmpty ? 0 : series.reduce(0, +) / Double(series.count)
    }

    private func peak(_ series: [Double]) -> Double { series.max() ?? 0 }

    // MARK: Config & data
    //
    // The tile's keys, key for key: a widget set to watch one direction must
    // not have the panel quietly report both.

    private var display: String { instance.config.string("display", default: "both") }
    private var showsDownload: Bool { display != "upload" }
    private var showsUpload: Bool { display != "download" }

    /// The shorter of the two buffers, so the axis under the chart cannot
    /// claim more seconds than both lines actually cover.
    private var window: Int {
        min(downloadHistory.count, uploadHistory.count)
    }

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

    /// Deterministic, plausible-looking traffic for the library, matching the
    /// tile's own preview by eye so a widget and its panel do not disagree.
    private static func sample(peak: Double, phase: Double) -> [Double] {
        (0..<40).map { i in
            let t = Double(i) / 4 + phase
            return peak * (0.45 + 0.35 * sin(t) + 0.18 * sin(t * 2.3))
        }
    }

    /// KB/s until it no longer fits, then MB/s - the tile's rule, so the
    /// headline reads the same before and after the panel opens.
    private func formatted(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let kb = max(bytesPerSecond, 0) / 1024
        if kb < 1024 { return ("\(Int(kb.rounded()))", "KB/s") }
        return (String(format: "%.1f", kb / 1024), "MB/s")
    }
}
