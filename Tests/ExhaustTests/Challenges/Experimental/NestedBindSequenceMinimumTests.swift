import Exhaust
import ExhaustTestSupport
import Testing

@Suite("Nested bind sequence minima", .tags(.challenge, .slow))
struct NestedBindSequenceMinimumTests {
    static let depthFour = #gen(.int(in: 1 ... 10)).bind { firstFactor in
        .int(in: 1 ... firstFactor).bind { secondFactor in
            .int(in: 1 ... secondFactor).bind { thirdFactor in
                .int(in: 1 ... thirdFactor).bind { fourthFactor in
                    .int(in: 0 ... 1).array(length: firstFactor * secondFactor * thirdFactor * fourthFactor)
                        .map { (firstFactor, secondFactor, thirdFactor, fourthFactor, $0) }
                }
            }
        }
    }

    @Test("An earlier payload acceptance does not leave controller search fruitless", arguments: [UInt64(1367), 1392])
    func depthFourMinimum(seed: UInt64) throws {
        let (firstFactor, secondFactor, thirdFactor, fourthFactor, elements) = try #require(#exhaust(
            Self.depthFour,
            .budget(.custom(screening: 0, sampling: 25000)),
            .suppress(.issueReporting),
            .replay(.numeric(seed)),
            property: { _, _, _, _, elements in elements.count < 24 || elements.contains(1) == false }
        ))
        #expect([firstFactor, secondFactor, thirdFactor, fourthFactor] == [3, 2, 2, 2])
        #expect(elements.count == 24)
        #expect(elements.dropLast().allSatisfy { $0 == 0 })
        #expect(elements.last == 1)
    }

    @Test("Nested controller compensation retains the exact six-bind minimum", arguments: [UInt64(1337), 1367, 1392])
    func depthSixMinimum(seed: UInt64) throws {
        let (firstFactor, secondFactor, thirdFactor, fourthFactor, fifthFactor, sixthFactor, elements) = try #require(#exhaust(
            DepthSixProductSequenceChallenge.gen,
            .budget(.custom(screening: 0, sampling: 25000)),
            .suppress(.issueReporting),
            .replay(.numeric(seed)),
            property: DepthSixProductSequenceChallenge.property
        ))
        #expect([firstFactor, secondFactor, thirdFactor, fourthFactor, fifthFactor, sixthFactor] == [3, 2, 2, 2, 1, 1])
        #expect(elements.count == 24)
        #expect(elements.dropLast().allSatisfy { $0 == 0 })
        #expect(elements.last == 1)
    }
}
