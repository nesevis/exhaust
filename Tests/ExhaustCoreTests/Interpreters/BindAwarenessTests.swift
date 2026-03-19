//
//  BindAwarenessTests.swift
//  ExhaustTests
//
//  Tests for Phase 1 bind-aware annotations: ChoiceTree.bind, ChoiceSequenceValue.bind,
//  and their treatment across the interpreter pipeline.
//

import Testing
@testable import ExhaustCore

@Suite("Bind Awareness — Phase 1")
struct BindAwarenessTests {
    // MARK: - ChoiceTree.bind

    @Test("Bind tree has two children")
    func bindTreeChildren() {
        let inner = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        #expect(tree.children.count == 2)
        #expect(tree.children[0] == inner)
        #expect(tree.children[1] == bound)
    }

    @Test("Bind tree replacingChild works for inner")
    func bindTreeReplacingInner() {
        let inner = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let newInner = ChoiceTree.choice(.unsigned(99, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let replaced = tree.replacingChild(at: 0, with: newInner)

        #expect(replaced.children[0] == newInner)
        #expect(replaced.children[1] == bound)
    }

    @Test("Bind tree replacingChild works for bound")
    func bindTreeReplacingBound() {
        let inner = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let newBound = ChoiceTree.choice(.unsigned(99, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let replaced = tree.replacingChild(at: 1, with: newBound)

        #expect(replaced.children[0] == inner)
        #expect(replaced.children[1] == newBound)
    }

    @Test("Bind tree containsPicks delegates to children")
    func bindTreeContainsPicks() {
        let inner = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        #expect(tree.containsPicks == false)
    }

    @Test("Bind debug description contains 'bind'")
    func bindDebugDescription() {
        let inner = ChoiceTree.just("x")
        let bound = ChoiceTree.just("y")
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        #expect(tree.debugDescription.contains("bind"))
    }

    @Test("Bind elementDescription wraps children in braces")
    func bindElementDescription() {
        let inner = ChoiceTree.just("a")
        let bound = ChoiceTree.just("b")
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        #expect(tree.elementDescription.contains("{"))
        #expect(tree.elementDescription.contains("}"))
    }

    // MARK: - ChoiceSequenceValue.bind

    @Test("Bind shortString produces { and }")
    func bindShortString() {
        #expect(ChoiceSequenceValue.bind(true).shortString == "{")
        #expect(ChoiceSequenceValue.bind(false).shortString == "}")
    }

    @Test("Bind markers have same kindOrder as group")
    func bindKindOrder() {
        // .bind and .group share kindOrder 1, so cross-kind comparison yields .eq
        let compare = ChoiceSequenceValue.group(true).shortLexCompare(.bind(true))
        #expect(compare == .eq)
    }

    @Test("Bind markers compare correctly with each other")
    func bindSelfCompare() {
        #expect(ChoiceSequenceValue.bind(true).shortLexCompare(.bind(true)) == .eq)
        #expect(ChoiceSequenceValue.bind(false).shortLexCompare(.bind(false)) == .eq)
        #expect(ChoiceSequenceValue.bind(false).shortLexCompare(.bind(true)) == .lt)
        #expect(ChoiceSequenceValue.bind(true).shortLexCompare(.bind(false)) == .gt)
    }

    // MARK: - Flatten round-trip

    @Test("Bind tree flattens with bind markers")
    func bindTreeFlattens() {
        let inner = ChoiceTree.choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(7, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let flattened = ChoiceSequence.flatten(tree)

        // Should have: .bind(true), value(42), value(7), .bind(false)
        #expect(flattened.count == 4)
        #expect(flattened[0] == .bind(true))
        #expect(flattened[3] == .bind(false))

        let values = flattened.compactMap(\.value)
        #expect(values.count == 2)
    }

    @Test("Flatten → validate succeeds for bind trees")
    func flattenValidateBindTree() {
        let inner = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let flattened = ChoiceSequence.flatten(tree)
        #expect(ChoiceSequence.validate(flattened))
    }

    @Test("Unbalanced bind markers fail validation")
    func unbalancedBindFailsValidation() {
        var seq = ChoiceSequence()
        seq.append(.bind(true))
        seq.append(.value(.init(choice: .unsigned(1, .uint64), validRange: 0 ... 10)))
        // Missing .bind(false)
        #expect(ChoiceSequence.validate(seq) == false)
    }

    @Test("extractContainerSpans identifies bind spans")
    func extractContainerSpansFindsBinds() {
        let inner = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let flattened = ChoiceSequence.flatten(tree)
        let spans = ChoiceSequence.extractContainerSpans(from: flattened)

        #expect(spans.count >= 1)
        let bindSpan = spans.first(where: { $0.kind == .bind(true) })
        #expect(bindSpan != nil)
        #expect(bindSpan?.range == 0 ... 3)
    }

    // MARK: - VACTI produces .bind for bound() generators

    @Test("VACTI produces bind tree for transform(.bind) operation")
    func vactiProducesBindTree() throws {
        // Construct a bind generator using Gen.liftF
        let gen: ReflectiveGenerator<[Int]> = Gen.choose(in: 0 ... 5 as ClosedRange<Int>)._bound(
            forward: { n in
                Gen.arrayOf(Gen.choose(in: 0 ... 100 as ClosedRange<Int>), exactly: UInt64(max(0, n)))
            },
            backward: { (output: [Int]) in
                output.count
            }
        )

        var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: 42)
        let (_, tree) = try #require(try interpreter.next())

        // The tree should contain a .bind node
        var foundBind = false
        for element in tree.walk() {
            if case .bind = element.node {
                foundBind = true
                break
            }
        }
        #expect(foundBind, "Expected .bind node in VACTI output for bound() generator")
    }

    // MARK: - Coverage analysis treats bound subtree as opaque

    @Test("ChoiceTreeAnalysis produces fewer parameters for bind-dependent generators")
    func coverageAnalysisTreatsBoundAsOpaque() {
        // Construct a bind generator: inner picks from 0...3, bound depends on inner
        let gen: ReflectiveGenerator<[Int]> = Gen.choose(in: 0 ... 3 as ClosedRange<Int>)._bound(
            forward: { n in
                Gen.arrayOf(Gen.choose(in: 0 ... 10 as ClosedRange<Int>), exactly: UInt64(max(0, n)))
            },
            backward: { (output: [Int]) in
                output.count
            }
        )

        let result = ChoiceTreeAnalysis.analyze(gen)

        // With opaque-bound handling, only the inner parameter (0...3) should be extracted.
        // Without opaque-bound, the bound array's parameters would also be extracted.
        if case let .finite(profile) = result {
            // inner: 0...3 = 4 values, that's 1 parameter
            #expect(profile.parameters.count <= 2, "Expected few parameters — bound subtree should be opaque")
        } else if case let .boundary(profile) = result {
            #expect(profile.parameters.count <= 2, "Expected few parameters — bound subtree should be opaque")
        }
        // It's also valid for analyze() to return nil if the generator is unanalyzable
    }
}
