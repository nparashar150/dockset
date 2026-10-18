import AppKit
import SwiftUI

/// Ask at length: the coding agents running on this Mac, and a question at
/// the foot that can be about them or about anything.
///
/// The agents are listed by project with the last thing asked in each; a chip
/// per session brings its tab forward, or takes a message for it. A question
/// carries the list with it, so "which ones are waiting?" is answered from
/// what is actually running. The answer replaces the list as cards.
///
/// The panel window is sized once when it opens, so the card is a fixed
/// height and the list and the answer scroll inside it.
struct AskDetail: View {
    var instance: WidgetInstance
    var context: WidgetContext

    @State private var draft = ""
    @State private var key = ""
    @FocusState private var focused: Bool
    /// The session a message is being written for, and the message.
    @State private var sendingTo: RunningAgent?
    @State private var message = ""

    private var service: AskService { AskService.shared }
    private var scanner: AgentScanner { AgentScanner.shared }

    var body: some View {
        DetailCard {
            MeshBackdrop(color: Color(hex: PaletteColor.indigo.hex))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if context.isPreview || service.canAsk {
                    stage
                        .frame(maxHeight: .infinity, alignment: .top)
                    // At the foot, where a chat's input is: the list above is
                    // what the question is usually about.
                    input
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
        // Every few seconds while this panel is the one open. The window is
        // hidden rather than torn down between openings, so the loop checks
        // rather than relying on being cancelled.
        .task {
            guard !context.isPreview else { return }
            while !Task.isCancelled {
                if WidgetDetailWindow.shared.openWidgetID == instance.id { await scanner.refresh() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        // An answer nobody is looking at is spend for nothing.
        .onDisappear { if !context.isPreview { service.cancel() } }
    }

    // MARK: Input

    private var busy: Bool { service.phase == .thinking || service.phase == .answering }

    private var input: some View {
        HStack(spacing: 10) {
            // Pulses while an answer is coming and gives one hop when it
            // lands: the mark is where the question went, so it is what
            // answers.
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(busy ? Color(hex: PaletteColor.indigo.hex) : Color.panelInk.opacity(0.7))
                .symbolEffect(.pulse, options: .repeating, isActive: busy)
                .symbolEffect(.bounce, value: service.phase == .done)
                .animation(.smooth(duration: 0.3), value: busy)
            TextField("", text: $draft, prompt: Text(scanner.agents.isEmpty ? "Ask anything…" : "Ask about your agents, or anything…").foregroundStyle(Color.panelInk.opacity(0.45)))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Color.panelInk)
                .focused($focused)
                .onSubmit(send)
                .disabled(context.isPreview)
            Button {
                if busy { service.cancel() } else { send() }
            } label: {
                Image(systemName: busy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.panelInk)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.panelInk.opacity(draft.isEmpty && !busy ? 0.1 : 0.24)))
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
        ask(draft)
        draft = ""
    }

    /// Every question carries the agents running right now, when there are
    /// any: the list is a few hundred tokens and it is what most questions
    /// asked from here are about.
    private func ask(_ question: String) {
        service.ask(question, context: scanner.agents.isEmpty ? nil : scanner.summary)
    }

    // MARK: Stage

    @ViewBuilder private var stage: some View {
        if context.isPreview {
            answer(title: Self.sampleTitle, blocks: Self.sample, finished: true)
        } else {
            switch service.phase {
            case .idle:
                if scanner.agents.isEmpty { suggestions } else { agentList }
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
                .foregroundStyle(Color.panelInk.opacity(0.5))
            ForEach(Self.prompts, id: \.self) { prompt in
                Button { ask(prompt) } label: {
                    Text(prompt)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.panelInk.opacity(0.85))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.panelInk.opacity(0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Agents

    /// One row per session, working first, then the most recently active.
    /// The row says what it is about: what it was last asked, and the start
    /// of its answer. Click to bring its tab forward.
    private var agentList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(agentHeadline)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Color.panelInk.opacity(0.5))
                    Spacer()
                    Button("What needs me?") { ask("Which of my agents need me, and what is each one doing?") }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.panelInk.opacity(0.7))
                }
                .padding(.bottom, 6)
                ForEach(scanner.sorted) { agent in
                    agentRow(agent)
                    if sendingTo == agent { sendField(agent) }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private var agentHeadline: String {
        let count = scanner.agents.count
        let working = scanner.working
        let base = count == 1 ? "1 AGENT" : "\(count) AGENTS"
        return working > 0 ? "\(base) · \(working) WORKING" : base
    }

    private func agentRow(_ agent: RunningAgent) -> some View {
        Button { AgentScanner.focus(agent) } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(agent.working ? Color.green : Color.panelInk.opacity(0.2))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(agent.headline)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.panelInk)
                        Spacer(minLength: 6)
                        Text(agent.working ? "now" : AgentScanner.age(agent.updated ?? agent.started))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.panelInk.opacity(0.45))
                            .monospacedDigit()
                    }
                    Text([agent.project, agent.lastReply].compactMap(\.self).joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.panelInk.opacity(0.55))
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(AgentRowStyle())
        .help("\(agent.name) in \(agent.host)\n\(agent.directory ?? "")\n" +
              (agent.canSend ? "Click to bring forward, right-click to send a message" : "Click to bring forward"))
        .contextMenu {
            Button("Bring Forward") { AgentScanner.focus(agent) }
            if agent.canSend { Button("Send a Message…") { sendingTo = agent } }
            if let directory = agent.directory {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(directory, forType: .string)
                }
            }
        }
    }

    private func sendField(_ target: RunningAgent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane")
                .font(.system(size: 11))
                .foregroundStyle(Color.panelInk.opacity(0.6))
            TextField("", text: $message,
                      prompt: Text("Type into this session…").foregroundStyle(Color.panelInk.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    AgentScanner.send(text, to: target)
                    message = ""
                    sendingTo = nil
                }
                .onExitCommand { sendingTo = nil }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassPane(cornerRadius: 9)
        .padding(.leading, 24)
        .padding(.bottom, 4)
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
                        .foregroundStyle(Color.panelInk.opacity(0.55))
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
                .foregroundStyle(Color.panelInk.opacity(0.75))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.panelInk.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func failure(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Color.panelInk.opacity(0.8))
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.panelInk.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                footerButton("Try again", symbol: "arrow.clockwise") { ask(service.question) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPane()
    }

    // MARK: No key

    /// Shown only when neither route exists: no key, and no `claude` CLI on
    /// this Mac. The key is taken here, where the question was going to be
    /// typed, rather than sending anyone off to find a Settings tab first.
    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            TileBadge(size: 44) {
                Image(systemName: "sparkle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.panelInk)
                    .symbolEffect(.breathe)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask Claude anything")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.panelInk)
                Text("Install the claude CLI and it is used automatically, or paste an Anthropic API key. A key stays in your Keychain and is only sent to Anthropic.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.panelInk.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField("", text: $key, prompt: Text("sk-ant-…").foregroundStyle(Color.panelInk.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.panelInk)
                .focused($focused)
                .onSubmit(saveKey)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassPane(cornerRadius: 12)
            HStack(spacing: 14) {
                Link("Get the claude CLI", destination: URL(string: "https://claude.com/claude-code")!)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.panelInk.opacity(0.75))
                Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.panelInk.opacity(0.75))
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
                .foregroundStyle(Color.panelInk)
                .fixedSize(horizontal: false, vertical: true)
        case .text:
            Text(markdown(block.text ?? ""))
                .font(.system(size: 13))
                .foregroundStyle(Color.panelInk.opacity(0.88))
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
                            .foregroundStyle(Color.panelInk)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.panelInk.opacity(0.14)))
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
                        Text(markdown(item))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.panelInk.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .list:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Color.panelInk.opacity(0.5)).frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        Text(markdown(item))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.panelInk.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code:
            code
        case .callout:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.panelInk.opacity(0.6)).frame(width: 3)
                Image(systemName: "lightbulb")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.panelInk.opacity(0.75))
                Text(markdown(block.text ?? ""))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.panelInk.opacity(0.88))
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
                    .foregroundStyle(Color.panelInk.opacity(0.5))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(block.text ?? "", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.panelInk.opacity(0.7))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            ScrollView(.horizontal) {
                Text(block.text ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.panelInk.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize()
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.panelInk.opacity(0.08)))
    }

