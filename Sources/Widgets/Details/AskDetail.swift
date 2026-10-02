import AppKit
import SwiftUI

/// Ask at length: a question at the top, the answer built under it as cards.
///
/// The panel window is sized once when it opens, so the card is a fixed
/// height and the answer scrolls inside it rather than growing a window that
/// cannot grow.
struct AskDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    @State private var draft = ""
    @State private var key = ""
    @FocusState private var focused: Bool

    private var service: AskService { AskService.shared }

    var body: some View {
        DetailCard {
            MeshBackdrop(color: Color(hex: PaletteColor.indigo.hex))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if context.isPreview || service.hasKey {
                    input
                    stage
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    connect
                }
            }
            // The card is the standard height; this is what is left of it
            // inside the padding. See `DetailCard.height`.
            .frame(height: DetailCard<EmptyView, EmptyView>.height - 32, alignment: .top)
        }
        .onAppear {
            guard !context.isPreview else { return }
            service.refreshKey()
            focused = true
        }
        // An answer nobody is looking at is spend for nothing.
        .onDisappear { if !context.isPreview { service.cancel() } }
    }

    // MARK: Input

    private var busy: Bool { service.phase == .thinking || service.phase == .answering }

    private var input: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            TextField("", text: $draft, prompt: Text("Ask anything…").foregroundStyle(.white.opacity(0.45)))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .tint(.white)
                .focused($focused)
                .onSubmit(send)
                .disabled(context.isPreview)
            Button {
                if busy { service.cancel() } else { send() }
            } label: {
                Image(systemName: busy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(draft.isEmpty && !busy ? 0.1 : 0.24)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty && !busy)
            .accessibilityLabel(busy ? "Stop" : "Ask")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassPane(cornerRadius: 12)
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        service.ask(draft)
        draft = ""
    }

    // MARK: Stage

    @ViewBuilder private var stage: some View {
        if context.isPreview {
            answer(title: Self.sampleTitle, blocks: Self.sample, finished: true)
        } else {
            switch service.phase {
            case .idle:
                suggestions
            case .thinking:
                AskThinking(question: service.question)
                    .transition(.opacity)
            case .answering, .done:
                answer(title: service.title, blocks: service.blocks, finished: service.phase == .done)
            case .failed(let message):
                failure(message)
            }
        }
    }

    private static let prompts = [
        "What's 15% of 248?",
        "Convert 72°F to Celsius",
        "Undo my last git commit",
    ]

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRY")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.5))
            ForEach(Self.prompts, id: \.self) { prompt in
                Button { service.ask(prompt) } label: {
                    Text(prompt)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func answer(title: String?, blocks: [AskBlock], finished: Bool) -> some View {
        // The library and the capture tool draw the sample offscreen, where a
        // scroll view renders nothing; the sample fits without one.
        if context.isPreview {
            answerBody(title: title, blocks: blocks, finished: finished)
        } else {
            ScrollView { answerBody(title: title, blocks: blocks, finished: finished) }
                .scrollIndicators(.never)
        }
    }

    private func answerBody(title: String?, blocks: [AskBlock], finished: Bool) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                if let title {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(.white.opacity(0.55))
                        .transition(.opacity)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    AskBlockView(block: block)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity))
                }
                if !finished {
                    AskDots().padding(.top, 2)
                } else if !context.isPreview {
                    footer
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.35), value: blocks.count)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerButton("Copy all", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(service.plainText, forType: .string)
            }
            footerButton("Ask another", symbol: "arrow.counterclockwise") {
                service.reset()
                focused = true
            }
        }
        .padding(.top, 4)
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func failure(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                footerButton("Try again", symbol: "arrow.clockwise") { service.ask(service.question) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPane()
    }

    // MARK: No key

    /// The key is taken here, where the question was going to be typed,
    /// rather than sending anyone off to find a Settings tab first.
    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            TileBadge(size: 44) {
                Image(systemName: "sparkle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask Claude anything")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Paste an Anthropic API key to start. It is kept in your Keychain and only ever sent to Anthropic.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField("", text: $key, prompt: Text("sk-ant-…").foregroundStyle(.white.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
                .tint(.white)
                .focused($focused)
                .onSubmit(saveKey)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassPane(cornerRadius: 12)
            HStack {
                Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                footerButton("Save", symbol: "key.fill", action: saveKey)
                    .disabled(key.isEmpty)
            }
        }
    }

    private func saveKey() {
        guard !key.isEmpty else { return }
        AnthropicKey.save(key)
        key = ""
        service.refreshKey()
        focused = true
    }

    // MARK: Sample

    private static let sampleTitle = "Brewing a pour-over"
    private static let sample: [AskBlock] = [
        AskBlock(kind: .answer, text: "About 3 minutes, with water just off the boil (93°C)."),
        AskBlock(kind: .facts, facts: [.init(label: "Ratio", value: "1 : 16"),
                                       .init(label: "Grind", value: "Medium-fine"),
                                       .init(label: "Dose", value: "15 g"),
                                       .init(label: "Water", value: "240 g")]),
        AskBlock(kind: .steps, items: ["Rinse the filter and warm the cup",
                                       "Bloom with 40 g for 30 seconds",
                                       "Pour slowly in circles to 240 g"]),
        AskBlock(kind: .callout, text: "Bitter? Go **coarser**. Sour? Go finer."),
    ]
}

// MARK: - Blocks

/// One block, drawn the way its kind reads best.
private struct AskBlockView: View {
    let block: AskBlock

    var body: some View {
        switch block.kind {
        case .answer:
            Text(block.text ?? "")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        case .text:
            Text(markdown(block.text ?? ""))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.88))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        case .facts:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(Array((block.facts ?? []).enumerated()), id: \.offset) { _, fact in
                    StatChip(label: fact.label, value: fact.value)
                }
            }
        case .steps:
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.white.opacity(0.14)))
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
                        Text(markdown(item))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .list:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(.white.opacity(0.5)).frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        Text(markdown(item))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code:
            code
        case .callout:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.6)).frame(width: 3)
                Image(systemName: "lightbulb")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                Text(markdown(block.text ?? ""))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Sized to its text: the accent bar alone would otherwise take
            // every point of height on offer.
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPane(cornerRadius: 10)
        case .table:
            table
        case .link:
            link
        case .handoff:
            handoff
        }
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((block.language ?? "code").lowercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(block.text ?? "", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            ScrollView(.horizontal) {
                Text(block.text ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize()
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.32)))
    }

    private var table: some View {
        let rows = block.rows ?? []
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.system(size: 12, weight: index == 0 ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(index == 0 ? 0.95 : 0.85))
                            .monospacedDigit()
                    }
                }
                if index == 0 {
                    Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPane(cornerRadius: 10)
    }

    @ViewBuilder private var link: some View {
        // https only: a link from model text opening anything else, a file
        // or a custom scheme, is not something a quick answer should do.
        if let url = block.url.flatMap(URL.init(string:)), url.scheme == "https" {
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "globe")
                        .foregroundStyle(.white.opacity(0.75))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(block.text ?? url.host() ?? url.absoluteString)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                        Text(url.host() ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(10)
                .glassPane(cornerRadius: 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private var handoff: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Continue in Claude Code")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            if let text = block.text {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { AskService.handOff(block.prompt ?? block.text ?? "") } label: {
                Text("Open in Terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Capsule().fill(.white.opacity(0.22)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glassPane()
    }

    /// Inline Markdown only: bold, italics, code spans and links read well in
    /// a line of a card; headings and lists have their own blocks.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Thinking

/// What the panel shows between asking and the first block arriving.
///
/// A slowly turning ring of light around the mark, breathing, over three
/// placeholder lines a soft light passes along: it says something is being
/// written rather than that something has stalled.
private struct AskThinking: View {
    let question: String

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    orb(t)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thinking" + String(repeating: ".", count: Int(t * 2.5) % 4))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(question)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    ForEach([1.0, 0.86, 0.6], id: \.self) { width in
                        skeleton(width: width, t: t)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private func orb(_ t: Double) -> some View {
        let breathe = 1 + 0.06 * sin(t * 2.4)
        return ZStack {
            Circle()
                .fill(.white.opacity(0.06))
            Circle()
                .strokeBorder(
                    AngularGradient(colors: [.white.opacity(0.05), .white.opacity(0.85),
                                             Color(hex: PaletteColor.indigo.hex).opacity(0.6),
                                             .white.opacity(0.05)],
                                    center: .center),
                    lineWidth: 1.6)
                .rotationEffect(.degrees(t * 120))
            Image(systemName: "sparkle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .scaleEffect(breathe)
                .opacity(0.75 + 0.25 * sin(t * 2.4))
        }
        .frame(width: 38, height: 38)
    }

    /// A placeholder line with a band of light sweeping along it.
    private func skeleton(width: Double, t: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width * width
            let phase = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay {
                    LinearGradient(colors: [.clear, .white.opacity(0.22), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 0.45)
                        .offset(x: -w * 0.45 + (w * 1.45) * phase)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .frame(width: w)
        }
        .frame(height: 9)
    }
}

/// Three dots that rise in turn, under blocks still arriving.
private struct AskDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(0.7))
                        .frame(width: 5, height: 5)
                        .offset(y: -3 * max(0, sin(t * 5 - Double(i) * 0.7)))
                        .opacity(0.45 + 0.55 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
        }
        .frame(height: 10)
    }
}
