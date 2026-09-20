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

    @Test("Zero-fuel layers include acyclic payloads but exclude recursive payloads")
    func leafLayers() {
        #expect(CapabilityOnlyRecursive.gen(recursion: 0).isReflective)
        #expect(CapabilityRecursive.gen(recursion: 0).isReflective == false)
        #expect(CapabilityRecursive.gen(
            recursion: 0,
            .budget(.custom(recursion: 0, nodes: 1))
        ).isReflective)
        #expect(CapabilityDictionary.gen(
            recursion: 0,
            .budget(.custom(recursion: 0, nodes: 2))
        ).isReflective)
        #expect(CapabilityDictionary.gen(
            recursion: 0,
            .budget(.custom(recursion: 0, nodes: 4))
        ).isReflective == false)
    }

    @Test("Forward-only overrides remain forward-only inside derived products and arrays", arguments: [Int?.none, 64])
    func overrides(maximumNodes: Int?) {
        let forwardOnly = ReflectiveGenerator<Int>.int(in: 0 ... 10).map { $0 + 1 }
        let reversible = ReflectiveGenerator<Int>.int(in: 0 ... 10).mapped(forward: { $0 + 1 }, backward: { $0 - 1 })
        let products = [
            CapabilityInteger.gen(
                recursion: 0,
                .budget(.custom(recursion: 0, nodes: maximumNodes ?? 100)),
                overriding: forwardOnly
            ),
            CapabilityInteger.gen(
                .budget(.custom(recursion: 3, nodes: maximumNodes ?? 100)),
                overriding: forwardOnly
            ),
        ]
        #expect(products.allSatisfy { $0.isReflective == false })
        #expect(CapabilityArray.gen(
            .budget(.custom(recursion: 10, nodes: maximumNodes ?? 100)),
            overriding: forwardOnly
        ).isReflective == false)
        #expect(CapabilityInteger.gen(
            .budget(.custom(recursion: 10, nodes: maximumNodes ?? 100)),
            overriding: reversible
        ).isReflective)
    }

    @Test("Recorded dictionary choices replay exactly", arguments: [Int?.none, 64])
    func recordedChoicesReplay(maximumNodes: Int?) throws {
        let generator = CapabilityDictionary.gen(
            .budget(.custom(recursion: 3, nodes: maximumNodes ?? 100)),
            .domain(.tiny)
        )
        #expect(generator.isReflective == false)
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 1337, sizeOverride: 100)
        for _ in 0 ..< 100 {
            let (value, choices) = try #require(try interpreter.next())
            #expect(try Interpreters.replay(generator.gen, using: choices) == value)
        }
    }

    @Test("Generated dictionary counterexamples reduce from recorded choices without reflection")
    func reduction() throws {
        let generator = CapabilityDictionary.gen(
            .budget(.custom(recursion: 3, nodes: 64)),
            .domain(.tiny)
        )
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
private indirect enum CapabilityOnlyRecursive {
    case leaf
    case children([CapabilityOnlyRecursive])
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
            type.gen(
                recursion: 3,
                .budget(.custom(recursion: 3, nodes: maximumNodes ?? 100))
            )
        case false:
            type.gen(.budget(.custom(recursion: 3, nodes: maximumNodes ?? 100)))
    }
}
