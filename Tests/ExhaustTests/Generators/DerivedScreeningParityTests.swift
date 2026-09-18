import Exhaust
import ExhaustCore
import Testing

@Suite("Derived screening parity")
struct DerivedScreeningParityTests {
    @Test("Flat products expose the same domains and materialized rows as handwritten zips", arguments: [Int?.none, 200], [false, true])
    func flatProducts(maximumNodes: Int?, drawn: Bool) throws {
        let handwritten = #gen(.int(in: 0 ... 31), .int(in: 0 ... 31), .bool()) { first, second, enabled in
            ScreeningRecord(first: first, second: second, enabled: enabled)
        }
        let derived: ReflectiveGenerator<ScreeningRecord> = switch drawn {
            case true:
                ScreeningRecord.gen(maximumDepth: 5, maximumNodes: maximumNodes, overriding: .int(in: 0 ... 31))
            case false:
                ScreeningRecord.gen(depth: 0, maximumNodes: maximumNodes, overriding: .int(in: 0 ... 31))
        }
        try expectScreeningParity(derived, handwritten)
    }

    @Test("Default drawn-depth nested products match handwritten rows", arguments: [Int?.none, 200])
    func drawnNestedProducts(maximumNodes: Int?) throws {
        let handwritten = #gen(.int(in: 0 ... 31), .int(in: 0 ... 31), .bool(), .int(in: 0 ... 31)) { first, second, enabled, outer in
            ScreeningNested(inner: ScreeningRecord(first: first, second: second, enabled: enabled), outer: outer)
        }
        let derived = ScreeningNested.gen(maximumNodes: maximumNodes, overriding: .int(in: 0 ... 31))
        try expectScreeningParity(derived, handwritten)
    }

    @Test("Array products expose lengths and element boundaries like handwritten sequences", arguments: [Int?.none, 200])
    func arrayProducts(maximumNodes: Int?) throws {
        let elements: ReflectiveGenerator<[Int]> = switch maximumNodes {
            case .none:
                .array(.int(in: 0 ... 31))
            case .some:
                .array(.int(in: 0 ... 31), length: 0 ... 99, scaling: .linear)
        }
        let handwritten = #gen(elements, .int(in: 0 ... 31)) { values, label in
            ScreeningArrayRecord(values: values, label: label)
        }
        let derived = ScreeningArrayRecord.gen(depth: 0, maximumNodes: maximumNodes, overriding: .int(in: 0 ... 31))
        try expectScreeningParity(derived, handwritten)
    }

    @Test("Full integer domains retain the handwritten problematic-value rows", arguments: [Int?.none, 200])
    func largeDomainProducts(maximumNodes: Int?) throws {
        let handwritten = #gen(.int(), .int(), .bool()) { first, second, enabled in
            ScreeningRecord(first: first, second: second, enabled: enabled)
        }
        let derived = ScreeningRecord.gen(maximumNodes: maximumNodes)
        let values = try matchingScreeningRows(derived, handwritten, expectedParameters: 3)
        #expect(values.contains { $0.first == Int.min })
        #expect(values.contains { $0.first == Int.max })
        #expect(values.contains { $0.second == Int.min })
        #expect(values.contains { $0.second == Int.max })
    }

    @Test("Pinned enums retain handwritten constructor selection and row values", arguments: [Int?.none, 200])
    func enumProducts(maximumNodes: Int?) throws {
        let integer = #gen(.int(in: 0 ... 31)) { ScreeningVariant.integer($0) }
        let flag = #gen(.bool()) { ScreeningVariant.flag($0) }
        let handwritten = #gen(.oneOf(integer, flag), .int(in: 0 ... 31)) { variant, label in
            ScreeningVariantRecord(variant: variant, label: label)
        }
        let variants = ScreeningVariant.gen(depth: 0, maximumNodes: maximumNodes, overriding: .int(in: 0 ... 31))
        let derived = #gen(variants, .int(in: 0 ... 31)) { variant, label in
            ScreeningVariantRecord(variant: variant, label: label)
        }
        let values = try matchingScreeningRows(derived, handwritten, expectedParameters: 2)
        #expect(values.contains { value in
            if case .integer = value.variant {
                true
            } else {
                false
            }
        })
        #expect(values.contains { value in
            if case .flag = value.variant {
                true
            } else {
                false
            }
        })
    }

    @Test(
        "Drawn recursive roots screen the full feasible layer without forcing deep values",
        arguments: [1, 3, 5],
        [Int?.none, 2, 32, 200]
    )
    func fullDepthScreening(ceiling: Int, maximumNodes: Int?) throws {
        let pinnedTree = ScreeningRecursive.gen(
            depth: ceiling,
            maximumNodes: maximumNodes,
            overriding: .int(in: 0 ... 31)
        )
        let drawnTree = ScreeningRecursive.gen(
            maximumDepth: ceiling,
            maximumNodes: maximumNodes,
            overriding: .int(in: 0 ... 31)
        )
        let pinned = #gen(pinnedTree, .int(in: 0 ... 31)) { tree, label in
            ScreeningRecursiveRecord(tree: tree, label: label)
        }
        let drawn = #gen(drawnTree, .int(in: 0 ... 31)) { tree, label in
            ScreeningRecursiveRecord(tree: tree, label: label)
        }
        let values = try matchingScreeningRows(drawn, pinned, expectedParameters: 2)
        #expect(values.contains { $0.tree.depth == 0 })
        #expect(values.allSatisfy { $0.tree.depth <= ceiling })
        #expect(values.allSatisfy { $0.tree.nodes <= (maximumNodes ?? Int.max) })
        let result = ScreeningRunner.run(
            drawn.gen,
            screeningBudget: 200,
            coveringSeed: 42,
            property: { _ in true },
            onExample: { _, tree, _ in
                #expect(screeningDepthControls(in: tree) == [UInt64(ceiling)])
            }
        )
        #expect(result.summary.propertyInvocations > 0)
        #expect(result.summary.rejectedRows == 0)
    }

    @Test("Drawn recursive generators match handwritten full-depth generators", arguments: [1, 3, 5])
    func handwrittenRecursiveParity(ceiling: Int) throws {
        let drawn = #gen(
            ScreeningRecursive.gen(maximumDepth: ceiling, overriding: .int(in: 0 ... 31)),
            .int(in: 0 ... 31)
        ) { tree, label in
            ScreeningRecursiveRecord(tree: tree, label: label)
        }
        let handwritten = #gen(
            handwrittenScreeningRecursive(depth: ceiling),
            .int(in: 0 ... 31)
        ) { tree, label in
            ScreeningRecursiveRecord(tree: tree, label: label)
        }
        _ = try matchingScreeningRows(drawn, handwritten, expectedParameters: 2)
    }

    @Test("Unmodeled branch payloads use their resized feasible depth", arguments: [1, 40, 100])
    func branchDepthScreening(size: Int) throws {
        let recursive = ScreeningRecursive.gen(maximumDepth: 5, maximumNodes: 32).resize(size)
        let payload = #gen(recursive) { ScreeningRecursiveEnvelope.tree($0) }
        let generator = ReflectiveGenerator<ScreeningRecursiveEnvelope>.oneOf(payload, .just(.empty))
        let plan = try #require(ScreeningRunner.plan(generator.gen, screeningBudget: 200))
        #expect(plan.parameterCount == 1)
        var controls: [[UInt64]] = []
        let result = ScreeningRunner.run(
            generator.gen,
            screeningBudget: 200,
            coveringSeed: 42,
            property: { _ in true },
            onExample: { _, tree, _ in
                controls.append(screeningDepthControls(in: tree))
            }
        )
        #expect(result.summary.propertyInvocations > 0)
        #expect(result.summary.rejectedRows == 0)
        #expect(Set(controls) == Set([[], [UInt64(size * 5 / 100)]]))
    }

    @Test("Full-depth screening respects nested annotation ceilings", arguments: [Int?.none, 32])
    func nestedDepthCeilings(maximumNodes: Int?) throws {
        let drawn = ScreeningAnnotatedRoot.gen(
            maximumDepth: 5,
            maximumNodes: maximumNodes,
            overriding: .int(in: 0 ... 31)
        )
        let pinned = ScreeningAnnotatedRoot.gen(
            depth: 5,
            maximumNodes: maximumNodes,
            overriding: .int(in: 0 ... 31)
        )
        let values = try matchingScreeningRows(drawn, pinned, expectedParameters: 2)
        #expect(values.allSatisfy { $0.nested.depth <= 2 })
        #expect(values.contains { $0.nested.depth == 2 })
        #expect(values.contains { $0.nested.depth == 0 })
    }

    @Test("Screening analysis does not change subsequent sampling of the same generator")
    func samplingRemainsDepthScaled() throws {
        let generator = ScreeningRecursive.gen(maximumDepth: 5, maximumNodes: 32)
        let before = try screeningSamplingValues(generator)
        _ = try #require(ScreeningRunner.plan(generator.gen, screeningBudget: 200))
        let after = try screeningSamplingValues(generator)
        #expect(before == after)
        #expect(Set(before.map { $0.depth }).count > 1)
    }

    @Test("Nested products expose fields through nonrecursive derived edges", arguments: [Int?.none, 200])
    func nestedProducts(maximumNodes: Int?) throws {
        let handwritten = #gen(.int(in: 0 ... 31), .int(in: 0 ... 31), .bool(), .int(in: 0 ... 31)) { first, second, enabled, outer in
            ScreeningNested(inner: ScreeningRecord(first: first, second: second, enabled: enabled), outer: outer)
        }
        let derived = ScreeningNested.gen(depth: 2, maximumNodes: maximumNodes, overriding: .int(in: 0 ... 31))
        try expectScreeningParity(derived, handwritten)
    }
}

