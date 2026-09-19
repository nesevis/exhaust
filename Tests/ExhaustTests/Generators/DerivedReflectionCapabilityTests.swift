import Exhaust
import ExhaustCore
import Testing

@Suite("Derived reflection capabilities")
struct DerivedReflectionCapabilityTests {
    @Test("Containers and nested products preserve their reflection capability", arguments: [Int?.none, 64], [false, true])
    func containers(maximumNodes: Int?, pinned: Bool) {
        #expect(derive(CapabilityArray.self, maximumNodes: maximumNodes, pinned: pinned).isReflective)
        #expect(derive(CapabilityDictionary.self, maximumNodes: maximumNodes, pinned: pinned).isReflective == false)
        #expect(derive(CapabilitySet.self, maximumNodes: maximumNodes, pinned: pinned).isReflective == false)
        #expect(derive(CapabilityNested.self, maximumNodes: maximumNodes, pinned: pinned).isReflective == false)
        #expect(derive(CapabilityRecursive.self, maximumNodes: maximumNodes, pinned: pinned).isReflective == false)
    }

    @Test("Forced leaf layers do not inherit capabilities from unreachable payloads")
    func leafLayers() {
        #expect(CapabilityRecursive.gen(depth: 0).isReflective)
        #expect(CapabilityRecursive.gen(depth: 0, maximumNodes: 1).isReflective)
        #expect(CapabilityDictionary.gen(depth: 0, maximumNodes: 2).isReflective)
        #expect(CapabilityDictionary.gen(depth: 0, maximumNodes: 4).isReflective == false)
    }

    @Test("Forward-only overrides remain forward-only inside derived products and arrays", arguments: [Int?.none, 64])
    func overrides(maximumNodes: Int?) {
        let forwardOnly = ReflectiveGenerator<Int>.int(in: 0 ... 10).map { $0 + 1 }
        let reversible = ReflectiveGenerator<Int>.int(in: 0 ... 10).mapped(forward: { $0 + 1 }, backward: { $0 - 1 })
        let products = [
            CapabilityInteger.gen(depth: 0, maximumNodes: maximumNodes, overriding: forwardOnly),
            CapabilityInteger.gen(maximumDepth: 3, maximumNodes: maximumNodes, overriding: forwardOnly),
        ]
        #expect(products.allSatisfy { $0.isReflective == false })
        #expect(CapabilityArray.gen(maximumNodes: maximumNodes, overriding: forwardOnly).isReflective == false)
        #expect(CapabilityInteger.gen(maximumNodes: maximumNodes, overriding: reversible).isReflective)
    }

    @Test("Recorded dictionary choices replay exactly; any successful reflection preserves the output", arguments: [Int?.none, 64])
    func replayAndBestEffortReflection(maximumNodes: Int?) throws {
        let generator = CapabilityDictionary.gen(maximumDepth: 3, maximumNodes: maximumNodes, stateSpace: .tiny)
        #expect(generator.isReflective == false)
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 1337, sizeOverride: 100)
        for _ in 0 ..< 100 {
            let (value, choices) = try #require(try interpreter.next())
            #expect(try Interpreters.replay(generator.gen, using: choices) == value)
            if let reflected = try? Interpreters.reflect(generator.gen, with: value) {
                #expect(try Interpreters.replay(generator.gen, using: reflected) == value)
            }
        }
    }

    @Test("Generated dictionary counterexamples reduce from recorded choices without reflection")
    func reduction() throws {
        let generator = CapabilityDictionary.gen(maximumDepth: 3, maximumNodes: 64, stateSpace: .tiny)
        let result = #exhaust(
            generator,
            .budget(.custom(screening: 0, sampling: 100)),
            .replay(1337),
            .suppress(.all)
        ) { $0.entries.isEmpty }
        let counterexample = try #require(result)
        #expect(counterexample.entries.count == 1)
    }
}

// MARK: - Fixtures

@Exhaustable
private struct CapabilityDictionary: Equatable {
    let entries: [Bool: Int]
}

@Exhaustable
private struct CapabilitySet {
    let elements: Set<Int>
}

@Exhaustable
private struct CapabilityArray {
    let elements: [Int?]
}

@Exhaustable
private struct CapabilityNested {
    let elements: [CapabilityDictionary?]
}

@Exhaustable
private indirect enum CapabilityRecursive {
    case leaf
    case children([CapabilityRecursive])
    case entries([Bool: Int])
}

@Exhaustable
private struct CapabilityInteger {
    let value: Int
}

private func derive<Value: __Exhaustable.Conformance>(
    _ type: Value.Type,
    maximumNodes: Int?,
    pinned: Bool
) -> ReflectiveGenerator<Value> {
    switch pinned {
        case true:
            type.gen(depth: 3, maximumNodes: maximumNodes)
        case false:
            type.gen(maximumDepth: 3, maximumNodes: maximumNodes)
    }
}
