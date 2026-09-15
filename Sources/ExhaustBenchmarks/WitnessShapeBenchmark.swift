// Synthetic witness-shape benchmark: does the mutator reach a shape a particular operator was built for, and how soon.
//
// Each shape is a generator with a property that fails only on one structural configuration the generator does not draw by chance in the budget, with a synthetic coverage source that gives the search a gradient the way an instrumented SUT would. The measure is attempts to the first witness over a fixed set of seeds, so the result is a distribution rather than one trajectory's luck. Configuration knobs are read from the environment by `FuzzTunables`, so a comparison is one process per configuration; the call in `main.swift` selects it.

import ExhaustCore
import Foundation

/// Runs the four shapes over `seeds` consecutive seeds starting at `seedOffset`, each search bounded by `budgetSeconds`, and prints attempts to the first witness per shape. `only` restricts the run to one shape by name. The mutation configuration is whatever the tunables say, so a comparison is one process per configuration.
func runWitnessShapeBenchmark(seeds: Int = 24, seedOffset: Int = 0, budgetSeconds: Double = 4, only: String? = nil) {
    print("witness shapes: seeds=\(seeds) offset=\(seedOffset) budget=\(budgetSeconds)s enumeration=\(FuzzTunables.smallDomainEnumerationEnabled) transplant=\(FuzzTunables.elementTransplantEnabled)")
    if only == nil || only == "mirror" {
        measure(name: "mirror", gen: mirrorGen, seeds: seeds, seedOffset: seedOffset, budgetSeconds: budgetSeconds, edgeCount: 96, hitEdges: mirrorEdges) { value in
            value.first.ops == value.second.ops && value.first.ops.count == 4 && value.first.regs == value.second.regs && value.first.regs.count >= 2 && value.first.pc >= 2 ? .fail(.returnedFalse) : .pass
        }
    }
    if only == nil || only == "twins" {
        measure(name: "twins", gen: termGen, seeds: seeds, seedOffset: seedOffset, budgetSeconds: budgetSeconds, edgeCount: 64, hitEdges: termEdges) { term in
            term.hasIdenticalSiblings(minimumDepth: 3) ? .fail(.returnedFalse) : .pass
        }
    }
    if only == nil || only == "cousins" {
        measure(name: "cousins", gen: termGen, seeds: seeds, seedOffset: seedOffset, budgetSeconds: budgetSeconds, edgeCount: 64, hitEdges: termEdges) { term in
            term.hasCousinCopy(minimumDepth: 2) ? .fail(.returnedFalse) : .pass
        }
    }
    if only == nil || only == "transplant" {
        measure(name: "transplant", gen: listsGen, seeds: seeds, seedOffset: seedOffset, budgetSeconds: budgetSeconds, edgeCount: 80, hitEdges: listsEdges) { lists in
            lists.first.count >= 4 && lists.second.count > lists.first.count && lists.second.containsRun(lists.first) ? .fail(.returnedFalse) : .pass
        }
    }
}

// MARK: - Measurement

/// One seed's run: attempts to the first witness (nil when none in budget), search seconds, evaluations, and whether the run reached the mutation phase.
private struct SeedOutcome {
    var attempts: Int?
    var seconds: Double
    var evaluations: Int
    var inMutation: Bool
}

private func measure<Output: Hashable & Sendable>(
    name: String,
    gen: Generator<Output>,
    seeds: Int,
    seedOffset: Int,
    budgetSeconds: Double,
    edgeCount: Int,
    hitEdges: @escaping @Sendable (Output) -> [(edge: Int, hitCount: UInt8)],
    property: @escaping @Sendable (Output) -> FuzzVerdict
) {
    // Every seed is an independent run, so they go across cores; results are gathered under a lock and the summary is order-free.
    nonisolated(unsafe) var outcomes = [SeedOutcome?](repeating: nil, count: seeds)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: seeds) { index in
        let seed = index + 1
        var configuration = FuzzRunnerConfiguration(
            budgetNanoseconds: UInt64(budgetSeconds * 1e9),
            seed: UInt64(seed + seedOffset),
            skipScreening: true,
            experiments: .shipped
        )
        configuration.stopOnFirstFault = true
        let runner = FuzzRunner(
            gen: gen,
            property: property,
            source: SyntheticCoverageSource<Output>(edgeCount: edgeCount, hitEdges: hitEdges),
            configuration: configuration
        )
        let result = runner.run()
        let outcome = SeedOutcome(
            attempts: result.clusters.isEmpty ? nil : result.attemptsAtFirstFault,
            seconds: Double(result.searchNanoseconds) / 1e9,
            evaluations: result.counts.totalAttempts,
            inMutation: result.counts.mutationAttempts > 0
        )
        lock.lock()
        outcomes[index] = outcome
        lock.unlock()
    }
    var attempts: [Int] = []
    var seconds: [Double] = []
    var evaluations = 0
    var elapsedTotal = 0.0
    var mutationSolves = 0
    for outcome in outcomes.compactMap({ $0 }) {
        elapsedTotal += outcome.seconds
        evaluations += outcome.evaluations
        if let found = outcome.attempts {
            attempts.append(found)
            seconds.append(outcome.seconds)
            if outcome.inMutation { mutationSolves += 1 }
        }
    }
    let sortedAttempts = attempts.sorted()
    let median = sortedAttempts.isEmpty ? "-" : "\(sortedAttempts[sortedAttempts.count / 2])"
    let medianSeconds = seconds.isEmpty ? "-" : String(format: "%.2f", seconds.sorted()[seconds.count / 2])
    print("\(name): solved=\(attempts.count)/\(seeds) inMutation=\(mutationSolves) medianAttempts=\(median) medianSeconds=\(medianSeconds) attempts=\(sortedAttempts) evals/s=\(Int(Double(evaluations) / max(elapsedTotal, 0.001)))")
}

