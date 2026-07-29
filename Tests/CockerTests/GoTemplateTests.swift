import Foundation
import Testing
@testable import CockerCLI

/// `cocker inspect` had no `--format`, so every script written against
/// `docker inspect --format '{{.State.Status}}'` failed outright. Worse,
/// the JSON had no `State.Status` and no `NetworkSettings.IPAddress` at
/// all — three e2e scenarios depended on exactly those paths.
@Suite("Go template --format")
struct GoTemplateTests {

    private let sample: [String: Any] = [
        "State": ["Status": "running", "Running": true, "ExitCode": 0],
        "NetworkSettings": ["IPAddress": "10.42.0.7", "MacAddress": "02:42:0a:2a:00:07"],
        "name": "web",
        "restartCount": 3,
        "labels": ["role": "api"],
    ]

    // MARK: - Field paths

    @Test func resolvesANestedField() throws {
        #expect(try GoTemplate.render("{{.State.Status}}", value: sample) == "running")
    }

    @Test func resolvesTheIPAddressScriptsRelyOn() throws {
        #expect(try GoTemplate.render("{{.NetworkSettings.IPAddress}}", value: sample)
            == "10.42.0.7")
    }

    /// Docker templates use Go's exported-field casing while cocker's JSON
    /// is lowerCamelCase. Both spellings must resolve.
    @Test func fieldLookupIsCaseInsensitive() throws {
        #expect(try GoTemplate.render("{{.Name}}", value: sample) == "web")
        #expect(try GoTemplate.render("{{.name}}", value: sample) == "web")
    }

    @Test func literalTextAroundFieldsIsPreserved() throws {
        #expect(try GoTemplate.render("ip={{.NetworkSettings.IPAddress}} up", value: sample)
            == "ip=10.42.0.7 up")
    }

    @Test func multipleFieldsInOneTemplate() throws {
        #expect(try GoTemplate.render("{{.Name}}:{{.State.Status}}", value: sample)
            == "web:running")
    }

    @Test func templateWithoutAnyFieldIsReturnedVerbatim() throws {
        #expect(try GoTemplate.render("plain text", value: sample) == "plain text")
    }

    // MARK: - Value formatting

    @Test func booleansRenderAsGoWouldPrintThem() throws {
        #expect(try GoTemplate.render("{{.State.Running}}", value: sample) == "true")
    }

    /// An integer must not come out as "3.0".
    @Test func integersRenderWithoutADecimalPart() throws {
        #expect(try GoTemplate.render("{{.restartCount}}", value: sample) == "3")
    }

    /// Go prints `<no value>` for a missing field ; a readable marker beats
    /// a crash or a silently empty string.
    @Test func missingFieldYieldsNoValue() throws {
        #expect(try GoTemplate.render("{{.Nope.Missing}}", value: sample) == "<no value>")
    }

    // MARK: - json function

    @Test func jsonFunctionSerialisesASubtree() throws {
        let out = try GoTemplate.render("{{json .NetworkSettings}}", value: sample)
        #expect(out.contains("\"IPAddress\":\"10.42.0.7\""))
    }

    @Test func jsonOfAMissingFieldIsNull() throws {
        #expect(try GoTemplate.render("{{json .Nope}}", value: sample) == "null")
    }

    // MARK: - Arrays

    /// `cocker inspect` prints a top-level array ; a template addressing
    /// `.State` must transparently target the first element, like Docker.
    @Test func topLevelArrayResolvesToItsFirstElement() throws {
        #expect(try GoTemplate.render("{{.State.Status}}", value: [sample]) == "running")
    }

    // MARK: - Unsupported input is rejected, never mis-rendered

    @Test func controlFlowIsRejected() {
        #expect(throws: GoTemplate.Error.self) {
            try GoTemplate.render("{{if .State.Running}}up{{end}}", value: sample)
        }
        #expect(throws: GoTemplate.Error.self) {
            try GoTemplate.render("{{range .labels}}x{{end}}", value: sample)
        }
    }

    @Test func pipelinesAreRejected() {
        #expect(throws: GoTemplate.Error.self) {
            try GoTemplate.render("{{.Name | upper}}", value: sample)
        }
    }

    @Test func unclosedBracesAreReported() {
        #expect(throws: GoTemplate.Error.self) {
            try GoTemplate.render("{{.State.Status", value: sample)
        }
    }

    /// A bare word is not a field path ; rejecting it prevents a typo from
    /// silently rendering as literal text.
    @Test func expressionWithoutALeadingDotIsRejected() {
        #expect(throws: GoTemplate.Error.self) {
            try GoTemplate.render("{{State.Status}}", value: sample)
        }
    }

    @Test func dotAloneRendersTheWholeDocument() throws {
        let out = try GoTemplate.render("{{.}}", value: ["a": 1])
        #expect(out.contains("\"a\":1"))
    }
}
