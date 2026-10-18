import AppKit
import SwiftUI

/// Now Playing at length: the artwork as the whole card, the transport in
/// its middle, and the track and a scrubber you can drag along its foot.
///
/// It used to stack them: artwork, then title, then scrubber, then controls,
/// which spent most of the panel on the gaps between four rows and left the
/// picture a small square in the middle of it. The card is the picture now,
/// dimmed where text sits on it, the way the system's own player does it.
///
/// The tile is width-starved - 264pt carrying artwork, two lines of text, a
/// scrubber and buttons - so it hides controls and shrinks the art. None of
/// those compromises apply here, and the panel undoes them rather than
/// restating the tile larger.
///
/// It does not start the services: the panel only ever opens from a tile that
/// is already on screen, and that tile owns the poll and the source list.
struct MusicDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    /// Where a drag is holding the playhead, 0…1, or nil when the bar is
    /// following playback. Readings keep arriving mid-drag, so the bar has to
    /// answer to the pointer until it is let go or it fights the poll.
    @State private var scrubbing: Double?

    private var config: WidgetConfig { instance.config }

    /// Same preference order the tile reads, so the panel cannot end up
    /// showing a different player than the tile it grew out of.
    private var sources: [MusicSource] {
        var list: [MusicSource] = []
        if config.bool("spotify", default: true) { list.append(.spotify) }
        if config.bool("apple", default: true) { list.append(.appleMusic) }
        return list
    }

    private var browsersEnabled: Bool { config.bool("browsers", default: true) }

    /// The ground the chrome paints, if the artwork gave one.
    ///
    /// Static because the chrome asks before this view exists, and it asks
    /// through the same `playing` resolution so the colour can never belong
    /// to a different track than the one on screen.
    @MainActor
    static func ground(instance: WidgetInstance, context: WidgetContext) -> ArtworkTint? {
        MusicDetail(instance: instance, context: context).playing?.tint
    }

    fileprivate var playing: Playing? {
        guard !context.isPreview else { return nil }
        let native = MusicService.shared.nowPlaying.map(Playing.init(native:))
        let browser = browsersEnabled
            ? BrowserMedia.shared.track.map {
                Playing(browser: $0, artwork: BrowserMedia.shared.artwork,
                        icon: BrowserMedia.shared.siteIcon, tint: BrowserMedia.shared.tint)
            }
            : nil
        if native?.isPlaying == true { return native }
        if browser?.isPlaying == true { return browser }
        return native ?? browser
    }

    private var needsPermission: Bool {
        guard !context.isPreview else { return false }
        return MusicService.shared.needsAutomationPermission
            || (browsersEnabled && BrowserMedia.shared.needsPermission)
    }

    var body: some View {
        Group {
            if let track = playing {
                card(track)
            } else if needsPermission {
                connect
            } else {
                idle
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Everything on the card is on a picture or on the source's colour, both
    /// darkened, so the ink is fixed white rather than following the system:
    /// a semantic colour would go dark in a light appearance and disappear.
    private let ink = Color.white
    private let subInk = Color.white.opacity(0.75)
    private let trackInk = Color.white.opacity(0.3)

    // MARK: Card

    /// How far the card reaches past the panel's padding: to 6pt from its
    /// edge, where a 14pt corner sits concentric with the panel's 20.
    private static let bleed: CGFloat = 10
    private static let corner: CGFloat = 14

    /// The artwork as the card, in both appearances: the picture is what
    /// the panel is for, and a light version either washed it out or shrank
    /// it to a thumbnail.
    private func card(_ track: Playing) -> some View {
        let icon = track.icon ?? AppCatalog.shared.icon(forBundleID: track.sourceBundleID)
        return ZStack {
            backdrop(track.artwork, tint: track.tint)
            scrim
            VStack(spacing: 0) {
                HStack {
                    if let icon {
                        // Whose it is: Netflix, Spotify, Music. Beside the
                        // picture rather than instead of it.
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    }
                    Spacer()
                }
                Spacer(minLength: 8)
                transport(track)
                Spacer(minLength: 8)
                titles(track)
                // A video with no readable duration would draw two 0:00
                // clocks around a bar that can never move, so it gets none.
                if track.duration > 0 || !track.isBrowser {
                    scrubber(track).padding(.top, 10)
                }
            }
            .padding(14)
        }
        // The same height as every other card. See `DetailCard.height`.
        .frame(height: DetailCard<EmptyView, EmptyView>.height)
        .clipShape(.rect(cornerRadius: Self.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(ink.opacity(0.1), lineWidth: 0.5)
        }
        .padding(-Self.bleed)
    }

    /// The artwork filling the card, or with none, the colour the source's
    /// icon gave, so a page with no picture still stands on its own brand.
    @ViewBuilder
    private func backdrop(_ image: NSImage?, tint: ArtworkTint?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .accessibilityLabel("Artwork")
        } else if let tint {
            LinearGradient(colors: [Self.colour(tint.top), Self.colour(tint.bottom)],
                           startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(colors: [Color(white: 0.26), Color(white: 0.12)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// Dark enough under the controls to read on any picture, darker still
    /// under the title and scrubber, and light at the top so the picture is
    /// still the picture.
    private var scrim: some View {
        ZStack {
            Color.black.opacity(0.22)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.25), location: 0),
                .init(color: .clear, location: 0.3),
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.75), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    private static func colour(_ rgb: (red: Double, green: Double, blue: Double)) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    // MARK: Track

    private func titles(_ track: Playing) -> some View {
        // One line each, never wrapped: the panel is sized once when it opens,
        // so a second line would be clipped by the window. What does not fit
        // scrolls instead, which the tile deliberately never does: text
        // moving on the shelf all day is a distraction, in a panel that was
        // opened to read it, it is the way to read it.
        VStack(alignment: .leading, spacing: 1) {
            Marquee(text: track.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ink)
            Marquee(text: track.artist)
                .font(WidgetStyle.caption(12))
                .foregroundStyle(subInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }

    // MARK: Scrubber

    private func scrubber(_ track: Playing) -> some View {
        let ratio = scrubbing ?? track.progress
        return HStack(spacing: 9) {
            time(MusicTime.clock(scrubbing.map { $0 * track.duration } ?? track.elapsed),
                 alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(trackInk)
                    Capsule()
                        .fill(ink)
                        .frame(width: max(0, geo.size.width * ratio))
                        // Playback advances at a constant rate, so gliding to
                        // each reading at that rate is the truth; a drag is
                        // not, and must land exactly where the pointer is.
                        .animation(track.isPlaying && scrubbing == nil
                                   ? .linear(duration: MusicTile.pollInterval) : nil,
                                   value: ratio)
                }
                .contentShape(Rectangle())
                .gesture(seek(track, width: geo.size.width))
            }
            .frame(height: 5)
            time(MusicTime.clock(track.duration), alignment: .trailing)
        }
    }

    /// Browser playback is read-only apart from play/pause: there is no way to
    /// move a `<video>` element's playhead from here.
    private func seek(_ track: Playing, width: CGFloat) -> some Gesture {
        // Zero minimum distance so a plain click seeks too - jumping to a
        // point is the more common gesture, dragging the rarer one.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canSeek(track), width > 0 else { return }
                scrubbing = min(1, max(0, value.location.x / width))
            }
            .onEnded { value in
                guard canSeek(track), width > 0 else { return }
                let ratio = min(1, max(0, value.location.x / width))
                scrubbing = nil
                MusicService.shared.seek(to: ratio * track.duration)
            }
    }

    private func canSeek(_ track: Playing) -> Bool {
        !context.isPreview && !track.isBrowser && track.duration > 0
    }

    /// A minimum width rather than a fitted one: without it the bar shifts
    /// sideways the moment a track crosses ten minutes.
    private func time(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(WidgetStyle.caption(12))
            .monospacedDigit()
            .rollingValue(text)
            .foregroundStyle(subInk)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 34, alignment: alignment)
    }

    // MARK: Transport

    /// Previous and next are unconditional here even though the tile makes
    /// them optional - that switch exists to buy width on a 264pt strip, and
    /// the panel has width to spare. The skip-by-N buttons stay opt-in,
    /// because those are a preference rather than a concession to space.
    @ViewBuilder
    private func transport(_ track: Playing) -> some View {
        if track.isBrowser {
            // One control, so it had better look deliberate. A lone glyph
            // under the scrubber reads as something left unfinished.
            play(track.isPlaying) { toggle(track) }
        } else {
            let step = max(1, config.int("skip", default: 15))
            HStack(spacing: 14) {
                if config.bool("backward") {
                    secondary(skipSymbol("gobackward", step), 15) {
                        MusicService.shared.skip(by: -Double(step))
                    }
                }
                secondary("backward.end.fill", 17) { MusicService.shared.previous() }
                play(track.isPlaying) { MusicService.shared.playPause() }
                secondary("forward.end.fill", 17) { MusicService.shared.next() }
                if config.bool("forward") {
                    secondary(skipSymbol("goforward", step), 15) {
                        MusicService.shared.skip(by: Double(step))
                    }
                }
            }
        }
    }

    /// Whichever service owns what is on screen. Firing both means pausing a
    /// tab also starts Spotify, and the panel then jumps to another track.
    private func toggle(_ track: Playing) {
        if track.isBrowser { BrowserMedia.shared.playPause() }
        else { MusicService.shared.playPause() }
    }

    /// SF Symbols ships numbered skip glyphs for a handful of intervals only;
    /// anything else falls back to the plain arrow rather than a blank square.
    private func skipSymbol(_ base: String, _ seconds: Int) -> String {
        let numbered: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]
        return numbered.contains(seconds) ? "\(base).\(seconds)" : base
    }

    /// The one you came for.
    ///
    /// `compact` is the same control sized to sit in the scrubber's row
    /// rather than to anchor a row of its own.
    private func play(_ playing: Bool, compact: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button {
            guard !context.isPreview else { return }
            action()
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: compact ? 13 : 21, weight: .semibold))
                // Optical, not geometric: play.fill is a triangle whose mass
                // sits left of its box, so centring the box leaves it looking
                // shoved to one side inside a circle. Pause is symmetric and
                // needs none.
                .offset(x: playing ? 0 : 1.5)
        }
        .buttonStyle(TransportButton(primary: true, ink: ink, compact: compact))
        .accessibilityLabel(playing ? "Pause" : "Play")
    }

    private func secondary(_ symbol: String, _ size: CGFloat,
                           action: @escaping () -> Void) -> some View {
        Button {
            guard !context.isPreview else { return }
            action()
        } label: {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
        }
        .buttonStyle(TransportButton(primary: false, ink: ink))
    }

    // MARK: Empty states

    /// The only thing that ever raises the automation consent dialog, and it
    /// runs solely because the user clicked it.
    private var connect: some View {
        Button {
            guard !context.isPreview else { return }
            MusicService.shared.requestAutomationPermission()
            if browsersEnabled { BrowserMedia.shared.requestPermission() }
        } label: {
            Text("Connect")
                .font(WidgetStyle.label(13))
                .foregroundStyle(WidgetStyle.primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(Capsule().fill(WidgetStyle.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Three different lines, because they mean different things: a player
    /// open and idle, a browser that will not run our JavaScript, or nothing
    /// open at all.
    private var idle: some View {
        let open = !context.isPreview && MusicService.shared.hasPlayer
        let setup = browserSetupHint
        return VStack(spacing: 4) {
            Text(setup == nil ? (open ? "Not playing" : "Nothing to read")
                              : "A tab has media Docket cannot read")
                .font(WidgetStyle.label(13))
                .foregroundStyle(WidgetStyle.primary)
            Text(setup ?? (open ? "Start something in \(sourceNames)."
                                : "Docket reads \(sourceNames), and video in a scriptable browser tab."))
                .font(WidgetStyle.caption(12))
                .foregroundStyle(WidgetStyle.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// The menu item the user has to switch on, or nil when nothing is asking.
    private var browserSetupHint: String? {
        guard !context.isPreview, browsersEnabled, BrowserMedia.shared.needsSetup else { return nil }
        let hint = BrowserMedia.shared.setupHint
        return hint.isEmpty ? nil : hint
    }

    private var sourceNames: String {
        let names = sources.map(\.displayName)
        guard !names.isEmpty else { return "no sources" }
        return names.count == 1 ? names[0] : names.joined(separator: " or ")
    }
}

/// Transport controls that answer a click and say which one is the point.
///
/// Every control used to be the same bare glyph at a different point size on
/// `.plain`, which draws no pressed state at all: play and pause read as
/// merely the largest of five rather than the one the panel is for, and
/// nothing acknowledged being clicked. A filled disc for the primary and
/// plain glyphs either side is the hierarchy Apple Music uses, and it is the
/// same disc-deepens-and-shrinks response `TileGlyph` already gives the
/// shelf, so the two surfaces answer a press the same way.
///
/// Ink is passed in rather than taken from `WidgetStyle`. When the panel is
/// standing on a colour drawn from the artwork, its brightness is fixed by
/// this app rather than by the system, so a semantic colour here would go
/// dark in a forced-light appearance and disappear into it. The title and
/// the scrubber were already pinned for that reason; these were missed.
private struct TransportButton: ButtonStyle {
    var primary: Bool
    var ink: Color
    /// Sized to ride in another row rather than to anchor one.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let side: CGFloat = compact ? 28 : (primary ? 46 : 34)
        return configuration.label
            // The secondaries sit back a little so the primary leads without
            // having to be enormous.
            .foregroundStyle(ink.opacity(primary ? 1 : (pressed ? 1 : 0.7)))
            .frame(width: side, height: side)
            .background {
                if primary {
                    Circle().fill(ink.opacity(pressed ? 0.26 : 0.14))
                }
            }
            // Round, so the corners of the box do not swallow a click meant
            // for the neighbour.
            .contentShape(Circle())
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.14), value: pressed)
    }
}

/// One line that slides to show its end when it does not fit, then back.
///
/// Truncated and still under Reduce Motion, and whenever it fits.
private struct Marquee: View {
    var text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var scrolled = false

    /// Points per second: slow enough to read while it moves.
    private static let speed: CGFloat = 30

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }
    private var moves: Bool { overflow > 1 && !reduceMotion }

    var body: some View {
        // The truncated line sets the size, always. The moving copy is an
        // overlay, which cannot change layout: as the view itself, its full
        // natural width reached the panel, and a long title widened the card
        // past its window.
        Text(text)
            .truncationMode(.tail)
            .opacity(moves ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if moves {
                    Text(text)
                        .fixedSize()
                        .offset(x: scrolled ? -overflow : 0)
                }
            }
            .clipped()
            .lineLimit(1)
            // The natural width, measured off-screen, against the room there
            // is. A background, like the overlay, has no say in the size.
            .background {
                Text(text).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { textWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { boxWidth = $0 }
            .onChange(of: moves, initial: true) { _, _ in restart() }
            .onChange(of: overflow) { _, _ in restart() }
            .accessibilityLabel(text)
    }

    private func restart() {
        // Back to the start without animating, then out again after a pause
        // long enough to read the beginning.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { scrolled = false }
        guard moves else { return }
        withAnimation(.linear(duration: Double(overflow / Self.speed))
            .delay(1.5)
            .repeatForever(autoreverses: true)) {
            scrolled = true
        }
    }
}
