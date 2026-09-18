import Exhaust
import ExhaustCore
import Testing

@Suite("Derived container screening coverage")
struct DerivedContainerScreeningCoverageTests {
    @Test("Product arrays cover modeled cardinalities and transparent element fields", arguments: [Int?.none, 8, 16])
    func productArrays(maximumNodes: Int?) throws {
        let element = #gen(.bool(), .bool()) { ContainerScreeningElement(first: $0, second: $1) }
        let maximumCount = maximumNodes.map { ($0 - 2) / 3 } ?? 100
        let budgetLabel = maximumNodes.map(String.init) ?? "none"
        let handwritten = #gen(ReflectiveGenerator<[ContainerScreeningElement]>.array(
            element,
            length: 0 ... maximumCount,
            scaling: .linear
        )) { ContainerScreeningProducts(values: $0) }
        let derived = ContainerScreeningProducts.gen(depth: 2, maximumNodes: maximumNodes)
        for (name, generator) in [("derived", derived), ("handwritten", handwritten)] {
            let values = try containerScreeningValues(generator, label: "products-\(budgetLabel)-\(name)")
            #expect(values.allSatisfy { 2 + 3 * $0.values.count <= (maximumNodes ?? Int.max) })
            let lengths = Set(values.map { $0.values.count }).sorted()
            let elements = Set(values.flatMap { $0.values }.map { ($0.first ? 2 : 0) + ($0.second ? 1 : 0) }).sorted()
            if name == "derived", maximumNodes != nil {
                // The dependent count layer models every feasible count, but its payloads remain opaque.
                #expect(lengths == Array(0 ... maximumCount))
            } else {
                #expect(elements == [0, 1, 2, 3])
                #expect(lengths == [0, 1, 2])
            }
        }
    }

    @Test("Transparent element wrappers preserve ordered rows, exact replay and sampling")
    func transparentElementParity() throws {
        let element = #gen(.bool(), .bool()) { ContainerScreeningElement(first: $0, second: $1) }
        let handwritten = ReflectiveGenerator<[ContainerScreeningElement]>.array(element, length: 0 ... 2)
        let derivedRoot = ContainerScreeningProducts.gen(depth: 2).mapped(
            forward: { $0.values },
            backward: { ContainerScreeningProducts(values: $0) }
        )
        let variants: [(String, ReflectiveGenerator<[ContainerScreeningElement]>)] = [
            ("derived-root", derivedRoot),
            ("pinned-element", .array(ContainerScreeningElement.gen(depth: 0), length: 0 ... 2)),
            ("drawn-element", .array(ContainerScreeningElement.gen(maximumDepth: 2), length: 0 ... 2)),
            ("lazy-element", .array(.lazy { element }, length: 0 ... 2)),
            ("sized-element", .array(ContainerScreeningElement.gen(depth: 0, maximumNodes: 3), length: 0 ... 2)),
        ]
        for (name, source) in variants {
            let generator = source.resize(100)
            let before = try containerSamplingValues(generator)
            let plan = try #require(ScreeningRunner.plan(generator.gen, screeningBudget: 200))
            #expect(plan.domainSizes == [21], "\(name)")
            for seed in [UInt64(1), 42, 1337] {
                var expected: [[ContainerScreeningElement]] = []
                let reference = ScreeningRunner.run(handwritten.resize(100).gen, screeningBudget: 200, coveringSeed: seed) {
                    expected.append($0)
                    return true
                }
                var actual: [[ContainerScreeningElement]] = []
                let result = ScreeningRunner.run(
                    generator.gen,
                    screeningBudget: 200,
                    coveringSeed: seed,
                    property: {
                        actual.append($0)
                        return true
                    },
                    onExample: { value, tree, _ in
                        for usesFallback in [false, true] {
                            let replay = Materializer.materializeAny(
                                generator.gen.erase(),
                                context: .init(
                                    prefix: ChoiceSequence(tree),
                                    mode: .exact,
                                    fallbackTree: usesFallback ? tree : nil
                                )
                            )
                            guard case let .success(replayed, _, _) = replay else {
                                Issue.record("Exact element replay failed: \(name), seed \(seed)")
                                continue
                            }
                            #expect(replayed as? [ContainerScreeningElement] == value)
                        }
                    }
                )
                #expect(reference.summary.rowAttempts == 21)
                #expect(reference.summary.rejectedRows == 0)
                #expect(result.summary.rowAttempts == 21)
                #expect(result.summary.rejectedRows == 0)
                #expect(actual == expected, "\(name), seed \(seed)")
                var valueOnly: [[ContainerScreeningElement]] = []
                let withoutTrees = ScreeningRunner.run(generator.gen, screeningBudget: 200, coveringSeed: seed) {
                    valueOnly.append($0)
                    return true
                }
                #expect(withoutTrees.summary.rejectedRows == 0)
                #expect(valueOnly == expected)
            }
            #expect(try containerSamplingValues(generator) == before)
        }
    }

    @Test("Ordinary dependent element binds remain opaque without consuming sibling fields")
    func dependentElementRemainsOpaque() throws {
        let dependent = ReflectiveGenerator<Bool>.bool().bound(forward: { .just($0) }, backward: { $0 })
        let element = #gen(dependent, .bool()) { ContainerScreeningElement(first: $0, second: $1) }
        let generator = ReflectiveGenerator<[ContainerScreeningElement]>.array(element, length: 0 ... 2)
        let plan = try #require(ScreeningRunner.plan(generator.gen, screeningBudget: 200))
        #expect(plan.domainSizes == [7])
        let values = try containerScreeningValues(generator, label: "opaque-dependent-element")
        #expect(Set(values.filter { $0.count == 1 }.map { $0[0].second }) == Set([false, true]))
        let pairs = values.filter { $0.count == 2 }.map { ($0[0].second ? 2 : 0) + ($0[1].second ? 1 : 0) }
        #expect(Set(pairs) == Set([0, 1, 2, 3]))
    }

    @Test("A public element override exposes the product fields in an unbudgeted array")
    func suppliedProductElements() throws {
        let element = #gen(.bool(), .bool()) { ContainerScreeningElement(first: $0, second: $1) }
        let generator = ContainerScreeningProducts.gen(depth: 2, overriding: element)
        let values = try containerScreeningValues(generator, label: "supplied-products", expectedRows: 21)
        let elements = Set(values.flatMap { $0.values }.map { ($0.first ? 2 : 0) + ($0.second ? 1 : 0) }).sorted()
        #expect(elements == [0, 1, 2, 3])
    }

    @Test("Native nested sequences model outer cardinality without claiming inner coverage")
    func nativeNestedArrays() throws {
        let inner = ReflectiveGenerator<[Bool]>.array(.bool(), length: 0 ... 2, scaling: .constant)
        let generator = ReflectiveGenerator<[[Bool]]>.array(inner, length: 0 ... 2, scaling: .constant)
        let values = try containerScreeningValues(generator, label: "native-nested")
        #expect(values.allSatisfy { $0.count <= 2 && $0.allSatisfy { $0.count <= 2 } })
        let outerLengths = Set(values.map { $0.count }).sorted()
        #expect(outerLengths == [0, 1, 2])
        let plan = try #require(ScreeningRunner.plan(generator.gen, screeningBudget: 200))
        #expect(plan.domainSizes == [3])
    }

    @Test("Budgeted nested arrays cover every feasible outer count", arguments: [8, 16])
    func nestedArrays(maximumNodes: Int) throws {
        let lengths = ReflectiveGenerator<Int>.int(in: 0 ... maximumNodes - 2, scaling: .linear)
        let arrays: ReflectiveGenerator<[[Bool]]> = lengths.bound(
            forward: { count in
                guard count > 0 else {
                    return .just([])
                }
                let maximumInnerCount = (maximumNodes - 2) / count - 1
                let inner = ReflectiveGenerator<[Bool]>.array(.bool(), length: 0 ... maximumInnerCount, scaling: .linear)
                return .array(inner, length: count ... count, scaling: .constant)
            },
            backward: { $0.count }
        )
        let handwritten = #gen(arrays) { ContainerScreeningNested(values: $0) }
        let derived = ContainerScreeningNested.gen(depth: 2, maximumNodes: maximumNodes)
        for (name, generator) in [("derived", derived), ("handwritten", handwritten)] {
            let values = try containerScreeningValues(generator, label: "nested-\(maximumNodes)-\(name)")
            #expect(values.allSatisfy { 2 + $0.values.reduce(0) { $0 + 1 + $1.count } <= maximumNodes })
            let outerLengths = Set(values.map { $0.values.count }).sorted()
            #expect(outerLengths == Array(0 ... maximumNodes - 2))
        }
    }
}

