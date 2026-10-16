import XCTest

final class AskBlocksTests: XCTestCase {

    private let full = #"""
    {"title":"Brewing a pour-over","blocks":[
    {"kind":"answer","text":"About 3 minutes at 93°C."},
    {"kind":"facts","facts":[{"label":"Ratio","value":"1:16"},{"label":"Grind","value":"Medium-fine"}]},
    {"kind":"steps","items":["Rinse the filter","Bloom 30s","Pour in circles"]},
    {"kind":"code","language":"swift","text":"let s = \"{\\\"a\\\": [1]}\""},
    {"kind":"table","rows":[["Dose","Water"],["15g","240g"]]},
    {"kind":"link","url":"https://example.com","text":"Guide"},
    {"kind":"handoff","prompt":"Write a brew timer","text":"Build it"}
    ]}
    """#

    func testEveryKindDecodesFromAFullAnswer() {
        let blocks = AskStream.completeBlocks(in: full)
        XCTAssertEqual(blocks.map(\.kind), [.answer, .facts, .steps, .code, .table, .link, .handoff])
        XCTAssertEqual(blocks[1].facts?.first, AskBlock.Fact(label: "Ratio", value: "1:16"))
        XCTAssertEqual(blocks[4].rows?.last, ["15g", "240g"])
        XCTAssertEqual(AskStream.title(in: full), "Brewing a pour-over")
    }

    /// Escaped quotes and braces inside a string must not close the block.
    func testBracesInsideStringsAreText() {
        let code = AskStream.completeBlocks(in: full).first { $0.kind == .code }
        XCTAssertEqual(code?.text, #"let s = "{\"a\": [1]}""#)
    }

    /// Mid-stream, only the blocks whose objects have closed come back.
    func testPartialStreamYieldsOnlyFinishedBlocks() {
        let cut = full.range(of: #"{"kind":"steps""#)!.lowerBound
        let partial = String(full[..<cut]) + #"{"kind":"steps","items":["Rinse the fil"#
        XCTAssertEqual(AskStream.completeBlocks(in: partial).map(\.kind), [.answer, .facts])
        XCTAssertNil(AskStream.title(in: #"{"title":"Brewing a po"#))
        XCTAssertEqual(AskStream.title(in: #"{"title":"Brewing""#), "Brewing")
    }

    /// A key called "blocks" inside a block is not the top-level array, and
    /// a block that does not match the model is skipped, not fatal.
    func testOnlyTopLevelBlocksAndBadBlocksSkipped() {
        let text = #"{"title":"blocks","blocks":[{"kind":"nope"},{"kind":"text","text":"ok"}]}"#
        XCTAssertEqual(AskStream.completeBlocks(in: text).map(\.kind), [.text])
        XCTAssertEqual(AskStream.completeBlocks(in: "").count, 0)
    }

    func testServerSentEvents() {
        XCTAssertEqual(AskSSE.event(fromLine: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"{\"ti"}}"#),
                       .text(#"{"ti"#))
        XCTAssertEqual(AskSSE.event(fromLine: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#),
                       .stop("refusal"))
        XCTAssertEqual(AskSSE.event(fromLine: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
                       .failure("Overloaded"))
        XCTAssertNil(AskSSE.event(fromLine: "event: ping"))
        XCTAssertNil(AskSSE.event(fromLine: #"data: {"type":"ping"}"#))
    }
}
