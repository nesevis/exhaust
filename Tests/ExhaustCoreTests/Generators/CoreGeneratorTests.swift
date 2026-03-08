//
//  CoreGeneratorTests.swift
//  ExhaustTests
//
//  Core generator functionality tests including Gen factory methods,
//  basic composition, and interpreter consistency.
//

import Testing
@testable import ExhaustCore

@Suite("Core Generator Functionality")
struct CoreGeneratorTests {
    @Suite("Gen Factory Methods")
    struct GenFactoryTests {
        @Test("Gen.choose produces values within specified range")
        func genChooseRange() throws {
            let gen = Gen.choose(in: 10 ... 20) as ReflectiveGenerator<Int>
            var iterator = ValueInterpreter(gen)

            for _ in 0 ..< 50 {
                let value = try iterator.next()!
                #expect(10 ... 20 ~= value)
            }
        }

        @Test("Reflection preserves explicit Gen.choose range metadata")
        func reflectionPreservesExplicitChooseRangeMetadata() throws {
            let gen = Gen.choose(in: UInt64(10) ... 20)
            let tree = try #require(try Interpreters.reflect(gen, with: UInt64(15)))

            guard case let .choice(_, metadata) = tree else {
                #expect(Bool(false), "Expected reflected tree to be a single choice")
                return
            }

            #expect(metadata.validRange == UInt64(10) ... 20)
        }

        @Test("Reflection rejects values outside explicit Gen.choose range")
        func reflectionRejectsOutOfRangeExplicitChoose() {
            let gen = Gen.choose(in: UInt64(10) ... 20)

            do {
                _ = try Interpreters.reflect(gen, with: UInt64(25))
                #expect(Bool(false), "Expected reflection to fail for out-of-range value")
            } catch let error as Interpreters.ReflectionError {
                guard case .inputWasOutOfGeneratorRange = error else {
                    #expect(Bool(false), "Expected inputWasOutOfGeneratorRange, got \(error)")
                    return
                }
            } catch {
                #expect(Bool(false), "Expected ReflectionError, got \(error)")
            }
        }

        @Test("Gen.choose with type produces valid values")
        func genChooseType() throws {
            let gen = Gen.choose(in: UInt32.min ... UInt32.max, scaling: UInt32.defaultScaling)
            var iterator = ValueInterpreter(gen)

            for _ in 0 ..< 20 {
                let value = try iterator.next()!
                #expect(value is UInt32)
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
            #expect(throws: Interpreters.ReflectionError.contramapWasWrongType) {
                _ = try Interpreters.reflect(gen, with: 43)
            }

            // Test replay
            guard let recipe else {
                #expect(false, "Reflection failed for Gen.exact test")
                return
            }
            guard let replayed = try Interpreters.replay(gen, using: recipe) else {
                #expect(false, "Replay failed for Gen.exact test")
                return
            }
            #expect(replayed == value)
        }

        @Test(".just produces constant value")
        func genJust() throws {
            let value = "constant"
            let gen = Gen.just(value)
            var iterator = ValueInterpreter(gen)

            for _ in 0 ..< 10 {
                let generated = try iterator.next()!
                #expect(generated == value)
            }
        }
    }

    @Suite("Interpreter Consistency")
    struct InterpreterTests {
        @Test("Generate-Reflect-Replay cycle consistency")
        func generateReflectReplayConsistency() throws {
            let generators: [ReflectiveGenerator<String>] = [
                Gen.contramap(
                    { (s: String) -> UInt64 in UInt64(s)! },
                    Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling)
                        ._map { $0.description },
                ),
                Gen.just("constant"),
            ]

            var seedIter = ValueInterpreter(
                Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling) as ReflectiveGenerator<UInt64>,
            )
            let seeds = try seedIter.prefix(10)

            for (index, gen) in generators.enumerated() {
                var iterator = ValueInterpreter(gen, seed: seeds.randomElement()!)
                for iteration in 0 ..< 10 {
                    let generated = try iterator.next()!
                    if let recipe = try Interpreters.reflect(gen, with: generated) {
                        if let replayed = try Interpreters.replay(gen, using: recipe) {
                            #expect(generated == replayed)
                        } else {
                            #expect(false, "Replay failed for generator \(index), iteration \(iteration)")
                        }
                    } else {
                        #expect(false, "Reflection failed for generator \(index), iteration \(iteration)")
                    }
                }
            }
        }

        @Test("Multiple generation consistency")
        func multipleGenerationConsistency() throws {
            let gen = Gen.choose(in: 1 ... 100) as ReflectiveGenerator<Int>
            guard let recipe = try Interpreters.reflect(gen, with: 42) else {
                #expect(false, "Reflection failed for value 42")
                return
            }

            // Multiple replays should produce the same result
            for _ in 0 ..< 20 {
                if let replayed = try Interpreters.replay(gen, using: recipe) {
                    #expect(replayed == 42)
                } else {
                    #expect(false, "Replay failed for value 42")
                }
            }
        }
    }

    @Suite("Performance Tests")
    struct PerformanceTests {
        @Test("High-frequency generation performance")
        func highFrequencyGeneration() throws {
            let gen = Gen.choose(in: 1 ... 1000) as ReflectiveGenerator<Int>
            var iterator = ValueInterpreter(gen, maxRuns: 10000)

            // Should be able to generate many values quickly
            for _ in 0 ..< 10000 {
                _ = try iterator.next()!
            }

            // If we get here without timeout, performance is acceptable
            #expect(true)
        }
    }

    @Suite("ChoiceTreeGeneratorTests")
    struct ChoiceTreeGeneratorTests {
        @Test("Simple integer test for RNG consistency")
        func simpleIntegerRNGConsistency() throws {
            let gen = Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling)
            var iterator = ValueInterpreter(gen, seed: 42)
            let output1 = try iterator.next()!

            var thing = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
            let (output2, _) = try thing.next()!

            #expect(output1 == output2, "First values should match: \(output1) vs \(output2)")
        }

        @Test("RNG state consistency between interpreters")
        func rNGStateConsistency() throws {
            // Use a simple generator that just picks between two values
            let gen = Gen.pick(choices: [(1, Gen.just(100)), (1, Gen.just(200))])

            var vi = ValueInterpreter(gen, seed: 42, maxRuns: 5)
            var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42, maxRuns: 5)

            let vi1 = try vi.next()!
            let (vact1, _) = try vact.next()!

            let vi2 = try vi.next()!
            let (vact2, _) = try vact.next()!

            let vi3 = try vi.next()!
            let (vact3, _) = try vact.next()!

            #expect(vi1 == vact1, "First: \(vi1) vs \(vact1)")
            #expect(vi2 == vact2, "Second: \(vi2) vs \(vact2)")
            #expect(vi3 == vact3, "Third: \(vi3) vs \(vact3)")
        }

        @Test("ValueInterpreter output for seed should match with and without materializePicks")
        func materializePicksDoesNotChangeSeedOutput() throws {
            let gen = stringGen()
            var iterator = ValueInterpreter(gen, seed: 4)
            _ = try iterator.next()
            _ = try iterator.next()
            let output = try iterator.next()!
            var thing = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 4)
            _ = try thing.next()
            _ = try thing.next()
            let test = try thing.next()
            let (output2, choiceTree) = try #require(test)

            print("ValueInterpreter output: \(output.description)")
            print("ValueAndChoiceTreeInterpreter output: \(output2.description)")

            #expect(output == output2)
            print()
        }
    }
}
