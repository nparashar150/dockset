import AppKit
import SwiftUI

/// Now Playing: artwork, track, transport and a scrubber (264×62 on a bottom
/// shelf, a stacked 76pt column on a side one, or a 64pt artwork-only chip).
///
/// Reads Spotify and Apple Music directly, and falls back to whatever video is
/// playing in a scriptable browser tab.
struct MusicTile: View {
    var instance: WidgetInstance
    var context: WidgetContext

    private var config: WidgetConfig { instance.config }
    private var isMini: Bool { config.bool("mini") }

    /// Sources the user allows, in preference order - whichever is enabled
    /// first wins when both are playing.
    private var sources: [MusicSource] {
        var list: [MusicSource] = []
        if config.bool("spotify", default: true) { list.append(.spotify) }
        if config.bool("apple", default: true) { list.append(.appleMusic) }
        return list
    }

    private var browsersEnabled: Bool { config.bool("browsers", default: true) }

    /// The artwork, when there is one to stand on.
    ///
    /// Never in a side column, where the artwork is the thumbnail at the top:
    /// 76pt is too narrow to put a title over a picture and keep either
    /// readable, so a cover behind it only buried both.
    private var cover: NSImage? {
        guard !context.isPreview, !context.position.isVertical else { return nil }
        return playing?.artwork
    }

    /// Ink, pinned once a cover is behind it.
    ///
    /// `WidgetSurface` lays 60% black over the artwork, which makes the card
    /// a dark surface in either appearance. `WidgetStyle.primary` follows the
    /// system, so in a light appearance it would go black and disappear into
    /// exactly the scrim that is there to keep text readable. Same reasoning
    /// as the detail panel's ground and the sticky note's fixed paper.
    private var ink: Color { cover == nil ? WidgetStyle.primary : .white }

    private var subInk: Color {
        cover == nil ? WidgetStyle.secondary : Color(white: 0.82)
    }

    /// The icon of whichever app is playing, for the tile to show when there
    /// is no album art.
    ///
    /// `AppCatalog` caches these; `NSWorkspace.icon(forFile:)` hits the disk
    /// and this is asked on every layout pass. Nil when the app is not
    /// installed, which leaves the generic note rather than a blank square.
    private func sourceIcon(_ track: Playing?) -> NSImage? {
        guard let track, !context.isPreview else { return nil }
        return track.icon ?? AppCatalog.shared.icon(forBundleID: track.sourceBundleID)
    }

    /// How often a playing track is re-read. The scrubber glides over exactly
    /// this long, so it arrives just as the next reading does.
    static let pollInterval: TimeInterval = 0.85

