//
//  CoreGeneratorTests.swift
//  ExhaustTests
//
//  Core generator functionality tests including Gen factory methods,
//  basic composition, and interpreter consistency.
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Core Generator Functionality")
struct CoreGeneratorTests {
    @Suite("Gen Factory Methods")
    struct GenFactoryTests {
        @Test("Gen.choose produces values within specified range")
        func genChooseRange() throws {
            let gen = Gen.choose(in: 10 ... 20) as Generator<Int>
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 50 {
                let value = try #require(try iterator.next())
                #expect(10 ... 20 ~= value)
            }
        }

        @Test("Reflection preserves explicit Gen.choose range metadata")
        func reflectionPreservesExplicitChooseRangeMetadata() throws {
            let gen = Gen.choose(in: UInt64(10) ... 20)
            let tree = try #require(try Interpreters.reflect(gen, with: UInt64(15)))

            guard case let .choice(_, metadata) = tree else {
                Issue.record("Expected reflected tree to be a single choice")
                return
            }

            #expect(metadata.validRange == UInt64(10) ... 20)
        }

        @Test("Reflection rejects values outside explicit Gen.choose range")
        func reflectionRejectsOutOfRangeExplicitChoose() {
            let gen = Gen.choose(in: UInt64(10) ... 20)

            do {
                _ = try Interpreters.reflect(gen, with: UInt64(25))
                Issue.record("Expected reflection to fail for out-of-range value")
            } catch let error as ReflectionError {
                guard case .inputWasOutOfGeneratorRange = error else {
                    Issue.record("Expected inputWasOutOfGeneratorRange, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected ReflectionError, got \(error)")
            }
        }

        @Test("Gen.exact produces exact value and reflects correctly")
        func genExact() throws {
            let value = 42
            let gen = Gen.exact(value)

            // Test reflection works with exact value
            let recipe = try Interpreters.reflect(gen, with: value)
            #expect(recipe != nil)

            // Test reflection fails with different value
            // TODO: This isn't a particularly useful error to be throwing
            #expect(throws: ReflectionError.contramapWasWrongType) {
                _ = try Interpreters.reflect(gen, with: 43)
            }

            // Test replay
            guard let recipe else {
                Issue.record("Reflection failed for Gen.exact test")
                return
            }
            guard let replayed = try Interpreters.replay(gen, using: recipe) else {
                Issue.record("Replay failed for Gen.exact test")
                return
            }
            #expect(replayed == value)
        }

        @Test(".just produces constant value")
        func genJust() throws {
            let value = "constant"
            let gen = Gen.just(value)
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 10 {
                let generated = try #require(try iterator.next())
                #expect(generated == value)
            }
        }
    }

    @Suite("Interpreter Consistency")
    struct InterpreterTests {
        @Test("Generate-Reflect-Replay cycle consistency")
        func generateReflectReplayConsistency() throws {
            let generators: [Generator<String>] = [
                Gen.contramap(
                    { (s: String) -> UInt64 in UInt64(s)! },
                    Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling)
                        .map(\.description)
                ),
                Gen.just("constant"),
            ]

            let seeds: [UInt64] = [42, 1337]

            for (index, gen) in generators.enumerated() {
                var iterator = ValueInterpreter(gen, seed: seeds[index])
                for iteration in 0 ..< 10 {
                    let generated = try #require(try iterator.next())
                    if let recipe = try Interpreters.reflect(gen, with: generated) {
                        if let replayed = try Interpreters.replay(gen, using: recipe) {
                            #expect(generated == replayed)
                        } else {
                            Issue.record("Replay failed for generator \(index), iteration \(iteration)")
                        }
                    } else {
                        Issue.record("Reflection failed for generator \(index), iteration \(iteration)")
                    }
                }
            }
        }

        @Test("Multiple generation consistency")
        func multipleGenerationConsistency() throws {
            let gen = Gen.choose(in: 1 ... 100) as Generator<Int>
            guard let recipe = try Interpreters.reflect(gen, with: 42) else {
                Issue.record("Reflection failed for value 42")
                return
            }

            // Multiple replays should produce the same result
            for _ in 0 ..< 20 {
                if let replayed = try Interpreters.replay(gen, using: recipe) {
                    #expect(replayed == 42)
                } else {
                    Issue.record("Replay failed for value 42")
                }
            }
        }
    }

    // VI/VACTI RNG parity is covered exhaustively in Interpreters/InterpreterRNGParityTests.swift.
}
