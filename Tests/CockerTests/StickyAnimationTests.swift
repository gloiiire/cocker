import Foundation
import Testing
@testable import CockerCLI

/// `cocker compose up --build` appeared frozen during long build steps :
/// the Braille glyph and the per-service timer both stopped moving while
/// `trunk build --release` ran for minutes. Two causes, both covered here :
///
///  1. the running rows painted the static `.progress` token instead of an
///     animated frame ;
///  2. the sticky views only repainted when an event arrived, and a long
///     `RUN` emits nothing at all.
@Suite("Sticky view animation")
struct StickyAnimationTests {

    // MARK: - Frame derived from elapsed time

    /// The frame must advance with wall-clock time alone, with no event
    /// and no state change. This is what the frozen spinner lacked.
    @Test func spinnerFrameAdvancesWithTimeAlone() {
        let start = Date()
        let first = UX.spinnerFrame(at: start, since: start)
        let later = UX.spinnerFrame(
            at: start.addingTimeInterval(UX.spinnerFrameInterval * 1.5), since: start)
        #expect(first != later)
    }

    @Test func spinnerFrameCyclesThroughEveryFrame() {
        let start = Date()
        var seen = Set<String>()
        for step in 0..<UX.spinnerFrames.count {
            let at = start.addingTimeInterval(UX.spinnerFrameInterval * Double(step))
            seen.insert(UX.spinnerFrame(at: at, since: start))
        }
        #expect(seen.count == UX.spinnerFrames.count)
    }

    /// One full cycle must land back on the first frame, so the animation
    /// loops instead of drifting.
    @Test func spinnerFrameWrapsAfterAFullCycle() {
        let start = Date()
        let cycle = UX.spinnerFrameInterval * Double(UX.spinnerFrames.count)
        #expect(UX.spinnerFrame(at: start, since: start)
            == UX.spinnerFrame(at: start.addingTimeInterval(cycle), since: start))
    }

    /// A clock that jumps backwards (NTP correction) must not crash on a
    /// negative modulo.
    @Test func spinnerFrameToleratesTimeGoingBackwards() {
        let start = Date()
        let frame = UX.spinnerFrame(at: start.addingTimeInterval(-5), since: start)
        #expect(UX.spinnerFrames.contains(frame))
    }

    // MARK: - Ticker cadence

    /// The ticker must beat faster than StickyView's coalescing budget,
    /// otherwise it lands on the boundary and roughly every other repaint
    /// is dropped, which is visible as a stuttering spinner.
    @Test func tickerBeatsFasterThanTheFrameBudget() {
        #expect(UX.tickerInterval < UX.spinnerFrameInterval)
    }

    /// The property under test is "it keeps firing on its own", not "it
    /// fires N times per second". Asserting a tick count made the test
    /// flaky on a loaded CI machine (observed: 2 ticks where 3 were
    /// expected), so wait for the ticks instead of assuming a cadence.
    @Test func tickerFiresRepeatedlyWithoutAnyEvent() async throws {
        let counter = TickCounter()
        let ticker = UX.Ticker(interval: 0.01) { counter.bump() }
        ticker.start()
        defer { ticker.stop() }

        // Generous ceiling: this only bounds how long a genuinely broken
        // ticker takes to fail, never how fast a healthy one must be.
        let deadline = Date().addingTimeInterval(10)
        while counter.value < 3 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(counter.value >= 3)
    }

    @Test func tickerStopsFiringAfterStop() async throws {
        let counter = TickCounter()
        let ticker = UX.Ticker(interval: 0.01) { counter.bump() }
        ticker.start()
        // Wait for proof it started rather than for a fixed delay.
        let deadline = Date().addingTimeInterval(10)
        while counter.value == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(counter.value > 0, "ticker never started")
        ticker.stop()
        // Let any in-flight tick land before sampling the baseline.
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterStop = counter.value
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(counter.value == afterStop)
    }

    @Test func tickerStartIsIdempotent() async throws {
        let counter = TickCounter()
        // A long interval keeps the assertion meaningful : a triple-started
        // ticker would fire ~3x, which stays far above this ceiling even
        // when the machine is slow.
        let ticker = UX.Ticker(interval: 0.05) { counter.bump() }
        ticker.start()
        ticker.start()
        ticker.start()
        try await Task.sleep(nanoseconds: 250_000_000)
        ticker.stop()
        // ~5 ticks expected from one ticker ; three would give ~15. The
        // bound only has to separate those two cases.
        #expect(counter.value <= 10)
    }

    // MARK: - Rendering

    /// The animated glyph must actually reach the rendered line, while the
    /// icon keeps its semantic colour.
    @Test func actionLineUsesTheOverriddenGlyph() {
        let line = UX.ActionLine(
            icon: .progress, iconOverride: "⠹", type: .service,
            name: "web", status: "Building", trailing: "3.2s"
        ).render()
        #expect(line.contains("⠹"))
    }

    @Test func actionLineFallsBackToTheIconGlyph() {
        let line = UX.ActionLine(
            icon: .success, type: .service, name: "web", status: "Built"
        ).render()
        #expect(line.contains(UX.Icon.success.rawValue))
    }

    /// Existing callers must keep compiling and rendering unchanged.
    @Test func actionLineOverrideDefaultsToNil() {
        let plain = UX.ActionLine(icon: .progress, type: .service, name: "api", status: "Building")
        #expect(plain.iconOverride == nil)
        #expect(plain.render().contains(UX.Icon.progress.rawValue))
    }

    // MARK: - Event parsing still intact

    /// The compose stream must keep mapping build lines to a running row,
    /// otherwise there is nothing to animate in the first place.
    @Test func composeBuildingLineStillParses() {
        #expect(UX.ComposeEvent.parse(stream: .status, line: "Building web...")
            == .building(service: "web"))
        #expect(UX.ComposeEvent.parse(stream: .status, line: "Built web")
            == .built(service: "web"))
    }
}

/// Thread-safe counter : the ticker fires from a detached task.
private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