    /// Whichever source has something to show.
    ///
    /// A native player always wins while it is actually playing; a browser
    /// only gets a look in once Spotify and Music have nothing going on.
    private var playing: Playing? {
        if context.isPreview { return Self.sample }
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

    /// Consent is per target app, so a browser can be blocked while Spotify is
    /// fine, and vice versa. One button clears whichever it is.
    private var needsPermission: Bool {
        guard !context.isPreview else { return false }
        return MusicService.shared.needsAutomationPermission
            || (browsersEnabled && BrowserMedia.shared.needsPermission)
    }

    private static let sample = Playing(native: NowPlaying(
        title: "Daylight", artist: "Sample artist", album: "Sample album",
        duration: 240, elapsed: 74, isPlaying: true, artwork: nil, source: .spotify
    ))

    var body: some View {
        // The cover is the card.
        //
        // It used to be a thumbnail drawn inside the card, which on a 64pt
        // chip is a square crop of a 16:9 frame and on the wide tile is
        // 38 points of picture competing with the text beside it. Behind
        // everything it is the record you are listening to rather than a
        // stamp of it.
        WidgetSurface(image: cover) {
            content
        }
        .onAppear {
            guard !context.isPreview else { return }
            // ponytail: shared poll, start-only - the shelf is always on
            // screen, so there is nothing to stop it for.
            MusicService.shared.enabled = sources
            MusicService.shared.start()
            BrowserMedia.shared.enabled = browsersEnabled
            BrowserMedia.shared.start()
        }
        .onChange(of: sources) { _, new in
            if !context.isPreview { MusicService.shared.enabled = new }
        }
        .onChange(of: browsersEnabled) { _, new in
            if !context.isPreview { BrowserMedia.shared.enabled = new }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isMini {
            // Just the control.
            //
            // Mini is a 64pt chip and artwork there is a thumbnail cropped to
            // a square: an album cover survives it, a video thumbnail becomes
            // two faces and half a word of somebody's title. At that size it
            // is texture rather than information, and it was competing with
            // the one thing the chip is for.
            //
            // Still a glyph rather than the whole card, so the rest of the
            // chip keeps the shelf's click and the panel stays reachable.
            // It is simply the only thing on the chip now, so it can be the
            // size it deserves instead of tucked into a corner.
            let side: CGFloat = context.position.isVertical ? 15 : 13
            if let playing, !context.isPreview {
                TileGlyph(symbol: playing.isPlaying ? "pause.fill" : "play.fill",
                          size: side) { toggle(playing) }
                    .accessibilityLabel(playing.isPlaying ? "Pause" : "Play")
            } else {
                // Nothing playing is nothing to toggle, so the chip shows what
                // it is and the whole of it opens the panel.
                Image(systemName: "music.note")
                    .font(.system(size: side * 1.4, weight: .medium))
                    .foregroundStyle(subInk)
            }
        } else if needsPermission, playing == nil {
            connect
        } else if let playing {
            if context.position.isVertical { column(playing) } else { strip(playing) }
        } else {
            idle
        }
    }

    // MARK: Wide, 264×62

    /// Whichever service actually owns what is on screen. Firing both meant
    /// pausing a YouTube tab also started Spotify, and the tile then jumped to
    /// a different track.
    private func toggle(_ track: Playing) {
        // The artwork reaches this without going through `button`, which is
        // where every other control's preview guard sits.
        guard !context.isPreview else { return }
        if track.isBrowser { BrowserMedia.shared.playPause() }
        else { MusicService.shared.playPause() }
    }

    private func strip(_ track: Playing) -> some View {
        HStack(spacing: 11) {
            Artwork(image: track.artwork, fallback: sourceIcon(track), side: 38, corner: 8,
                    isPlaying: track.isPlaying) { toggle(track) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        title(track, size: 15)
                        artist(track, size: 12)
                    }
                    Spacer(minLength: 0)
                    // Play/pause is on the artwork in this layout, so the row
                    // carries only what the artwork cannot - and is dropped
                    // entirely when there is nothing else to carry.
                    if track.hasSkipControls {
                        transport(track, size: 14, spacing: 10, playPause: false)
                    }
                }
                // A video with no readable duration (a live stream, or a site
                // that reports none) would draw two 0:00 clocks around an
                // empty bar, so it gets no scrubber at all.
                if track.duration > 0 || !track.isBrowser { scrubber(track) }
            }
        }
        // 52pt of content, so this must satisfy 52 + 2*padding <= the
        // catalog's card height or the surface overflows its frame and
        // `.clipped()` shaves the 14pt corner radius flat. At 7 it painted
        // 66pt inside a 62pt box, which is the "1-2px too tall" card.
        .padding(.vertical, 3)
    }

