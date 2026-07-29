import Foundation
import Testing
@testable import CockerCore

/// The daemon forwards container output as it arrives, so one log line can
/// reach the CLI split across several events. With a sticky footer that
/// redraws between events, a mid-line redraw tears the line in half and
/// wedges the footer inside it:
///
///     [api] API-LOG- → Attached api
///        press d detach · q quit
///     3
///
/// Buffering to line boundaries is what keeps the view readable.
@Suite("Line buffering for the sticky log view")
struct LineBufferTests {

    @Test func completeLineIsEmittedImmediately() {
        let buf = LineBuffer()
        #expect(buf.feed("hello\n") == ["hello\n"])
    }

    /// The case that caused the tearing: a line arriving in pieces must be
    /// held until it is whole.
    @Test func splitLineIsHeldUntilTheNewline() {
        let buf = LineBuffer()
        #expect(buf.feed("[api] API-LOG-").isEmpty)
        #expect(buf.feed("3\n") == ["[api] API-LOG-3\n"])
    }

    @Test func severalLinesInOneChunkAreAllEmitted() {
        let buf = LineBuffer()
        #expect(buf.feed("a\nb\nc\n") == ["a\n", "b\n", "c\n"])
    }

    /// A chunk that ends mid-line emits what is complete and keeps the rest.
    @Test func trailingFragmentIsKeptForTheNextChunk() {
        let buf = LineBuffer()
        #expect(buf.feed("first\nsec") == ["first\n"])
        #expect(buf.feed("ond\n") == ["second\n"])
    }

    /// A container that exits without a trailing newline must not have its
    /// last line swallowed — that would silently lose output.
    @Test func flushReturnsTheUnterminatedTail() {
        let buf = LineBuffer()
        #expect(buf.feed("no newline here").isEmpty)
        #expect(buf.flush() == "no newline here")
        #expect(buf.flush() == nil, "flushing twice must not repeat it")
    }

    @Test func flushOnAnEmptyBufferReturnsNothing() {
        #expect(LineBuffer().flush() == nil)
    }

    /// Blank lines are real output and must survive.
    @Test func emptyLinesArePreserved() {
        let buf = LineBuffer()
        #expect(buf.feed("\n\n") == ["\n", "\n"])
    }

    @Test func isEmptyReflectsWhatIsHeldBack() {
        let buf = LineBuffer()
        #expect(buf.isEmpty)
        _ = buf.feed("partial")
        #expect(!buf.isEmpty)
        _ = buf.feed("\n")
        #expect(buf.isEmpty)
    }

    /// Byte-by-byte delivery is the worst case and must still work.
    @Test func characterByCharacterDeliveryReassembles() {
        let buf = LineBuffer()
        var out: [String] = []
        for ch in "ab\ncd\n" { out += buf.feed(String(ch)) }
        #expect(out == ["ab\n", "cd\n"])
    }

    /// Nothing is lost across a long stream: what goes in comes out.
    @Test func nothingIsLostAcrossManyChunks() {
        let buf = LineBuffer()
        let source = (1...50).map { "line-\($0)\n" }.joined()
        var out = ""
        // Feed in awkward 7-character slices to force split boundaries.
        var idx = source.startIndex
        while idx < source.endIndex {
            let end = source.index(idx, offsetBy: 7, limitedBy: source.endIndex) ?? source.endIndex
            out += buf.feed(String(source[idx..<end])).joined()
            idx = end
        }
        out += buf.flush() ?? ""
        #expect(out == source)
    }

    // MARK: - CRLF

    // Container output reaches us over a serial console, so lines end in
    // CRLF, and in Swift "\r\n" is a single Character — one grapheme
    // cluster. So `"a\r\n".contains("\n")` is *false*, and any line-splitting
    // written in terms of Character silently matches nothing: the buffer
    // holds every line forever and the log view stays blank. Measured
    // against a real container: 36 stream events in, 0 lines out, 0 bytes
    // written to stdout. These tests pin the scalar-level behaviour.

    /// The exact shape that broke `compose up -a`.
    @Test func crlfLineIsEmitted() {
        let buf = LineBuffer()
        #expect(buf.feed("API-LOG-3\r\n") == ["API-LOG-3\r\n"],
                "CRLF must terminate a line — Character-based matching misses it")
        #expect(buf.isEmpty, "nothing may stay held back after a CRLF line")
    }

    @Test func severalCRLFLinesInOneChunk() {
        let buf = LineBuffer()
        #expect(buf.feed("a\r\nb\r\n") == ["a\r\n", "b\r\n"])
    }

    /// The CR and the LF can land in different chunks; joined they form one
    /// grapheme cluster, which is precisely where Character-based code fails.
    @Test func crlfSplitAcrossChunks() {
        let buf = LineBuffer()
        #expect(buf.feed("value\r").isEmpty, "a lone CR does not end the line")
        #expect(buf.feed("\nnext") == ["value\r\n"])
        #expect(buf.flush() == "next")
    }

    @Test func mixedLFAndCRLFBothTerminate() {
        let buf = LineBuffer()
        #expect(buf.feed("unix\ndos\r\n") == ["unix\n", "dos\r\n"])
    }

    /// Byte-at-a-time CRLF delivery, the worst case on a slow console.
    @Test func crlfCharacterByCharacter() {
        let buf = LineBuffer()
        var out: [String] = []
        for scalar in "x\r\ny\r\n".unicodeScalars { out += buf.feed(String(scalar)) }
        #expect(out == ["x\r\n", "y\r\n"])
    }

    /// End-to-end conservation with CRLF: every byte in comes back out.
    @Test func nothingIsLostWithCRLF() {
        let buf = LineBuffer()
        let source = (1...30).map { "API-LOG-\($0)\r\n" }.joined()
        var out = ""
        var idx = source.unicodeScalars.startIndex
        let scalars = source.unicodeScalars
        while idx < scalars.endIndex {
            let end = scalars.index(idx, offsetBy: 5, limitedBy: scalars.endIndex) ?? scalars.endIndex
            out += buf.feed(String(String.UnicodeScalarView(scalars[idx..<end]))).joined()
            idx = end
        }
        out += buf.flush() ?? ""
        #expect(out == source)
    }
}
