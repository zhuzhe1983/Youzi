import Foundation

enum YouziCronFieldName: String, Equatable, Sendable {
    case minute
    case hour
    case dayOfMonth
    case month
    case dayOfWeek
}

enum YouziAutomationScheduleError: Error, Equatable, Sendable {
    case invalidCronFieldCount
    case invalidCronField(YouziCronFieldName)
    case invalidTimeZone
    case noOccurrenceWithinHorizon
    case intervalNotFinite
    case intervalOutOfBounds(minimum: TimeInterval, maximum: TimeInterval)
}

extension YouziAutomationScheduleError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidCronFieldCount:
            return "The schedule must contain five fields."
        case let .invalidCronField(field):
            return "The schedule's \(field.rawValue) field is invalid."
        case .invalidTimeZone:
            return "The selected time zone is unavailable."
        case .noOccurrenceWithinHorizon:
            return "No future occurrence was found for this schedule."
        case .intervalNotFinite:
            return "The repeat interval must be a finite number."
        case let .intervalOutOfBounds(minimum, maximum):
            return "The repeat interval must be between \(Int(minimum)) and \(Int(maximum)) seconds."
        }
    }
}

/// A validated five-field cron expression. It deliberately supports the
/// portable subset people expect from desktop scheduling: wildcards, lists,
/// ranges, steps, and English month/weekday names. Seconds and implementation-
/// specific aliases such as `@daily` are rejected rather than interpreted
/// differently on another machine.
struct YouziCronExpression: Equatable, Sendable {
    let source: String

    private let minute: Field
    private let hour: Field
    private let dayOfMonth: Field
    private let month: Field
    private let dayOfWeek: Field

    init(_ source: String) throws {
        let components = source.split(whereSeparator: { $0.isWhitespace })
        guard components.count == 5 else {
            throw YouziAutomationScheduleError.invalidCronFieldCount
        }

        self.source = components.map(String.init).joined(separator: " ")
        self.minute = try Field(
            String(components[0]),
            name: .minute,
            range: 0 ... 59
        )
        self.hour = try Field(
            String(components[1]),
            name: .hour,
            range: 0 ... 23
        )
        self.dayOfMonth = try Field(
            String(components[2]),
            name: .dayOfMonth,
            range: 1 ... 31
        )
        self.month = try Field(
            String(components[3]),
            name: .month,
            range: 1 ... 12,
            names: [
                "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4,
                "MAY": 5, "JUN": 6, "JUL": 7, "AUG": 8,
                "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
            ]
        )
        self.dayOfWeek = try Field(
            String(components[4]),
            name: .dayOfWeek,
            range: 0 ... 7,
            names: [
                "SUN": 0, "MON": 1, "TUE": 2, "WED": 3,
                "THU": 4, "FRI": 5, "SAT": 6,
            ],
            normalize: { $0 == 7 ? 0 : $0 }
        )
    }

    func matches(_ date: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents(
            [.minute, .hour, .day, .month, .weekday],
            from: date
        )
        guard let minuteValue = parts.minute,
              let hourValue = parts.hour,
              let dayValue = parts.day,
              let monthValue = parts.month,
              let weekdayValue = parts.weekday
        else { return false }

        guard minute.contains(minuteValue),
              hour.contains(hourValue),
              month.contains(monthValue)
        else { return false }

        let dayMatches = dayOfMonth.contains(dayValue)
        // Foundation weekday is Sunday=1; portable cron is Sunday=0/7.
        let weekdayMatches = dayOfWeek.contains(weekdayValue - 1)
        switch (dayOfMonth.isWildcard, dayOfWeek.isWildcard) {
        case (true, true):
            return true
        case (true, false):
            return weekdayMatches
        case (false, true):
            return dayMatches
        case (false, false):
            // Vixie cron semantics: the two restricted day fields are ORed.
            return dayMatches || weekdayMatches
        }
    }