    private func scrubber(_ track: Playing) -> some View {
        HStack(spacing: 7) {
            time(MusicTime.clock(track.elapsed))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(cover == nil ? WidgetStyle.secondary.opacity(0.3)
                                                : .white.opacity(0.42))
                    Capsule()
                        .fill(ink)
                        .frame(width: max(0, geo.size.width * track.progress))
                        // Playback advances at a constant rate, so gliding to
                        // each new reading at that rate *is* the truth - and a
                        // bar that steps once a second reads as a stutter even
                        // though the number behind it is correct. Linear, and
                        // only while playing: a seek or a pause should land.
                        .animation(track.isPlaying ? .linear(duration: MusicTile.pollInterval)
                                                   : nil,
                                   value: track.progress)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    // Browser playback is read-only apart from play/pause.
                    guard !context.isPreview, !track.isBrowser,
                          geo.size.width > 0, track.duration > 0 else { return }
                    let ratio = min(1, max(0, location.x / geo.size.width))
                    MusicService.shared.seek(to: ratio * track.duration)
                }
            }
            .frame(height: 4)
            time(MusicTime.clock(track.duration))
        }
    }

    private func time(_ text: String) -> some View {
        Text(text)
            .font(WidgetStyle.caption(11))
            .monospacedDigit()
            .rollingValue(text)
            .foregroundStyle(subInk)
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: Column, 76pt wide

    /// No scrubber here: 56pt of usable width cannot carry two clocks and a
    /// bar, so the column spends its height on the track instead.
    private func column(_ track: Playing) -> some View {
        VStack(spacing: 3) {
            Artwork(image: track.artwork, fallback: sourceIcon(track), side: 32, corner: 7)
            VStack(spacing: 0) {
                // Two lines in a column, where one cut a title to its first
                // word: a column has height to spare and no width at all.
                Text(track.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                artist(track, size: 10)
            }
            transport(track, size: 11, spacing: 6)
        }
        .padding(.vertical, 2)
    }

    // MARK: Shared pieces

    private func title(_ track: Playing, size: CGFloat) -> some View {
        Text(track.title)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            // Truncated, never shrunk. A video title runs long, and scaling it
            // to fit drove the most important line on the tile down to a few
            // points - smaller than the artist underneath it.
            .truncationMode(.tail)
    }

    private func artist(_ track: Playing, size: CGFloat) -> some View {
        Text(track.artist)
            .font(WidgetStyle.caption(size))
            .foregroundStyle(subInk)
            .lineLimit(1)
            // A little shrink before the cut, so a short name such as
            // "Sample artist" fits a side column whole.
            .minimumScaleFactor(0.8)
            .truncationMode(.tail)
    }

    /// Browser video gets play/pause only: seeking, skipping and track changes
    /// mean nothing to a `<video>` element, and a button that does nothing is
    /// worse than one that is not there.
    ///
    /// `playPause` is false where the layout already puts it on the artwork -
    /// the wide strip does, the column does not - because the two rendered it
    /// side by side otherwise, twice in the same row.
    @ViewBuilder
    private func transport(_ track: Playing, size: CGFloat, spacing: CGFloat,
                           playPause: Bool = true) -> some View {
        if track.isBrowser {
            button(track.isPlaying ? "pause.fill" : "play.fill", size) { toggle(track) }
        } else {
            let skip = max(1, config.int("skip", default: 15))
            HStack(spacing: spacing) {
                if config.bool("backward") {
                    button(skipSymbol("gobackward", skip), size) { MusicService.shared.skip(by: -Double(skip)) }
                }
                if config.bool("previous", default: true) {
                    button("backward.end.fill", size) { MusicService.shared.previous() }
                }
                if playPause {
                    button(track.isPlaying ? "pause.fill" : "play.fill", size) { toggle(track) }
                }
                if config.bool("next", default: true) {
                    button("forward.end.fill", size) { MusicService.shared.next() }
                }
                if config.bool("forward") {
                    button(skipSymbol("goforward", skip), size) { MusicService.shared.skip(by: Double(skip)) }
                }
            }
        }
    }

    /// SF Symbols only ships numbered skip glyphs for a handful of intervals;
    /// anything else falls back to the plain arrow rather than a blank square.
    private func skipSymbol(_ base: String, _ seconds: Int) -> String {
        let numbered: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]
        return numbered.contains(seconds) ? "\(base).\(seconds)" : base
    }

    private func button(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: { if !context.isPreview { action() } }) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(ink)
                .frame(minWidth: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty states

    /// Shown instead of silently failing, and it is the *only* thing that ever
    /// raises the automation consent dialog.
    ///
    /// Sized to the glyph and its label, not to the card: the card's own click
    /// belongs to the detail panel, which offers the same button.
    private var connect: some View {
        Button {
            MusicService.shared.requestAutomationPermission()
            if browsersEnabled { BrowserMedia.shared.requestPermission() }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .medium))
                Text("Connect")
                    .font(WidgetStyle.label(11))
                    .lineLimit(1)
                    // A side shelf leaves 56pt inside the card, which the word
                    // only just fits; truncating it to "Conne…" reads as a bug.
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(ink)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Three different empty states, because they mean different things.
    ///
    /// "Not playing" when a player is open and idle; the menu path when a
    /// browser has media tabs but will not run our JavaScript; the app names
    /// when nothing at all is open.
    private var idle: some View {
        let open = !context.isPreview && MusicService.shared.hasPlayer
        let setup = browserSetupHint
        return VStack(spacing: 2) {
            Image(systemName: setup != nil ? "switch.2" : (open ? "music.note" : "music.note.list"))
                .font(.system(size: 14, weight: .medium))
            Text(setup ?? (open ? "Not playing" : sourceNames))
                .font(WidgetStyle.caption(11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(subInk)
        .frame(maxWidth: .infinity)
        .help(setup.map { "A browser tab has media, but Docket cannot read it. Turn on \($0)." }
              ?? (open ? "Nothing is playing." : "Docket reads \(sourceNames), and video in a scriptable browser tab."))
    }

    /// The menu item the user has to switch on, or nil when nothing is asking.
    private var browserSetupHint: String? {
        guard !context.isPreview, browsersEnabled, BrowserMedia.shared.needsSetup else { return nil }
        let hint = BrowserMedia.shared.setupHint
        return hint.isEmpty ? nil : hint
    }

    /// The players this widget is configured to read, e.g. "Spotify or Music".
    private var sourceNames: String {
        let names = sources.map(\.displayName)
        guard !names.isEmpty else { return "No sources" }
        return names.count == 1 ? names[0] : names.joined(separator: " or ")
    }
}

/// One reading, whatever produced it, so the layouts do not care whether they
/// are drawing Spotify or a YouTube tab.
struct Playing {
    var title: String
    var artist: String
    var isPlaying: Bool
    var elapsed: TimeInterval
    var duration: TimeInterval
    var progress: Double
    var artwork: NSImage?
    var isBrowser: Bool

    /// The app the sound is actually coming from, so the tile can show its
    /// icon when there is no album art.
    ///
    /// Browser video never has artwork, which used to mean every YouTube or
    /// Netflix tab drew the same generic note. The browser's own icon says
    /// far more, and it is the honest answer besides: the browser is what is
    /// playing. Read from the system at runtime rather than shipped, which
    /// is also the only way to show Spotify's mark without redistributing
    /// it.
    var sourceBundleID: String

    /// A better icon than the source app's, when there is one: the site's
    /// own, for browser playback. Netflix in Safari is Netflix, not Safari.
    var icon: NSImage?

    /// The ground the detail panel stands on, when the artwork yielded one.
    var tint: ArtworkTint?

    /// Whether anything beyond play/pause is meaningful.
    ///
    /// A `<video>` element has nothing to skip to, so browser playback offers
    /// play/pause and nothing else. Which view draws that one button is the
    /// layout's business - see `transport`'s `playPause`.
    var hasSkipControls: Bool { !isBrowser }

    init(native: NowPlaying) {
        title = native.title
        artist = native.artist
        isPlaying = native.isPlaying
        elapsed = native.elapsed
        duration = native.duration
        progress = native.progress
        artwork = native.artwork
        isBrowser = false
        sourceBundleID = native.source.bundleID
        tint = native.tint
    }

    /// Artwork comes from `BrowserMedia`, which fetches it once per video
    /// rather than once per poll, so it is passed in rather than read here.
    init(browser: BrowserTrack, artwork: NSImage?, icon: NSImage?, tint: ArtworkTint?) {
        title = browser.title
        artist = browser.site
        isPlaying = browser.isPlaying
        elapsed = browser.elapsed
        duration = browser.duration
        progress = browser.progress
        self.artwork = artwork
        isBrowser = true
        sourceBundleID = browser.browser.bundleID
        self.icon = icon
        self.tint = tint
    }
}

/// Album art, or a music-note placeholder when there is none - the tile must
/// never show an empty hole while artwork is still downloading.
private struct Artwork: View {
    var image: NSImage?
    /// Drawn instead of the note when there is no album art: the icon of
    /// whichever app is playing.
    var fallback: NSImage?
    var side: CGFloat
    var corner: CGFloat
    /// When set, the artwork itself toggles playback.
    var isPlaying: Bool?
    var onToggle: (() -> Void)?

    /// Plain album art takes no gesture at all. A tap gesture with nothing to
    /// do still *consumes* the tap, so an always-attached handler was how the
    /// column's artwork ate the shelf's click and left the panel unreachable.
    var body: some View {
        if let onToggle, let isPlaying {
            square(control: isPlaying)
                .contentShape(.rect)
                .onTapGesture(perform: onToggle)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
        } else {
            square(control: nil)
                .accessibilityLabel("Artwork")
        }
    }

    /// `control` carries the play state while the artwork is acting as a
    /// button, and is nil when it is only showing the album art.
    private func square(control: Bool?) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(WidgetStyle.primary.opacity(0.08))
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if let fallback {
                    // The playing app's own icon. Inset, because an app icon
                    // already carries its own rounded shape and padding, and
                    // filling the square with it made the tile look like a
                    // launcher for that app rather than a reading from it.
                    Image(nsImage: fallback)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(side * 0.17)
                } else if control == nil {
                    // Nothing playing and nothing to name, so the generic
                    // note. Only when nothing else occupies the square: with
                    // the play control on top, the note showed through
                    // behind it and read as two overlapping glyphs.
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.48, weight: .medium))
                        .foregroundStyle(WidgetStyle.primary)
                }
            }
            .overlay {
                // The control lives on the artwork rather than beside it: for
                // video there is nothing to skip to, so a lone button was
                // spending width the title badly needed.
                if let control {
                    ZStack {
                        // Fixed, not hover-driven: SwiftUI's .onHover never
                        // fires in this non-activating accessory panel (see
                        // HoverCatcher), so a hover-only affordance is invisible.
                        Color.black.opacity(0.34)
                        // Full strength, and large. The artwork renders about
                        // 31pt on a default-sized shelf, so a small
                        // semi-transparent glyph over a dark placeholder was
                        // invisible in practice - it read as no control at all.
                        Image(systemName: control ? "pause.fill" : "play.fill")
                            .font(.system(size: side * 0.46, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
