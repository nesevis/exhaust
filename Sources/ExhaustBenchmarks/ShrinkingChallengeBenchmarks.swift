// swiftlint:disable file_length function_body_length force_try

import Benchmark
@_spi(ExhaustInternal) import Exhaust
import ExhaustCore
import Foundation

// MARK: - Configuration

let enableReport = true
let enableCounterExamples = false
private let reductionCount = 100

/// Returns both strategy variants of a base config.
private func withStrategies(
    _ base: Interpreters.BonsaiReducerConfiguration = .fast
) -> [(name: String, config: Interpreters.BonsaiReducerConfiguration)] {
    var adaptive = base
    adaptive.schedulingStrategy = .adaptive
    // Topological strategy needs more stall budget because each CDG level
    // is a separate scheduler cycle. Use the base config but bump maxStalls
    // to give the level walk and cleanup pass enough room to converge.
    var topological = base
    topological.schedulingStrategy = .topological
    topological.maxStalls = base.maxStalls // max(base.maxStalls, 10)
    return [
        ("adaptive", adaptive),
//        ("topological", topological),
    ]
}

// MARK: - Registration

func registerShrinkingChallengeBenchmarks() {
    registerBound5()
    registerBinaryHeap()
    registerCalculator()
    registerCoupling()
    registerDeletion()
    registerDifferenceMustNotBeZero()
    registerDifferenceMustNotBeSmall()
    registerDifferenceMustNotBeOne()
    registerDistinct()
    registerLargeUnionList()
    registerLengthList()
    registerNestedLists()
    registerReplacement() // Not included
//    registerReverse()
//    registerParser() // Not included
}

// MARK: - Bound5

