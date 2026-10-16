import Charts
import SwiftUI

/// The card every panel is drawn on.
///
/// Panels used to be forms: a label and a figure per row, dividers between
/// the groups, grey on the popover's grey. Now Playing showed the other way
/// to do it, one card whose backdrop *is* the reading, with the content laid
/// on it, and this is that card for every panel.
///
/// It reaches past the panel's own padding to 6pt from its edge, where a
/// 14pt corner sits concentric with the panel's 20. It follows the app's
/// appearance: graphite in the dark, soft white in the light, with everything
/// on it drawn in `Color.panelInk` and the semantic colours, which resolve to
/// whichever the card is.
///
/// `dark` keeps a card dark in both, for the panels whose ground is a picture
/// - a sky at an hour, a sheet of paper - that white ink was chosen against.
struct DetailCard<Backdrop: View, Content: View>: View {
    var dark = false
    @ViewBuilder var backdrop: () -> Backdrop
    @ViewBuilder var content: () -> Content

    static var bleed: CGFloat { 10 }
    static var corner: CGFloat { 14 }
    /// Every card is this tall, so every panel is the same size: content sits
    /// at the top and the backdrop fills the rest. See `WidgetDetail.width`.
    static var height: CGFloat { 240 }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .topLeading)
            .background { backdrop() }
            .clipShape(.rect(cornerRadius: Self.corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(Color.panelInk.opacity(0.1), lineWidth: 0.5)
            }
            .environment(\.colorScheme, dark ? .dark : scheme)
            .padding(-Self.bleed)
    }
}

// MARK: - Chips

/// A small figure with its name above it, on a pane of frosted glass.
///
/// What replaces the label-and-value row. A row puts the label and the figure
/// as far apart as the panel is wide and draws a line under them; a chip keeps
/// the two together and sets several side by side.
struct StatChip: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.panelInk.opacity(0.55))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.panelInk)
                .monospacedDigit()
                .rollingValue(value)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPane(cornerRadius: 10)
    }
}

extension View {
    /// A pane of the card's own frosted glass: lighter than the card, with a
    /// hairline catching the light along its top.
    func glassPane(cornerRadius: CGFloat = 12) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.panelInk.opacity(0.09))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [Color.panelInk.opacity(0.22), Color.panelInk.opacity(0.04)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                }
        }
    }
}

// MARK: - Backdrops

/// The card's surface: deep graphite with light falling on it from above,
/// and the widget's own colour only as a faint warmth in one corner.
///
/// It was the widget's colour as a whole-card mesh, and even pulled halfway
/// to graphite a card of calendar red or AirDrop amber read as a coloured
/// sticker, not as part of the Mac. Apple's own surfaces are neutral, and
/// colour is something placed on them: a ring, a mark, a figure. So the card
/// is the same graphite for every widget, told apart by what is on it, and
/// the colour is a hint you notice second.
struct MeshBackdrop: View {
    var color: Color

    static let graphite = Color(red: 0.115, green: 0.115, blue: 0.13)
    /// How much of the widget's colour reaches the corner glow.
    static var hint: Double { 0.16 }

    /// A colour taken most of the way to graphite: for surfaces that have to
    /// keep a meaning (water, a sky) without becoming the loudest thing.
    ///
    /// Toward paper instead on the light card, where a colour pulled to
    /// graphite would be a dark slab under dark ink.
    static func muted(_ colour: Color, by amount: Double = 0.72,
                      on scheme: ColorScheme = .dark) -> Color {
        colour.mix(with: scheme == .dark ? graphite : paper, by: amount)
    }

