import Exhaust
import Foundation
import Testing

@Suite("Large-domain screening budgets")
struct LargeDomainBudgetTests {
    @Test("Every shape materializes within its screening budget", arguments: DateBudgetFixture.all, [100, 200, 600])
    func screeningBudget(fixture: DateBudgetFixture, budget: Int) throws {
        let report = try fixture.run(budget)
        #expect(report.screeningRows > 0)
        #expect(report.screeningRows <= budget)
        #expect(report.screeningInvocations == report.screeningRows)
        #expect(report.screeningRejectedRows == 0)
        #expect(report.randomSamplingInvocations == 0)
    }
}

// MARK: - Fixtures

/// Each fixture runs its original generator and checks every date and scalar in its output.
struct DateBudgetFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let run: @Sendable (Int) throws -> ExhaustReport

    init<Value>(name: String, generator: ReflectiveGenerator<Value>, sample: @escaping @Sendable (Value) -> DateBudgetSample) {
        self.name = name
        run = { budget in
            var captured: ExhaustReport?
            let result = #exhaust(
                generator,
                .budget(.custom(screening: budget, sampling: 0)),
                .replay(42),
                .onReport { captured = $0 }
            ) { value in
                sample(value).isValid
            }
            #expect(result == nil)
            return try #require(captured)
        }
    }

    var testDescription: String {
        name
    }

    static let start = Date(timeIntervalSinceReferenceDate: 725_760_000)
    static let year = start ... start.addingTimeInterval(86400 * 366)
    static let firstQuarter = start ... start.addingTimeInterval(86400 * 91)
    static let lastQuarter = start.addingTimeInterval(86400 * 274) ... year.upperBound
    static let spring = Date(timeIntervalSinceReferenceDate: 731_746_800 - 14 * 86400)
        ... Date(timeIntervalSinceReferenceDate: 731_746_800 + 14 * 86400)

    static var all: [DateBudgetFixture] {
        let hourly = ReflectiveGenerator<Date>.date(between: year, interval: .hours(1))
        let fine = ReflectiveGenerator<Date>.date(between: year, interval: .minutes(15))
        let quarter = ReflectiveGenerator<Date>.date(between: firstQuarter, interval: .hours(1))
        let late = ReflectiveGenerator<Date>.date(between: lastQuarter, interval: .hours(1))
        let springDate = ReflectiveGenerator<Date>.date(between: spring, interval: .hours(1))
        let springArray = springDate.array(length: 0 ... 5)
        return [
            .init(name: "one hourly", generator: #gen(hourly)) { DateBudgetSample([$0], in: year) },
            .init(name: "one fine", generator: #gen(fine)) { DateBudgetSample([$0], in: year, interval: 900) },
            .init(name: "two quarter", generator: #gen(quarter, quarter)) { DateBudgetSample([$0, $1], in: firstQuarter) },
            .init(name: "cross quarter", generator: #gen(quarter, late)) { DateBudgetSample([$0, $1], in: year, scalarsValid: firstQuarter.contains($0) && lastQuarter.contains($1)) },
            .init(name: "two year", generator: #gen(hourly, hourly)) { DateBudgetSample([$0, $1], in: year) },
            .init(name: "three quarter", generator: #gen(quarter, quarter, quarter)) { DateBudgetSample([$0, $1, $2], in: firstQuarter) },
            .init(name: "date and offset", generator: #gen(hourly, .int(in: -168 ... 168))) { DateBudgetSample([$0], in: year, scalarsValid: (-168 ... 168).contains($1)) },
            .init(name: "date and two offsets", generator: #gen(hourly, .int(in: -72 ... 72), .int(in: -72 ... 72))) { DateBudgetSample([$0], in: year, scalarsValid: (-72 ... 72).contains($1) && (-72 ... 72).contains($2)) },
            .init(name: "five dates", generator: #gen(quarter, quarter, quarter, quarter, quarter)) { DateBudgetSample([$0, $1, $2, $3, $4], in: firstQuarter) },
            .init(name: "six mixed", generator: #gen(quarter, quarter, quarter, quarter, .int(in: 0 ... 4), .int(in: 1 ... 5))) { DateBudgetSample([$0, $1, $2, $3], in: firstQuarter, scalarsValid: (0 ... 4).contains($4) && (1 ... 5).contains($5)) },
            .init(name: "two fine", generator: #gen(fine, fine)) { DateBudgetSample([$0, $1], in: year, interval: 900) },
            .init(name: "year array", generator: #gen(hourly.array(length: 1 ... 10))) { DateBudgetSample($0, in: year, scalarsValid: (1 ... 10).contains($0.count)) },
            .init(name: "DST fine array", generator: #gen(.date(between: spring, interval: .minutes(30)).array(length: 1 ... 5))) { DateBudgetSample($0, in: spring, interval: 1800, scalarsValid: (1 ... 5).contains($0.count)) },
            .init(name: "array and date", generator: #gen(springDate.array(length: 1 ... 5), springDate)) { DateBudgetSample($0 + [$1], in: spring, scalarsValid: (1 ... 5).contains($0.count)) },
            .init(name: "two arrays", generator: #gen(springArray, springArray)) { DateBudgetSample($0 + $1, in: spring, scalarsValid: $0.count <= 5 && $1.count <= 5) },
            .init(name: "array and offset", generator: #gen(hourly.array(length: 1 ... 5), .int(in: -168 ... 168))) { DateBudgetSample($0, in: year, scalarsValid: (1 ... 5).contains($0.count) && (-168 ... 168).contains($1)) },
            .init(name: "two arrays and date", generator: #gen(springArray, springArray, springDate)) { DateBudgetSample($0 + $1 + [$2], in: spring, scalarsValid: $0.count <= 5 && $1.count <= 5) },
        ]
    }
}

struct DateBudgetSample {
    let dates: [Date]
    let range: ClosedRange<Date>
    let interval: TimeInterval
    let scalarsValid: Bool

    init(_ dates: [Date], in range: ClosedRange<Date>, interval: TimeInterval = 3600, scalarsValid: Bool = true) {
        self.dates = dates
        self.range = range
        self.interval = interval
        self.scalarsValid = scalarsValid
    }

    var isValid: Bool {
        scalarsValid && dates.allSatisfy { date in
            range.contains(date) && abs(date.timeIntervalSince(range.lowerBound).remainder(dividingBy: interval)) < 0.001
        }
    }
}
