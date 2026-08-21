//
//  LazyGeneratorTests.swift
//  Exhaust
//

import Exhaust
import Testing

@Suite("lazy generator")
struct LazyGeneratorTests {
    @Test("Construction is deferred until generation reaches the generator")
    func constructionIsDeferredUntilGenerationReachesTheGenerator() {
        let counter = ConstructionCounter()
        let generator: ReflectiveGenerator<Int> = .lazy {
            counter.increment()
            return .int(in: 0 ... 9)
        }

        #expect(counter.isEmpty)

        #exhaust(#gen(generator), .budget(.quick)) { value in
            (0 ... 9).contains(value)
        }

        #expect(!counter.isEmpty)
    }

    @Test("Produces the wrapped generator's values")
    func producesTheWrappedGeneratorsValues() {
        #exhaust(#gen(.lazy { .just(42) }), .budget(.quick)) { value in
            value == 42
        }
    }

    @Test("Replaying the same seed produces the same values")
    func replayingTheSameSeedProducesTheSameValues() {
        func collect(seed: UInt64) -> [Int] {
            let recorder = ValueRecorder()
            let generator: ReflectiveGenerator<Int> = .lazy { .int(in: 0 ... 1_000_000) }
            #exhaust(
                #gen(generator),
                .budget(.custom(screening: 0, sampling: 50)),
                .replay(ReplaySeed.numeric(seed))
            ) { value in
                recorder.append(value)
                return true
            }
            return recorder.values
        }

        let first = collect(seed: 1337)
        let second = collect(seed: 1337)

        #expect(first.isEmpty == false)
        #expect(first == second)
    }

    @Test("Reduction searches through the deferred generator")
    func reductionSearchesThroughTheDeferredGenerator() {
        let reduced = #exhaust(
            #gen(.lazy { .int(in: 0 ... 1000) }),
            .suppress(.issueReporting)
        ) { value in
            value < 10
        }

        #expect(reduced == 10)
    }

    @Test("Reflection passes through into the deferred generator")
    func reflectionPassesThroughIntoTheDeferredGenerator() {
        let generator: ReflectiveGenerator<Int> = .lazy { .int(in: 0 ... 1000) }

        // reflecting: decomposes the known counterexample through the lazy wrapper and reduces it; a forward-only wrapper cannot start from the reflected value.
        let reduced = #exhaust(
            #gen(generator),
            reflecting: 700,
            .suppress(.issueReporting)
        ) { value in
            value < 10
        }

        #expect(reduced == 10)
    }

    @Test("Examine round-trips a lazy recursive generator")
    func examineRoundTripsALazyRecursiveGenerator() {
        let generator: ReflectiveGenerator<Int> = .oneOf(
            .just(0),
            .lazy { .int(in: 1 ... 100) }
        )
        let report = #examine(generator, .samples(50))

        #expect(report.passed)
    }

    @Test("Building a oneOf does not build its lazy branches")
    func buildingAOneOfDoesNotBuildItsLazyBranches() {
        let counter = ConstructionCounter()
        let generator: ReflectiveGenerator<Int> = .oneOf(
            .just(-1),
            .lazy {
                counter.increment()
                return .int(in: 0 ... 9)
            }
        )

        // An eagerly constructed branch rebuilds its whole recursive subtree every time the enclosing generator is constructed, before any value is generated.
        #expect(counter.isEmpty)

        #exhaust(#gen(generator), .budget(.quick)) { value in
            value == -1 || (0 ... 9).contains(value)
        }
    }
}

// MARK: - Helpers

private final class ConstructionCounter: @unchecked Sendable {
    private(set) var count = 0

    func increment() {
        count += 1
    }

    var isEmpty: Bool {
        count < 1
    }
}

private final class ValueRecorder: @unchecked Sendable {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
