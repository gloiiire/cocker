import Testing
import Foundation
@testable import CockerCore

@Suite("Log level parsing")
struct LogLevelTests {
    @Test func debugString() { #expect(LogLevel.parse("debug") == .debug) }
    @Test func infoString()  { #expect(LogLevel.parse("info")  == .info) }
    @Test func warnString()  { #expect(LogLevel.parse("warn")  == .warn) }
    @Test func warningString() { #expect(LogLevel.parse("warning") == .warn) }
    @Test func errorString() { #expect(LogLevel.parse("error") == .error) }
    @Test func emptyDefaultsToInfo() { #expect(LogLevel.parse("") == .info) }
    @Test func nilDefaultsToInfo()   { #expect(LogLevel.parse(nil) == .info) }
    @Test func unknownDefaultsToInfo() { #expect(LogLevel.parse("trace") == .info) }
    @Test func caseInsensitive() {
        #expect(LogLevel.parse("DEBUG") == .debug)
        #expect(LogLevel.parse("Error") == .error)
    }

    @Test func comparable() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info  < LogLevel.warn)
        #expect(LogLevel.warn  < LogLevel.error)
    }

    @Test func labels() {
        #expect(LogLevel.debug.label == "DEBUG")
        #expect(LogLevel.info.label  == "INFO")
        #expect(LogLevel.warn.label  == "WARN")
        #expect(LogLevel.error.label == "ERROR")
    }
}

@Suite("Log format parsing")
struct LogFormatTests {
    @Test func jsonIsParsed() { #expect(LogFormat.parse("json") == .json) }
    @Test func textIsDefault() {
        #expect(LogFormat.parse("text") == .text)
        #expect(LogFormat.parse("") == .text)
        #expect(LogFormat.parse(nil) == .text)
        #expect(LogFormat.parse("anything") == .text)
    }
    @Test func caseInsensitive() { #expect(LogFormat.parse("JSON") == .json) }
}

@Suite("Log text formatter")
struct CockerLogTextTests {
    @Test func includesIsoTimestamp() {
        let s = CockerLog.formatText(level: .info, module: "vm", message: "hi")
        #expect(s.contains("T"))   // ISO8601 has T separator
        #expect(s.contains("Z"))   // UTC indicator
    }

    @Test func includesLevelAndModuleAndMessage() {
        let s = CockerLog.formatText(level: .warn, module: "dns", message: "fallback")
        #expect(s.contains("WARN"))
        #expect(s.contains("[dns]"))
        #expect(s.contains("fallback"))
    }

    @Test func paddingKeepsAlignment() {
        let info = CockerLog.formatText(level: .info, module: "x", message: "y")
        let warn = CockerLog.formatText(level: .warn, module: "x", message: "y")
        // INFO and WARN are both padded to 5 chars
        #expect(info.contains("INFO "))
        #expect(warn.contains("WARN "))
    }
}

@Suite("Log JSON formatter")
struct CockerLogJSONTests {
    @Test func wellFormedSingleLine() throws {
        let s = CockerLog.formatJSON(level: .error, module: "engine",
                                     message: "boom")
        #expect(s.contains("\"level\":\"error\""))
        #expect(s.contains("\"module\":\"engine\""))
        #expect(s.contains("\"msg\":\"boom\""))
        // Parses as JSON
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
        #expect(obj?["level"] as? String == "error")
        #expect(obj?["module"] as? String == "engine")
        #expect(obj?["msg"] as? String == "boom")
    }

    @Test func escapesQuotes() throws {
        let s = CockerLog.formatJSON(level: .info, module: "m",
                                     message: "he said \"hello\"")
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
        #expect(obj?["msg"] as? String == "he said \"hello\"")
    }

    @Test func escapesNewlinesAndTabs() throws {
        let s = CockerLog.formatJSON(level: .info, module: "m",
                                     message: "line1\nline2\twith tab")
        // Should stay on one line in the JSON output
        #expect(!s.contains("\n"))
        #expect(s.contains("\\n"))
        #expect(s.contains("\\t"))
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
        #expect(obj?["msg"] as? String == "line1\nline2\twith tab")
    }

    @Test func escapesBackslashes() throws {
        let s = CockerLog.formatJSON(level: .info, module: "m",
                                     message: "path\\to\\file")
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
        #expect(obj?["msg"] as? String == "path\\to\\file")
    }
}

@Suite("Log level filtering")
struct CockerLogFilteringTests {
    @Test func minimumDebugAllowsAll() {
        let l = CockerLog(minimum: .debug)
        #expect(l.minimum == .debug)
    }

    @Test func minimumWarnDropsInfoAndDebug() {
        let l = CockerLog(minimum: .warn)
        #expect(l.minimum == .warn)
        #expect(LogLevel.debug < l.minimum)
        #expect(LogLevel.info  < l.minimum)
        #expect(!(LogLevel.warn < l.minimum))
        #expect(!(LogLevel.error < l.minimum))
    }
}
