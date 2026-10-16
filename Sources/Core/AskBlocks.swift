import Foundation

/// One piece of an Ask answer: a headline, a paragraph, a set of facts, a
/// snippet of code. The model chooses which pieces an answer needs and the
/// panel draws each kind its own way, so a quick answer reads as a card
/// rather than as a wall of text.
public struct AskBlock: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case answer, text, facts, steps, list, code, callout, table, link, handoff
    }

    public struct Fact: Codable, Hashable, Sendable {
        public var label: String
        public var value: String
    }

    public var kind: Kind
    public var text: String?
    public var items: [String]?
    public var facts: [Fact]?
    public var language: String?
    public var url: String?
    public var rows: [[String]]?
    public var prompt: String?
}

/// A finished answer, in the shape the request's schema asks for.
public struct AskAnswer: Codable, Hashable, Sendable {
    public var title: String
    public var blocks: [AskBlock]
}

/// Reading an answer while it is still arriving.
///
/// The response streams as one JSON document. Waiting for all of it would
/// leave the panel on its loader for the whole answer, so this scans the text
/// received so far and hands back every block whose object has already
/// closed. Pure, so it is tested.
public enum AskStream {
    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
    private static let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")

    /// Every block in the top-level `blocks` array that is complete so far.
    ///
    /// Braces and brackets are only counted outside strings, and a string
    /// only ends on an unescaped quote, so `"a \"}\" b"` inside a block does
    /// not close it. A block that does not decode is skipped rather than
    /// failing the ones around it.
    public static func completeBlocks(in text: String) -> [AskBlock] {
        let bytes = Array(text.utf8)
        var depth = 0
        var inString = false, escaped = false
        var stringStart = 0
        var lastTopLevelString: String?
        var blocksDepth: Int?
        var objectStart: Int?
        var blocks: [AskBlock] = []

        for index in bytes.indices {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                    if depth == 1 {
                        lastTopLevelString = String(decoding: bytes[(stringStart + 1)..<index], as: UTF8.self)
                    }
                }
                continue
            }
            switch byte {
            case quote:
                inString = true
                stringStart = index
            case openBrace:
                depth += 1
                if let blocksDepth, depth == blocksDepth + 1 { objectStart = index }
            case closeBrace:
                if let blocksDepth, depth == blocksDepth + 1, let start = objectStart {
                    if let block = try? JSONDecoder().decode(AskBlock.self, from: Data(bytes[start...index])) {
                        blocks.append(block)
                    }
                    objectStart = nil
                }
                depth -= 1
            case openBracket:
                depth += 1
                // Only a `[` straight after the top-level `blocks` key: the
                // last string read at the top level is then that key.
                if blocksDepth == nil, depth == 2, lastTopLevelString == "blocks" { blocksDepth = depth }
            case closeBracket:
                if depth == blocksDepth { blocksDepth = nil }
                depth -= 1
            default:
                break
            }
        }
        return blocks
    }

    /// The answer's title, once its string has closed.
    public static func title(in text: String) -> String? {
        let bytes = Array(text.utf8)
        var depth = 0
        var inString = false, escaped = false
        var stringStart = 0
        var afterTitleKey = false

        for index in bytes.indices {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                    guard depth == 1 else { continue }
                    let literal = Data(bytes[stringStart...index])
                    if afterTitleKey { return try? JSONDecoder().decode(String.self, from: literal) }
                    afterTitleKey = (try? JSONDecoder().decode(String.self, from: literal)) == "title"
                }
                continue
            }
            switch byte {
            case quote: inString = true; stringStart = index
            case openBrace, openBracket: depth += 1
            case closeBrace, closeBracket: depth -= 1
            default: break
            }
        }
        return nil
    }
}

/// The server-sent events a streamed Messages response is made of, reduced to
/// the three things the panel acts on.
public enum AskSSE {
    public enum Event: Equatable, Sendable {
        /// More of the answer's JSON.
        case text(String)
        /// Why generation ended: `end_turn`, `max_tokens`, `refusal`...
        case stop(String)
        /// The stream itself reported a failure.
        case failure(String)
    }

    /// The event carried by one `data:` line, or nil for lines that carry
    /// nothing the panel needs (pings, block starts, the message envelope).
    public static func event(fromLine line: String) -> Event? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "message_delta":
            guard let delta = object["delta"] as? [String: Any],
                  let reason = delta["stop_reason"] as? String else { return nil }
            return .stop(reason)
        case "error":
            let error = object["error"] as? [String: Any]
            return .failure(error?["message"] as? String ?? "The answer stopped part way.")
        default:
            return nil
        }
    }
}
