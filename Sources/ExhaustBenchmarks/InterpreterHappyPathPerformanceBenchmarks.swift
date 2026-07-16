// MARK: - Interpreter Happy-Path Performance

//
// Direct interpreter-level benchmarks for the happy path: ValueInterpreter throughput,
// Materializer throughput (screening-row, exact-replay, and fuzz-mutator shapes, including the
// flat-emission and skipTree variants), FuzzMutator operator cost, and the end-to-end fuzz
// mutation loop. Each benchmark performs a fixed amount of work per iteration under a pinned
// seed so ns/iter is directly comparable across builds. These are the fixtures behind the
// numbers in ExhaustDocs/perf-survey-b-2026-07-16.md, which reports them under a "Survey"
// name prefix.

import Benchmark
import Exhaust
import ExhaustCore
import Foundation

private let happyPathStringGen = #gen(.string(length: 1 ... 20))
private let happyPathIntArrayGen = #gen(.int(in: 0 ... 1000).array(length: 0 ... 50))
private let happyPathBigArrayGen = #gen(.int(in: 0 ... 1000).array(length: 400 ... 500))
private let happyPathZipOfArraysGen = #gen(
    .int(in: 0 ... 100).array(length: 0 ... 30),
    .int(in: 0 ... 100).array(length: 0 ... 30),
    .double().array(length: 0 ... 30)
)

/// One generated example: the tree and its flattened sequence, used as materializer input.
private struct HappyPathFixture {
    let tree: ChoiceTree
    let sequence: ChoiceSequence
}

/// A coverage source computing signatures as a pure function of the generated value, so the full search loop runs without instrumentation. Mirrors the test-support SyntheticCoverageSource, which the benchmark target does not depend on.
private final class ValueDerivedCoverageSource<Value>: CoverageSource, @unchecked Sendable {
    let edgeCount: Int

    var wantsValues: Bool {
        true
    }

    private let hitEdges: @Sendable (Value) -> [(edge: Int, hitCount: UInt8)]
    private var currentValue: Value?

    init(edgeCount: Int, hitEdges: @escaping @Sendable (Value) -> [(edge: Int, hitCount: UInt8)]) {
        self.edgeCount = edgeCount
        self.hitEdges = hitEdges
    }

    func beginAttempt() {
        currentValue = nil
    }

    func noteValue(_ value: Any) {
        currentValue = value as? Value
    }

    func forEachHitEdge(_ body: (_ edge: Int, _ hitCount: UInt8) -> Void) {
        guard let currentValue else {
            return
        }
        for (edge, hitCount) in hitEdges(currentValue) {
            body(edge, hitCount)
        }
    }
}

private func makeFixture(_ gen: Generator<some Any>, seed: UInt64, skip: Int = 3) -> HappyPathFixture {
    var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: UInt64(skip) + 1)
    var last: ChoiceTree?
    do {
        while let (_, tree) = try interpreter.next() {
            last = tree
        }
    } catch {
        fatalError("fixture generation failed: \(error)")
    }
    guard let tree = last else {
        fatalError("fixture generation produced no tree")
    }
    return HappyPathFixture(tree: tree, sequence: ChoiceSequence.flatten(tree))
}

