import SwiftUI

/// System Activity said at length: one chart, a line for every reading the
/// widget shows, over the last minute.
///
/// It was a stack - a row and a tick meter per metric, a chart under them,
/// chips for pressure and swap, a folder scan - and grew taller than every
/// other panel. One chart on the card every panel shares says the same thing
/// at a glance: where each reading is, by the legend, and whether it is on its
/// way up, by its line.
///
/// Which metrics appear is the widget's own `metrics` config, chosen per
/// metric in Dock Settings, so the panel follows it rather than assuming the
/// CPU-and-memory default it ships with.
struct SystemActivityDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        // Graphite with a violet cast: a machine's insides, dark enough that
        // the lines' own colours are the only colour in it.
        DetailCard {
            MeshBackdrop(color: Color(red: 0.3, green: 0.24, blue: 0.5))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                legend
                // Absolute, so a CPU idling low sits low. Lines only once
                // there are two: fills stacked on fills turn to mud.
                AreaHistory(series: metrics.map {
                                AreaHistory.Series(name: $0.label, samples: samples($0), color: $0.color)
                            },
                            range: 0...1, length: SystemMetrics.historyLength,
                            filled: metrics.count == 1)
                    .frame(height: 128)
                HStack {
                    Text(span)
                    Spacer()
                    Text("Now")
                }
                .font(WidgetStyle.caption(10))
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    /// The key to the lines, and the current reading of each.
    private var legend: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(metrics, id: \.self) { metric in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Circle().fill(metric.color).frame(width: 7, height: 7)
                        Text(metric.label)
                            .font(WidgetStyle.label(11))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text("\(whole(value(metric)))%")
                        .font(.system(size: 24, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(WidgetStyle.primary)
                        .rollingValue(whole(value(metric)))
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
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
