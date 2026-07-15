import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

@Suite("Public generator API review regressions")
struct PublicGeneratorAPIReviewTests {
    @Test("getSize reflects through the maximum size")
    func getSizeReflectsThroughMaximumSize() throws {
        let generator = #gen(.getSize { size in
            .uint64(in: 0 ... size)
        })
        let target: UInt64 = 73

        let tree = try #require(
            try Interpreters.reflect(generator.gen, with: target)
        )
        let replayed = try #require(
            try Interpreters.replay(generator.gen, using: tree)
        )

        #expect(replayed == target)
    }

    @Test("Fixed-prefix Data overloads reject reflection targets outside their domains")
    func fixedPrefixDataRejectsMismatchedPrefix() throws {
        let generators: [ReflectiveGenerator<Data>] = [
            #gen(.data(prefix: [0xCA, 0xFE])),
            #gen(.data(prefix: [0xCA, 0xFE], length: 1 ... 3)),
            #gen(.data(prefix: [0xCA, 0xFE], length: 2)),
        ]
        let mismatched = Data([0xBA, 0xAD, 0x01, 0x02])

        for generator in generators {
            let tree = try Interpreters.reflect(generator.gen, with: mismatched)
            #expect(tree == nil)
        }
    }

    @Test("UUID reflection accepts Foundation values and canonicalizes them to v4")
    func uuidReflectionMatchesFoundationRepresentableDomain() throws {
        let generator = #gen(.uuid())
        let uuidStrings = [
            "00000000-0000-0000-0000-000000000000",
            "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
        ]

        for uuidString in uuidStrings {
            let target = try #require(UUID(uuidString: uuidString))
            let tree = try #require(
                try Interpreters.reflect(generator.gen, with: target)
            )
            let replayed = try #require(
                try Interpreters.replay(generator.gen, using: tree)
            )
            let targetBytes = withUnsafeBytes(of: target.uuid) { Array($0) }
            let replayedBytes = withUnsafeBytes(of: replayed.uuid) { Array($0) }

            for index in targetBytes.indices {
                switch index {
                    case 6:
                        #expect(replayedBytes[index] & 0x0F == targetBytes[index] & 0x0F)
                        #expect(replayedBytes[index] >> 4 == 0x4)
                    case 8:
                        #expect(replayedBytes[index] & 0x3F == targetBytes[index] & 0x3F)
                        #expect(replayedBytes[index] >> 6 == 0b10)
                    default:
                        #expect(replayedBytes[index] == targetBytes[index])
                }
            }
        }
    }
}
