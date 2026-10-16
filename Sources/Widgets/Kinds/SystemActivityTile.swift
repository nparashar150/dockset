import SwiftUI

/// CPU / memory / disk, as numbers, rings or bars.
///
/// The card itself belongs to the shelf: a click opens the detail panel, which
/// draws every configured metric at a size that can hold a number. Which
/// metrics those are is `metrics` in the widget's own config, picked per metric
/// in Dock Settings, so it survives a relaunch and follows the widget between
/// profiles.
struct SystemActivityTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    var body: some View {
        WidgetSurface {
            Group {
                if context.position.isVertical { vertical } else { horizontal }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The sampler is shared; nobody stops it because a single tile went
        // away. ponytail: start-only, add refcounting if idle cost ever shows.
        .onAppear { if !context.isPreview { SystemMetrics.shared.start() } }
    }

    private var layout: String { instance.config.string("layout", default: "numbers") }

    /// Asks whether a chart applies here as well as whether it is wanted.
    ///
    /// Switching to rings or bars did not clear the stored value, so a widget
    /// could sit on chart true while showing bars and produce a graph nobody
    /// asked for the moment it went back to numbers. Reading the rule rather
    /// than rewriting the config on every layout change means a stale value is
    /// simply inert, and the setting is remembered if the layout comes back.
    private var showsChart: Bool {
        WidgetCatalog.applies("chart", to: instance.config, kind: .system)
            && instance.config.bool("chart", default: false)
    }

    @ViewBuilder
    private var horizontal: some View {
        switch layout {
        case "rings": rings
        case "bars": bars
        default: numbers
        }
    }

    @ViewBuilder
    private var vertical: some View {
        switch layout {
        case "rings": verticalRings
        case "bars": verticalBars
        default: verticalNumbers
        }
    }

    // MARK: Wide layouts

    private var numbers: some View {
        HStack(spacing: 0) {
            ForEach(metrics, id: \.self) { metric in
                VStack(spacing: 3) {
                    // The shelf's value and caption styles, so these figures
                    // sit level with every other tile's reading.
                    percent(value(metric), size: 19)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(metric.color)
                            .frame(width: 6, height: 6)
                        Text(metric.label)
                            .font(.system(size: 12))
                            .foregroundStyle(WidgetStyle.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The number says where the machine is; the graph says where
                // it is heading. Low opacity so the figure still leads.
                // Opt-in. A short strip along the floor, inset so the card's
                // rounded corners do not slice its ends off.
                .background(alignment: .bottom) {
                    if showsChart {
                        graph(metric)
                            .frame(height: 9)
                            .padding(.horizontal, 3)
                            .padding(.bottom, 4)
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private var rings: some View {
        HStack(spacing: 0) {
            ForEach(metrics, id: \.self) { metric in
                // Named under the ring, as the reference shelf does. A row of
                // bare percentages cannot say which one is the memory.
                // The arc is the reading. A number inside it says the same
                // thing twice and is the part that made the gauge look busy,
                // so the middle carries what the ring is *of* instead - which
                // also retires the label underneath and lets the ring take
                // the card's full height.
                MetricProgressRing(progress: value(metric),
                                   tint: metric.color,
                                   track: metric.color.opacity(0.16),
                                   diameter: 42,
                                   lineWidth: 4.5,
                                   peak: history(metric).max()) {
                    Image(systemName: metric.symbol)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(metric.color)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(metric.label)
                .accessibilityValue("\(Int((value(metric) * 100).rounded())) percent")
            }
        }
    }

    private var bars: some View {
        VStack(spacing: 6) {
            ForEach(metrics, id: \.self) { metric in
                HStack(spacing: 8) {
                    Text(metric.label)
                        .font(WidgetStyle.caption(11))
                        .foregroundStyle(WidgetStyle.secondary)
                        .frame(width: 44, alignment: .leading)
                    GeometryReader { geo in
                        let width = geo.size.width * min(max(value(metric), 0), 1)
                        ZStack(alignment: .leading) {
                            Capsule().fill(metric.color.opacity(0.18))
                            Capsule().fill(metric.color).frame(width: width)
                        }
                    }
                    .frame(height: 6)
                    percent(value(metric), size: 11)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .lineLimit(1)
    }

    // MARK: Column layouts
    //
    // Each metric owns a 54pt row - `WidgetCatalog.verticalHeight` hands out
    // `metrics * 54 + 8`, the 8 being this stack's vertical padding.

    private var verticalNumbers: some View {
        VStack(spacing: 0) {
            ForEach(metrics, id: \.self) { metric in
                ZStack(alignment: .top) {
                    // Same switch as the wide layout: one config key, one
                    // answer, so the widget does not change character when
                    // the shelf moves to a side.
                    if showsChart {
                        graph(metric)
                            .frame(height: 26)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    VStack(spacing: 0) {
                        percent(value(metric), size: 17)
                        // Grey like every other caption on the shelf: the
                        // metric's colour on its name was the loudest thing in
                        // a side column.
                        Text(metric.short)
                            .font(.system(size: 11))
                            .foregroundStyle(WidgetStyle.secondary)
                    }
                    .padding(.top, 2)
                }
                .frame(height: 54)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.vertical, 4)
    }

    private var verticalRings: some View {
        VStack(spacing: 0) {
            ForEach(metrics, id: \.self) { metric in
                VStack(spacing: 2) {
                    // White on a faint track, as the side shelf's other
                    // rings are; colour stays on the wide layout.
                    MetricProgressRing(progress: value(metric),
                                       tint: WidgetStyle.primary.opacity(0.85),
                                       track: WidgetStyle.primary.opacity(0.1),
                                       diameter: 36,
                                       lineWidth: 3) {
                        percent(value(metric), size: 11)
                    }
                    Text(metric.short)
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetStyle.secondary)
                }
                .frame(height: 54)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.vertical, 4)
    }

    private var verticalBars: some View {
        VStack(spacing: 0) {
            ForEach(metrics, id: \.self) { metric in
                VStack(spacing: 5) {
                    HStack(spacing: 4) {
                        Text(metric.short)
                            .font(WidgetStyle.label(10))
                            .foregroundStyle(WidgetStyle.secondary)
                        Spacer(minLength: 0)
                        percent(value(metric), size: 12)
                    }
                    bar(metric).frame(height: 6)
                }
                .frame(height: 54)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.vertical, 4)
    }

    // MARK: Graphs

    /// History behind a metric: a filled sparkline, or a bar for disk, which
    /// the sampler keeps no history for (a flat line would say nothing).
    @ViewBuilder
    private func graph(_ metric: Metric) -> some View {
        if metric == .disk {
            bar(metric)
                .frame(height: 5)
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            let series = history(metric)
            // Scale to the range the series actually occupies, not 0...max.
            // A metric sitting at 77% would otherwise fill the whole box and
            // read as a coloured block behind the label rather than a graph.
            // The minimum span keeps a near-flat series looking flat instead
            // of amplifying sampling noise into a mountain range.
            let lo = series.min() ?? 0
            let hi = series.max() ?? 0
            let span = max(hi - lo, 0.08)
            let mid = (hi + lo) / 2
            let floor = mid - span * 0.9
            let peak = mid + span * 0.9
            ZStack {
                Sparkline(values: series, peak: peak, floor: floor, closed: true)
                    .fill(metric.color.opacity(0.14))
                Sparkline(values: series, peak: peak, floor: floor)
                    .stroke(metric.color.opacity(0.65),
                            style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }

    private func bar(_ metric: Metric) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(metric.color.opacity(0.18))
                Capsule().fill(metric.color.opacity(0.7))
                    .frame(width: geo.size.width * min(max(value(metric), 0), 1))
            }
        }
    }

    // MARK: Data

    private var metrics: [Metric] {
        let parsed = instance.config
            .strings("metrics", default: ["cpu", "memory"])
            .compactMap(Metric.init(rawValue:))
        return parsed.isEmpty ? [.cpu, .memory] : parsed
    }

    private func value(_ metric: Metric) -> Double {
        if context.isPreview { return metric.sample }
        let live = SystemMetrics.shared
        switch metric {
        case .cpu: return live.cpu
        case .memory: return live.memory
        case .disk: return live.disk
        // The Mac's own battery: the other devices belong to the battery
        // widget, which is the one that can show more than one of them.
        case .battery:
            return BatteryMetrics.shared.devices.first { $0.kind == .mac }?.level ?? 0
        }
    }

    /// Most recent last; empty until the sampler has two readings.
    private func history(_ metric: Metric) -> [Double] {
        context.isPreview ? metric.sampleHistory : SystemMetrics.shared.history(for: metric.rawValue)
    }

    @ViewBuilder
    private func percent(_ value: Double, size: CGFloat) -> some View {
        let whole = Int((min(max(value, 0), 1) * 100).rounded())
        HStack(spacing: 0) {
            Text("\(whole)")
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(WidgetStyle.primary)
                .rollingValue(whole)
            Text("%")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(WidgetStyle.secondary)
        }
    }

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

        /// The column has 56pt of usable width, so the long label is out.
        var short: String {
            switch self {
            case .cpu: "CPU"
            case .memory: "MEM"
            case .disk: "SSD"
            case .battery: "BATT"
            }
        }

        /// Shown inside its ring in place of a number. `cpuchip` does not
        /// exist on this system - checked - so the older `cpu` is used.
        var symbol: String {
            switch self {
            case .cpu: "cpu"
            case .memory: "memorychip"
            case .disk: "internaldrive"
            case .battery: "laptopcomputer"
            }
        }

        var color: Color {
            switch self {
            case .cpu: Color(hex: MetricColor.cpu)
            case .memory: Color(hex: MetricColor.memory)
            case .disk: Color(hex: MetricColor.storage)
            case .battery: Color(hex: MetricColor.batteryPresent)
            }
        }

        /// The library has no sampler behind it, so preview tiles show these.
        var sample: Double {
            switch self {
            case .cpu: 0.24
            case .memory: 0.63
            case .disk: 0.41
            case .battery: 0.78
            }
        }

        /// Deterministic, plausible-looking history for the library.
        var sampleHistory: [Double] {
            // Neither has a meaningful minute-by-minute history.
            guard self != .disk, self != .battery else { return [] }
            let phase = self == .cpu ? 0.0 : 1.7
            return (0..<40).map { i in
                let t = Double(i) / 4 + phase
                return min(max(sample + 0.2 * sin(t) + 0.09 * sin(t * 2.3), 0), 1)
            }
        }
    }
}

/// A round progress gauge with something in the middle. Shared by the system
/// and battery tiles - the only two kinds that draw one.
struct MetricProgressRing<Content: View>: View {
    var progress: Double
    var tint: Color
    var track: Color
    var diameter: CGFloat
    var lineWidth: CGFloat
    /// The highest this metric reached recently, marked on the track.
    ///
    /// A ring reading 20% cannot say whether that is a machine settling down
    /// or one about to be busy, and the sampler has kept a minute of history
    /// all along that nothing on the tile ever drew. One tick costs no space
    /// and turns an instant into a direction.
    var peak: Double?
    var content: Content

    init(progress: Double,
         tint: Color,
         track: Color,
         diameter: CGFloat,
         lineWidth: CGFloat,
         peak: Double? = nil,
         @ViewBuilder content: () -> Content) {
        self.progress = progress
        self.tint = tint
        self.track = track
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.peak = peak
        self.content = content()
    }

    /// Open at the bottom rather than a closed circle.
    ///
    /// Measured off the reference shelf: its gauges leave about 35° clear at
    /// the foot of the ring, which is what stops a full-value ring from
    /// reading as a plain filled disc and gives the arc a visible start and
    /// end. Stroke is 0.12 of the diameter there, which is what this draws.
    var body: some View {
        let sweep: Double = 320
        let clamped = min(max(progress, 0), 1)
        let fraction = sweep / 360
        // Rotated so the gap is centred on the bottom of the ring.
        let rotation = Angle.degrees(90 + (360 - sweep) / 2)
        ZStack {
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(rotation)
            // Only when it is meaningfully above the arc. A tick sitting on
            // the head of the arc is the same fact twice, and a tick that
            // follows the reading around is just a thicker arc.
            if let peak, peak > clamped + 0.08 {
                let at = fraction * min(max(peak, 0), 1)
                Circle()
                    .trim(from: max(0, at - 0.006), to: min(fraction, at + 0.006))
                    .stroke(tint.opacity(0.5),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(rotation)
            }
            if clamped > 0 {
                Circle()
                    .trim(from: 0, to: fraction * clamped)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(rotation)
            }
            content
        }
        .frame(width: diameter, height: diameter)
    }
}
