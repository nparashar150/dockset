import AppKit
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

                if metrics.contains(.cpu), !cores.isEmpty { coreBars }
                if metrics.contains(.memory) { memoryChips }
                scanSection
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
    /// Every moving metric on one chart, each in its own colour, with a
    /// legend that doubles as the current reading.
    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(charted, id: \.self) { metric in
                    HStack(spacing: 5) {
                        Circle().fill(metric.color).frame(width: 7, height: 7)
                        Text("\(metric.label) \(whole(value(metric)))%")
                            .font(WidgetStyle.label(11))
                            .foregroundStyle(WidgetStyle.primary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            // Absolute, so a CPU idling low sits low.
            AreaHistory(series: charted.map {
                            AreaHistory.Series(name: $0.label, samples: samples($0), color: $0.color)
                        },
                        range: 0...1, length: SystemMetrics.historyLength)
                .frame(height: 96)
            HStack {
                Text(span.capitalized(with: nil))
                Spacer()
                Text("Now")
            }
            .font(WidgetStyle.caption(10))
            .foregroundStyle(.white.opacity(0.45))
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

    // MARK: Cores, pressure, swap

    private var cores: [Double] {
        context.isPreview ? [0.4, 0.2, 0.7, 0.1, 0.3, 0.5, 0.15, 0.25] : SystemMetrics.shared.cores
    }

    /// One bar per core, so a single thread pinning one core is visible where
    /// the average would bury it.
    private var coreBars: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(cores.count) cores")
                .font(WidgetStyle.caption(10))
                .foregroundStyle(.white.opacity(0.45))
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(cores.indices, id: \.self) { index in
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color(hex: MetricColor.cpu))
                                .frame(height: max(2, proxy.size.height * cores[index]))
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.08)))
                }
            }
            .frame(height: 24)
            .animation(.easeOut(duration: 0.3), value: cores)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU cores")
        .accessibilityValue(cores.map { "\(whole($0))" }.joined(separator: ", ") + " percent")
    }

    private var memoryChips: some View {
        let metrics = SystemMetrics.shared
        let pressure = context.isPreview ? "Normal" : metrics.pressure.rawValue
        let swap = context.isPreview ? "0 bytes"
            : ByteCountFormatter.string(fromByteCount: metrics.swapUsed, countStyle: .memory)
        return HStack(spacing: 8) {
            StatChip(label: "Pressure", value: pressure)
            StatChip(label: "Swap used", value: swap)
        }
    }

    // MARK: Large items

    /// The largest things in the home folder, Applications and Library.
    ///
    /// Asked for rather than always shown: the walk is slow and reads every
    /// file's metadata. It runs in `FolderScanner`, so it carries on if the
    /// panel closes.
    private var scanSection: some View {
        let scanner = FolderScanner.shared
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LARGE ITEMS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if scanner.scanning {
                    ProgressView().controlSize(.mini)
                    Text("Scanning…")
                        .font(WidgetStyle.caption(11))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Button(scanner.finishedAt == nil ? "Scan Folders" : "Scan Again") {
                        guard !context.isPreview else { return }
                        scanner.scan()
                    }
                    .buttonStyle(.plain)
                    .font(WidgetStyle.label(11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.14)))
                }
            }
            ForEach(scanner.items) { item in
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(item.url.lastPathComponent)
                            .font(WidgetStyle.label(12))
                            .foregroundStyle(WidgetStyle.primary)
                        Spacer(minLength: 8)
                        Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                            .font(WidgetStyle.caption(11))
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show \(item.url.path) in Finder")
            }
        }
        .padding(10)
        .glassPane(cornerRadius: 10)
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

        var color: Color {
            switch self {
            case .cpu: Color(hex: MetricColor.cpu)
            case .memory: Color(hex: MetricColor.memory)
            case .disk: Color(hex: MetricColor.storage)
            case .battery: Color(hex: MetricColor.batteryPresent)
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