// MARK: - Test helpers

/// Compares actual guided materialization, not merely the number of rows produced by the covering-array builder.
private func expectScreeningParity<Value: Equatable>(
    _ derived: ReflectiveGenerator<Value>,
    _ handwritten: ReflectiveGenerator<Value>
) throws {
    let expectedPlan = try #require(ScreeningRunner.plan(handwritten.gen, screeningBudget: 200))
    let actualPlan = try #require(ScreeningRunner.plan(derived.gen, screeningBudget: 200))
    #expect(actualPlan.domainSizes == expectedPlan.domainSizes)
    #expect(actualPlan.parameterCount == expectedPlan.parameterCount)
    #expect(actualPlan.kind == expectedPlan.kind)
    for seed in [UInt64(0), 42, 1337] {
        var expectedRows: [Value] = []
        var actualRows: [Value] = []
        let expected = ScreeningRunner.run(handwritten.gen, screeningBudget: 200, coveringSeed: seed) { value in
            expectedRows.append(value)
            return true
        }
        let actual = ScreeningRunner.run(derived.gen, screeningBudget: 200, coveringSeed: seed) { value in
            actualRows.append(value)
            return true
        }
        #expect(expected.summary.rowAttempts == 200)
        #expect(expected.summary.rejectedRows == 0)
        #expect(actual.summary.rowAttempts == expected.summary.rowAttempts)
        #expect(actual.summary.rejectedRows == expected.summary.rejectedRows)
        #expect(actualRows == expectedRows)
    }
}

