import AppKit
import Foundation
import Observation

/// Quick questions to Claude, answered as cards.
///
/// Two ways in. An Anthropic API key, kept in the Keychain, streams the answer
/// block by block. Without one, an installed `claude` CLI answers instead,
/// through the person's own sign-in: most people who would add this widget
/// already have `claude`, and asking them for a second credential was the
/// wall the widget stopped at.
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

    /// Whether a question can be sent at all, by either route.
    var canAsk: Bool { hasKey || claudePath != nil }

    /// `context` is facts the question may be about - the agents running on
    /// this Mac - put ahead of it in the same message. The question alone is
    /// what is shown and kept.
    func ask(_ text: String, context: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancel()
        refreshKey()
        let key = AnthropicKey.read()
        guard key != nil || claudePath != nil else { return }
        question = trimmed
        title = nil
        blocks = []
        phase = .thinking
        let message = context.map { "\($0)\n\nQuestion: \(trimmed)" } ?? trimmed
        if let key {
            task = Task { await stream(message, key: key) }
        } else if let claudePath {
            task = Task { await answerWithClaudeCode(message, path: claudePath) }
        }
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
    for a coding agent, and its `text` one short line saying what it will do. \
    A message may begin with a list of the coding agents running on this Mac, \
    read from it moments ago; answer questions about them from that list, by \
    project, and never claim you cannot see them.
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

    // MARK: claude CLI

    /// One `claude -p` run with the widget's own prompt and schema.
    ///
    /// Stripped to the question: no tools, no MCP servers, none of the
    /// person's settings, memory or plugins, and no saved session. Measured,
    /// a bare `claude -p` carried a 62,000-token default prompt and cost half
    /// a dollar to add two numbers; this costs a fraction of a cent and
    /// answers in about three seconds. Run from a scratch directory so no
    /// project's files are anywhere in reach.
    private func answerWithClaudeCode(_ question: String, path: String) async {
        guard let schema = try? JSONSerialization.data(withJSONObject: Self.schema) else { return }
        let arguments = [
            "-p", question,
            "--output-format", "json",
            "--system-prompt", Self.system,
            "--json-schema", String(decoding: schema, as: UTF8.self),
            "--model", "sonnet",
            "--tools", "",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--no-session-persistence",
        ]
        do {
            let output = try await Self.run(path, arguments)
            guard !Task.isCancelled else { return }
            guard let reply = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                return fail("The claude CLI didn't answer. Run `claude` once in Terminal to sign in.")
            }
            if reply["is_error"] as? Bool == true {
                let detail = (reply["result"] as? String) ?? ""
                return fail(detail.localizedCaseInsensitiveContains("log")
                            ? "The claude CLI isn't signed in. Run `claude` once in Terminal."
                            : "Claude couldn't answer that.")
            }
            guard let structured = reply["structured_output"],
                  let data = try? JSONSerialization.data(withJSONObject: structured),
                  let answer = try? JSONDecoder().decode(AskAnswer.self, from: data) else {
                return fail("No answer came back.")
            }
            title = answer.title
            blocks = answer.blocks.filter(showable)
            phase = blocks.isEmpty ? .failed("No answer came back.") : .done
        } catch is CancellationError {
            return
        } catch {
            fail("Couldn't start the claude CLI.")
        }
    }

    /// Runs a command to completion off the main thread and returns what it
    /// printed. Cancelling the task terminates the process, so closing the
    /// panel stops a question that is still being answered.
    nonisolated private static func run(_ path: String, _ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // A GUI app inherits launchd's bare PATH, and `claude` may be a
        // script that needs node from Homebrew or a version manager.
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                               environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                process.terminationHandler = { _ in
                    continuation.resume(returning: output.fileHandleForReading.readDataToEndOfFile())
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
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
