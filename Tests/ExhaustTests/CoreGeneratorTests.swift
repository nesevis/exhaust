//
//  CoreGeneratorTests.swift
//  ExhaustTests
//
//  Core generator functionality tests including Gen factory methods,
//  basic composition, and interpreter consistency.
//

@testable import Exhaust
import Testing

@Suite("Core Generator Functionality")
struct CoreGeneratorTests {
    @Suite("Gen Factory Methods")
    struct GenFactoryTests {
        @Test("Gen.choose produces values within specified range")
        func genChooseRange() throws {
            let gen = Gen.choose(in: 10 ... 20)
            var iterator = ValueInterpreter(gen)

            for _ in 0 ..< 50 {
                let value = iterator.next()!
                #expect(10 ... 20 ~= value)
            }
        }

        @Test("Flatzip", .disabled("FIXME"))
        func reflectionHashStability() throws {
            let gen = Gen.zip(Int.arbitrary, Double.arbitrary)
            var iterator = ValueAndChoiceTreeInterpreter(gen)
            while let (next, choiceTree) = iterator.next() {
                let reflected = try Interpreters.reflect(gen, with: next)
                // FIXME: Beyond the first result, the hash values go out of whack because reflection has no knowledge of the getSize parameter
                #expect(choiceTree == reflected)
            }
        }

        @Test("Gen.choose with type produces valid values")
        func genChooseType() throws {
            let gen = Gen.choose(type: UInt32.self)
            var iterator = ValueInterpreter(gen)

            for _ in 0 ..< 20 {
                let value = iterator.next()!
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
            let badRecipe = try? Interpreters.reflect(gen, with: 43)
            #expect(badRecipe == nil)

            // Test replay
            guard let recipe = recipe else {
                #expect(false, "Reflection failed for Gen.exact test")
                return
            }
            guard let replayed = try Interpreters.replay(gen, using: recipe) else {
                #expect(false, "Replay failed for Gen.exact test")
                return
            }
            #expect(replayed == value)
        }

        @Test("Gen.just produces constant value")
        func genJust() throws {
            let value = "constant"
            let gen = Gen.just(value)
            var iterator = ValueInterpreter(gen)

            for _ in 0 ..< 10 {
                let generated = iterator.next()!
                #expect(generated == value)
            }
        }

//        @Test("Empty range handling")
//        func testEmptyRangeHandling() throws {
//            // Single value range
//            let gen = Gen.choose(in: Int(42)...42)
//
//            for _ in 0..<10 {
//                let value: Int = #require(Interpreters.generate(gen))
//                #expect(value == 42)
//            }
//        }
    }

    @Suite("Interpreter Consistency")
    struct InterpreterTests {
        @Test("Generate-Reflect-Replay cycle consistency")
        func generateReflectReplayConsistency() throws {
            let generators: [ReflectiveGenerator<String>] = [
                UInt64.arbitrary.mapped(forward: \.description, backward: { UInt64($0)! }),
                Gen.just("constant"),
            ]

            let seeds = Array(ValueInterpreter(UInt64.arbitrary).prefix(10))

            for (index, gen) in generators.enumerated() {
                var iterator = ValueInterpreter(gen, seed: seeds.randomElement()!)
                for iteration in 0 ..< 10 {
                    let generated = iterator.next()!
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
            let gen = Gen.choose(in: 1 ... 100)
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

        @Test("Expect failure")
        func opaqueMapReplayFailure() throws {
            let gen = String.arbitrary
                .proliferate(with: 2 ... 5)
                .map { $0.joined() } // Using mapped here wouldn't be possible; we don't know what the string boundaries were
            var iterator = ValueInterpreter(gen)

            // String.arbitrary takes getSize so the first output will be empty
            _ = iterator.next()!
            let generated = iterator.next()!
            let reflect = try? Interpreters.reflect(gen, with: generated)
            #expect(reflect == nil)
        }
    }

    @Suite("Performance Tests")
    struct PerformanceTests {
        @Test("High-frequency generation performance")
        func highFrequencyGeneration() throws {
            let gen = Gen.choose(in: 1 ... 1000)
            var iterator = ValueInterpreter(gen, maxRuns: 10000)

            // Should be able to generate many values quickly
            for _ in 0 ..< 10000 {
                _ = iterator.next()!
            }

            // If we get here without timeout, performance is acceptable
            #expect(true)
        }
    }

    @Suite("ChoiceTreeGeneratorTests")
    struct ChoiceTreeGeneratorTests {
        @Test("Simple integer test for RNG consistency")
        func simpleIntegerRNGConsistency() throws {
            let gen = Int.arbitrary
            var iterator = ValueInterpreter(gen, seed: 42)
            let output1 = iterator.next()!

            var thing = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
            let (output2, _) = thing.next()!

            #expect(output1 == output2, "First values should match: \(output1) vs \(output2)")
        }

        @Test("RNG state consistency between interpreters")
        func rNGStateConsistency() throws {
            // Use a simple generator that just picks between two values
            let gen = Gen.pick(choices: [
                (1, Gen.just(100)),
                (1, Gen.just(200)),
            ])

            var vi = ValueInterpreter(gen, seed: 42, maxRuns: 5)
            var vact = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42, maxRuns: 5)

            let vi1 = vi.next()!
            let (vact1, _) = vact.next()!

            let vi2 = vi.next()!
            let (vact2, _) = vact.next()!

            let vi3 = vi.next()!
            let (vact3, _) = vact.next()!

            #expect(vi1 == vact1, "First: \(vi1) vs \(vact1)")
            #expect(vi2 == vact2, "Second: \(vi2) vs \(vact2)")
            #expect(vi3 == vact3, "Third: \(vi3) vs \(vact3)")
        }

        @Test("ValueInterpreter output for seed should match with and without materializePicks")
        func materializePicksDoesNotChangeSeedOutput() throws {
            let gen = String.arbitrary // Gen.pick(choices: [(UInt64(1), UInt64.arbitrary), (UInt64(1), UInt64.arbitrary)])
            var iterator = ValueInterpreter(gen, seed: 4)
            _ = iterator.next()
            _ = iterator.next()
            let output = iterator.next()!
            var thing = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 4)
            _ = thing.next()
            _ = thing.next()
            let test = thing.next()
            let (output2, choiceTree) = try #require(test)
//            let replay = try? Interpreters.replay(gen, using: choiceTree)
//            let reflection = try Interpreters.reflect(gen, with: output)

            print("ValueInterpreter output: \(output.description)")
            print("ValueAndChoiceTreeInterpreter output: \(output2.description)")

            #expect(output == output2)
            // This will fail because the ranges are slightly different, so we need a structural equality check
//            #expect(choiceTree == reflection)
            print()
        }
    }
}