/// Allows exhaustive small domains to finish below the budget while requiring identical ordered values and explicit model breadth.
private func matchingScreeningRows<Value: Equatable>(
    _ derived: ReflectiveGenerator<Value>,
    _ handwritten: ReflectiveGenerator<Value>,
    expectedParameters: Int
) throws -> [Value] {
    let expectedPlan = try #require(ScreeningRunner.plan(handwritten.gen, screeningBudget: 200))
    let actualPlan = try #require(ScreeningRunner.plan(derived.gen, screeningBudget: 200))
    #expect(expectedPlan.parameterCount == expectedParameters)
    #expect(actualPlan.parameterCount == expectedParameters)
    #expect(actualPlan.domainSizes == expectedPlan.domainSizes)
    #expect(actualPlan.kind == expectedPlan.kind)
    var allValues: [Value] = []
    for seed in [UInt64(0), 42, 1337] {
        var expectedRows: [Value] = []
        var actualRows: [Value] = []
        let expected = ScreeningRunner.run(handwritten.gen, screeningBudget: 200, coveringSeed: seed) { value in
            expectedRows.append(value)
            return true
        }
        let actual = ScreeningRunner.run(derived.gen, screeningBudget: 200, coveringSeed: seed) { value in
            actualRows.append(value)
            return true
        }
        #expect(expected.summary.rowAttempts > 0)
        #expect(expected.summary.rejectedRows == 0)
        #expect(actual.summary.rowAttempts == expected.summary.rowAttempts)
        #expect(actual.summary.rejectedRows == 0)
        #expect(actualRows == expectedRows)
        allValues.append(contentsOf: actualRows)
    }
    return allValues
}

