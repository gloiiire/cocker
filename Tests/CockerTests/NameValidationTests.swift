import Testing
import Foundation
@testable import CockerCore

// Regression for PRO-36 : `ResourceName.validate` is the allowlist that
// keeps user-supplied secret / config / volume names from becoming path
// traversals once they hit `appendingPathComponent`.

@Suite("ResourceName — accepts valid names")
struct ResourceNameAcceptsTests {
    @Test(arguments: [
        "data", "db_password", "api-token", "my.secret.v1",
        "Postgres15", "a", "0", "UPPER_lower-1.2.3",
    ])
    func accepts(_ name: String) throws {
        // Should not throw.
        try ResourceName.validate(name, kind: "volume")
    }

    @Test func acceptsMaxLengthName() throws {
        let name = String(repeating: "a", count: ResourceName.maxLength)
        try ResourceName.validate(name, kind: "secret")
    }
}

@Suite("ResourceName — rejects unsafe names")
struct ResourceNameRejectsTests {
    @Test(arguments: [
        "",                 // empty
        ".",                // current dir
        "..",               // parent dir
        "../escape",        // classic traversal
        "a/b",              // sub-path
        "/abs",             // absolute-ish
        ".hidden",          // leading dot → not alphanumeric first char
        "-flag",            // leading dash
        "with space",       // space
        "tab\tname",        // control char
        "emoji😀",          // outside allowlist
    ])
    func rejects(_ name: String) {
        #expect(throws: CockerError.self) {
            try ResourceName.validate(name, kind: "volume")
        }
    }

    @Test func rejectsEmbeddedNulByte() {
        // Foundation truncates at NUL, so "a\0/../escape" could otherwise
        // smuggle a traversal past a naive check.
        #expect(throws: CockerError.self) {
            try ResourceName.validate("a\u{0}b", kind: "secret")
        }
    }

    @Test func rejectsOverlongName() {
        let name = String(repeating: "a", count: ResourceName.maxLength + 1)
        #expect(throws: CockerError.self) {
            try ResourceName.validate(name, kind: "config")
        }
    }

    @Test func errorMentionsKindAndName() {
        do {
            try ResourceName.validate("../x", kind: "volume")
            Issue.record("expected validation to throw")
        } catch let error as CockerError {
            let msg = error.description
            #expect(msg.contains("volume"))
            #expect(msg.contains("../x"))
        } catch {
            Issue.record("expected CockerError, got \(error)")
        }
    }
}