private func registerBound5() {
    let arrayGen = #gen(.int16(scaling: .constant).array(length: 0 ... 10, scaling: .constant))
        .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
    let gen = #gen(arrayGen, arrayGen, arrayGen, arrayGen, arrayGen) { a, b, c, d, e in
        Bound5(a: a, b: b, c: c, d: d, e: e)
    }

    let property: @Sendable (Bound5) -> Bool = { bound5 in
        if bound5.arr.isEmpty { return true }
        return bound5.arr.dropFirst().reduce(bound5.arr[0], &+) < 5 * 256
    }

    let failingValues = generateFailingValues(gen: gen, property: property, name: "Bound5")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("Bound5 (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "Bound5 (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Binary Heap

private func registerBinaryHeap() {
    let gen = binaryHeapGen(depth: 7)

    let property: @Sendable (Heap<Int>) -> Bool = { heap in
        guard heapInvariant(heap) else { return true }
        let sorted = heapToSortedList(heap)
        let reference = heapToList(heap).sorted()
        return reference == sorted.sorted() && sorted == sorted.sorted()
    }

    let failingPairs = generateFailingPairs(gen: gen, property: property, name: "BinaryHeap")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("BinaryHeap (\(strategy.name))") {
            let results = runNonReflectableBenchmark(
                gen: gen,
                property: property,
                failingPairs: failingPairs,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "BinaryHeap (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Calculator

private func registerCalculator() {
    let gen = #gen(calculatorExpressionGen(depth: 4))

    let property: @Sendable (Expr) -> Bool = { expr in
        guard containsLiteralDivisionByZero(expr) == false else { return true }
        do {
            _ = try evalExpr(expr)
            return true
        } catch {
            return false
        }
    }

    let failingValues = generateFailingValues(gen: gen, property: property, name: "Calculator")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies(.slow) {
        benchmark("Calculator (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "Calculator (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Coupling

private func registerCoupling() {
    let gen = #gen(.int(in: 0 ... 10))
        .bind { n in
            #gen(.int(in: 0 ... n)).array(length: 2 ... max(2, n + 1))
        }
        .filter { arr in arr.allSatisfy { arr.indices.contains($0) } }

    let property: @Sendable ([Int]) -> Bool = { arr in
        arr.indices.allSatisfy { i in
            let j = arr[i]
            if j != i, arr[j] == i {
                return false
            }
            return true
        }
    }

    let failingPairs = generateFailingPairs(gen: gen, property: property, name: "Coupling")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("Coupling (\(strategy.name))") {
            let results = runNonReflectableBenchmark(
                gen: gen,
                property: property,
                failingPairs: failingPairs,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "Coupling (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Deletion

private func registerDeletion() {
    let numberGen = #gen(.int(in: 0 ... 20))
    let gen = #gen(numberGen.array(length: 2 ... 20), numberGen)
        .filter { $0.contains($1) }

    let property: @Sendable (([Int], Int)) -> Bool = { pair in
        var array = pair.0
        let element = pair.1
        guard let index = array.firstIndex(of: element) else { return true }
        array.remove(at: index)
        return array.contains(element) == false
    }

    let failingValues = generateFailingValues(gen: gen, property: property, name: "Deletion")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("Deletion (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "Deletion (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Difference (Must Not Be Zero)

private func registerDifferenceMustNotBeZero() {
    let gen = #gen(.int(in: 1 ... 1000)).array(length: 2)

    let property: @Sendable ([Int]) -> Bool = { arr in
        arr[0] < 10 || arr[0] != arr[1]
    }

    let failingValues = generateFailingValues(
        gen: gen,
        property: property,
        name: "DifferenceMustNotBeZero",
        maxRuns: 500_000
    )
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("Difference: Must Not Be Zero (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "Difference: Must Not Be Zero (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Difference (Must Not Be Small)

private func registerDifferenceMustNotBeSmall() {
    let gen = #gen(.int(in: 1 ... 1000)).array(length: 2)

    let property: @Sendable ([Int]) -> Bool = { arr in
        let diff = abs(arr[0] - arr[1])
        return arr[0] < 10 || diff < 1 || diff > 4
    }

    let failingValues = generateFailingValues(
        gen: gen,
        property: property,
        name: "DifferenceMustNotBeSmall",
        maxRuns: 500_000
    )
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("Difference: Must Not Be Small (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "Difference: Must Not Be Small (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Difference (Must Not Be One)

private func registerDifferenceMustNotBeOne() {
    let gen = #gen(.int(in: 1 ... 1000)).array(length: 2)

    let property: @Sendable ([Int]) -> Bool = { arr in
        let diff = abs(arr[0] - arr[1])
        return arr[0] < 10 || diff != 1
    }

    let failingValues = generateFailingValues(
        gen: gen,
        property: property,
        name: "DifferenceMustNotBeOne",
        maxRuns: 500_000
    )
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("Difference: Must Not Be One (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "Difference: Must Not Be One (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Distinct

private func registerDistinct() {
    let gen = #gen(.int().array(length: 3 ... 30))

    let property: @Sendable ([Int]) -> Bool = { arr in
        Set(arr).count < 3
    }

    let failingValues = generateFailingValues(gen: gen, property: property, name: "Distinct")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("Distinct (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "Distinct (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Large Union List

private func registerLargeUnionList() {
    let gen = #gen(.int().array(length: 1 ... 10).array(length: 1 ... 10))

    let property: @Sendable ([[Int]]) -> Bool = { arr in
        Set(arr.flatMap(\.self)).count <= 4
    }

    let failingValues = generateFailingValues(gen: gen, property: property, name: "LargeUnionList")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("LargeUnionList (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "LargeUnionList (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Length List

private func registerLengthList() {
    let gen: ReflectiveGenerator<[UInt]> = #gen(.uint(in: 0 ... 1000)).array(length: 1 ... 100)

    let property: @Sendable ([UInt]) -> Bool = { arr in
        arr.max() ?? 0 < 900
    }

    let failingValues = generateFailingValues(gen: gen, property: property, name: "LengthList")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("LengthList (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "LengthList (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Nested Lists

private func registerNestedLists() {
    let gen = #gen(.uint().array().array())

    let property: @Sendable ([[UInt]]) -> Bool = { arr in
        arr.map(\.count).reduce(0, +) <= 10
    }

    let failingValues = generateFailingValues(gen: gen, property: property, name: "NestedLists")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("NestedLists (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "NestedLists (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Parser

private func registerParser() {
    let gen = parserLangGen

    let property: @Sendable (ParserLang) -> Bool = { lang in
        parserParse(parserSerialize(lang)) == lang
    }

    let failingValues = generateFailingValues(gen: gen, property: property, name: "Parser")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

//    for strategy in withStrategies() {
//        benchmark("Parser (\(strategy.name))") {
//            let results = runReflectableBenchmark(
//                gen: gen,
//                property: property,
//                failingValues: failingValues,
//                config: strategy.config
//            )
//            if enableReport { printChallengeReport(name: "Parser (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
//        }
//    }

    // ECOOP 2020 comparison: 1000 independent seeds, one failure per seed,
    // matching the methodology from MacIver & Donaldson Figure 13.
    benchmark("Parser ECOOP (adaptive)") {
        var adaptive = Interpreters.BonsaiReducerConfiguration.fast
        adaptive.schedulingStrategy = .adaptive

        let seedCount = 1000
        let baseSeed: UInt64 = 1337
        var sizes: [Int] = []
        var invocations: [Int] = []
        var uniqueCEs = Set<String>()

        for i in 0 ..< seedCount {
            let seed = baseSeed &+ UInt64(i)
            var iterator = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 10_000)

            // Find first failure for this seed.
            var failingValue: ParserLang?
            var failingTree: ChoiceTree?
            do {
                while let (value, tree) = try iterator.next() {
                    if property(value) == false {
                        failingValue = value
                        failingTree = tree
                        break
                    }
                }
            } catch {}
            guard let value = failingValue, let tree = failingTree else { continue }

            // Reflect and reduce.
            var invocationCount = 0
            let countingProperty: (ParserLang) -> Bool = { candidate in
                invocationCount += 1
                return property(candidate)
            }
            let result = try? Interpreters.bonsaiReduce(
                gen: gen,
                tree: tree,
                output: value,
                config: adaptive,
                property: countingProperty
            )
            print("\(seed), \(invocationCount)")
            let output = result?.1 ?? value
            let outputSize = parserSize(output)
            sizes.append(outputSize)
            invocations.append(invocationCount)
            uniqueCEs.insert(String(describing: output))
        }

        guard sizes.isEmpty == false else {
            print("[Parser ECOOP] No failures found")
            return
        }
        let meanSize = Double(sizes.reduce(0, +)) / Double(sizes.count)
        let meanInvoc = Double(invocations.reduce(0, +)) / Double(sizes.count)
        let sortedSizes = sizes.sorted()
        let medianSize = sortedSizes.count % 2 == 0
            ? Double(sortedSizes[sortedSizes.count / 2 - 1] + sortedSizes[sortedSizes.count / 2]) / 2.0
            : Double(sortedSizes[sortedSizes.count / 2])

        // 95% confidence interval for the mean.
        let variance = sizes.map { pow(Double($0) - meanSize, 2) }.reduce(0, +) / Double(sizes.count - 1)
        let stdError = sqrt(variance / Double(sizes.count))
        let ciLow = String(format: "%.2f", meanSize - 1.96 * stdError)
        let ciHigh = String(format: "%.2f", meanSize + 1.96 * stdError)

        print("[Parser ECOOP] seeds=\(sizes.count) mean_size=\(String(format: "%.2f", meanSize)) (\(ciLow)–\(ciHigh)) median_size=\(String(format: "%.1f", medianSize)) mean_invocations=\(String(format: "%.1f", meanInvoc)) unique_CEs=\(uniqueCEs.count)")
        if enableCounterExamples {
            print("[Parser ECOOP] unique counterexamples (\(uniqueCEs.count)):")
            for ce in uniqueCEs.sorted() {
                print("  \(ce)")
            }
        }
    }
}

// MARK: - Replacement

private func registerReplacement() {
    let gen = #gen(.int(in: 0 ... 1_000_000), .int(in: 2 ... 5).array())

    let property: @Sendable ((Int, [Int])) -> Bool = { pair in
        let (initial, multipliers) = pair
        return replacementProds(initial, multipliers).allSatisfy { $0 < 1_000_000 }
    }

    let failingValues = generateFailingValues(gen: gen, property: property, name: "Replacement")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("Replacement (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "Replacement (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Reverse

private func registerReverse() {
    let gen = #gen(.uint()).array(length: 1 ... 1000)

    let property: @Sendable ([UInt]) -> Bool = { arr in
        arr.elementsEqual(arr.reversed())
    }

    let failingValues = generateFailingValues(gen: gen, property: property, name: "Reverse")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    for strategy in withStrategies() {
        benchmark("Reverse (\(strategy.name))") {
            let results = runReflectableBenchmark(
                gen: gen,
                property: property,
                failingValues: failingValues,
                config: strategy.config
            )
            if enableReport { printChallengeReport(name: "Reverse (\(strategy.name))", results: results, foundWithCoveringArray: coverageFinds, iterationsToFirstFailure: iterToFail) }
        }
    }
}

// MARK: - Bound5 Type

struct Bound5: Equatable, CustomStringConvertible {
    let a: [Int16]
    let b: [Int16]
    let c: [Int16]
    let d: [Int16]
    let e: [Int16]
    let arr: [Int16]

    init(a: [Int16], b: [Int16], c: [Int16], d: [Int16], e: [Int16]) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        arr = a + b + c + d + e
    }

    var description: String {
        "Bound5(a: \(a), b: \(b), c: \(c), d: \(d), e: \(e))"
    }
}

// MARK: - Calculator Types

indirect enum Expr: Equatable, CustomDebugStringConvertible, CustomStringConvertible {
    case value(Int)
    case add(Expr, Expr)
    case div(Expr, Expr)

    var intValue: Int? {
        guard case let .value(value) = self else { return nil }
        return value
    }

    var debugDescription: String {
        switch self {
        case let .value(value):
            "value(\(value))"
        case let .add(lhs, rhs):
            "add(\(lhs.debugDescription), \(rhs.debugDescription))"
        case let .div(lhs, rhs):
            "div(\(lhs.debugDescription), \(rhs.debugDescription))"
        }
    }

    var description: String { debugDescription }
}

private enum EvalError: Error {
    case divisionByZero
}

private func evalExpr(_ expr: Expr) throws -> Int {
    switch expr {
    case let .value(value):
        return value
    case let .add(lhs, rhs):
        return try evalExpr(lhs) + evalExpr(rhs)
    case let .div(lhs, rhs):
        let denominator = try evalExpr(rhs)
        guard denominator != 0 else { throw EvalError.divisionByZero }
        return try evalExpr(lhs) / denominator
    }
}

private func containsLiteralDivisionByZero(_ expr: Expr) -> Bool {
    switch expr {
    case .value:
        false
    case let .add(lhs, rhs):
        containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
    case .div(_, .value(0)):
        true
    case let .div(lhs, rhs):
        containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
    }
}

private func calculatorExpressionGen(depth: UInt64) -> ReflectiveGenerator<Expr> {
    let leaf = #gen(.int(in: -10 ... 10, scaling: .constant))
        .mapped(forward: { Expr.value($0) }, backward: { $0.intValue ?? 0 })
    
    let calculator = #gen(.recursive(base: leaf, depthRange: 0 ... depth) { recurse, _ in
        let add = #gen(recurse(), leaf)
            .mapped(
                forward: { lhs, rhs in Expr.add(lhs, rhs) },
                backward: { value in
                    switch value {
                    case let .add(lhs, rhs): (lhs, rhs)
                    case let .div(lhs, rhs): (lhs, rhs)
                    case .value:
                        (value, value)
                    }
                }
            )
        let div = #gen(leaf, recurse())
            .mapped(
                forward: { lhs, rhs in Expr.div(lhs, rhs) },
                backward: { value in
                    switch value {
                    case let .add(lhs, rhs): (lhs, rhs)
                    case let .div(lhs, rhs): (lhs, rhs)
                    case .value:
                        (value, value)
                    }
                }
            )

        return .oneOf(weighted:
            (3, leaf),
            (3, add),
            (3, div))
        
    })
    
    return calculator
}

// MARK: - Binary Heap Types

indirect enum Heap<Element: Comparable>: Equatable {
    case empty
    case node(Element, Heap, Heap)
}

extension Heap: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .empty:
            "None"
        case let .node(value, left, right):
            "(\(value), \(left.debugDescription), \(right.debugDescription))"
        }
    }
}

private func heapToList<Element>(_ heap: Heap<Element>) -> [Element] {
    var queue = [heap]
    var result: [Element] = []
    while queue.isEmpty == false {
        let current = queue.removeFirst()
        switch current {
        case .empty:
            continue
        case let .node(x, h1, h2):
            result.append(x)
            queue.append(h1)
            queue.append(h2)
        }
    }
    return result
}

private func heapToSortedList<Element: Comparable>(_ heap: Heap<Element>) -> [Element] {
    switch heap {
    case .empty:
        []
    case let .node(x, h1, h2):
        [x] + heapToList(heapMerge(h1, h2))
    }
}

private func heapMerge<Element: Comparable>(_ h1: Heap<Element>, _ h2: Heap<Element>) -> Heap<Element> {
    switch (h1, h2) {
    case (_, .empty):
        h1
    case (.empty, _):
        h2
    case let (.node(x, h11, h12), .node(y, h21, h22)):
        if x <= y {
            .node(x, heapMerge(h12, h2), h11)
        } else {
            .node(y, heapMerge(h22, h1), h21)
        }
    }
}

private func heapInvariant(_ heap: Heap<some Comparable>) -> Bool {
    switch heap {
    case .empty:
        true
    case let .node(x, h1, h2):
        heapLte(x, h1) && heapLte(x, h2) && heapInvariant(h1) && heapInvariant(h2)
    }
}

private func heapLte<Element: Comparable>(_ x: Element, _ heap: Heap<Element>) -> Bool {
    switch heap {
    case .empty:
        true
    case let .node(y, _, _):
        x <= y
    }
}

private func binaryHeapGen(min: Int = 0, depth: UInt64) -> ReflectiveGenerator<Heap<Int>> {
    let maxVal = 100
    let emptyGen: ReflectiveGenerator<Heap<Int>> = #gen(.just(.empty))

    guard depth > 0, min <= maxVal else {
        return emptyGen
    }

    let nodeGen = #gen(.int(in: min ... maxVal))
        .bind { value in
            #gen(
                binaryHeapGen(min: value, depth: depth / 2),
                binaryHeapGen(min: value, depth: depth / 2)
            )
            .mapped(
                forward: { left, right in Heap.node(value, left, right) },
                backward: { heap in
                    switch heap {
                    case let .node(_, left, right): (left, right)
                    case .empty: (.empty, .empty)
                    }
                }
            )
        }

    return #gen(.oneOf(weighted: (1, emptyGen), (7, nodeGen)))
}

// MARK: - Parser Types

struct ParserLang: Equatable, CustomDebugStringConvertible {
    let modules: [ParserMod]
    let funcs: [ParserFunc]
    var debugDescription: String { "Lang(\(modules), \(funcs))" }
}

struct ParserMod: Equatable, CustomDebugStringConvertible {
    let imports: [ParserVar]
    let exports: [ParserVar]
    var debugDescription: String { "Mod(\(imports), \(exports))" }
}

struct ParserFunc: Equatable, CustomDebugStringConvertible {
    let name: ParserVar
    let args: [ParserExp]
    let body: [ParserStmt]
    var debugDescription: String { "Func(\(name), \(args), \(body))" }
}

enum ParserStmt: Equatable, CustomDebugStringConvertible {
    case assign(ParserVar, ParserExp)
    case alloc(ParserVar, ParserExp)
    case ret(ParserExp)
    var debugDescription: String {
        switch self {
        case let .assign(variable, expression): "Assign(\(variable), \(expression))"
        case let .alloc(variable, expression): "Alloc(\(variable), \(expression))"
        case let .ret(expression): "Return(\(expression))"
        }
    }
}

indirect enum ParserExp: Equatable, CustomDebugStringConvertible {
    case int(Int)
    case bool(Bool)
    case add(ParserExp, ParserExp)
    case sub(ParserExp, ParserExp)
    case mul(ParserExp, ParserExp)
    case div(ParserExp, ParserExp)
    case not(ParserExp)
    case and(ParserExp, ParserExp)
    case or(ParserExp, ParserExp)
    var debugDescription: String {
        switch self {
        case let .int(value): "Int(\(value))"
        case let .bool(value): "Bool(\(value))"
        case let .add(lhs, rhs): "Add(\(lhs), \(rhs))"
        case let .sub(lhs, rhs): "Sub(\(lhs), \(rhs))"
        case let .mul(lhs, rhs): "Mul(\(lhs), \(rhs))"
        case let .div(lhs, rhs): "Div(\(lhs), \(rhs))"
        case let .not(inner): "Not(\(inner))"
        case let .and(lhs, rhs): "And(\(lhs), \(rhs))"
        case let .or(lhs, rhs): "Or(\(lhs), \(rhs))"
        }
    }
}

struct ParserVar: Equatable, CustomDebugStringConvertible {
    let name: String
    var debugDescription: String { name }
}

// MARK: - Parser Serializer

private func parserSerialize(_ lang: ParserLang) -> String {
    let mods = lang.modules.map { parserSerialize($0) }.joined(separator: ";")
    let fns = lang.funcs.map { parserSerialize($0) }.joined(separator: ";")
    return "Lang (\(mods)) (\(fns))"
}

private func parserSerialize(_ mod: ParserMod) -> String {
    let imps = mod.imports.map(\.name).joined(separator: ":")
    let exps = mod.exports.map(\.name).joined(separator: ":")
    return "Mod (\(imps)) (\(exps))"
}

private func parserSerialize(_ function: ParserFunc) -> String {
    let args = function.args.map { parserSerialize($0) }.joined(separator: ",")
    let stmts = function.body.map { parserSerialize($0) }.joined(separator: ",")
    return "Func \(function.name.name) (\(args)) (\(stmts))"
}

private func parserSerialize(_ stmt: ParserStmt) -> String {
    switch stmt {
    case let .assign(variable, expression):
        "Assign \(variable.name) (\(parserSerialize(expression)))"
    case let .alloc(variable, expression):
        "Alloc \(variable.name) (\(parserSerialize(expression)))"
    case let .ret(expression):
        "Return (\(parserSerialize(expression)))"
    }
}

private func parserSerialize(_ expression: ParserExp) -> String {
    switch expression {
    case let .int(value): "Int \(value)"
    case let .bool(value): "Bool \(value)"
    case let .add(lhs, rhs): "Add (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    case let .sub(lhs, rhs): "Sub (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    case let .mul(lhs, rhs): "Mul (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    case let .div(lhs, rhs): "Div (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    case let .not(inner): "Not (\(parserSerialize(inner)))"
    case let .and(lhs, rhs): "And (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    case let .or(lhs, rhs): "Or (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    }
}

// MARK: - Parser (with bugs)

private func parserParse(_ input: String) -> ParserLang? {
    var cursor = input[...]
    return parserParseLang(&cursor)
}

private func parserParseLang(_ cursor: inout Substring) -> ParserLang? {
    guard parserConsume("Lang", from: &cursor) else { return nil }
    guard let modsStr = parserParseParenGroup(&cursor) else { return nil }
    guard let funcsStr = parserParseParenGroup(&cursor) else { return nil }
    let mods = parserParseSemicolonSeparated(modsStr) { parserParseMod(&$0) }
    let fns = parserParseSemicolonSeparated(funcsStr) { parserParseFunc(&$0) }
    return ParserLang(modules: mods, funcs: fns)
}

private func parserParseMod(_ cursor: inout Substring) -> ParserMod? {
    guard parserConsume("Mod", from: &cursor) else { return nil }
    guard let impsStr = parserParseParenGroup(&cursor) else { return nil }
    guard let expsStr = parserParseParenGroup(&cursor) else { return nil }
    let imps = parserParseColonSeparated(impsStr).map { ParserVar(name: String($0)) }
    let exps = parserParseColonSeparated(expsStr).map { ParserVar(name: String($0)) }
    return ParserMod(imports: imps, exports: exps)
}

private func parserParseFunc(_ cursor: inout Substring) -> ParserFunc? {
    guard parserConsume("Func", from: &cursor) else { return nil }
    parserSkipSpaces(&cursor)
    guard let name = parserParseWord(&cursor) else { return nil }
    guard let argsStr = parserParseParenGroup(&cursor) else { return nil }
    guard let stmtsStr = parserParseParenGroup(&cursor) else { return nil }
    let args = parserParseCommaSeparated(argsStr) { parserParseExp(&$0) }
    let stmts = parserParseCommaSeparated(stmtsStr) { parserParseStmt(&$0) }
    return ParserFunc(name: ParserVar(name: String(name)), args: args, body: stmts)
}

private func parserParseStmt(_ cursor: inout Substring) -> ParserStmt? {
    parserSkipSpaces(&cursor)
    if parserConsume("Assign", from: &cursor) {
        parserSkipSpaces(&cursor)
        guard let name = parserParseWord(&cursor) else { return nil }
        guard let expStr = parserParseParenGroup(&cursor) else { return nil }
        var expCursor = expStr
        guard let expression = parserParseExp(&expCursor) else { return nil }
        return .assign(ParserVar(name: String(name)), expression)
    } else if parserConsume("Alloc", from: &cursor) {
        parserSkipSpaces(&cursor)
        guard let name = parserParseWord(&cursor) else { return nil }
        guard let expStr = parserParseParenGroup(&cursor) else { return nil }
        var expCursor = expStr
        guard let expression = parserParseExp(&expCursor) else { return nil }
        return .alloc(ParserVar(name: String(name)), expression)
    } else if parserConsume("Return", from: &cursor) {
        guard let expStr = parserParseParenGroup(&cursor) else { return nil }
        var expCursor = expStr
        guard let expression = parserParseExp(&expCursor) else { return nil }
        return .ret(expression)
    }
    return nil
}

private func parserParseExp(_ cursor: inout Substring) -> ParserExp? {
    parserSkipSpaces(&cursor)
    if parserConsume("Int", from: &cursor) {
        parserSkipSpaces(&cursor)
        guard let value = parserParseInt(&cursor) else { return nil }
        return .int(value)
    } else if parserConsume("Bool", from: &cursor) {
        parserSkipSpaces(&cursor)
        if parserConsume("true", from: &cursor) { return .bool(true) }
        if parserConsume("false", from: &cursor) { return .bool(false) }
        return nil
    } else if parserConsume("Add", from: &cursor) {
        return parserParseBinaryExp(&cursor) { .add($0, $1) }
    } else if parserConsume("Sub", from: &cursor) {
        return parserParseBinaryExp(&cursor) { .sub($0, $1) }
    } else if parserConsume("Mul", from: &cursor) {
        return parserParseBinaryExp(&cursor) { .mul($0, $1) }
    } else if parserConsume("Div", from: &cursor) {
        return parserParseBinaryExp(&cursor) { .div($0, $1) }
    } else if parserConsume("Not", from: &cursor) {
        guard let innerStr = parserParseParenGroup(&cursor) else { return nil }
        var innerCursor = innerStr
        guard let inner = parserParseExp(&innerCursor) else { return nil }
        return .not(inner)
    } else if parserConsume("And", from: &cursor) {
        // BUG 1: operands are swapped
        return parserParseBinaryExp(&cursor) { lhs, rhs in .and(rhs, lhs) }
    } else if parserConsume("Or", from: &cursor) {
        // BUG 2: parsed as And with swapped operands
        return parserParseBinaryExp(&cursor) { lhs, rhs in .and(rhs, lhs) }
    }
    return nil
}

private func parserParseBinaryExp(
    _ cursor: inout Substring,
    constructor: (ParserExp, ParserExp) -> ParserExp
) -> ParserExp? {
    guard let lhsStr = parserParseParenGroup(&cursor) else { return nil }
    guard let rhsStr = parserParseParenGroup(&cursor) else { return nil }
    var lhsCursor = lhsStr
    var rhsCursor = rhsStr
    guard let lhs = parserParseExp(&lhsCursor) else { return nil }
    guard let rhs = parserParseExp(&rhsCursor) else { return nil }
    return constructor(lhs, rhs)
}

private func parserSkipSpaces(_ cursor: inout Substring) {
    cursor = cursor.drop(while: { $0 == " " })
}

private func parserConsume(_ prefix: String, from cursor: inout Substring) -> Bool {
    parserSkipSpaces(&cursor)
    if cursor.hasPrefix(prefix) {
        cursor = cursor.dropFirst(prefix.count)
        return true
    }
    return false
}

private func parserParseWord(_ cursor: inout Substring) -> Substring? {
    let word = cursor.prefix(while: { $0.isLetter || $0.isNumber })
    guard word.isEmpty == false else { return nil }
    cursor = cursor.dropFirst(word.count)
    return word
}

private func parserParseInt(_ cursor: inout Substring) -> Int? {
    var numStr = ""
    if cursor.first == "-" {
        numStr.append("-")
        cursor = cursor.dropFirst()
    }
    let digits = cursor.prefix(while: { $0.isNumber })
    guard digits.isEmpty == false else { return nil }
    numStr.append(contentsOf: digits)
    cursor = cursor.dropFirst(digits.count)
    return Int(numStr)
}

private func parserParseParenGroup(_ cursor: inout Substring) -> Substring? {
    parserSkipSpaces(&cursor)
    guard cursor.first == "(" else { return nil }
    cursor = cursor.dropFirst()
    var depth = 1
    var endIndex = cursor.startIndex
    while endIndex < cursor.endIndex {
        if cursor[endIndex] == "(" {
            depth += 1
        } else if cursor[endIndex] == ")" {
            depth -= 1
            if depth == 0 {
                let content = cursor[cursor.startIndex ..< endIndex]
                cursor = cursor[cursor.index(after: endIndex)...]
                return content
            }
        }
        endIndex = cursor.index(after: endIndex)
    }
    return nil
}

private func parserParseSemicolonSeparated<Result>(
    _ input: Substring,
    parser: (inout Substring) -> Result?
) -> [Result] {
    guard input.isEmpty == false else { return [] }
    return input.split(separator: ";").compactMap { part in
        var cursor = part[...]
        return parser(&cursor)
    }
}

private func parserParseCommaSeparated<Result>(
    _ input: Substring,
    parser: (inout Substring) -> Result?
) -> [Result] {
    guard input.isEmpty == false else { return [] }
    return parserSplitTopLevel(input, separator: ",").compactMap { part in
        var cursor = part[...]
        return parser(&cursor)
    }
}

private func parserParseColonSeparated(_ input: Substring) -> [Substring] {
    guard input.isEmpty == false else { return [] }
    return input.split(separator: ":")
}

private func parserSplitTopLevel(_ input: Substring, separator: Character) -> [Substring] {
    var results: [Substring] = []
    var depth = 0
    var start = input.startIndex
    var index = input.startIndex
    while index < input.endIndex {
        let character = input[index]
        if character == "(" {
            depth += 1
        } else if character == ")" {
            depth -= 1
        } else if character == separator, depth == 0 {
            results.append(input[start ..< index])
            start = input.index(after: index)
        }
        index = input.index(after: index)
    }
    results.append(input[start ..< input.endIndex])
    return results
}

// MARK: - Parser Size Metric (matches SmartCheck/Hypothesis Support.hs)

private func parserSize(_ lang: ParserLang) -> Int {
    lang.modules.map { parserSize($0) }.reduce(0, +)
        + lang.funcs.map { parserSize($0) }.reduce(0, +)
}

private func parserSize(_ mod: ParserMod) -> Int {
    mod.imports.count + mod.exports.count
}

private func parserSize(_ function: ParserFunc) -> Int {
    function.args.map { parserSize($0) }.reduce(0, +)
        + function.body.map { parserSize($0) }.reduce(0, +)
}

private func parserSize(_ stmt: ParserStmt) -> Int {
    switch stmt {
    case let .assign(_, expression): 1 + parserSize(expression)
    case let .alloc(_, expression): 1 + parserSize(expression)
    case let .ret(expression): 1 + parserSize(expression)
    }
}

private func parserSize(_ expression: ParserExp) -> Int {
    switch expression {
    case .int, .bool: 1
    case let .not(inner): 1 + parserSize(inner)
    case let .add(lhs, rhs), let .sub(lhs, rhs),
         let .mul(lhs, rhs), let .div(lhs, rhs),
         let .and(lhs, rhs), let .or(lhs, rhs):
        1 + parserSize(lhs) + parserSize(rhs)
    }
}

// MARK: - Parser Generators

private var parserVarGen: ReflectiveGenerator<ParserVar> {
    #gen(.int(in: 0 ... 25))
        .mapped(
            forward: { ParserVar(name: String(Character(UnicodeScalar(UInt8(97 + $0))))) },
            backward: { Int($0.name.first?.asciiValue ?? 97) - 97 }
        )
}

private func parserExpGen(depth: UInt64) -> ReflectiveGenerator<ParserExp> {
    let intLeaf = #gen(.int(in: -10 ... 10))
        .mapped(
            forward: { ParserExp.int($0) },
            backward: { if case let .int(inner) = $0 { return inner }; return 0 }
        )
    let boolLeaf = #gen(.bool())
        .mapped(
            forward: { ParserExp.bool($0) },
            backward: { if case let .bool(inner) = $0 { return inner }; return false }
        )

    guard depth > 0 else {
        return #gen(.oneOf(weighted: (1, intLeaf), (1, boolLeaf)))
    }

    let child = parserExpGen(depth: depth - 1)

    let notExp = #gen(child)
        .mapped(
            forward: { ParserExp.not($0) },
            backward: { if case let .not(inner) = $0 { return inner }; return .int(0) }
        )

    func binaryExp(
        _ constructor: @Sendable @escaping (ParserExp, ParserExp) -> ParserExp,
        _ destructor: @Sendable @escaping (ParserExp) -> (ParserExp, ParserExp)?
    ) -> ReflectiveGenerator<ParserExp> {
        #gen(child, child)
            .mapped(
                forward: { lhs, rhs in constructor(lhs, rhs) },
                backward: { value in destructor(value) ?? (.int(0), .int(0)) }
            )
    }

    let addExp = binaryExp(ParserExp.add) {
        guard case let .add(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }
    let subExp = binaryExp(ParserExp.sub) {
        guard case let .sub(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }
    let mulExp = binaryExp(ParserExp.mul) {
        guard case let .mul(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }
    let divExp = binaryExp(ParserExp.div) {
        guard case let .div(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }
    let andExp = binaryExp(ParserExp.and) {
        guard case let .and(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }
    let orExp = binaryExp(ParserExp.or) {
        guard case let .or(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }

    return #gen(.oneOf(weighted:
        (3, intLeaf),
        (3, boolLeaf),
        (1, notExp),
        (10, addExp),
        (10, subExp),
        (10, mulExp),
        (10, divExp),
        (10, andExp),
        (10, orExp)))
}

private var parserStmtGen: ReflectiveGenerator<ParserStmt> {
    let assignGen = #gen(parserVarGen, parserExpGen(depth: 3))
        .mapped(
            forward: { variable, expression in ParserStmt.assign(variable, expression) },
            backward: { stmt in
                if case let .assign(variable, expression) = stmt { return (variable, expression) }
                return (ParserVar(name: "a"), .int(0))
            }
        )
    let allocGen = #gen(parserVarGen, parserExpGen(depth: 3))
        .mapped(
            forward: { variable, expression in ParserStmt.alloc(variable, expression) },
            backward: { stmt in
                if case let .alloc(variable, expression) = stmt { return (variable, expression) }
                return (ParserVar(name: "a"), .int(0))
            }
        )
    let retGen = #gen(parserExpGen(depth: 3))
        .mapped(
            forward: { ParserStmt.ret($0) },
            backward: { stmt in
                if case let .ret(expression) = stmt { return expression }
                return .int(0)
            }
        )
    return #gen(.oneOf(weighted: (1, assignGen), (1, allocGen), (1, retGen)))
}

private var parserFuncGen: ReflectiveGenerator<ParserFunc> {
    #gen(parserVarGen, parserExpGen(depth: 3).array(length: 0 ... 3), parserStmtGen.array(length: 0 ... 3))
        .mapped(
            forward: { name, args, body in ParserFunc(name: name, args: args, body: body) },
            backward: { function in (function.name, function.args, function.body) }
        )
}

private var parserModGen: ReflectiveGenerator<ParserMod> {
    #gen(parserVarGen.array(length: 0 ... 3), parserVarGen.array(length: 0 ... 3))
        .mapped(
            forward: { imports, exports in ParserMod(imports: imports, exports: exports) },
            backward: { mod in (mod.imports, mod.exports) }
        )
}

private var parserLangGen: ReflectiveGenerator<ParserLang> {
    #gen(parserModGen.array(length: 0 ... 2), parserFuncGen.array(length: 0 ... 2))
        .mapped(
            forward: { modules, funcs in ParserLang(modules: modules, funcs: funcs) },
            backward: { lang in (lang.modules, lang.funcs) }
        )
}

// MARK: - Replacement Helpers

private func replacementProds(_ initial: Int, _ multipliers: [Int]) -> [Int] {
    var result = [initial]
    var running = initial
    for multiplier in multipliers {
        let (product, overflow) = running.multipliedReportingOverflow(by: multiplier)
        running = overflow ? Int.max : product
        result.append(running)
    }
    return result
}

// MARK: - Benchmark Runners

private func runReflectableBenchmark<Output>(
    gen: ReflectiveGenerator<Output>,
    property: @Sendable @escaping (Output) -> Bool,
    failingValues: [Output],
    config: Interpreters.BonsaiReducerConfiguration = .fast
) -> [ReductionResult] {
    var results: [ReductionResult] = []
    var seenCEs = Set<String>()
    for value in failingValues {
        guard let tree = try? Interpreters.reflect(gen, with: value) else {
            continue
        }
        var isTargetValue = value as? Expr == Expr.div(.value(0), .add(.value(-10), .value(10)))
        var invocationCount = 0
        let countingProperty: (Output) -> Bool = { candidate in
            invocationCount += 1
//            if isTargetValue {
//                print("Attempt: \(candidate)")
//            }
            return property(candidate)
        }
        var output: Output?
        let startTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
//        if isTargetValue {
//            ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .human))
//        } else {
//            ExhaustLog.setConfiguration(.init(isEnabled: false, minimumLevel: .error, categoryMinimumLevels: [.reducer: .error], format: .human))
//        }
        let result = try? Interpreters.bonsaiReduce(
            gen: gen,
            tree: tree,
            output: value,
            config: config,
            property: countingProperty
        )
        let endTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        output = result?.1
        let milliseconds = Double(endTime - startTime) / 1_000_000.0
        let description = output.map { String(describing: $0) } ?? String(describing: value)
        if enableCounterExamples, seenCEs.insert(description).inserted {
            print("  (\(String(describing: value)) -> \(description))")
        }
        results.append(ReductionResult(
            propertyInvocations: invocationCount,
            reductionMilliseconds: milliseconds,
            counterexampleDescription: description
        ))
    }
    return results
}

private func runNonReflectableBenchmark<Output>(
    gen: ReflectiveGenerator<Output>,
    property: @Sendable @escaping (Output) -> Bool,
    failingPairs: [(value: Output, tree: ChoiceTree)],
    config: Interpreters.BonsaiReducerConfiguration = .fast
) -> [ReductionResult] {
    var results: [ReductionResult] = []
    var seenCEs = Set<String>()
    for (value, tree) in failingPairs {
        var invocationCount = 0
        let countingProperty: (Output) -> Bool = { candidate in
            invocationCount += 1
            return property(candidate)
        }
        var output: Output?
        let startTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let result = try? Interpreters.bonsaiReduce(
            gen: gen,
            tree: tree,
            output: value,
            config: config,
            property: countingProperty
        )
        let endTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        output = result?.1
        let milliseconds = Double(endTime - startTime) / 1_000_000.0
        let description = output.map { String(describing: $0) } ?? String(describing: value)
        if enableCounterExamples, seenCEs.insert(description).inserted {
            print("  (\(String(describing: value)) -> \(description))")
        }
        results.append(ReductionResult(
            propertyInvocations: invocationCount,
            reductionMilliseconds: milliseconds,
            counterexampleDescription: description
        ))
    }
    return results
}

// MARK: - Pre-Generation Helpers

private func generateFailingValues<Output>(
    gen: ReflectiveGenerator<Output>,
    property: @Sendable @escaping (Output) -> Bool,
    name: String,
    maxRuns: UInt64 = 1_000_000
) -> [Output] {
    var values: [Output] = []
    var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 1337, maxRuns: maxRuns)
    do {
        while let (value, _) = try iterator.next(), values.count < reductionCount {
            if property(value) == false {
                values.append(value)
            }
        }
    } catch {
        print("WARNING: \(name): generation stopped with error: \(error)")
    }
    if values.count < reductionCount {
        print("WARNING: \(name): expected \(reductionCount) failing values but only generated \(values.count)")
    }
    return values
}

private func generateFailingPairs<Output>(
    gen: ReflectiveGenerator<Output>,
    property: @Sendable @escaping (Output) -> Bool,
    name: String,
    maxRuns: UInt64 = 1_000_000
) -> [(value: Output, tree: ChoiceTree)] {
    var pairs: [(value: Output, tree: ChoiceTree)] = []
    var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 1337, maxRuns: maxRuns)
    do {
        while let (value, tree) = try iterator.next(), pairs.count < reductionCount {
            if property(value) == false {
                pairs.append((value, tree))
            }
        }
    } catch {
        print("WARNING: \(name): generation stopped with error: \(error)")
    }
    if pairs.count < reductionCount {
        print("WARNING: \(name): expected \(reductionCount) failing pairs but only generated \(pairs.count)")
    }
    return pairs
}

// MARK: - Generation Metrics

private func coverageFindsFailure<Output>(
    gen: ReflectiveGenerator<Output>,
    property: @escaping (Output) -> Bool
) -> Bool {
    let result = CoverageRunner.run(gen, coverageBudget: 200, property: property)
    if case .failure = result { return true }
    return false
}

private func measureIterationsToFirstFailure<Output>(
    gen: ReflectiveGenerator<Output>,
    property: @escaping (Output) -> Bool,
    seeds: Int = 100,
    maxIterations: UInt64 = 500
) -> [Int] {
    var counts: [Int] = []
    for seed in 0 ..< seeds {
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: UInt64(seed), maxRuns: maxIterations)
        var iteration = 0
        var found = false
        do {
            while let (value, _) = try iterator.next() {
                iteration += 1
                if property(value) == false {
                    found = true
                    break
                }
            }
        } catch {}
        counts.append(found ? iteration : Int(maxIterations))
    }
    return counts
}

// MARK: - Reporting Infrastructure

private struct ReductionResult {
    let propertyInvocations: Int
    let reductionMilliseconds: Double
    let counterexampleDescription: String
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let count = sorted.count
    guard count > 0 else { return 0 }
    if count % 2 == 0 {
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
    }
    return sorted[count / 2]
}

private func mean(_ values: [Double]) -> Double {
    guard values.isEmpty == false else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

private func printChallengeReport(
    name: String,
    results: [ReductionResult],
    foundWithCoveringArray: Bool,
    iterationsToFirstFailure: [Int]
) {
    let invocations = results.map { Double($0.propertyInvocations) }
    let times = results.map { $0.reductionMilliseconds }
    let uniqueCounterexamples = Set(results.map(\.counterexampleDescription)).sorted()

    let medianInvocations = String(format: "%.1f", median(invocations))
    let meanInvocations = String(format: "%.1f", mean(invocations))
    let medianTime = String(format: "%.1f", median(times))
    let meanTime = String(format: "%.1f", mean(times))

    let iterDoubles = iterationsToFirstFailure.map { Double($0) }
    let medianIter = String(format: "%.0f", median(iterDoubles))
    let meanIter = String(format: "%.1f", mean(iterDoubles))

    print("[\(name)] invocations: median=\(medianInvocations) mean=\(meanInvocations) | time(ms): median=\(medianTime) mean=\(meanTime) counterexamples=\(uniqueCounterexamples.count) | coverage=\(foundWithCoveringArray) iterToFail: median=\(medianIter) mean=\(meanIter)")
    if enableCounterExamples {
        print("[\(name)] unique counterexamples (\(uniqueCounterexamples.count)):")
        for counterexample in uniqueCounterexamples {
            print("  \(counterexample)")
        }
    }
}

// swiftlint:enable file_length function_body_length force_try