    /// Returns the first representable occurrence strictly after `date`.
    /// Candidate construction uses Calendar's strict matching so a local time
    /// inside a DST gap is skipped. Both repetitions in a fall-back fold are
    /// considered and ordered by their absolute Date value.
    func next(
        after date: Date,
        in timeZone: TimeZone,
        horizonYears: Int = 8
    ) throws -> Date {
        guard horizonYears > 0 else {
            throw YouziAutomationScheduleError.noOccurrenceWithinHorizon
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var dayStart = calendar.startOfDay(for: date)
        guard let horizon = calendar.date(byAdding: .year, value: horizonYears, to: date)
        else {
            throw YouziAutomationScheduleError.noOccurrenceWithinHorizon
        }

        while dayStart <= horizon {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { break }
            let dayParts = calendar.dateComponents([.day, .month, .weekday], from: dayStart)
            if let dayValue = dayParts.day,
               let monthValue = dayParts.month,
               let weekdayValue = dayParts.weekday,
               month.contains(monthValue),
               matchesDay(day: dayValue, weekday: weekdayValue - 1) {
                var earliest: Date?
                for hourValue in hour.sortedValues {
                    for minuteValue in minute.sortedValues {
                        let requested = DateComponents(
                            timeZone: timeZone,
                            hour: hourValue,
                            minute: minuteValue,
                            second: 0
                        )
                        for repeatedPolicy in [
                            Calendar.RepeatedTimePolicy.first,
                            Calendar.RepeatedTimePolicy.last,
                        ] {
                            guard let candidate = calendar.nextDate(
                                after: dayStart.addingTimeInterval(-1),
                                matching: requested,
                                matchingPolicy: .strict,
                                repeatedTimePolicy: repeatedPolicy,
                                direction: .forward
                            ), candidate >= dayStart, candidate < nextDay,
                            candidate > date, candidate <= horizon,
                            matches(candidate, in: timeZone)
                            else { continue }
                            if earliest == nil || candidate < earliest! {
                                earliest = candidate
                            }
                        }
                    }
                }
                if let earliest { return earliest }
            }
            dayStart = nextDay
        }

        throw YouziAutomationScheduleError.noOccurrenceWithinHorizon
    }

    func next(
        after date: Date,
        timeZoneIdentifier: String,
        horizonYears: Int = 8
    ) throws -> Date {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw YouziAutomationScheduleError.invalidTimeZone
        }
        return try next(after: date, in: timeZone, horizonYears: horizonYears)
    }

    private func matchesDay(day: Int, weekday: Int) -> Bool {
        let dayMatches = dayOfMonth.contains(day)
        let weekdayMatches = dayOfWeek.contains(weekday)
        switch (dayOfMonth.isWildcard, dayOfWeek.isWildcard) {
        case (true, true): return true
        case (true, false): return weekdayMatches
        case (false, true): return dayMatches
        case (false, false): return dayMatches || weekdayMatches
        }
    }

    private struct Field: Equatable, Sendable {
        let values: Set<Int>
        let isWildcard: Bool

        var sortedValues: [Int] { values.sorted() }
        func contains(_ value: Int) -> Bool { values.contains(value) }