    private var table: some View {
        let rows = block.rows ?? []
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.system(size: 12, weight: index == 0 ? .semibold : .regular))
                            .foregroundStyle(Color.panelInk.opacity(index == 0 ? 0.95 : 0.85))
                            .monospacedDigit()
                    }
                }
                if index == 0 {
                    Rectangle().fill(Color.panelInk.opacity(0.12)).frame(height: 0.5).gridCellUnsizedAxes(.horizontal)
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
                        .foregroundStyle(Color.panelInk.opacity(0.75))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(block.text ?? url.host() ?? url.absoluteString)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.panelInk)
                        Text(url.host() ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.panelInk.opacity(0.55))
                    }
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.panelInk.opacity(0.6))
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
                    .foregroundStyle(Color.panelInk)
                Text("Continue in Terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.panelInk)
            }
            if let text = block.text {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.panelInk.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { AskService.handOff(block.prompt ?? block.text ?? "") } label: {
                Text("Open in Terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.panelInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.panelInk.opacity(0.22)))
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

/// What the panel shows between asking and the first block arriving: the
/// word "Thinking" with light passing through it, over the question.
///
/// It was a turning ring around the mark and three skeleton lines, which read
/// as a loading spinner on a loop. Light moving across the word reads as
/// something being written, and the mark in the input pulses alongside it.
private struct AskThinking: View {
    let question: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // Across and off the end every 1.8s, eased so it lingers on
                // the word rather than sweeping at one speed.
                let raw = t.truncatingRemainder(dividingBy: 1.8) / 1.8
                let phase = raw * raw * (3 - 2 * raw)
                Text("Thinking")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.panelInk.opacity(0.35))
                    .overlay {
                        Text("Thinking")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(LinearGradient(
                                colors: [Color.panelInk, Color(hex: PaletteColor.indigo.hex)],
                                startPoint: .leading, endPoint: .trailing))
                            .mask {
                                GeometryReader { geo in
                                    LinearGradient(colors: [.clear, .white, .clear],
                                                   startPoint: .leading, endPoint: .trailing)
                                        .frame(width: geo.size.width * 0.7)
                                        .offset(x: -geo.size.width * 0.7 + geo.size.width * 1.7 * phase)
                                }
                            }
                    }
            }
            Text(question)
                .font(.system(size: 12))
                .foregroundStyle(Color.panelInk.opacity(0.55))
                .lineLimit(2)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thinking about \(question)")
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
                        .fill(Color.panelInk.opacity(0.7))
                        .frame(width: 5, height: 5)
                        .offset(y: -3 * max(0, sin(t * 5 - Double(i) * 0.7)))
                        .opacity(0.45 + 0.55 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
        }
        .frame(height: 10)
    }
}

/// A row that lights on hover and dips when pressed, with no chrome at rest:
/// a list of sessions reads as a list, not a stack of cards.
private struct AgentRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering(pressed: configuration.isPressed) { configuration.label }
    }

    private struct Hovering<Label: View>: View {
        var pressed: Bool
        @ViewBuilder var label: () -> Label
        @State private var hovered = false

        var body: some View {
            label()
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.panelInk.opacity(pressed ? 0.1 : hovered ? 0.06 : 0)))
                .onHover { hovered = $0 }
                .animation(.smooth(duration: 0.15), value: hovered)
        }
    }
}
