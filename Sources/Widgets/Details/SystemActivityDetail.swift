import Foundation
import SwiftUI

/// System Activity said at length: the tile's gauges at a size that can hold a
/// number, and under them the figures a 42pt ring has no room for.
///
/// Which metrics appear is the widget's own `metrics` config, chosen per
/// metric in Dock Settings, so the panel has to follow it rather than assume
/// the CPU-and-memory default it happens to ship with.
struct SystemActivityDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        // Graphite with a violet cast: a machine's insides, dark enough that
        // the rings' own colours are the only colour in it.
        DetailCard {
            MeshBackdrop(color: Color(red: 0.3, green: 0.24, blue: 0.5))
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(metrics, id: \.self) { row($0) }

                // The last minute, for the metrics that move. Disk and
                // battery keep a history that would be a flat line, so they
                // are not drawn one.
                if !charted.isEmpty { history }
            }
        }
    }

    // MARK: History

    private var charted: [Metric] {
        metrics.filter { !samples($0).isEmpty }
    }

    /// One line per moving metric, over a shared minute.
    ///
    /// The weather panel earns its keep by showing the shape of the next few
    /// hours rather than one temperature; this is the same idea pointed
    /// backwards. The rings say where things are, and this says whether they
    /// are on their way up.
    ///
    /// To the card's edges and foot, as the ground the readings stand on.
    /// The lead metric's minute, a bar a second.
    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(charted[0].label), \(span)")
                .font(WidgetStyle.caption(10))
                .foregroundStyle(.white.opacity(0.45))
            // Absolute, so a CPU idling low sits low.
            TickHistory(samples: samples(charted[0]), range: 0...1)
                .frame(height: 24)
        }
        .padding(.top, 2)
    }

    /// Named with the span the buffer actually holds, which is under a minute
    /// until it fills.
    private var span: String {
        let count = charted.map { samples($0).count }.max() ?? 0
        return count >= SystemMetrics.historyLength ? "last minute" : "last \(count)s"
    }

    private func samples(_ metric: Metric) -> [Double] {
        guard !context.isPreview else { return [] }
        return SystemMetrics.shared.history(for: metric.rawValue)
    }

    // MARK: Readings

    /// A metric as a row: its name and the fact the percentage leaves out on
    /// the left, the percentage on the right, and its level as ticks under
    /// both.
    private func row(_ metric: Metric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.label)
                        .font(WidgetStyle.label(13))
                        .foregroundStyle(WidgetStyle.primary)
                    Text(detail(metric).value)
                        .font(WidgetStyle.caption(11))
                        .foregroundStyle(WidgetStyle.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                percent(value(metric), size: 30)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            TickMeter(fraction: value(metric))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metric.label)
        .accessibilityValue("\(whole(value(metric))) percent")
    }

    @ViewBuilder
    private func percent(_ value: Double, size: CGFloat) -> some View {
        let reading = whole(value)
        HStack(spacing: 0) {
            Text("\(reading)")
                .font(.system(size: size, weight: .light))
                .monospacedDigit()
                .foregroundStyle(WidgetStyle.primary)
                .rollingValue(reading)
            // Smaller than the figure, so a three-digit reading still clears
            // the arc it sits inside.
            Text("%")
                .font(.system(size: size * 0.5, weight: .light))
                .foregroundStyle(WidgetStyle.secondary)
        }
    }

    // MARK: Detail

    /// The one fact each gauge leaves out.
    ///
    /// The sampler publishes fractions, so memory is the only one that can be
    /// restated in bytes - its fraction is measured against
    /// `physicalMemory`, which makes the multiplication the reading itself
    /// rather than a guess. The others say what they are a fraction *of*, or
    /// what the number cannot show, instead of inventing an absolute figure.
    private func detail(_ metric: Metric) -> (label: String, value: String) {
        switch metric {
        case .cpu:
            // The ring is this second; the average is the minute behind it,
            // off the same series the tile's sparkline draws. Named with the
            // span it actually has, which is shorter than a minute until the
            // history fills.
            let series = context.isPreview ? [] : SystemMetrics.shared.cpuHistory
            guard !series.isEmpty else { return ("Average CPU", "-") }
            let average = series.reduce(0, +) / Double(series.count)
            return ("Average CPU", "avg \(whole(average))%")
        case .memory:
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            let gib = 1024.0 * 1024 * 1024
            return ("Memory used",
                    String(format: "%.1f of %.0f GB", value(metric) * total / gib, total / gib))
        case .disk:
            // The percentage is the ring's job. This is the figure you
            // actually act on, off the same sample.
            let free = Double(SystemMetrics.shared.diskFree)
            let total = Double(SystemMetrics.shared.diskTotal)
            guard !context.isPreview, total > 0 else { return ("Startup volume", "-") }
            let gib = 1024.0 * 1024 * 1024
            return ("Startup volume free",
                    String(format: "%.0f GB free", free / gib))
        case .battery:
            let mac = context.isPreview ? nil : BatteryMetrics.shared.device(.mac)
            guard let mac, mac.present else { return ("Mac battery", "Not reported") }
            return ("Mac battery", mac.status)
        }
    }

    // MARK: Data

    /// The tile's key and the tile's fallback, so the panel cannot disagree
    /// with the card that opened it.
    private var metrics: [Metric] {
        let parsed = instance.config
            .strings("metrics", default: ["cpu", "memory"])
            .compactMap(Metric.init(rawValue:))
        return parsed.isEmpty ? [.cpu, .memory] : parsed
    }

    private func value(_ metric: Metric) -> Double {
        if context.isPreview { return metric.sample }
        switch metric {
        case .cpu, .memory, .disk:
            return SystemMetrics.shared.value(for: metric.rawValue)
        // The Mac's own battery: the other devices belong to the battery
        // widget, which is the one that can show more than one of them.
        case .battery:
            return BatteryMetrics.shared.device(.mac)?.level ?? 0
        }
    }

    private func whole(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 100).rounded())
    }

    /// The tile's metric list, which is nested and private to it. Same raw
    /// values because both sides read the same config key - a metric added
    /// there has to be added here too, or the panel drops it silently.
    private enum Metric: String {
        case cpu, memory, disk, battery

        var label: String {
            switch self {
            case .cpu: "CPU"
            case .memory: "Memory"
            case .disk: "Disk"
            case .battery: "Battery"
            }
        }

        /// The library has no sampler behind it.
        var sample: Double {
            switch self {
            case .cpu: 0.24
            case .memory: 0.63
            case .disk: 0.41
            case .battery: 0.78
            }
        }
    }
}