        init(
            _ source: String,
            name: YouziCronFieldName,
            range: ClosedRange<Int>,
            names: [String: Int] = [:],
            normalize: (Int) -> Int = { $0 }
        ) throws {
            let uppercased = source.uppercased()
            guard !uppercased.isEmpty else {
                throw YouziAutomationScheduleError.invalidCronField(name)
            }
            self.isWildcard = uppercased == "*"
            var parsed: Set<Int> = []

            for rawItem in uppercased.split(separator: ",", omittingEmptySubsequences: false) {
                let item = String(rawItem)
                guard !item.isEmpty else {
                    throw YouziAutomationScheduleError.invalidCronField(name)
                }
                let stepParts = item.split(separator: "/", omittingEmptySubsequences: false)
                guard stepParts.count <= 2,
                      !stepParts[0].isEmpty
                else {
                    throw YouziAutomationScheduleError.invalidCronField(name)
                }
                let step: Int
                if stepParts.count == 2 {
                    guard let value = Int(stepParts[1]), value > 0 else {
                        throw YouziAutomationScheduleError.invalidCronField(name)
                    }
                    step = value
                } else {
                    step = 1
                }

                let base = String(stepParts[0])
                let rawValues: [Int]
                if base == "*" {
                    rawValues = Array(range)
                } else {
                    let rangeParts = base.split(separator: "-", omittingEmptySubsequences: false)
                    if rangeParts.count == 2 {
                        let lower = try Self.value(
                            String(rangeParts[0]),
                            names: names,
                            range: range,
                            field: name
                        )
                        let upper = try Self.value(
                            String(rangeParts[1]),
                            names: names,
                            range: range,
                            field: name
                        )
                        guard lower <= upper else {
                            throw YouziAutomationScheduleError.invalidCronField(name)
                        }
                        rawValues = Array(lower ... upper)
                    } else if rangeParts.count == 1 {
                        let first = try Self.value(
                            base,
                            names: names,
                            range: range,
                            field: name
                        )
                        rawValues = stepParts.count == 2
                            ? Array(first ... range.upperBound)
                            : [first]
                    } else {
                        throw YouziAutomationScheduleError.invalidCronField(name)
                    }
                }

                for (offset, value) in rawValues.enumerated() where offset.isMultiple(of: step) {
                    parsed.insert(normalize(value))
                }
            }

            guard !parsed.isEmpty else {
                throw YouziAutomationScheduleError.invalidCronField(name)
            }
            self.values = parsed
        }

        private static func value(
            _ token: String,
            names: [String: Int],
            range: ClosedRange<Int>,
            field: YouziCronFieldName
        ) throws -> Int {
            let value = names[token] ?? Int(token)
            guard let value, range.contains(value) else {
                throw YouziAutomationScheduleError.invalidCronField(field)
            }
            return value
        }
    }
}

/// Pure schedule arithmetic used by both the persisted automation repository
/// and the app-resident scheduler. It owns the one interval bound so UI,
/// migration, and background reconciliation cannot disagree.
struct YouziAutomationScheduleEvaluator: Equatable, Sendable {
    static let minimumInterval: TimeInterval = 300
    static let maximumInterval: TimeInterval = 365 * 24 * 60 * 60

    var minimumInterval: TimeInterval = Self.minimumInterval
    var maximumInterval: TimeInterval = Self.maximumInterval
    var cronHorizonYears = 8

    func validateInterval(_ seconds: TimeInterval) throws {
        guard seconds.isFinite else {
            throw YouziAutomationScheduleError.intervalNotFinite
        }
        guard seconds >= minimumInterval, seconds <= maximumInterval else {
            throw YouziAutomationScheduleError.intervalOutOfBounds(
                minimum: minimumInterval,
                maximum: maximumInterval
            )
        }
    }

    /// Stable-anchor arithmetic prevents an app restart or delayed run from
    /// drifting every later occurrence. The result is strictly after `date`.
    func nextInterval(
        after date: Date,
        seconds: TimeInterval,
        anchorAt anchor: Date
    ) throws -> Date {
        try validateInterval(seconds)
        guard date >= anchor else { return anchor }
        let elapsed = date.timeIntervalSince(anchor)
        let step = floor(elapsed / seconds) + 1
        return anchor.addingTimeInterval(step * seconds)
    }

    func nextCron(
        after date: Date,
        expression: String,
        timeZoneIdentifier: String
    ) throws -> Date {
        try YouziCronExpression(expression).next(
            after: date,
            timeZoneIdentifier: timeZoneIdentifier,
            horizonYears: cronHorizonYears
        )
    }
}