/// Reads the structural control from the materialized row, rather than inferring the selected layer from an output that can terminate early.
private func screeningDepthControls(in tree: ChoiceTree) -> [UInt64] {
    switch tree {
        case let .choice(value, _):
            value.tag == .depthControl ? [value.bitPattern64] : []
        case let .bind(_, inner, bound):
            screeningDepthControls(in: inner) + screeningDepthControls(in: bound)
        case let .group(children, _, _), let .resize(_, children):
            children.flatMap { screeningDepthControls(in: $0) }
        case let .sequence(elements, _):
            elements.flatMap { screeningDepthControls(in: $0) }
        case let .branch(branch):
            screeningDepthControls(in: branch.choice)
        case .just, .getSize:
            []
    }
}

/// Recreates the same sampling context on either side of analysis so changes to a shared generator cannot hide behind different seeds or size schedules.
private func screeningSamplingValues(
    _ generator: ReflectiveGenerator<ScreeningRecursive>
) throws -> [ScreeningRecursive] {
    var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, sizeOverride: 100)
    var values: [ScreeningRecursive] = []
    for _ in 0 ..< 50 {
        let (value, _) = try #require(try interpreter.next())
        values.append(value)
    }
    return values
}

/// Retains singleton constructor picks and lazy recursive arms so its runtime choice structure matches the ordinary handwritten spelling of the derived generator.
private func handwrittenScreeningRecursive(depth: Int) -> ReflectiveGenerator<ScreeningRecursive> {
    let leaf = #gen(.int(in: 0 ... 31)) { ScreeningRecursive.leaf($0) }
    guard depth > 0 else {
        return .oneOf(leaf)
    }
    let child = handwrittenScreeningRecursive(depth: depth - 1)
    let branch = ReflectiveGenerator<ScreeningRecursive>.lazy {
        #gen(child, child) { ScreeningRecursive.branch($0, $1) }
    }
    return .oneOf(leaf, branch)
}

@Exhaustable
private struct ScreeningAnnotatedRoot: Equatable {
    let nested: ScreeningLimitedRecursive
    let label: Int
}

@Exhaustable(maximumDepth: 2)
private indirect enum ScreeningLimitedRecursive: Equatable {
    case leaf(Int)
    case branch(ScreeningLimitedRecursive, ScreeningLimitedRecursive)

    var depth: Int {
        switch self {
            case .leaf:
                0
            case let .branch(first, second):
                1 + max(first.depth, second.depth)
        }
    }
}

private enum ScreeningRecursiveEnvelope {
    case tree(ScreeningRecursive)
    case empty
}

private struct ScreeningRecursiveRecord: Equatable {
    let tree: ScreeningRecursive
    let label: Int
}

@Exhaustable
private indirect enum ScreeningRecursive: Equatable {
    case leaf(Int)
    case branch(ScreeningRecursive, ScreeningRecursive)

    var depth: Int {
        switch self {
            case .leaf:
                0
            case let .branch(first, second):
                1 + max(first.depth, second.depth)
        }
    }

    var nodes: Int {
        switch self {
            case .leaf:
                2
            case let .branch(first, second):
                1 + first.nodes + second.nodes
        }
    }
}

private struct ScreeningVariantRecord: Equatable {
    let variant: ScreeningVariant
    let label: Int
}

@Exhaustable
private enum ScreeningVariant: Equatable {
    case integer(Int)
    case flag(Bool)
}

@Exhaustable
private struct ScreeningRecord: Equatable {
    let first: Int
    let second: Int
    let enabled: Bool
}

@Exhaustable
private struct ScreeningArrayRecord: Equatable {
    let values: [Int]
    let label: Int
}

@Exhaustable
private struct ScreeningNested: Equatable {
    let inner: ScreeningRecord
    let outer: Int
}
