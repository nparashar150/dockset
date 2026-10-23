import SwiftUI

/// The sticky note at length: the same paper the shelf shows, at a size a note
/// can be written on rather than glanced at.
///
/// Paper and nothing else. A swatch picker or a word count would turn the note
/// into a form; the swatch already lives in the widget's settings, one button
/// up in the chrome.
struct StickyNoteDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    /// The chrome tints the panel with the *kind's* yellow, which is neither
    /// the note's own swatch nor, in the dark, light enough to carry dark ink.
    /// So the sheet is drawn on top of it: every `PaperColor` is a light swatch
    /// in both appearances, which is what lets the ink stay a fixed dark
    /// instead of a semantic colour that would go white and vanish.
    private static let darkInk = Color(hex: "#1C1C1E")

    /// The card is always drawn dark, so anything that is not a light swatch
    /// writes in white.
    private var ink: Color { color.needsLightInk ? .white : Self.darkInk }

    private var color: PaperColor {
        PaperColor(rawValue: instance.config.string("color", default: "yellow")) ?? .yellow
    }

    /// What is being typed, kept apart from the stored note so the profile is
    /// written once the sentence is finished rather than once per keystroke.
    @State private var draft = ""
    @FocusState private var writing: Bool

    /// No paper still needs a ground under white ink: the panel's material
    /// is light in the light appearance. Smoked glass keeps it translucent
    /// and readable either way.
    private var paper: Color {
        color.isTranslucent ? .black.opacity(0.55) : WidgetStyle.paper(color)
    }

    private var stored: String { instance.config.string("text") }

    var body: some View {
        // The same card every other panel is drawn on, with paper as its
        // surface. It was a tile surface sitting inside the panel's full
        // padding, so it stood a good 10pt further in from the edge than any
        // other panel's card, and read as a sheet in a frame rather than as
        // the panel.
        DetailCard(dark: true) {
            paper
        } content: {
            // Return finishes the note and Shift-Return breaks the line, which
            // is the vertical field's own behaviour: a note is usually one
            // thought, and the panel is open to be written in, not read.
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($writing)
                .font(.system(size: Self.fontSize(for: draft), weight: .semibold))
                .foregroundStyle(ink)
                .lineSpacing(4)
                .onSubmit {
                    commit()
                    writing = false
                }
                .onChange(of: writing) { _, active in if !active { commit() } }
                // Saved a moment after typing stops, not only when focus
                // leaves: a pasted note stayed off the tile until the panel
                // was clicked out of. Each save is a profile write, so a
                // pause rather than every keystroke.
                .task(id: draft) {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    commit()
                }
                // One panel serves every note in turn, so reopening it hands
                // this view a different widget; take that note's words unless
                // the caret is still mid-sentence in the last one.
                .onChange(of: stored) { _, note in if !writing { draft = note } }
                .onAppear {
                    draft = stored
                    beginWriting()
                }
                // Closing the panel hides its window rather than tearing this
                // view down, so whichever of the two happens first, the words
                // are already saved.
                .onDisappear { commit() }
                .accessibilityLabel("Note")
                // The card forces the dark scheme; the caret has to be ink
                // like the words, or it is white on paper.
                .tint(ink)
                // Tall enough that a short note leaves the rest of the sheet
                // blank, the way paper does.
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                .background {
                    // Blank paper is most of the sheet and is where people aim.
                    // Behind the field so a click on the words still reaches it
                    // directly.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { beginWriting() }
                }
                // The sheet keeps the card's height and a long note scrolls
                // on it. The field grew with every line instead, past the
                // window, which is sized once as it opens, and the panel lost
                // its outline to the overflow.
                .scrollable(height: DetailCard<EmptyView, EmptyView>.height - 32)
        }
    }

    /// Large while a note is a few words, smaller as it becomes a paragraph,
    /// so a pasted page is still a page and not three words a line.
    static func fontSize(for text: String) -> CGFloat {
        switch text.count {
        case ..<80: 20
        case ..<240: 16
        default: 13
        }
    }

    /// The panel takes key status as it opens and the caret may as well be in
    /// the paper: there is nothing else here to click.
    private func beginWriting() {
        guard !context.isPreview else { return }
        writing = true
    }

    /// Focus leaves the paper far more often than the words change, and every
    /// write is a profile save.
    private func commit() {
        guard !context.isPreview, draft != stored else { return }
        WidgetWriter.write(instance) { config in
            config.set("text", .string(draft))
        }
    }
}

private extension View {
    func scrollable(height: CGFloat) -> some View {
        ScrollView(.vertical) { self }
            .scrollIndicators(.automatic)
            .frame(height: height)
    }
}
