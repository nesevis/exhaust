import Exhaust
import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Date large-domain covering arrays")
struct DateLargeDomainCoverageAnalysis {
    @Test("Every emitted row addresses valid date and string values", arguments: [100, 200, 600, 2000], [false, true])
    func coverage(budget: Int, balanced: Bool) throws {
        let date = try ReflectiveGenerator<Date>.date(
            between: DateBudgetFixture.year, interval: .hours(1),
            timeZone: #require(TimeZone(identifier: "America/New_York"))
        )
        let generator = #gen(date, date, .string(length: 1 ... 20))
        let profile = try #require(analyzeLargeDomain(generator.gen, expand: false))
        try #require(profile.parameterCount >= 3)
        let pull = PullBasedCoveringArrayGenerator(domainSizes: profile.domainSizes, strength: 2)
        let uniform = BalancedCoveringArrayGenerator(domainSizes: profile.domainSizes)
        var covered = Array(repeating: Set<UInt64>(), count: profile.parameterCount)
        var rows = 0
        for _ in 0 ..< budget {
            guard let coveringRow = balanced ? uniform.next() : pull.next() else {
                break
            }
            try #require(coveringRow.values.count == profile.parameterCount)
            for (index, value) in coveringRow.values.enumerated() {
                #expect(value < profile.domainSizes[index])
                covered[index].insert(value)
            }
            rows += 1
        }
        #expect(rows > 0)
        for (index, values) in covered.enumerated() {
            #expect(values.count > 1 || profile.domainSizes[index] == 1)
        }
    }
}
