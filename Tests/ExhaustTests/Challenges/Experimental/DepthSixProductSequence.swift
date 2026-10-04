import Exhaust
import ExhaustTestSupport
import Testing

@Suite("Experimental Challenge: Depth 6 Bind (product sequence)", .tags(.challenge, .slow))
struct DepthSixProductSequenceChallenge {
    /// Each controller constrains the next controller's domain. Their product fixes the array length, so reducing a controller requires replaying the dependent binds and preserving a failing array.
    static let gen = #gen(.int(in: 1 ... 10)).bind { first in
        .int(in: 1 ... first).bind { second in
            .int(in: 1 ... second).bind { third in
                .int(in: 1 ... third).bind { fourth in
                    .int(in: 1 ... fourth).bind { fifth in
                        .int(in: 1 ... fifth).bind { sixth in
                            .int(in: 0 ... 1).array(length: first * second * third * fourth * fifth * sixth)
                                .map { (first, second, third, fourth, fifth, sixth, $0) }
                        }
                    }
                }
            }
        }
    }

    static let property: @Sendable (Int, Int, Int, Int, Int, Int, [Int]) -> Bool = { _, _, _, _, _, _, elements in
        elements.count < 24 || elements.contains(1) == false
    }

    @Test("Dependent product sequence, seed 1392")
    func depthSixProductSequence() throws {
        let output = try #require(
            #exhaust(
                Self.gen,
                .suppress(.issueReporting),
                .replay(.numeric(1392)),
                property: Self.property
            )
        )
        let (first, second, third, fourth, fifth, sixth, elements) = output

        #expect(Self.property(first, second, third, fourth, fifth, sixth, elements) == false)
        #expect((1 ... 10).contains(first))
        #expect((1 ... first).contains(second))
        #expect((1 ... second).contains(third))
        #expect((1 ... third).contains(fourth))
        #expect((1 ... fourth).contains(fifth))
        #expect((1 ... fifth).contains(sixth))
        #expect(elements.count == first * second * third * fourth * fifth * sixth)
        #expect(elements.allSatisfy { (0 ... 1).contains($0) })
        #expect(elements.count(where: { $0 == 1 }) == 1)

        // This seed currently reaches length 64. Keep that quality floor while allowing better results; length 24 is attainable in the domain, so this is not an assertion of minimality.
        #expect(elements.count <= 64)
    }

    @Test("Bind search recovers after pair acceptances, seed 1392 at the challenge harness budget")
    func depthSixProductSequenceAtHarnessBudget() throws {
        let output = try #require(
            #exhaust(
                Self.gen,
                .budget(.custom(screening: 0, sampling: 25000)),
                .suppress(.issueReporting),
                .replay(.numeric(1392)),
                property: Self.property
            )
        )
        let (first, second, third, fourth, fifth, sixth, elements) = output

        #expect(Self.property(first, second, third, fourth, fifth, sixth, elements) == false)
        // Pair acceptances change the controllers. If bind search keeps the budget decay from before them, this seed stalls at (4, 4, 2, 2, 1, 1), length 64. Length 24 is attainable in the domain, so this is not an assertion of minimality.
        #expect(elements.count <= 32)
    }
}
