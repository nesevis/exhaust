//
//  BindAwareReducerBenchmark.swift
//  Exhaust
//
//  Measures property invocation counts during reduction of bind-heavy generators.
//  Run on both main and feature/bind-awareness-in-shrinking to quantify the
//  improvement from bind-aware shrink passes.
//

import Testing
@testable import ExhaustCore
@testable import Exhaust

@Suite("Bind-Aware Reducer Benchmark")
struct BindAwareReducerBenchmark {
    // MARK: - Scenario 1: Bind-dependent array length

    @Test("Scenario 1: bind-dependent array length", arguments: [
        UInt64(42), UInt64(123), UInt64(999), UInt64(7777), UInt64(31415),
    ])
    func bindDependentArrayLength(seed: UInt64) throws {
        // Inner: pick n from 1...20.
        // Bound: array of n elements, each from 0...100.
        // Property: array.count <= 3 (fails when n >= 4).
        let gen = #gen(.int(in: 1 ... 20))
            .bound(
                forward: { n in Gen.int(in: 0 ... 100).array(length: UInt64(max(0, n))) },
                backward: { (arr: [Int]) in arr.count }
            )

        let result = try reduceAndMeasure(gen: gen, seed: seed) { $0.count <= 3 }
        guard let result else { return }

        print("  [Scenario 1, seed=\(seed)] invocations=\(result.invocations), shrunk_length=\(result.output.count), original_length=\(result.originalOutput.count)")
    }

    // MARK: - Scenario 2: Bind-dependent range

    @Test("Scenario 2: bind-dependent range", arguments: [
        UInt64(42), UInt64(123), UInt64(999), UInt64(7777), UInt64(31415),
    ])
    func bindDependentRange(seed: UInt64) throws {
        // Inner: pick n from 0...100.
        // Bound: pick m from 0...max(1, n).
        // Property: m < 10.
        let gen = #gen(.int(in: 0 ... 100))
            .bound(
                forward: { n in Gen.int(in: 0 ... max(1, n)) },
                backward: { (m: Int) in m }
            )

        let result = try reduceAndMeasure(gen: gen, seed: seed) { $0 < 10 }
        guard let result else { return }

        print("  [Scenario 2, seed=\(seed)] invocations=\(result.invocations), shrunk=\(result.output), original=\(result.originalOutput)")
    }

    // MARK: - Scenario 3: Zip of two bind generators

    @Test("Scenario 3: zip of two binds", .disabled(), arguments: [
        UInt64(42)//, UInt64(123), UInt64(999), UInt64(7777), UInt64(31415),
    ])
    func zipOfTwoBinds(seed: UInt64) throws {
        ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .human))
        // Two independent bind generators zipped together.
        // Each: inner picks n from 0...50, bound picks m from 0...max(1,n).
        // Property: sum of both bound values < 20.
        let singleBind = #gen(.int(in: 0 ... 50))
            .bound(
                forward: { n in Gen.int(in: 0 ... max(1, n)) },
                backward: { (m: Int) in m }
            )

        let gen = #gen(singleBind, singleBind)
        
        let result = try #require(
            #exhaust(
                gen,
//                .useKleisliReducer,
                .suppressIssueReporting
            ) { pair in
            pair.0 + pair.1 < 20
        })

        #expect(result == (0, 20))
    }

    // MARK: - Scenario 4: Bind with array of bound values

    @Test("Scenario 4: bind producing grouped bound subtree", arguments: [
        UInt64(42), UInt64(123), UInt64(999), UInt64(7777), UInt64(31415),
    ])
    func bindGroupedBound(seed: UInt64) throws {
        // Inner: pick n from 1...30.
        // Bound: group of two values, both from 0...max(1,n).
        // Property: both bound values < 5.
        let gen = #gen(.int(in: 1 ... 30))
            .bound(
                forward: { n in
                    let upper = max(1, n)
                    return Gen.zip(Gen.int(in: 0 ... upper), Gen.int(in: 0 ... upper))
                },
                backward: { (pair: (Int, Int)) in max(pair.0, pair.1) }
            )

        let result = try reduceAndMeasure(gen: gen, seed: seed) { pair in
            pair.0 < 5 && pair.1 < 5
        }
        guard let result else { return }

        let (a, b) = result.output
        let (origA, origB) = result.originalOutput
        print("  [Scenario 4, seed=\(seed)] invocations=\(result.invocations), shrunk=(\(a),\(b)), original=(\(origA),\(origB))")
    }
}

// MARK: - Helpers

private struct MeasuredResult<Output> {
    let invocations: Int
    let output: Output
    let originalOutput: Output
}

private func reduceAndMeasure<Output>(
    gen: ReflectiveGenerator<Output>,
    seed: UInt64,
    property: @escaping (Output) -> Bool,
) throws -> MeasuredResult<Output>? {
    var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed)
    var failingTree: ChoiceTree?
    var failingValue: Output?

    // Find first failing value (try up to 200 generations)
    for _ in 0 ..< 200 {
        guard let (value, tree) = try iterator.next() else { break }
        if property(value) == false {
            failingTree = tree
            failingValue = value
            break
        }
    }

    guard let tree = failingTree, let originalOutput = failingValue else {
        return nil
    }

    var invocationCount = 0
    let countingProperty: (Output) -> Bool = { value in
        invocationCount += 1
        return property(value)
    }

    guard let (_, shrunk) = try Interpreters.reduce(
        gen: gen, tree: tree, config: .fast, property: countingProperty
    ) else {
        return nil
    }

    return MeasuredResult(
        invocations: invocationCount,
        output: shrunk,
        originalOutput: originalOutput
    )
}
