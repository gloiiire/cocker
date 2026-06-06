import Testing
import Foundation
@testable import CockerCore

@Suite("Prometheus value formatting")
struct PromValueTests {
    @Test func integerValuesEmitWithoutDecimal() {
        #expect(PrometheusExposition.format(value: 0) == "0")
        #expect(PrometheusExposition.format(value: 1) == "1")
        #expect(PrometheusExposition.format(value: 42) == "42")
        #expect(PrometheusExposition.format(value: -7) == "-7")
    }

    @Test func fractionalValuesUseSixDecimals() {
        #expect(PrometheusExposition.format(value: 0.5) == "0.500000")
        #expect(PrometheusExposition.format(value: 3.14) == "3.140000")
    }

    @Test func nanIsLiteralNaN() {
        #expect(PrometheusExposition.format(value: .nan) == "NaN")
    }

    @Test func infinitiesAreSerialized() {
        #expect(PrometheusExposition.format(value: .infinity) == "+Inf")
        #expect(PrometheusExposition.format(value: -.infinity) == "-Inf")
    }
}

@Suite("Prometheus help/label escaping")
struct PromEscapingTests {
    @Test func helpEscapesBackslashAndNewline() {
        #expect(PrometheusExposition.escapeHelp("hello\nworld") == "hello\\nworld")
        #expect(PrometheusExposition.escapeHelp("a\\b") == "a\\\\b")
    }

    @Test func helpLeavesQuoteAlone() {
        // HELP doesn't need quotes escaped per spec
        #expect(PrometheusExposition.escapeHelp("\"quote\"") == "\"quote\"")
    }

    @Test func labelEscapesQuotesNewlinesBackslash() {
        #expect(PrometheusExposition.escapeLabel("a\"b") == "a\\\"b")
        #expect(PrometheusExposition.escapeLabel("line1\nline2") == "line1\\nline2")
        #expect(PrometheusExposition.escapeLabel("a\\b") == "a\\\\b")
    }
}

@Suite("Prometheus exposition render")
struct PromRenderTests {
    @Test func emptyInputIsEmptyString() {
        #expect(PrometheusExposition.render([]) == "")
    }

    @Test func gaugeWithoutLabels() {
        let m = PromMetric(
            name: "cocker_containers_running",
            help: "Number of running containers",
            type: .gauge,
            samples: [PromSample(value: 3)]
        )
        let out = PrometheusExposition.render([m])
        #expect(out.contains("# HELP cocker_containers_running Number of running containers"))
        #expect(out.contains("# TYPE cocker_containers_running gauge"))
        #expect(out.contains("cocker_containers_running 3"))
    }

    @Test func counterWithLabels() {
        let m = PromMetric(
            name: "cocker_requests_total",
            help: "IPC requests handled",
            type: .counter,
            samples: [
                PromSample(value: 42, labels: [("method", "run"), ("result", "ok")]),
                PromSample(value: 1,  labels: [("method", "run"), ("result", "error")]),
            ]
        )
        let out = PrometheusExposition.render([m])
        #expect(out.contains("# TYPE cocker_requests_total counter"))
        #expect(out.contains("cocker_requests_total{method=\"run\",result=\"ok\"} 42"))
        #expect(out.contains("cocker_requests_total{method=\"run\",result=\"error\"} 1"))
    }

    @Test func multipleMetricsRenderedInOrder() {
        let a = PromMetric(name: "a", help: "first", type: .gauge,
                           samples: [PromSample(value: 1)])
        let b = PromMetric(name: "b", help: "second", type: .gauge,
                           samples: [PromSample(value: 2)])
        let out = PrometheusExposition.render([a, b])
        let posA = out.range(of: "# HELP a")?.lowerBound
        let posB = out.range(of: "# HELP b")?.lowerBound
        #expect(posA != nil && posB != nil && posA! < posB!)
    }

    @Test func helpNewlinesAreEscapedInOutput() {
        let m = PromMetric(name: "x", help: "line1\nline2", type: .gauge,
                           samples: [PromSample(value: 0)])
        let out = PrometheusExposition.render([m])
        // The escaped form must appear verbatim — the actual character pair
        // backslash + n, not a literal newline.
        #expect(out.contains("# HELP x line1\\nline2"))
        // The first physical line of the output is the HELP line, and it
        // includes everything because the \n was escaped (no real line break).
        let firstPhysicalLine = out.split(separator: "\n").first!
        #expect(firstPhysicalLine == "# HELP x line1\\nline2")
    }

    @Test func labelValueWithQuoteIsEscaped() {
        let m = PromMetric(name: "x", help: "h", type: .counter,
                           samples: [PromSample(value: 1, labels: [("k", "v\"x")])])
        let out = PrometheusExposition.render([m])
        #expect(out.contains("x{k=\"v\\\"x\"} 1"))
    }

    @Test func contentTypeIsSpecCompliant() {
        // The constant we expose for HTTP responses.
        #expect(PrometheusExposition.contentType.contains("text/plain"))
        #expect(PrometheusExposition.contentType.contains("version=0.0.4"))
    }
}