// MARK: - Shape: mirrored composite

/// An instruction with one of four opcodes and two small operands, from one pick site.
enum WitnessOp: Hashable, Sendable {
    case a(UInt64, UInt64)
    case b(UInt64, UInt64)
    case c(UInt64, UInt64)
    case d(UInt64, UInt64)
}

struct WitnessState: Hashable, Sendable {
    var ops: [WitnessOp]
    var regs: [UInt64]
    var pc: UInt64
}

struct WitnessMirror: Hashable, Sendable {
    var observer: UInt64
    var first: WitnessState
    var second: WitnessState
}

private let operand: Generator<UInt64> = Gen.choose(in: UInt64(0) ... 7)

private let opGen: Generator<WitnessOp> = Gen.pick(choices: [
    (1, Gen.zip(operand, operand).map { WitnessOp.a($0, $1) }),
    (1, Gen.zip(operand, operand).map { WitnessOp.b($0, $1) }),
    (1, Gen.zip(operand, operand).map { WitnessOp.c($0, $1) }),
    (1, Gen.zip(operand, operand).map { WitnessOp.d($0, $1) }),
])

private let stateGen: Generator<WitnessState> = Gen.zip(
    Gen.arrayOf(opGen, within: 0 ... 4, scaling: .constant),
    Gen.arrayOf(Gen.choose(in: UInt64(0) ... 3), within: 0 ... 4, scaling: .constant),
    Gen.choose(in: UInt64(0) ... 3)
).map { WitnessState(ops: $0, regs: $1, pc: $2) }

private let mirrorGen: Generator<WitnessMirror> = Gen.zip(Gen.choose(in: UInt64(0) ... 3), stateGen, stateGen)
    .map { WitnessMirror(observer: $0, first: $1, second: $2) }

/// Opcode per position per half, list lengths, pc, and the length of the common prefix of the two instruction lists, which is the gradient an instrumented comparison would leak.
@Sendable private func mirrorEdges(_ value: WitnessMirror) -> [(edge: Int, hitCount: UInt8)] {
    var edges: [(edge: Int, hitCount: UInt8)] = []
    for (half, state) in [value.first, value.second].enumerated() {
        edges.append((edge: half * 40 + state.ops.count, hitCount: 1))
        for (index, op) in state.ops.prefix(4).enumerated() {
            edges.append((edge: half * 40 + 5 + index * 4 + op.opcode, hitCount: 1))
        }
        edges.append((edge: half * 40 + 25 + Int(state.pc), hitCount: 1))
        edges.append((edge: half * 40 + 30 + state.regs.count, hitCount: 1))
    }
    var prefix = 0
    while prefix < min(value.first.ops.count, value.second.ops.count), value.first.ops[prefix] == value.second.ops[prefix] {
        prefix += 1
    }
    edges.append((edge: 80 + prefix, hitCount: 1))
    return edges
}

extension WitnessOp {
    var opcode: Int {
        switch self {
            case .a: 0
            case .b: 1
            case .c: 2
            case .d: 3
        }
    }
}

// MARK: - Shape: recursive term

