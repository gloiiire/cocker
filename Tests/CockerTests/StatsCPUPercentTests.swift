import Foundation
import Testing
@testable import CockerCLI

/// `cocker stats` printed "--" in the CPU column forever.
///
/// The probe read /proc/stat and threw that half of its own output away, and
/// the code said so: *"Without a previous sample we can't compute a
/// delta-based percentage on the very first frame ; show '--' to signal
/// warming up."* No sample was ever retained, so the warm-up never ended —
/// frame 1 and frame 10 000 both read "--". Measured against a container
/// spinning in `while :; do :; done`: "--" on every call.
///
/// The probe now reads /proc/stat twice, a fifth of a second apart, in the
/// same round-trip. These cover the arithmetic; the end-to-end check is that
/// an idle container reads 0.00% and a saturated one ~100%.
@Suite("stats — CPU percentage")
struct StatsCPUPercentTests {

    /// `cpu` aggregate + one per-core line, in the field order the kernel
    /// writes: user nice system idle iowait irq softirq steal.
    private func procStat(user: Int, idle: Int, cores: Int = 1) -> String {
        var s = "cpu  \(user) 0 0 \(idle) 0 0 0 0\n"
        for i in 0..<cores { s += "cpu\(i) \(user) 0 0 \(idle) 0 0 0 0\n" }
        s += "intr 12345\nctxt 6789\n"
        return s
    }

    private func probe(first: String, second: String) -> String {
        "MemTotal: 100 kB\n__STAT__\n" + first + "__STAT2__\n" + second
    }

    @Test func aSaturatedSingleCoreReads100() {
        // 100 jiffies of work, none idle, one core.
        let out = probe(first: procStat(user: 0, idle: 0),
                        second: procStat(user: 100, idle: 0))
        #expect(StatsCommand.cpuPercent(from: out) == "100.00%")
    }

    @Test func anIdleCoreReadsZero() {
        let out = probe(first: procStat(user: 0, idle: 0),
                        second: procStat(user: 0, idle: 100))
        #expect(StatsCommand.cpuPercent(from: out) == "0.00%")
    }

    @Test func halfBusyReads50() {
        let out = probe(first: procStat(user: 0, idle: 0),
                        second: procStat(user: 50, idle: 50))
        #expect(StatsCommand.cpuPercent(from: out) == "50.00%")
    }

    /// Docker's convention: a container saturating four cores reads 400%.
    /// Without the core count a fully loaded machine would cap at 100% and
    /// read the same as one busy core out of four.
    @Test func theFigureScalesWithCoreCount() {
        let out = probe(first: procStat(user: 0, idle: 0, cores: 4),
                        second: procStat(user: 100, idle: 0, cores: 4))
        #expect(StatsCommand.cpuPercent(from: out) == "400.00%")
    }

    /// iowait is idle: a core blocked on IO is not running anything.
    @Test func iowaitCountsAsIdle() {
        let first = "cpu  0 0 0 0 0 0 0 0\ncpu0 0 0 0 0 0 0 0 0\n"
        let second = "cpu  0 0 0 0 100 0 0 0\ncpu0 0 0 0 0 100 0 0 0\n"
        #expect(StatsCommand.cpuPercent(from: probe(first: first, second: second)) == "0.00%")
    }

    // MARK: - the cases where "--" is the honest answer

    @Test func noSecondSampleIsNotAZero() {
        // An image without `sleep` produces no second marker. Reporting 0%
        // there would be indistinguishable from a genuinely idle container.
        let out = "MemTotal: 100 kB\n__STAT__\n" + procStat(user: 5, idle: 5)
        #expect(StatsCommand.cpuPercent(from: out) == "--")
    }

    @Test func twoReadsInTheSameJiffyGiveNoAnswer() {
        let same = procStat(user: 10, idle: 10)
        #expect(StatsCommand.cpuPercent(from: probe(first: same, second: same)) == "--")
    }

    @Test func aMalformedStatLineGivesNoAnswer() {
        let out = probe(first: "cpu  1 2\n", second: "cpu  3 4\n")
        #expect(StatsCommand.cpuPercent(from: out) == "--")
    }

    @Test func emptyOutputGivesNoAnswer() {
        #expect(StatsCommand.cpuPercent(from: "") == "--")
    }
}