/// Collects actual full-size property inputs, requiring every screening attempt to reach the property rather than mistaking an empty or rejected run for coverage.
private func containerScreeningValues<Value>(
    _ source: ReflectiveGenerator<Value>,
    label: String,
    expectedRows: Int? = nil
) throws -> [Value] {
    let generator = source.resize(100)
    _ = try #require(ScreeningRunner.plan(generator.gen, screeningBudget: 200))
    var values: [Value] = []
    for seed in [UInt64(1), 42, 1337] {
        let result = ScreeningRunner.run(generator.gen, screeningBudget: 200, coveringSeed: seed) { value in
            values.append(value)
            return true
        }
        #expect(result.summary.propertyInvocations > 0, "\(label), seed \(seed)")
        #expect(result.summary.rejectedRows == 0)
        #expect(result.summary.propertyInvocations == result.summary.rowAttempts)
        if let expectedRows {
            #expect(result.summary.propertyInvocations == expectedRows, "\(label), seed \(seed)")
        }
    }
    return values
}

/// Recreates the same sampling stream before and after screening to detect changes to generator state or sampling policy.
private func containerSamplingValues<Value>(_ generator: ReflectiveGenerator<Value>) throws -> [Value] {
    var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, sizeOverride: 100)
    var values: [Value] = []
    for _ in 0 ..< 32 {
        let (value, _) = try #require(try interpreter.next())
        values.append(value)
    }
    return values
}

@Exhaustable
private struct ContainerScreeningElement: Equatable {
    let first: Bool
    let second: Bool
}

@Exhaustable
private struct ContainerScreeningProducts {
    let values: [ContainerScreeningElement]
}

@Exhaustable
private struct ContainerScreeningNested {
    let values: [[Bool]]
}