    /// The light card's ground: warm white rather than pure, so it sits in
    /// the popover's material instead of glaring out of it.
    static let paper = Color(red: 0.965, green: 0.965, blue: 0.97)

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let base = dark ? Self.graphite : Self.paper
        ZStack {
            LinearGradient(stops: [
                .init(color: base.mix(with: .white, by: dark ? 0.07 : 0.6), location: 0),
                .init(color: base, location: 0.45),
                .init(color: base.mix(with: .black, by: dark ? 0.4 : 0.04), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            // A little stronger on white, where the same opacity all but
            // vanishes.
            RadialGradient(colors: [color.opacity(dark ? Self.hint : Self.hint * 1.4), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 280)
            // A sheen along the top edge, the way light catches the lip of
            // an aluminium case.
            LinearGradient(colors: [.white.opacity(dark ? 0.06 : 0.5), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.18))
        }
    }
}

/// The sky at an hour in a zone, with the sun or the moon where it is.
///
/// The colour is the time of day before it is anything else: navy through the
/// night, rose at dawn, blue through the day, amber into dusk. A dotted arc
/// runs across the card as the day's path, with the sun on it at the current
/// hour between six and six, and the moon and a scatter of stars outside it.
struct SkyBackdrop: View {
    var date: Date
    var zone: TimeZone

    private var hour: Double {
        var calendar = Calendar.current
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    var body: some View {
        let colors = Self.palette(hour)
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                if !isDay { stars(in: size) }
                path(in: size)
                    .stroke(Color.panelInk.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                orb(in: size)
            }
        }
    }

    private var isDay: Bool { (6..<18).contains(hour) }

    /// A shallow arc from the card's lower left corner to its lower right,
    /// cresting a little below the top.
    private func path(in size: CGSize) -> Path {
        Path { p in
            p.move(to: CGPoint(x: -10, y: size.height * 0.95))
            p.addQuadCurve(to: CGPoint(x: size.width + 10, y: size.height * 0.95),
                           control: CGPoint(x: size.width / 2, y: -size.height * 0.15))
        }
    }

    /// Where on that arc the sun, or the moon on the night's own arc, is now.
    private func point(in size: CGSize) -> CGPoint {
        let t = isDay ? (hour - 6) / 12 : ((hour + 6).truncatingRemainder(dividingBy: 24)) / 12
        let start = CGPoint(x: -10, y: size.height * 0.95)
        let end = CGPoint(x: size.width + 10, y: size.height * 0.95)
        let control = CGPoint(x: size.width / 2, y: -size.height * 0.15)
        let u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }

    private func orb(in size: CGSize) -> some View {
        let at = point(in: size)
        let glow: Color = isDay ? Color(red: 1, green: 0.93, blue: 0.8) : Color(white: 0.9)
        return ZStack {
            // A tight halo, not a bloom: at midday the sun crests behind the
            // time itself, and a wide glow there washed the figures out.
            Circle()
                .fill(RadialGradient(colors: [glow.opacity(0.18), .clear],
                                     center: .center, startRadius: 0, endRadius: 22))
                .frame(width: 44, height: 44)
            Circle()
                .fill(glow.opacity(0.85))
                .frame(width: isDay ? 9 : 7, height: isDay ? 9 : 7)
        }
        .position(at)
    }

    /// Fixed positions rather than random ones, so the stars do not move
    /// every second when the view redraws.
    private func stars(in size: CGSize) -> some View {
        let spots: [(CGFloat, CGFloat, CGFloat)] = [
            (0.12, 0.18, 1.6), (0.27, 0.42, 1.1), (0.41, 0.12, 1.3), (0.58, 0.3, 1.0),
            (0.73, 0.15, 1.5), (0.86, 0.38, 1.1), (0.93, 0.1, 1.2), (0.66, 0.55, 0.9),
            (0.2, 0.65, 0.9), (0.48, 0.6, 1.0),
        ]
        return ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
            Circle()
                .fill(Color.panelInk.opacity(0.55))
                .frame(width: spot.2, height: spot.2)
                .position(x: size.width * spot.0, y: size.height * spot.1)
        }
    }

    /// Top and bottom of the sky for an hour, blended across the edges of
    /// each band so the colour never jumps on the hour.
    static func palette(_ hour: Double) -> [Color] {
        let night: [Color] = [Color(red: 0.05, green: 0.07, blue: 0.2), Color(red: 0.1, green: 0.1, blue: 0.3)]
        let dawn: [Color] = [Color(red: 0.22, green: 0.22, blue: 0.42), Color(red: 0.62, green: 0.4, blue: 0.4)]
        let day: [Color] = [Color(red: 0.15, green: 0.33, blue: 0.56), Color(red: 0.3, green: 0.47, blue: 0.66)]
        let dusk: [Color] = [Color(red: 0.26, green: 0.17, blue: 0.38), Color(red: 0.66, green: 0.36, blue: 0.28)]
        let stops: [(Double, [Color])] = [(0, night), (5, night), (6.5, dawn), (8.5, day),
                                          (16.5, day), (18.5, dusk), (20, night), (24, night)]
        // The sky's hue is kept as a tone, not a colour: enough to tell
        // night from noon at a glance, not enough to look like a wallpaper.
        for i in 1..<stops.count where hour <= stops[i].0 {
            let (h0, c0) = stops[i - 1], (h1, c1) = stops[i]
            let f = h1 == h0 ? 0 : (hour - h0) / (h1 - h0)
            return zip(c0, c1).map { MeshBackdrop.muted($0.mix(with: $1, by: f), by: 0.6) }
        }
        return night.map { MeshBackdrop.muted($0, by: 0.6) }
    }
}

// MARK: - Ticks

/// A level as a row of fine vertical ticks lit up to it.
///
/// What replaced the rings. A ring is the stock dashboard gauge, and two or
/// three side by side read as any monitoring app; a filled bar is the same
/// thing flattened. Ticks read as an instrument: precise, quiet, and of a
/// piece with the dithered stock chart, so the panels share one hand.
struct TickMeter: View {
    var fraction: Double
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let count = max(1, Int((geo.size.width + 3) / 6))
            let lit = Int((min(max(fraction, 0), 1) * Double(count)).rounded())
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(Color.panelInk.opacity(index < lit ? 0.88 : 0.1))
                        .frame(width: 3)
                }
            }
            .animation(.smooth(duration: 0.4), value: lit)
        }
        .frame(height: height)
    }
}

