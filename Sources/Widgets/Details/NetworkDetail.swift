import AppKit
import SwiftUI

/// Network said at length: the two rates the tile leads with, and under them
/// the minute they came out of.
///
/// The tile answers "how fast, right now" - a figure that is already stale by
/// the time it is read. What a card cannot hold is the *shape*: whether this
/// second is a spike in an idle minute or the tail of a long download, and how
/// the two directions relate. That is the whole reason this panel exists.
///
/// The rates are what `NetworkMetrics` publishes: instantaneous figures and
/// the last sixty one-second samples of each, summed over every link. It keeps
/// rates rather than counters, so there is no session total to report. The
/// averages and peaks are read off the same history the chart draws. Under
/// them, the links that are up and their addresses, read as the panel opens.
struct NetworkDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    @State private var interfaces: [NetworkInterface] = []

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

                if !shownInterfaces.isEmpty { interfaceList }
            }
        }
        .onAppear { readInterfaces() }
        // The panel is hidden rather than torn down between openings, so
        // appearing happens once; it becomes key every time it opens.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            readInterfaces()
        }
    }

    /// Read after the panel has measured itself, so it is placed again once
    /// the list is known.
    private func readInterfaces() {
        guard !context.isPreview else { return }
        let now = NetworkInterface.active()
        guard now != interfaces else { return }
        interfaces = now
        Task { @MainActor in WidgetDetailWindow.shared.relayout() }
    }

    // MARK: Interfaces

    private var shownInterfaces: [NetworkInterface] {
        context.isPreview
            ? [NetworkInterface(id: "en0", name: "Wi-Fi", ipv4: "192.168.1.24",
                                ipv6: "2001:db8::24", isPrimary: true)]
            : interfaces
    }

    /// One row per link: its name, which one is carrying traffic, and its
    /// addresses, selectable so they can be copied.
    private var interfaceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shownInterfaces) { link in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(link.name)
                            .font(WidgetStyle.label(13))
                            .foregroundStyle(WidgetStyle.primary)
                        Text(link.id)
                            .font(WidgetStyle.caption(11))
                            .foregroundStyle(Color.panelInk.opacity(0.5))
                        if link.isPrimary {
                            Text("In use")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.panelInk)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.panelInk.opacity(0.18)))
                        }
                    }
                    ForEach([link.ipv4, link.ipv6].compactMap(\.self), id: \.self) { address in
                        Text(address)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.panelInk.opacity(0.75))
                            .textSelection(.enabled)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .glassPane(cornerRadius: 10)
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
    /// stray bytes are drawn as a mountain range. Download and upload are two
    /// filled curves on that one scale, each in its own colour.
    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(window >= NetworkMetrics.historyLength ? "Last minute" : "Last \(window)s")
                .font(WidgetStyle.caption(10))
                .foregroundStyle(Color.panelInk.opacity(0.45))
            AreaHistory(series: [
                            showsDownload ? AreaHistory.Series(name: "Down", samples: downloadHistory,
                                                               color: Color(hex: MetricColor.netDownload)) : nil,
                            showsUpload ? AreaHistory.Series(name: "Up", samples: uploadHistory,
                                                             color: Color(hex: MetricColor.netUpload)) : nil,
                        ].compactMap(\.self),
                        range: scale, length: NetworkMetrics.historyLength)
                .frame(height: 96)
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
