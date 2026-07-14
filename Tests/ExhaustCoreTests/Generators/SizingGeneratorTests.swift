//
//  SizingGeneratorTests.swift
//  ExhaustCoreTests
//

import ExhaustCore
import Testing

@Suite("Gen sizing")
struct SizingGeneratorTests {
    @Test("Public getSize preserves the reified bind")
    func publicGetSizePreservesReifiedBind() {
        let generator = ReflectiveGenerator<UInt64>.getSize { size in
            .just(size)
        }

        guard case let .impure(.transform(kind, _), _) = generator.gen else {
            Issue.record("Expected getSize to produce a transform operation")
            return
        }
        guard case .bind = kind else {
            Issue.record("Expected getSize to produce a reified bind")
            return
        }
    }

    @Test("Public getSize reflects through the maximum size")
    func publicGetSizeReflectsThroughMaximumSize() throws {
        let generator = ReflectiveGenerator<UInt64>.getSize { size in
            Gen.chooseDerived(in: 0 ... size).wrapped
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

    @Test("Non-reified getSize uses a contramap and an invisible bind")
    func nonReifiedGetSizeUsesContramap() throws {
        let generator = Gen.nonReifiedGetSize { size in
            Gen.chooseDerived(in: 0 ... size)
        }

        guard case let .impure(.contramap(_, innerGenerator), continuation) = generator else {
            Issue.record("Expected nonReifiedGetSize to start with a contramap")
            return
        }
        guard case .impure(.getSize, _) = innerGenerator else {
            Issue.record("Expected the contramap to wrap a raw getSize operation")
            return
        }

        let dependentGenerator = try continuation(UInt64(37))
        guard case let .impure(.chooseBits(minimum, maximum, _, _, _, _), _) = dependentGenerator else {
            Issue.record("Expected the invisible bind to continue into chooseBits")
            return
        }
        #expect(minimum == 0)
        #expect(maximum == 37)
    }

    @Test("Non-reified getSize reflects through the maximum size")
    func nonReifiedGetSizeReflectsThroughMaximumSize() throws {
        let generator = Gen.nonReifiedGetSize { size in
            Gen.chooseDerived(in: 0 ... size)
        }
        let target: UInt64 = 73

        let tree = try #require(
            try Interpreters.reflect(generator, with: target)
        )
        let replayed = try #require(
            try Interpreters.replay(generator, using: tree)
        )

        #expect(replayed == target)
    }

    @Test("Default sequence length uses non-reified getSize")
    func defaultSequenceLengthUsesNonReifiedGetSize() {
        let generator = Gen.arrayOf(Gen.just(0))

        guard case let .impure(.sequence(lengthGenerator, _), _) = generator else {
            Issue.record("Expected arrayOf to produce a sequence operation")
            return
        }
        guard case let .impure(.contramap(_, innerGenerator), _) = lengthGenerator else {
            Issue.record("Expected the default length to start with a contramap")
            return
        }
        guard case .impure(.getSize, _) = innerGenerator else {
            Issue.record("Expected the default length contramap to wrap getSize")
            return
        }
    }
}
