import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

@Suite("Public generator API review regressions")
struct PublicGeneratorAPIReviewTests {
    @Test("getSize reflects through the maximum size")
    func getSizeReflectsThroughMaximumSize() throws {
        let generator = ReflectiveGenerator<UInt64>.getSize { size in
            .uint64(in: 0 ... size)
        }
        let target: UInt64 = 73

        let tree = try #require(
            try Interpreters.reflect(generator.gen, with: target)
        )
        let replayed = try #require(
            try Interpreters.replay(generator.gen, using: tree)
        )

        #expect(replayed == target)
    }
}
