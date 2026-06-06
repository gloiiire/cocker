import Foundation

// Minimal OpenTelemetry-compatible span model + JSON serializer.
//
// We deliberately don't pull in `swift-distributed-tracing` : the full OTel
// SDK brings batch processors, multiple exporters, samplers, propagation, the
// whole context-propagation API. We need five spans (container.create, .start,
// .stop, image.pull, image.build) and a way to emit them somewhere.
//
// What's here :
//   - TraceID / SpanID generators following the W3C TraceContext spec
//     (16-byte trace id, 8-byte span id, lowercase hex)
//   - Span value type carrying name, ids, timestamps, status, attributes
//   - JSON serializer producing OTLP-compatible payloads (single resourceSpan)
//
// Where the spans go is up to the caller. The daemon writes them as
// JSON-lines to stderr when COCKER_TRACE=stderr is set ; we may add an OTLP
// HTTP exporter later.

public enum SpanStatus: String, Sendable {
    case unset
    case ok
    case error
}

public enum SpanKind: String, Sendable {
    case unspecified = "SPAN_KIND_UNSPECIFIED"
    case internalKind = "SPAN_KIND_INTERNAL"
    case server = "SPAN_KIND_SERVER"
    case client = "SPAN_KIND_CLIENT"
    case producer = "SPAN_KIND_PRODUCER"
    case consumer = "SPAN_KIND_CONSUMER"
}

public struct TraceID: Sendable, Hashable, CustomStringConvertible {
    public let value: String  // 32 lowercase hex chars

    public init(_ value: String) {
        precondition(value.count == 32, "trace id must be 32 hex chars")
        self.value = value
    }

    public var description: String { value }

    public static func random(using rng: inout some RandomNumberGenerator) -> TraceID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { bytes[i] = UInt8.random(in: 0...UInt8.max, using: &rng) }
        return TraceID(bytes.map { String(format: "%02x", $0) }.joined())
    }

    public static func random() -> TraceID {
        var g = SystemRandomNumberGenerator()
        return .random(using: &g)
    }
}

public struct SpanID: Sendable, Hashable, CustomStringConvertible {
    public let value: String  // 16 lowercase hex chars

    public init(_ value: String) {
        precondition(value.count == 16, "span id must be 16 hex chars")
        self.value = value
    }

    public var description: String { value }

    public static func random(using rng: inout some RandomNumberGenerator) -> SpanID {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { bytes[i] = UInt8.random(in: 0...UInt8.max, using: &rng) }
        return SpanID(bytes.map { String(format: "%02x", $0) }.joined())
    }

    public static func random() -> SpanID {
        var g = SystemRandomNumberGenerator()
        return .random(using: &g)
    }
}

public struct Span: Sendable {
    public let name: String
    public let traceID: TraceID
    public let spanID: SpanID
    public let parentSpanID: SpanID?
    public let kind: SpanKind
    public let startedAt: Date
    public let endedAt: Date
    public let status: SpanStatus
    public let attributes: [String: String]

    public init(name: String,
                traceID: TraceID,
                spanID: SpanID,
                parentSpanID: SpanID? = nil,
                kind: SpanKind = .internalKind,
                startedAt: Date,
                endedAt: Date,
                status: SpanStatus = .ok,
                attributes: [String: String] = [:]) {
        self.name = name
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.attributes = attributes
    }

    public var durationNanoseconds: UInt64 {
        let s = UInt64(startedAt.timeIntervalSince1970 * 1_000_000_000)
        let e = UInt64(endedAt.timeIntervalSince1970 * 1_000_000_000)
        return e >= s ? e - s : 0
    }
}

/// OTLP/JSON encoder — produces a single ResourceSpans payload per call. Pure,
/// no I/O, suitable for either stderr emission or HTTP POST to an OTLP
/// collector at /v1/traces.
public enum OTLPEncoder {

    public static let serviceName = "cockerd"

