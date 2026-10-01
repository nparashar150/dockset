import AppKit
import Foundation
import Observation

/// Quick questions to Claude, answered as cards.
///
/// One question at a time: asking again cancels the one in flight, and so
/// does closing the panel, because an answer nobody is looking at is spend
/// for nothing. The answer streams, and each block is handed to the panel
/// the moment its JSON closes, so the card builds itself rather than
/// appearing all at once after a long pause.
@MainActor @Observable
final class AskService {
    static let shared = AskService()

    enum Phase: Equatable {
        case idle
        /// Sent, nothing back yet.
        case thinking
        /// At least one block has arrived.
        case answering
        case done
        case failed(String)
    }

    private(set) var question = ""
    private(set) var phase: Phase = .idle
    private(set) var title: String?
    private(set) var blocks: [AskBlock] = []
    private(set) var hasKey = AnthropicKey.read() != nil
    /// Where the `claude` command lives, once found. Hand-off cards are only
    /// drawn when there is somewhere to hand off to.
    private(set) var claudePath: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lookedForClaude = false

    /// Starts looking for `claude` straight away, so a hand-off in the
    /// first answer is not dropped for want of a path found a moment later.
    private init() { findClaude() }

    func refreshKey() { hasKey = AnthropicKey.read() != nil }

    func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancel()
        refreshKey()
        guard let key = AnthropicKey.read() else { return }
        question = trimmed
        title = nil
        blocks = []
        phase = .thinking
        task = Task { await stream(trimmed, key: key) }
    }

    /// Stops the answer in flight and keeps whatever had already arrived.
    func cancel() {
        task?.cancel()
        task = nil
        if phase == .thinking { phase = .idle }
        if phase == .answering { phase = .done }
    }

    func reset() {
        cancel()
        question = ""
        title = nil
        blocks = []
        phase = .idle
    }

    // MARK: Request

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Frozen: nothing per request goes in here, so it is the same bytes on
    /// every call.
    private static let system = """
    You answer quick questions asked from a small widget on a Mac's dock. The \
    person wants the answer at a glance. Be accurate and brief, and build the \
    answer from the fewest blocks that make it scannable: lead with an \
    `answer` block that states the answer in one sentence, then add only what \
    helps (facts for figures, steps for procedures, code for code, a table for \
    comparisons, a link when a source is the answer). `text` blocks may use \
    inline Markdown. Keep the title under six words. Add a `handoff` block \
    only when the request needs real work in files, code or a multi-step task \
    on this Mac; its `prompt` must be a complete, self-contained instruction \
    for a coding agent, and its `text` one short line saying what it will do.
    """

    private static let schema: [String: Any] = {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let fact: [String: Any] = [
            "type": "object",
            "properties": ["label": string, "value": string],
            "required": ["label", "value"],
            "additionalProperties": false,
        ]
        let block: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": AskBlock.Kind.allCases.map(\.rawValue)],
                "text": string,
                "items": strings,
                "facts": ["type": "array", "items": fact],
                "language": string,
                "url": string,
                "rows": ["type": "array", "items": strings],
                "prompt": string,
            ],
            "required": ["kind"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": ["title": string, "blocks": ["type": "array", "items": block]],
            "required": ["title", "blocks"],
            "additionalProperties": false,
        ]
    }()

    private func request(_ question: String, key: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // A declined question is re-run on the recommended fallback model
        // inside the same call, rather than coming back as a refusal.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": 8000,
            "stream": true,
            "fallbacks": "default",
            // Low effort: these are quick questions, and a quick answer is
            // the whole point of the widget.
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": Self.schema],
            ],
            "system": Self.system,
            "messages": [["role": "user", "content": question]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func stream(_ question: String, key: String) async {
        var buffer = ""
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request(question, key: key))
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                return fail(Self.message(forStatus: status))
            }
            for try await line in bytes.lines {
                guard let event = AskSSE.event(fromLine: line) else { continue }
                switch event {
                case .text(let delta):
                    buffer += delta
                    absorb(buffer)
                case .stop(let reason):
                    if reason == "refusal" {
                        return fail("Claude couldn't help with that one.")
                    }
                case .failure(let message):
                    return fail(message)
                }
            }
            // The finished document, decoded whole, in case the last block
            // closed in the same delta as the array.
            if let answer = try? JSONDecoder().decode(AskAnswer.self, from: Data(buffer.utf8)) {
                title = answer.title
                blocks = answer.blocks.filter(showable)
            }
            guard !Task.isCancelled else { return }
            phase = blocks.isEmpty ? .failed("No answer came back.") : .done
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                fail("Offline. Check your connection and try again.")
            default:
                fail("Couldn't reach Claude.")
            }
        } catch {
            fail("Couldn't reach Claude.")
        }
    }

    /// Takes whatever blocks have closed in the text received so far.
    private func absorb(_ buffer: String) {
        guard !Task.isCancelled else { return }
        if title == nil { title = AskStream.title(in: buffer) }
        let found = AskStream.completeBlocks(in: buffer).filter(showable)
        guard found.count != blocks.count else { return }
        blocks = found
        phase = .answering
    }

    /// A hand-off with nowhere to go is a button that does nothing.
    private func showable(_ block: AskBlock) -> Bool {
        block.kind != .handoff || claudePath != nil
    }

    private func fail(_ message: String) {
        guard !Task.isCancelled else { return }
        phase = .failed(message)
    }

    private static func message(forStatus status: Int) -> String {
        switch status {
        case 401, 403: "API key not valid. Check it in Settings ▸ Widgets."
        case 429: "Rate limited, try again in a moment."
        case 529, 500...599: "Claude is busy right now. Try again shortly."
        default: "Couldn't get an answer (HTTP \(status))."
        }
    }

    // MARK: Hand-off

    /// Looks for the `claude` command once, through a login shell so the
    /// person's own PATH applies, off the main thread.
    private func findClaude() {
        guard !lookedForClaude else { return }
        lookedForClaude = true
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v claude"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !path.isEmpty else { return }
            await MainActor.run { AskService.shared.claudePath = path }
        }
    }

    /// Opens Terminal running `claude` with the prompt already given.
    ///
    /// The prompt is model text, so it is escaped for the AppleScript string
    /// it sits in and then handed to the shell through `quoted form of`,
    /// which is AppleScript's own shell quoting: nothing in it can break out
    /// into a second command.
    static func handOff(_ prompt: String) {
        let literal = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "claude " & quoted form of "\(literal)"
        end tell
        """
        NSAppleScript(source: source)?.executeAndReturnError(nil)
    }

    // MARK: Copy

    /// The answer as plain text, for "Copy all".
    var plainText: String {
        var lines: [String] = []
        if let title { lines.append(title) }
        for block in blocks {
            if let text = block.text { lines.append(text) }
            if let items = block.items {
                lines += items.enumerated().map { block.kind == .steps ? "\($0.offset + 1). \($0.element)" : "- \($0.element)" }
            }
            if let facts = block.facts { lines += facts.map { "\($0.label): \($0.value)" } }
            if let rows = block.rows { lines += rows.map { $0.joined(separator: "\t") } }
            if let url = block.url { lines.append(url) }
            if let prompt = block.prompt { lines.append(prompt) }
        }
        return lines.joined(separator: "\n\n")
    }
}
