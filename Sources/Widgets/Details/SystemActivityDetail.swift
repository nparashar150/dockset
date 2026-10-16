import SwiftUI

/// System Activity said at length: a row per reading the widget shows, each
/// its current figure beside its last minute as a dithered chart.
///
/// The stock panel's chart, because it was the one that read best: a line
/// with the ground under it stippled in, rather than a smooth wash. One row
/// per metric rather than every line on one chart, since each gets its own
/// scale fitted to it - memory moving between 75 and 77% is invisible on a
/// 0 to 100 axis shared with a CPU that jumps from 5 to 60.
///
/// Which metrics appear is the widget's own `metrics` config, chosen per
/// metric in Dock Settings, so the panel follows it rather than assuming the
/// CPU-and-memory default it ships with.
struct SystemActivityDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        // Graphite with a violet cast: a machine's insides, dark enough that
        // the charts' own colours are the only colour in it.
        DetailCard {
            MeshBackdrop(color: Color(red: 0.3, green: 0.24, blue: 0.5))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(metrics, id: \.self) { row($0) }
                HStack {
                    Text(span)
                    Spacer()
                    Text("Now")
                }
                .font(WidgetStyle.caption(10))
                .foregroundStyle(Color.panelInk.opacity(0.45))
            }
            // The card's height, shared out between the rows, so one metric
            // gets one tall chart and four get four short ones.
            .frame(height: DetailCard<EmptyView, EmptyView>.height - 32)
        }
    }

    private func row(_ metric: Metric) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(metric.color).frame(width: 7, height: 7)
                    Text(metric.label)
                        .font(WidgetStyle.label(11))
                        .foregroundStyle(Color.panelInk.opacity(0.7))
                }
                Text("\(whole(value(metric)))%")
                    .font(.system(size: 22, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(WidgetStyle.primary)
                    .rollingValue(whole(value(metric)))
            }
            .frame(width: 82, alignment: .leading)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .combine)

            DitherChart(samples: samples(metric), tint: metric.color,
                        range: Self.fit(samples(metric)), lineWidth: 1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity)
    }

    /// The series' own range with room around it, never narrower than a
    /// fifth of the scale, so a near-flat reading stays near-flat instead of
    /// having its noise blown up to fill the row.
    private static func fit(_ samples: [Double]) -> ClosedRange<Double> {
        guard let low = samples.min(), let high = samples.max() else { return 0...1 }
        let span = max(high - low, 0.2) * 1.4
        let lower = max(0, min((low + high) / 2 - span / 2, 1 - span))
        return lower ... min(1, lower + span)
    }

    /// Named with the span the buffer actually holds, which is under a minute
    /// until it fills.
    private var span: String {
        let count = metrics.map { samples($0).count }.max() ?? 0
        return count >= SystemMetrics.historyLength ? "Last minute" : "Last \(count)s"
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

    private func samples(_ metric: Metric) -> [Double] {
        context.isPreview ? metric.sampleHistory : SystemMetrics.shared.history(for: metric.rawValue)
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

        var color: Color {
            switch self {
            case .cpu: Color(hex: MetricColor.cpu)
            case .memory: Color(hex: MetricColor.memory)
            case .disk: Color(hex: MetricColor.storage)
            case .battery: Color(hex: MetricColor.batteryPresent)
            }
        }

        /// A minute for the library, which has no sampler behind it.
        var sampleHistory: [Double] {
            (0 ..< SystemMetrics.historyLength).map { i in
                sample + 0.06 * sin(Double(i) / 6 + Double(rawValue.count))
            }
        }

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