func registerInterpreterHappyPathPerformanceBenchmarks() {
    let runsPerIteration: UInt64 = 100

    // MARK: - VI value-only generation

    func registerVI(_ name: String, _ gen: Generator<some Any>) {
        benchmark("VI: \(name)") {
            var interpreter = ValueInterpreter(gen, seed: 1337, maxRuns: runsPerIteration)
            do {
                while try interpreter.next() != nil {}
            } catch {
                fatalError("VI generation failed: \(error)")
            }
        }
    }

    registerVI("scalars (zip8)", mixedCouplingGen.gen)
    registerVI("array+filter (bound5)", bound5Gen.gen)
    registerVI("bind (coupling)", couplingGen.gen)
    registerVI("int array 0...50", happyPathIntArrayGen.gen)
    registerVI("string 1...20", happyPathStringGen.gen)
    registerVI("recursive (binaryHeap)", binaryHeapGenRecursive().gen)
    registerVI("calculator depth 5", calculatorExpressionGen(depth: 5).gen)

    // MARK: - Materializer: screening-row shape (guided, empty prefix, skipTree, no report)

    func registerScreeningRow(_ name: String, _ gen: Generator<some Any>, seed: UInt64) {
        let erased = gen.erase()
        let fixture = makeFixture(gen, seed: seed)
        benchmark("Mat screening: \(name)") {
            for rowIndex in 0 ..< 50 {
                let result = Materializer.materializeAny(
                    erased,
                    prefix: ChoiceSequence(),
                    mode: .guided(seed: UInt64(rowIndex), fallbackTree: nil),
                    fallbackTree: fixture.tree,
                    skipTree: true,
                    collectDecodingReport: false
                )
                guard case .success = result else { continue }
            }
        }
    }

    registerScreeningRow("scalars (zip8)", mixedCouplingGen.gen, seed: 7)
    registerScreeningRow("int array 0...50", happyPathIntArrayGen.gen, seed: 7)
    registerScreeningRow("recursive (binaryHeap)", binaryHeapGenRecursive().gen, seed: 7)

    // MARK: - Materializer: exact replay (normalizer / reduction probe shape)

    func registerExactReplay(_ name: String, _ gen: Generator<some Any>, seed: UInt64) {
        let erased = gen.erase()
        let fixture = makeFixture(gen, seed: seed)
        benchmark("Mat exact: \(name)") {
            for _ in 0 ..< 50 {
                let result = Materializer.materializeAny(
                    erased,
                    prefix: fixture.sequence,
                    mode: .exact,
                    fallbackTree: fixture.tree
                )
                guard case .success = result else { fatalError("exact replay rejected") }
            }
        }
    }

    registerExactReplay("scalars (zip8)", mixedCouplingGen.gen, seed: 7)
    registerExactReplay("int array 0...50", happyPathIntArrayGen.gen, seed: 7)
    registerExactReplay("recursive (binaryHeap)", binaryHeapGenRecursive().gen, seed: 7)
    registerExactReplay("string 1...20", happyPathStringGen.gen, seed: 7)

    // MARK: - Fuzz candidate cycle (mutate + guided materialize + flatten + hash)

    func registerFuzzCycle(_ name: String, _ gen: Generator<some Any>, seed: UInt64) {
        let erased = gen.erase()
        let fixture = makeFixture(gen, seed: seed)
        benchmark("Fuzz cycle: \(name)") {
            var prng = Xoshiro256(seed: 42)
            for _ in 0 ..< 50 {
                let intensityDraw = prng.next(upperBound: 3)
                let intensity = MutationIntensity.allCases[Int(intensityDraw)]
                let candidate = FuzzMutator.mutate(fixture.sequence, intensity: intensity, prng: &prng)
                let result = Materializer.materializeAny(
                    erased,
                    prefix: candidate,
                    mode: .guided(seed: prng.next(), fallbackTree: fixture.tree)
                )
                guard case let .success(_, freshTree, _) = result else { continue }
                let sequence = ChoiceSequence.flatten(freshTree)
                _ = ZobristHash.hash(of: sequence)
            }
        }
    }

    registerFuzzCycle("scalars (zip8)", mixedCouplingGen.gen, seed: 7)
    registerFuzzCycle("int array 0...50", happyPathIntArrayGen.gen, seed: 7)
    registerFuzzCycle("string 1...20", happyPathStringGen.gen, seed: 7)
    registerFuzzCycle("recursive (binaryHeap)", binaryHeapGenRecursive().gen, seed: 7)
    registerFuzzCycle("calculator depth 5", calculatorExpressionGen(depth: 5).gen, seed: 7)

    // MARK: - Fuzz candidate cycle: flat emission (sequence and hash without a tree)

    func registerFuzzCycleFlat(_ name: String, _ gen: Generator<some Any>, seed: UInt64) {
        let erased = gen.erase()
        let fixture = makeFixture(gen, seed: seed)
        benchmark("Fuzz flat: \(name)") {
            var prng = Xoshiro256(seed: 42)
            for _ in 0 ..< 50 {
                let intensityDraw = prng.next(upperBound: 3)
                let intensity = MutationIntensity.allCases[Int(intensityDraw)]
                let candidate = FuzzMutator.mutate(fixture.sequence, intensity: intensity, prng: &prng)
                let result = Materializer.materializeAnyFlat(
                    erased,
                    prefix: candidate,
                    mode: .guided(seed: prng.next(), fallbackTree: fixture.tree)
                )
                guard case let .success(_, sequence, _) = result else { continue }
                _ = ZobristHash.hash(of: sequence)
            }
        }
    }

    registerFuzzCycleFlat("scalars (zip8)", mixedCouplingGen.gen, seed: 7)
    registerFuzzCycleFlat("int array 0...50", happyPathIntArrayGen.gen, seed: 7)
    registerFuzzCycleFlat("string 1...20", happyPathStringGen.gen, seed: 7)
    registerFuzzCycleFlat("recursive (binaryHeap)", binaryHeapGenRecursive().gen, seed: 7)
    registerFuzzCycleFlat("calculator depth 5", calculatorExpressionGen(depth: 5).gen, seed: 7)

    // MARK: - Fuzz candidate cycle ceiling: skipTree phase-1 (no tree, no flatten, no hash)

    func registerFuzzCycleSkipTree(_ name: String, _ gen: Generator<some Any>, seed: UInt64) {
        let erased = gen.erase()
        let fixture = makeFixture(gen, seed: seed)
        benchmark("Fuzz skipTree: \(name)") {
            var prng = Xoshiro256(seed: 42)
            for _ in 0 ..< 50 {
                let intensityDraw = prng.next(upperBound: 3)
                let intensity = MutationIntensity.allCases[Int(intensityDraw)]
                let candidate = FuzzMutator.mutate(fixture.sequence, intensity: intensity, prng: &prng)
                let result = Materializer.materializeAny(
                    erased,
                    prefix: candidate,
                    mode: .guided(seed: prng.next(), fallbackTree: fixture.tree),
                    skipTree: true
                )
                guard case .success = result else { continue }
            }
        }
    }

    registerFuzzCycleSkipTree("scalars (zip8)", mixedCouplingGen.gen, seed: 7)
    registerFuzzCycleSkipTree("int array 0...50", happyPathIntArrayGen.gen, seed: 7)
    registerFuzzCycleSkipTree("string 1...20", happyPathStringGen.gen, seed: 7)
    registerFuzzCycleSkipTree("recursive (binaryHeap)", binaryHeapGenRecursive().gen, seed: 7)
    registerFuzzCycleSkipTree("calculator depth 5", calculatorExpressionGen(depth: 5).gen, seed: 7)

    // Retro-insertion stress: shapes whose pair-group inserts shift large already-emitted spans.
    registerFuzzCycle("int array 400...500", happyPathBigArrayGen.gen, seed: 7)
    registerFuzzCycleFlat("int array 400...500", happyPathBigArrayGen.gen, seed: 7)
    registerFuzzCycleSkipTree("int array 400...500", happyPathBigArrayGen.gen, seed: 7)
    registerFuzzCycle("zip of 3 arrays", happyPathZipOfArraysGen.gen, seed: 7)
    registerFuzzCycleFlat("zip of 3 arrays", happyPathZipOfArraysGen.gen, seed: 7)
    registerFuzzCycleSkipTree("zip of 3 arrays", happyPathZipOfArraysGen.gen, seed: 7)

    // MARK: - End-to-end fuzz mutation loop (no coverage instrumentation, no oracles)

    func registerRunnerLoop(_ name: String, _ gen: ReflectiveGenerator<[Int]>) {
        benchmark("Runner: \(name)") {
            let source = ValueDerivedCoverageSource<[Int]>(edgeCount: 160) { values in
                var edges: [(edge: Int, hitCount: UInt8)] = [(edge: min(values.count, 10), hitCount: 1)]
                for (position, value) in values.prefix(8).enumerated() {
                    edges.append((
                        edge: 11 + position * 10 + abs(value) % 10,
                        hitCount: UInt8(clamping: values.count)
                    ))
                }
                return edges
            }
            let runner = FuzzRunner(
                gen: gen.gen,
                property: { _ in FuzzVerdict.pass },
                source: source,
                configuration: FuzzRunnerConfiguration(
                    budgetNanoseconds: 60_000_000_000,
                    seed: 1337,
                    skipScreening: true,
                    // Sampling consumes ~1100 attempts before its plateau hands over; the high limit makes the mutation phase dominate what this benchmark measures.
                    attemptLimit: 10000
                )
            )
            _ = runner.run()
        }
    }

    registerRunnerLoop("int array 0...50", happyPathIntArrayGen)
    registerRunnerLoop("bind (coupling)", couplingGen)

    // MARK: - Mutator operators in isolation

    let mutatorFixture = makeFixture(happyPathIntArrayGen.gen, seed: 11)
    let heapFixture = makeFixture(binaryHeapGenRecursive().gen, seed: 11)

    benchmark("Mut: low (int array)") {
        var prng = Xoshiro256(seed: 42)
        for _ in 0 ..< 200 {
            _ = FuzzMutator.mutate(mutatorFixture.sequence, intensity: .low, prng: &prng)
        }
    }
    benchmark("Mut: medium (int array)") {
        var prng = Xoshiro256(seed: 42)
        for _ in 0 ..< 200 {
            _ = FuzzMutator.mutate(mutatorFixture.sequence, intensity: .medium, prng: &prng)
        }
    }
    benchmark("Mut: high (int array)") {
        var prng = Xoshiro256(seed: 42)
        for _ in 0 ..< 200 {
            _ = FuzzMutator.mutate(mutatorFixture.sequence, intensity: .high, prng: &prng)
        }
    }
    benchmark("Mut: splice (binaryHeap)") {
        var prng = Xoshiro256(seed: 42)
        for _ in 0 ..< 200 {
            _ = FuzzMutator.splice(recipient: heapFixture.sequence, donor: heapFixture.sequence, prng: &prng)
        }
    }

    // MARK: - Support costs

    benchmark("Support: flatten (binaryHeap)") {
        for _ in 0 ..< 200 {
            _ = ChoiceSequence.flatten(heapFixture.tree)
        }
    }
    benchmark("Support: zobrist hash (binaryHeap)") {
        for _ in 0 ..< 200 {
            _ = ZobristHash.hash(of: heapFixture.sequence)
        }
    }
}