/// The last minute as smooth filled lines, one per series, on faint rules.
///
/// It was a row of fine bars, one per sample, on the reasoning that a line
/// through a one-second sampler is either jagged or smoothed into something
/// that did not happen. Monotone interpolation answers both: it curves
/// between the samples without overshooting any of them, so every peak
/// drawn is a peak that was measured.
///
/// Several series share one scale so they can be read against each other,
/// and each is filled to the floor with its own colour fading out, which is
/// what lets two of them overlap without one hiding the other.
struct AreaHistory: View {
    struct Series: Identifiable {
        var name: String
        var samples: [Double]
        var color: Color
        var id: String { name }
    }

    var series: [Series]
    var range: ClosedRange<Double>
    /// How many samples a full buffer holds. A buffer still filling is drawn
    /// against the right edge, the way the minute will look once it is full.
    var length: Int
    /// Lines alone when false, for several series where fills stacked on
    /// fills would muddy every colour.
    var filled = true

    var body: some View {
        Chart {
            ForEach(series) { line in
                let offset = length - line.samples.count
                ForEach(Array(line.samples.enumerated()), id: \.offset) { index, value in
                    let x = Double(offset + index)
                    let y = min(max(value, range.lowerBound), range.upperBound)
                    if filled {
                        AreaMark(x: .value("Second", x), yStart: .value("Floor", range.lowerBound),
                                 yEnd: .value(line.name, y), series: .value("Series", line.name))
                            .foregroundStyle(LinearGradient(colors: [line.color.opacity(0.32),
                                                                     line.color.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Second", x), y: .value(line.name, y),
                             series: .value("Series", line.name))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: 0 ... Double(max(length - 1, 1)))
        .chartYScale(domain: range)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.panelInk.opacity(0.08))
            }
        }
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}