    public static func encode(_ spans: [Span]) -> Data {
        // OTLP uses nanoseconds since unix epoch as fixed64 strings.
        let scopeSpansJSON: [[String: Any]] = [[
            "scope": ["name": "cocker", "version": CockerVersion.version],
            "spans": spans.map(spanToOTLP)
        ]]

        let resource: [String: Any] = [
            "attributes": [
                ["key": "service.name", "value": ["stringValue": serviceName]],
                ["key": "service.version", "value": ["stringValue": CockerVersion.version]],
            ]
        ]

        let payload: [String: Any] = [
            "resourceSpans": [[
                "resource": resource,
                "scopeSpans": scopeSpansJSON
            ]]
        ]

        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    private static func spanToOTLP(_ s: Span) -> [String: Any] {
        var obj: [String: Any] = [
            "traceId": s.traceID.value,
            "spanId":  s.spanID.value,
            "name":    s.name,
            "kind":    otlpKindCode(s.kind),
            "startTimeUnixNano": String(UInt64(s.startedAt.timeIntervalSince1970 * 1_000_000_000)),
            "endTimeUnixNano":   String(UInt64(s.endedAt.timeIntervalSince1970 * 1_000_000_000)),
            "status": ["code": otlpStatusCode(s.status)],
        ]
        if let parent = s.parentSpanID {
            obj["parentSpanId"] = parent.value
        }
        if !s.attributes.isEmpty {
            obj["attributes"] = s.attributes.map { (k, v) -> [String: Any] in
                ["key": k, "value": ["stringValue": v]]
            }
        }
        return obj
    }

    private static func otlpKindCode(_ k: SpanKind) -> Int {
        switch k {
        case .unspecified:  return 0
        case .internalKind: return 1
        case .server:       return 2
        case .client:       return 3
        case .producer:     return 4
        case .consumer:     return 5
        }
    }

    private static func otlpStatusCode(_ s: SpanStatus) -> Int {
        switch s {
        case .unset: return 0
        case .ok:    return 1
        case .error: return 2
        }
    }
}

/// Simple span emitter. Hand a span in, it writes one JSON line to whatever
/// sink was configured. Two sinks for now :
///
///   .disabled  — drop on the floor (default ; zero overhead)
///   .stderr    — JSON line per span to stderr (developer-friendly)
///
/// We'll add an HTTP/OTLP exporter when there's a concrete consumer.
public enum TraceSink: Sendable {
    case disabled
    case stderr

    public static func fromEnvironment() -> TraceSink {
        switch (ProcessInfo.processInfo.environment["COCKER_TRACE"] ?? "").lowercased() {
        case "stderr": return .stderr
        default:       return .disabled
        }
    }
}

public final class CockerTracer: @unchecked Sendable {
    public let sink: TraceSink

    public init(sink: TraceSink = .disabled) { self.sink = sink }

    public static func fromEnvironment() -> CockerTracer {
        CockerTracer(sink: TraceSink.fromEnvironment())
    }

    /// Start a span. The returned handle is closed via `.end(status:)`.
    public func startSpan(_ name: String,
                          traceID: TraceID = .random(),
                          parentSpanID: SpanID? = nil,
                          kind: SpanKind = .internalKind,
                          attributes: [String: String] = [:]) -> SpanHandle {
        SpanHandle(tracer: self,
                   name: name,
                   traceID: traceID,
                   spanID: .random(),
                   parentSpanID: parentSpanID,
                   kind: kind,
                   startedAt: Date(),
                   attributes: attributes)
    }

    func emit(_ span: Span) {
        switch sink {
        case .disabled: return
        case .stderr:
            let data = OTLPEncoder.encode([span])
            if let s = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data((s + "\n").utf8))
            }
        }
    }
}

/// Mutable handle for an in-flight span. The contract is to call `end()` exactly
/// once — calling end multiple times emits multiple spans (probably not what you
/// want, but cheap to detect at the consumer side via duplicate span IDs).
public final class SpanHandle: @unchecked Sendable {
    private let tracer: CockerTracer
    private let name: String
    private let traceID: TraceID
    private let spanID: SpanID
    private let parentSpanID: SpanID?
    private let kind: SpanKind
    private let startedAt: Date
    private var attributes: [String: String]

    init(tracer: CockerTracer, name: String, traceID: TraceID, spanID: SpanID,
         parentSpanID: SpanID?, kind: SpanKind, startedAt: Date,
         attributes: [String: String]) {
        self.tracer = tracer; self.name = name
        self.traceID = traceID; self.spanID = spanID; self.parentSpanID = parentSpanID
        self.kind = kind; self.startedAt = startedAt; self.attributes = attributes
    }

    public var id: SpanID { spanID }
    public var trace: TraceID { traceID }

    public func setAttribute(_ key: String, _ value: String) {
        attributes[key] = value
    }

    public func end(status: SpanStatus = .ok) {
        let span = Span(
            name: name, traceID: traceID, spanID: spanID,
            parentSpanID: parentSpanID, kind: kind,
            startedAt: startedAt, endedAt: Date(),
            status: status, attributes: attributes
        )
        tracer.emit(span)
    }
}
