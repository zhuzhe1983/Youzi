import Foundation
import Testing
@testable import Rapid

@Suite("Youzi automation — deterministic schedules")
struct YouziAutomationScheduleTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let iso = ISO8601DateFormatter()

    private func date(_ value: String) -> Date {
        iso.date(from: value)!
    }

    @Test("Five-field expressions normalize whitespace and match lists, ranges, steps, and names")
    func portableCronGrammar() throws {
        let expression = try YouziCronExpression("  */15  9-17/2  * JAN,MAR MON-FRI ")
        #expect(expression.source == "*/15 9-17/2 * JAN,MAR MON-FRI")
        #expect(expression.matches(date("2026-03-02T09:30:00Z"), in: utc))
        #expect(expression.matches(date("2026-03-02T11:45:00Z"), in: utc))
        #expect(!expression.matches(date("2026-03-02T10:30:00Z"), in: utc))
        #expect(!expression.matches(date("2026-04-06T09:30:00Z"), in: utc))
    }

    @Test("Sunday accepts both zero and seven")
    func sundayAliases() throws {
        let sunday = date("2026-03-01T12:00:00Z")
        #expect(try YouziCronExpression("0 12 * * 0").matches(sunday, in: utc))
        #expect(try YouziCronExpression("0 12 * * 7").matches(sunday, in: utc))
        #expect(try YouziCronExpression("0 12 * * SUN").matches(sunday, in: utc))
    }

    @Test("Restricted month-day and weekday use portable cron OR semantics")
    func dayOrSemantics() throws {
        let expression = try YouziCronExpression("0 8 10 * MON")
        #expect(expression.matches(date("2026-03-09T08:00:00Z"), in: utc)) // Monday
        #expect(expression.matches(date("2026-03-10T08:00:00Z"), in: utc)) // tenth
        #expect(!expression.matches(date("2026-03-11T08:00:00Z"), in: utc))
    }

    @Test("Malformed cron input fails with a typed field and never partial-parses")
    func invalidCron() {
        #expect(throws: YouziAutomationScheduleError.invalidCronFieldCount) {
            _ = try YouziCronExpression("0 8 * *")
        }
        #expect(throws: YouziAutomationScheduleError.invalidCronField(.minute)) {
            _ = try YouziCronExpression("60 8 * * *")
        }
        #expect(throws: YouziAutomationScheduleError.invalidCronField(.hour)) {
            _ = try YouziCronExpression("0 10-2 * * *")
        }
        #expect(throws: YouziAutomationScheduleError.invalidCronField(.month)) {
            _ = try YouziCronExpression("0 8 * FOO *")
        }
        #expect(throws: YouziAutomationScheduleError.invalidCronField(.dayOfWeek)) {
            _ = try YouziCronExpression("0 8 * * */0")
        }
    }

    @Test("Next occurrence is strictly later and respects leap years")
    func nextAndLeapYear() throws {
        let hourly = try YouziCronExpression("0 * * * *")
        #expect(try hourly.next(after: date("2026-03-01T12:00:00Z"), in: utc)
            == date("2026-03-01T13:00:00Z"))

        let leap = try YouziCronExpression("0 0 29 FEB *")
        #expect(try leap.next(after: date("2026-03-01T00:00:00Z"), in: utc)
            == date("2028-02-29T00:00:00Z"))
    }

    @Test("DST spring gaps skip nonexistent local times")
    func dstGap() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let expression = try YouziCronExpression("30 2 * * *")
        #expect(try expression.next(after: date("2025-03-09T08:00:00Z"), in: zone)
            == date("2025-03-10T09:30:00Z"))
    }

    @Test("DST fall folds expose both absolute occurrences")
    func dstFold() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let expression = try YouziCronExpression("30 1 * * *")
        #expect(try expression.next(after: date("2025-11-02T08:00:00Z"), in: zone)
            == date("2025-11-02T08:30:00Z"))
        #expect(try expression.next(after: date("2025-11-02T08:45:00Z"), in: zone)
            == date("2025-11-02T09:30:00Z"))
    }

    @Test("Unknown time zones and exhausted horizons fail closed")
    func timeZoneAndHorizonFailures() throws {
        let expression = try YouziCronExpression("0 0 29 FEB *")
        #expect(throws: YouziAutomationScheduleError.invalidTimeZone) {
            _ = try expression.next(
                after: date("2026-01-01T00:00:00Z"),
                timeZoneIdentifier: "Not/A_Zone"
            )
        }
        #expect(throws: YouziAutomationScheduleError.noOccurrenceWithinHorizon) {
            _ = try expression.next(
                after: date("2026-01-01T00:00:00Z"),
                in: utc,
                horizonYears: 1
            )
        }
    }

    @Test("Interval bounds and a stable anchor prevent restart drift")
    func intervals() throws {
        let evaluator = YouziAutomationScheduleEvaluator()
        let anchor = date("2026-01-01T00:00:00Z")
        #expect(try evaluator.nextInterval(
            after: date("2026-01-01T00:11:00Z"),
            seconds: 600,
            anchorAt: anchor
        ) == date("2026-01-01T00:20:00Z"))
        #expect(try evaluator.nextInterval(
            after: date("2025-12-31T23:00:00Z"),
            seconds: 600,
            anchorAt: anchor
        ) == anchor)
        #expect(throws: YouziAutomationScheduleError.intervalOutOfBounds(
            minimum: 300,
            maximum: 31_536_000
        )) {
            try evaluator.validateInterval(299)
        }
        #expect(throws: YouziAutomationScheduleError.intervalNotFinite) {
            try evaluator.validateInterval(.infinity)
        }
    }

    @Test("Shuffled equivalent list fields produce identical next dates")
    func deterministicOrdering() throws {
        let first = try YouziCronExpression("5,35 8,18 * MAR,JAN MON,WED")
        let second = try YouziCronExpression("35,5 18,8 * JAN,MAR WED,MON")
        let now = date("2026-01-01T00:00:00Z")
        let firstNext = try first.next(after: now, in: utc)
        let secondNext = try second.next(after: now, in: utc)
        #expect(firstNext == secondNext)
    }
}
