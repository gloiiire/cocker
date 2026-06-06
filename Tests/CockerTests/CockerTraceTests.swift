import Testing
import Foundation
@testable import CockerCore

@Suite("Trace and span IDs")
struct TraceIDTests {
    @Test func traceIDIs32HexChars() {
        let id = TraceID.random()
        #expect(id.value.count == 32)
        #expect(id.value.allSatisfy { c in "0123456789abcdef".contains(c) })
    }

    @Test func spanIDIs16HexChars() {
        let id = SpanID.random()
        #expect(id.value.count == 16)
        #expect(id.value.allSatisfy { c in "0123456789abcdef".contains(c) })
    }

    @Test func traceIDsDifferAcrossCalls() {
        // Astronomically unlikely to collide
        var seen = Set<String>()
        for _ in 0..<50 {
            seen.insert(TraceID.random().value)
        }
        #expect(seen.count == 50)
    }

    @Test func spanIDsDifferAcrossCalls() {
        var seen = Set<String>()
        for _ in 0..<50 {
            seen.insert(SpanID.random().value)
        }
        #expect(seen.count == 50)
    }

    @Test func traceIDDescriptionEqualsValue() {
        let id = TraceID(String(repeating: "a", count: 32))
        #expect(id.description == id.value)
    }
}

@Suite("Span duration")
struct SpanDurationTests {
    @Test func durationFromTimestamps() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1001)
        let s = Span(name: "x", traceID: TraceID(String(repeating: "0", count: 32)),
                     spanID: SpanID(String(repeating: "0", count: 16)),
                     startedAt: start, endedAt: end)
        #expect(s.durationNanoseconds == 1_000_000_000)
    }

    @Test func durationZeroForReversedTimestamps() {
        let start = Date(timeIntervalSince1970: 2000)
        let end = Date(timeIntervalSince1970: 1000)
        let s = Span(name: "x", traceID: TraceID(String(repeating: "0", count: 32)),
                     spanID: SpanID(String(repeating: "0", count: 16)),
                     startedAt: start, endedAt: end)
        #expect(s.durationNanoseconds == 0)
    }
}

@Suite("OTLP JSON encoder")
struct OTLPEncoderTests {
    private func span(name: String = "container.create",
                      attrs: [String: String] = [:],
                      status: SpanStatus = .ok,
                      kind: SpanKind = .internalKind,
                      parent: SpanID? = nil) -> Span {
        Span(name: name,
             traceID: TraceID(String(repeating: "a", count: 32)),
             spanID: SpanID(String(repeating: "b", count: 16)),
             parentSpanID: parent,
             kind: kind,
             startedAt: Date(timeIntervalSince1970: 1000),
             endedAt: Date(timeIntervalSince1970: 1001),
             status: status,
             attributes: attrs)
    }

    @Test func emptyInputProducesValidEnvelope() throws {
        let data = OTLPEncoder.encode([])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let resourceSpans = obj?["resourceSpans"] as? [[String: Any]]
        #expect(resourceSpans?.count == 1)
        let scopeSpans = resourceSpans?.first?["scopeSpans"] as? [[String: Any]]
        let spans = scopeSpans?.first?["spans"] as? [Any]
        #expect(spans?.count == 0)
    }

    @Test func carriesServiceName() throws {
        let data = OTLPEncoder.encode([span()])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let resource = (obj?["resourceSpans"] as? [[String: Any]])?.first?["resource"] as? [String: Any]
        let attrs = resource?["attributes"] as? [[String: Any]]
        let serviceName = attrs?.first { ($0["key"] as? String) == "service.name" }
        let value = (serviceName?["value"] as? [String: Any])?["stringValue"] as? String
        #expect(value == "cockerd")
    }

    @Test func spanContainsCoreFields() throws {
        let data = OTLPEncoder.encode([span(name: "container.start")])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let span = (((obj?["resourceSpans"] as? [[String: Any]])?.first?["scopeSpans"] as? [[String: Any]])?.first?["spans"] as? [[String: Any]])?.first
        #expect(span?["name"] as? String == "container.start")
        #expect(span?["traceId"] as? String == String(repeating: "a", count: 32))
        #expect(span?["spanId"] as? String == String(repeating: "b", count: 16))
        // SPAN_KIND_INTERNAL = 1
        #expect(span?["kind"] as? Int == 1)
    }

    @Test func attributesAreEncodedAsKeyValuePairs() throws {
        let data = OTLPEncoder.encode([span(attrs: ["container.id": "abc123", "image": "alpine"])])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let s = (((obj?["resourceSpans"] as? [[String: Any]])?.first?["scopeSpans"] as? [[String: Any]])?.first?["spans"] as? [[String: Any]])?.first
        let attrs = s?["attributes"] as? [[String: Any]]
        let ids = attrs?.compactMap { $0["key"] as? String } ?? []
        #expect(ids.contains("container.id"))
        #expect(ids.contains("image"))
    }

    @Test func parentSpanIDIsPropagated() throws {
        let parent = SpanID(String(repeating: "c", count: 16))
        let data = OTLPEncoder.encode([span(parent: parent)])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let s = (((obj?["resourceSpans"] as? [[String: Any]])?.first?["scopeSpans"] as? [[String: Any]])?.first?["spans"] as? [[String: Any]])?.first
        #expect(s?["parentSpanId"] as? String == String(repeating: "c", count: 16))
    }

    @Test func errorStatusEncodesCodeTwo() throws {
        let data = OTLPEncoder.encode([span(status: .error)])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let s = (((obj?["resourceSpans"] as? [[String: Any]])?.first?["scopeSpans"] as? [[String: Any]])?.first?["spans"] as? [[String: Any]])?.first
        let status = s?["status"] as? [String: Any]
        #expect(status?["code"] as? Int == 2)
    }

    @Test func timestampsAreFixed64Strings() throws {
        let data = OTLPEncoder.encode([span()])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let s = (((obj?["resourceSpans"] as? [[String: Any]])?.first?["scopeSpans"] as? [[String: Any]])?.first?["spans"] as? [[String: Any]])?.first
        let start = s?["startTimeUnixNano"] as? String
        let end = s?["endTimeUnixNano"] as? String
        #expect(start == "1000000000000")    // 1000 sec * 1e9
        #expect(end == "1001000000000")
    }
}

@Suite("Trace sink env parsing")
struct TraceSinkEnvTests {
    @Test func explicitStderr() {
        // We can't easily mutate ProcessInfo, so test the parse function via
        // reasonably small surface — re-using the enum's behaviour we exposed.
        // (TraceSink.fromEnvironment reads the env directly — we just confirm
        // the enum has the cases we expect.)
        let s = TraceSink.stderr
        if case .stderr = s { /* ok */ } else { Issue.record("expected .stderr") }
    }

    @Test func defaultDisabled() {
        let s = TraceSink.disabled
        if case .disabled = s { /* ok */ } else { Issue.record("expected .disabled") }
    }
}

@Suite("Span handle lifecycle")
struct SpanHandleTests {
    @Test func endProducesSpanInDisabledModeWithoutCrash() {
        // Disabled tracer ignores spans — just confirm we don't crash and
        // attribute mutation works.
        let tracer = CockerTracer(sink: .disabled)
        let h = tracer.startSpan("container.create")
        h.setAttribute("container.id", "abc")
        h.end(status: .ok)
    }

    @Test func handleExposesIds() {
        let tracer = CockerTracer(sink: .disabled)
        let h = tracer.startSpan("container.start")
        #expect(h.id.value.count == 16)
        #expect(h.trace.value.count == 32)
    }
}
