import AppKit
import SwiftUI

/// The one thing about AirDrop a glyph cannot say: whether anybody can
/// actually see this Mac.
///
/// The tile is a launcher and nothing more - it draws the same blue square
/// whether AirDrop is set to Everyone or switched off entirely, which is the
/// state where the tile is quietly a lie. So the panel reports the setting and
/// then gets out of the way with the two doors worth having: the Finder window
/// that lists nearby devices, and the settings pane where the mode is changed.
///
/// What is deliberately absent: nearby devices, transfer history, and a mode
/// picker. `sharingd` discovers peers over AWDL for its own UI and publishes
/// none of it to unprivileged apps, and `DiscoverableMode` is readable but not
/// ours to write - a toggle here would either do nothing or need a scripted
/// click on somebody else's window. The footnote says so plainly rather than
/// leaving the omission to look like an oversight.
///
/// The mode is read once, when the panel opens. It changes only when the user
/// goes and changes it - in Control Centre, in Finder, or in Settings - and
/// all three mean leaving this panel, which dismisses it. Polling for a value
/// that cannot move while it is on screen would be a timer spent on nothing.
struct AirDropDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    /// `nil` covers both "not read yet" and "sharingd has no answer", because
    /// the panel says the same honest thing in either case.
    @State private var mode: Discoverability?

    var body: some View {
        // The mode is the colour: blue for contacts, amber for everyone,
        // graphite for off. Rings spread from the corner the way the signal
        // does, fainter the further they go.
        DetailCard {
            ZStack(alignment: .topTrailing) {
                MeshBackdrop(color: ground)
                ripples
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                state
                HStack(spacing: 8) {
                    button("Open AirDrop", fill: Color.panelInk.opacity(0.24), label: Color.panelInk, action: openWindow)
                    button("Settings", fill: Color.panelInk.opacity(0.14), label: Color.panelInk, action: openSettings)
                }
                Text("Nearby devices are listed only in Finder's AirDrop window, and the mode is changed in Control Centre or Settings.")
                    .font(WidgetStyle.caption(10))
                    .foregroundStyle(Color.panelInk.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: read)
    }

    private var ground: Color {
        switch mode {
        case .contacts: Self.blue
        case .everyone: Color(red: 0.85, green: 0.5, blue: 0.1)
        case .off, nil: Color(white: 0.32)
        }
    }

    /// Four rings from the top corner, the broadcast drawn rather than named.
    /// Still when nobody can see this Mac: there is nothing going out.
    private var ripples: some View {
        ZStack {
            ForEach(1...4, id: \.self) { ring in
                Circle()
                    .strokeBorder(Color.panelInk.opacity(mode == .off || mode == nil ? 0.04 : 0.16 / Double(ring)),
                                  lineWidth: 1.5)
                    .frame(width: CGFloat(ring) * 70, height: CGFloat(ring) * 70)
            }
        }
        .offset(x: 70, y: -70)
    }

    // MARK: Pieces

    private var state: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.panelInk.opacity(0.16))
                .frame(width: 46, height: 46)
                .overlay {
                    // The tile's stand-in glyph, so the panel and the card it
                    // opened from are recognisably the same widget.
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(Color.panelInk)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(mode?.title ?? "Setting unavailable")
                    .font(WidgetStyle.label(18))
                    .foregroundStyle(WidgetStyle.primary)
                Text(mode?.detail ?? "macOS is not reporting a discoverability mode.")
                    .font(WidgetStyle.caption(12))
                    .foregroundStyle(Color.panelInk.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        // Two labels that are one fact; read separately they sound like a list.
        .accessibilityElement(children: .combine)
    }

    /// Solid white for the door people came here for, glass for the other,
    /// both capsules so they read on any of the three grounds.
    private func button(_ title: String, fill: Color, label: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(WidgetStyle.label(13))
                .foregroundStyle(label)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(fill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: Data

    private static let blue = Color(hex: "#0A7CFF")

    private func read() {
        guard !context.isPreview else {
            mode = .contacts
            return
        }
        // `sharingd` owns this preference and writes it whenever the user
        // flips the mode somewhere else entirely; cfprefsd keeps handing us a
        // cached copy until it is told to look again, which is all the
        // synchronise does. Public domain, undocumented schema - same footing
        // as the Dock's own preferences, so the read is a lenient match rather
        // than a switch over exact strings.
        _ = CFPreferencesAppSynchronize(Self.domain as CFString)
        let raw = CFPreferencesCopyAppValue("DiscoverableMode" as CFString,
                                            Self.domain as CFString) as? String
        mode = raw.flatMap(Discoverability.init(preference:))
    }

    private static let domain = "com.apple.sharingd"

    // MARK: Actions

    /// Finder's own AirDrop window - the only place peers are ever listed.
    private func openWindow() {
        guard !context.isPreview, let url = URL(string: "nwnode://domain-AirDrop") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSettings() {
        guard !context.isPreview,
              let url = WidgetTarget.settings("com.apple.AirDrop-Handoff-Settings.extension").settingsURL
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// The three modes `sharingd` stores, with what each one costs the user.
    enum Discoverability {
        case off, contacts, everyone

        init?(preference: String) {
            switch preference.lowercased() {
            case let value where value.contains("everyone"): self = .everyone
            case let value where value.contains("contact"): self = .contacts
            case let value where value.contains("off"): self = .off
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .off: "Receiving Off"
            case .contacts: "Contacts Only"
            case .everyone: "Everyone"
            }
        }

        /// Who can see this Mac, which is the question the mode answers.
        var detail: String {
            switch self {
            case .off: "Nobody nearby can see this Mac."
            case .contacts: "People in your contacts, signed in to iCloud."
            case .everyone: "Anyone nearby can see this Mac."
            }
        }

        /// Off is grey rather than red: it is a sensible way to leave a Mac,
        /// not a fault. Everyone is the one worth a warm colour.
        var tint: Color {
            switch self {
            case .off: Color.secondary.opacity(0.5)
            case .contacts: AirDropDetail.blue
            case .everyone: Color(hex: "#FF9F0A")
            }
        }
    }
}
