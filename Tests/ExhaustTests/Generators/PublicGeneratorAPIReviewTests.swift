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

    @Test("Fixed-prefix Data rejects reflection targets outside its domain")
    func fixedPrefixDataRejectsMismatchedPrefix() throws {
        let generator = ReflectiveGenerator<Data>.data(
            prefix: [0xCA, 0xFE],
            length: 2
        )
        let mismatched = Data([0xBA, 0xAD, 0x01, 0x02])

        let tree = try Interpreters.reflect(generator.gen, with: mismatched)

        #expect(tree == nil)
    }

    @Test("UUID v4 rejects reflection targets outside its domain")
    func uuidRejectsNonVersionFourTarget() throws {
        let generator = ReflectiveGenerator<UUID>.uuid()
        let nonVersionFour = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")
        )

        let tree = try Interpreters.reflect(generator.gen, with: nonVersionFour)

        #expect(tree == nil)
    }
}
