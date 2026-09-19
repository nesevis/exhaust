import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("MetaFuzz size screening capabilities")
struct MetaFuzzSizeScreeningTests {
    @Test("The raw-size recipe screens every value at its fixed analysis size", arguments: [UInt64(0), 42, 1337])
    func rawSizeRecipe(seed: UInt64) throws {
        let fixture = try #require(metaFuzzOperationFixtures.first { $0.name == "getSize" })
        let generator = buildGenerator(from: fixture.recipe)
        let plan = try #require(ScreeningRunner.plan(generator, screeningBudget: 512))
        #expect(plan.parameterCount == 1)
        #expect(plan.domainSizes == [101])
        var values: [Int] = []
        let result = ScreeningRunner.run(
            generator,
            screeningBudget: 512,
            coveringSeed: seed,
            property: { output in
                guard let value = output as? Int else {
                    Issue.record("Size fixture produced a non-integer")
                    return false
                }
                values.append(value)
                return true
            },
            onExample: { output, tree, _ in
                do {
                    let replayed = try Interpreters.replay(generator, using: tree)
                    #expect(replayed as? Int == output as? Int)
                    for usesFallback in [false, true] {
                        let replay = Materializer.materializeAny(
                            generator,
                            context: .init(
                                prefix: ChoiceSequence(tree),
                                mode: .exact,
                                fallbackTree: usesFallback ? tree : nil
                            )
                        )
                        guard case let .success(value, _, _) = replay else {
                            Issue.record("Raw-size screening row failed exact materialization")
                            continue
                        }
                        #expect(value as? Int == output as? Int)
                    }
                } catch {
                    Issue.record("Raw-size screening row failed replay: \(error)")
                }
            }
        )
        #expect(result.summary.rowAttempts == 101)
        #expect(result.summary.propertyInvocations == 101)
        #expect(result.summary.rejectedRows == 0)
        #expect(Set(values) == Set(0 ... 100))
    }

    @Test("The public size factory has a reducible size choice and remains opaque to screening")
    func publicSizeFactory() throws {
        let fixture = try #require(metaFuzzOperationFixtures.first { $0.name == "getSize" })
        var recipeInterpreter = ValueAndChoiceTreeInterpreter(
            buildGenerator(from: fixture.recipe),
            seed: 42,
            sizeOverride: 100
        )
        let (_, recipeTree) = try #require(try recipeInterpreter.next())
        guard case .bind(_, .getSize, _) = recipeTree else {
            Issue.record("Expected the recipe's bind to read the raw size")
            return
        }
        let publicGenerator = ReflectiveGenerator<Int>.getSize { size in
            ReflectiveGenerator<Bool>.bool().mapped(
                forward: { $0 ? Int(size) : 0 },
                backward: { $0 != 0 }
            )
        }
        var publicInterpreter = ValueAndChoiceTreeInterpreter(publicGenerator.gen, seed: 42, sizeOverride: 100)
        let (_, publicTree) = try #require(try publicInterpreter.next())
        guard case let .bind(_, .choice(_, metadata), _) = publicTree else {
            Issue.record("Expected the public factory's reducible size choice")
            return
        }
        #expect(metadata.isPinnedToSize == true)
        #expect(ChoiceTreeAnalysis.analyze(publicGenerator.gen) == nil)
        var propertyCalls = 0
        let screening = ScreeningRunner.run(publicGenerator.gen, screeningBudget: 512, coveringSeed: 42) { _ in
            propertyCalls += 1
            return true
        }
        guard case .notApplicable = screening else {
            Issue.record("The public size-dependent payload unexpectedly entered the screening model")
            return
        }
        #expect(propertyCalls == 0)

        var sampledValues: Set<Int> = []
        for _ in 0 ..< 32 {
            let (value, tree) = try #require(try publicInterpreter.next())
            sampledValues.insert(value)
            #expect(try Interpreters.replay(publicGenerator.gen, using: tree) == value)
            let reflected = try #require(try Interpreters.reflect(publicGenerator.gen, with: value))
            #expect(try Interpreters.replay(publicGenerator.gen, using: reflected) == value)
            let replay = Materializer.materialize(
                publicGenerator.gen,
                context: .init(prefix: ChoiceSequence(tree), mode: .exact)
            )
            guard case let .success(replayed, _, _) = replay else {
                Issue.record("Public size generator failed exact materialization")
                continue
            }
            #expect(replayed == value)
        }
        #expect(sampledValues == Set([0, 100]))
    }
}
