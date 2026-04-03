// swiftlint:disable file_length function_body_length force_try

import Benchmark
import Exhaust
import ExhaustCore
import Foundation

// MARK: - Configuration

let enableReport = true
let enableCounterExamples = true
private let reductionCount = 100

/// Returns strategy variants of a base config.
private func withStrategies(
    _ base: Interpreters.BonsaiReducerConfiguration = .fast
) -> [(name: String, config: Interpreters.BonsaiReducerConfiguration)] {
    [("adaptive", base)]
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
    registerReverse()
    registerReplacement()
//    registerParser()
}

// MARK: - Bound5

private func registerBound5() {
    let gen = bound5Gen
    let property = bound5Property

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
    let gen = binaryHeapGen(depth: 10).unique()
        .unique()
    let property = binaryHeapProperty

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
    let property = calculatorProperty

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
    let gen = couplingGen
    let property = couplingProperty

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
    let gen = deletionGen
    let property = deletionProperty

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
    let gen = differenceMustNotBeZeroGen
    let property = differenceMustNotBeZeroProperty

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
    let gen = differenceMustNotBeSmallGen
    let property = differenceMustNotBeSmallProperty

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
    let gen = differenceMustNotBeOneGen
    let property = differenceMustNotBeOneProperty

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
    let gen = distinctGen
    let property = distinctProperty

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
    let gen = largeUnionListGen
    let property = largeUnionListProperty

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
    let gen = lengthListGen
    let property = lengthListProperty

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
    let gen = nestedListsGen
    let property = nestedListsProperty

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
    let property = parserProperty

    let failingValues = generateFailingValues(gen: gen, property: property, name: "Parser")
    let coverageFinds = coverageFindsFailure(gen: gen, property: property)
    let iterToFail = measureIterationsToFirstFailure(gen: gen, property: property)

    // ECOOP 2020 comparison: 1000 independent seeds, one failure per seed,
    // matching the methodology from MacIver & Donaldson Figure 13.
    benchmark("Parser ECOOP (adaptive)") {
        let adaptive = Interpreters.BonsaiReducerConfiguration.slow

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
    let gen = replacementGen
    let property = replacementProperty

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
    let gen = reverseGen
    let property = reverseProperty

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

struct ReductionResult {
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
    let minInvocations = invocations.min().map { String(format: "%.0f", $0) } ?? "n/a"
    let maxInvocations = invocations.max().map { String(format: "%.0f", $0) } ?? "n/a"
    let medianTime = String(format: "%.1f", median(times))
    let meanTime = String(format: "%.1f", mean(times))

    let iterDoubles = iterationsToFirstFailure.map { Double($0) }
    let medianIter = String(format: "%.0f", median(iterDoubles))
    let meanIter = String(format: "%.1f", mean(iterDoubles))

    print("[\(name)] invocations: median=\(medianInvocations) mean=\(meanInvocations) min=\(minInvocations) max=\(maxInvocations) | time(ms): median=\(medianTime) mean=\(meanTime) counterexamples=\(uniqueCounterexamples.count) | coverage=\(foundWithCoveringArray) iterToFail: median=\(medianIter) mean=\(meanIter)")
    if enableCounterExamples {
        print("[\(name)] unique counterexamples (\(uniqueCounterexamples.count)):")
        for counterexample in uniqueCounterexamples {
            print("  \(counterexample)")
        }
    }
}

// swiftlint:enable file_length function_body_length force_try