indirect enum WitnessTerm: Hashable, Sendable {
    case leaf(UInt64)
    case node(WitnessTerm)
    case pair(WitnessTerm, WitnessTerm)

    var depth: Int {
        switch self {
            case .leaf: 0
            case let .node(inner): 1 + inner.depth
            case let .pair(left, right): 1 + max(left.depth, right.depth)
        }
    }

    /// A pair whose two children are equal and at least `minimumDepth` deep: the sibling twin splice's shape.
    func hasIdenticalSiblings(minimumDepth: Int) -> Bool {
        switch self {
            case .leaf: false
            case let .node(inner): inner.hasIdenticalSiblings(minimumDepth: minimumDepth)
            case let .pair(left, right):
                (left == right && left.depth >= minimumDepth) || left.hasIdenticalSiblings(minimumDepth: minimumDepth) || right.hasIdenticalSiblings(minimumDepth: minimumDepth)
        }
    }

    /// A pair whose right child wraps a copy of the left child one level down, `pair(x, node(x))`: the copy's twin is not its sibling, so only a same-site rule that reaches across levels makes it in one move.
    func hasCousinCopy(minimumDepth: Int) -> Bool {
        switch self {
            case .leaf:
                return false
            case let .node(inner):
                return inner.hasCousinCopy(minimumDepth: minimumDepth)
            case let .pair(left, right):
                if case let .node(inner) = right, inner == left, left.depth >= minimumDepth {
                    return true
                }
                return left.hasCousinCopy(minimumDepth: minimumDepth) || right.hasCousinCopy(minimumDepth: minimumDepth)
        }
    }
}

/// Depth-limited term generator whose pick is one call site at every level, so every level shares the fingerprint. Depth 4 keeps a depth-two subterm common enough that the shapes are a matter of arrangement rather than size.
private func witnessTermGen(depth: Int) -> Generator<WitnessTerm> {
    let leaf: Generator<WitnessTerm> = Gen.choose(in: UInt64(0) ... 15).map { WitnessTerm.leaf($0) }
    guard depth > 0 else {
        return leaf
    }
    let inner = witnessTermGen(depth: depth - 1)
    return witnessTermPick(leaf: leaf, node: inner.map { WitnessTerm.node($0) }, pair: Gen.zip(inner, inner).map { WitnessTerm.pair($0, $1) })
}

private func witnessTermPick(leaf: Generator<WitnessTerm>, node: Generator<WitnessTerm>, pair: Generator<WitnessTerm>) -> Generator<WitnessTerm> {
    Gen.pick(choices: [(2, leaf), (1, node), (2, pair)])
}

private let termGen: Generator<WitnessTerm> = witnessTermGen(depth: 4)

/// Constructor per level along the leftmost and rightmost spines, depth, and leaf count buckets.
@Sendable private func termEdges(_ term: WitnessTerm) -> [(edge: Int, hitCount: UInt8)] {
    var edges: [(edge: Int, hitCount: UInt8)] = [(edge: term.depth, hitCount: 1)]
    var current = term
    var level = 0
    while level < 5 {
        let constructor: Int
        switch current {
            case .leaf: constructor = 0
            case .node: constructor = 1
            case .pair: constructor = 2
        }
        edges.append((edge: 8 + level * 3 + constructor, hitCount: 1))
        switch current {
            case .leaf: level = 5
            case let .node(inner): current = inner
            case let .pair(_, right): current = right
        }
        level += 1
    }
    edges.append((edge: 30 + min(term.leafCount, 20), hitCount: 1))
    return edges
}

extension WitnessTerm {
    var leafCount: Int {
        switch self {
            case .leaf: 1
            case let .node(inner): inner.leafCount
            case let .pair(left, right): left.leafCount + right.leafCount
        }
    }
}

// MARK: - Shape: two lists of one site

private let listElement: Generator<WitnessOp> = opGen

struct WitnessLists: Hashable, Sendable {
    var first: [WitnessOp]
    var second: [WitnessOp]
}

private let listsGen: Generator<WitnessLists> = Gen.zip(
    Gen.arrayOf(listElement, within: 0 ... 5, scaling: .constant),
    Gen.arrayOf(listElement, within: 0 ... 5, scaling: .constant)
).map { WitnessLists(first: $0, second: $1) }

extension [WitnessOp] {
    /// Whether `run` appears contiguously in this list.
    func containsRun(_ run: [WitnessOp]) -> Bool {
        guard run.isEmpty == false, count >= run.count else { return false }
        for start in 0 ... (count - run.count) where Array(self[start ..< start + run.count]) == run {
            return true
        }
        return false
    }
}

/// Lengths, opcode per position per list, and the longest run of the first list found in the second, the gradient.
@Sendable private func listsEdges(_ lists: WitnessLists) -> [(edge: Int, hitCount: UInt8)] {
    var edges: [(edge: Int, hitCount: UInt8)] = []
    for (which, list) in [lists.first, lists.second].enumerated() {
        edges.append((edge: which * 30 + list.count, hitCount: 1))
        for (index, op) in list.prefix(5).enumerated() {
            edges.append((edge: which * 30 + 6 + index * 4 + op.opcode, hitCount: 1))
        }
    }
    var longest = 0
    if lists.first.isEmpty == false {
        for length in stride(from: lists.first.count, through: 1, by: -1) {
            var found = false
            for start in 0 ... (lists.first.count - length) where lists.second.containsRun(Array(lists.first[start ..< start + length])) {
                found = true
                break
            }
            if found { longest = length; break }
        }
    }
    edges.append((edge: 60 + longest, hitCount: 1))
    return edges
}
