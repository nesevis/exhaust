# Implementation Plan: KleisliComposition

Based on `docs/compositional-encoder-algebra.md`. Four phases, each independently testable.

## Phase 1: Foundation types (non-breaking)

### 1a. `PointEncoder` protocol

**New file**: `Sources/ExhaustCore/Interpreters/Reduction/PointEncoder.swift`

```swift
protocol PointEncoder {
    var name: EncoderName { get }
    var phase: ReductionPhase { get }

    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    )

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence?
    var convergenceRecords: [Int: ConvergedOrigin] { get }
}

struct ReductionContext {
    let bindIndex: BindSpanIndex?
    let convergedOrigins: [Int: ConvergedOrigin]?
    let dag: ChoiceDependencyGraph?
}
```

Default implementations: `convergenceRecords` returns `[:]`.

### 1b. `LegacyEncoderAdapter`

Same file. Bridges `AdaptiveEncoder` → `PointEncoder`:

```swift
struct LegacyEncoderAdapter: PointEncoder {
    var inner: any AdaptiveEncoder
    let name: EncoderName
    let phase: ReductionPhase

    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        // Extract value spans within positionRange from the sequence
        let spans = ChoiceSequence.extractAllValueSpans(from: sequence)
            .filter { positionRange.contains($0.range.lowerBound) }
        inner.start(
            sequence: sequence,
            targets: .spans(spans),
            convergedOrigins: context.convergedOrigins
        )
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        inner.nextProbe(lastAccepted: lastAccepted)
    }

    var convergenceRecords: [Int: ConvergedOrigin] {
        inner.convergenceRecords
    }
}
```

### 1c. `GeneratorLift`

**New file**: `Sources/ExhaustCore/Interpreters/Reduction/GeneratorLift.swift`

Wraps `ReductionMaterializer.materialize` with no property check:

```swift
struct GeneratorLift {
    let gen: ReflectiveGenerator<Any>
    let mode: LiftMode

    enum LiftMode {
        case exact
        case guided(fallbackTree: ChoiceTree)
    }

    func lift(_ candidate: ChoiceSequence) -> LiftResult? {
        let matMode: ReductionMaterializer.Mode = switch mode {
        case .exact:
            .exact
        case let .guided(fallbackTree):
            .guided(seed: 0, fallbackTree: fallbackTree)
        }

        switch ReductionMaterializer.materialize(
            gen, prefix: candidate, mode: matMode, fallbackTree: nil
        ) {
        case let .success(value: _, tree: freshTree, decodingReport: report):
            let freshSequence = ChoiceSequence(freshTree)
            return LiftResult(
                sequence: freshSequence,
                tree: freshTree,
                liftReport: report  // DecodingReport — already contains per-coordinate tiers
            )
        case .rejected, .failed:
            return nil
        }
    }
}

struct LiftResult {
    let sequence: ChoiceSequence
    let tree: ChoiceTree
    let liftReport: DecodingReport?
}
```

Note: `LiftReport` in the design doc maps to the existing `DecodingReport` type — no new type needed. The `DecodingReport` already contains per-coordinate resolution tier data.

### 1d. `KleisliComposition`

**New file**: `Sources/ExhaustCore/Interpreters/Reduction/KleisliComposition.swift`

Conforms to `AdaptiveEncoder` so the scheduler can run it via the existing `runAdaptive` path or a manual loop (following the `runRelaxRound` pattern).

```swift
struct KleisliComposition: AdaptiveEncoder {
    var upstream: any PointEncoder
    var downstream: any PointEncoder
    let lift: GeneratorLift
    let rollback: RollbackPolicy
    let upstreamRange: ClosedRange<Int>
    let downstreamRange: ClosedRange<Int>

    let name: EncoderName = .kleisliComposition
    let phase: ReductionPhase = .exploration

    enum RollbackPolicy {
        case atomic
        case partial
    }

    // --- Internal iteration state ---
    private var baseSequence: ChoiceSequence!
    private var baseTree: ChoiceTree!
    private var context: ReductionContext!
    private var upstreamStarted = false
    private var downstreamActive = false
    private var liftedSequence: ChoiceSequence?
    private var liftedTree: ChoiceTree?
    private var lastLiftReport: DecodingReport?
    private var downstreamConvergenceCache: [Int: ConvergedOrigin] = [:]
    private var upstreamBudget = 0
    private var downstreamBudgetPerUpstream = 0
    private var downstreamProbesThisUpstream = 0
}
```

**`start()` implementation**: captures base state, computes budget split (10–15 upstream candidates, remainder for downstream per candidate).

**`nextProbe(lastAccepted:)` implementation**: the outer-inner loop:
1. If downstream is active: advance downstream. If downstream returns a probe, return it. If downstream exhausts, handle rollback policy, advance upstream.
2. If downstream is not active: get next upstream probe. If nil, return nil (converged). Lift it. If lift fails, advance upstream. If lift succeeds, initialize downstream on lifted (sequence, tree) with convergence transfer gated by lift report coverage. Set downstream active.

**`convergenceRecords`**: exposes only upstream records.

**`estimatedCost`**: `upstream.estimatedCost * (1 + downstream.estimatedCost)` or nil if upstream has no work.

### 1e. `EncoderName` addition

**Modify**: `Sources/ExhaustCore/Interpreters/Reduction/SequenceEncoder.swift`

Add to the enum:
```swift
/// Exploration
case relaxRound
case kleisliComposition  // <-- add here
```

### Phase 1 verification

- Unit test: wrap `ZeroValueEncoder` in `LegacyEncoderAdapter`, call `start()` with a `positionRange`, verify it produces the same probes as calling the encoder directly with equivalent spans.
- Unit test: `GeneratorLift.lift()` on a simple bind generator returns a `LiftResult` with a fresh tree.
- Unit test: `KleisliComposition` with identity upstream returns same probes as downstream alone.
- Build: `swift build` succeeds with no existing code changed (purely additive).

---

## Phase 2: CDG integration

**Modify**: `Sources/ExhaustCore/Interpreters/Reduction/ChoiceDependencyGraph.swift`

Add `reductionEdges()` method and `ReductionEdge` type:

```swift
struct ReductionEdge {
    let upstreamRange: ClosedRange<Int>
    let downstreamRange: ClosedRange<Int>
    let regionIndex: Int
    let isStructurallyConstant: Bool
}

extension ChoiceDependencyGraph {
    func reductionEdges() -> [ReductionEdge] {
        var edges: [ReductionEdge] = []
        for nodeIndex in topologicalOrder {
            let node = nodes[nodeIndex]
            guard case let .structural(.bindInner(regionIndex: regionIndex)) = node.kind,
                  let scopeRange = node.scopeRange,
                  node.isStructurallyConstant == false
            else { continue }
            edges.append(ReductionEdge(
                upstreamRange: node.positionRange,
                downstreamRange: scopeRange,
                regionIndex: regionIndex,
                isStructurallyConstant: node.isStructurallyConstant
            ))
        }
        return edges
    }
}
```

Filters out structurally constant edges (where the bind closure ignores its argument — the lift is trivial and the composition is unnecessary).

### Phase 2 verification

- Unit test: build a CDG from a simple bind generator (`int.bind { n in int(in: 0...n) }`), verify `reductionEdges()` returns one edge with the correct upstream/downstream ranges.
- Unit test: bind-free generator returns empty `reductionEdges()`.

---

## Phase 3: Scheduler integration

**Modify**: `Sources/ExhaustCore/Interpreters/Reduction/ReductionState+Bonsai.swift`

Add `runKleisliExploration(budget:dag:)` method. Follows the `runRelaxRound` checkpoint/rollback pattern exactly:

```swift
func runKleisliExploration(
    budget: inout Int,
    dag: ChoiceDependencyGraph?
) throws -> Bool {
    guard hasBind, let dag, let bindSpanIndex = bindIndex else { return false }

    let edges = dag.reductionEdges()
    guard edges.isEmpty == false else { return false }

    let checkpoint = makeSnapshot()
    var anyAccepted = false

    for edge in edges {
        guard budget > 0 else { break }

        // Build upstream and downstream point encoders via adapter
        var upstreamEncoder = LegacyEncoderAdapter(
            inner: binarySearchToZeroEncoder,
            name: .binarySearchToSemanticSimplest,
            phase: .valueMinimization
        )
        var downstreamEncoder = LegacyEncoderAdapter(
            inner: zeroValueEncoder,
            name: .zeroValue,
            phase: .valueMinimization
        )

        let composed = KleisliComposition(
            upstream: upstreamEncoder,
            downstream: downstreamEncoder,
            lift: GeneratorLift(gen: gen, mode: .guided(fallbackTree: fallbackTree ?? tree)),
            rollback: .atomic,
            upstreamRange: edge.upstreamRange,
            downstreamRange: edge.downstreamRange
        )

        // Run via manual loop (same pattern as runRelaxRound)
        var legBudget = ReductionScheduler.LegBudget(hardCap: min(budget, 100))
        var encoder = composed
        let context = ReductionContext(
            bindIndex: bindSpanIndex,
            convergedOrigins: convergenceCache.allEntries,
            dag: dag
        )
        encoder.start(
            sequence: sequence,
            targets: .wholeSequence,
            convergedOrigins: convergenceCache.allEntries
        )

        var lastAccepted = false
        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            guard legBudget.isExhausted == false else { break }
            legBudget.recordMaterialization()

            // Decode: materialize + property check
            if let result = try SequenceDecoder.exact().decode(
                candidate: probe, gen: gen, tree: tree,
                originalSequence: sequence, property: property
            ) {
                if result.sequence.shortLexPrecedes(sequence) {
                    accept(result, structureChanged: true)
                    lastAccepted = true
                    anyAccepted = true
                } else {
                    lastAccepted = false
                }
            } else {
                lastAccepted = false
            }
        }

        budget -= legBudget.used
    }

    // Pipeline acceptance: net improvement check
    if anyAccepted, sequence.shortLexPrecedes(checkpoint.sequence) {
        bestSequence = sequence
        bestOutput = output
        return true
    }

    // Rollback
    restoreSnapshot(checkpoint)
    return false
}
```

**Wire into BonsaiScheduler**: In `BonsaiScheduler.swift`, after fibre descent stalls and before `runRelaxRound`:

```swift
// After line ~118 in BonsaiScheduler.run():
if baseProgress == false, fibreProgress == false {
    // Kleisli exploration: cross-level minima
    if try state.runKleisliExploration(budget: &remaining, dag: finalDAG) {
        cycleImproved = true
        continue  // restart cycle
    }
    // Relax-round: same-level minima
    if try state.runRelaxRound(remaining: &remaining) {
        cycleImproved = true
        continue
    }
}
```

### Phase 3 verification

- Enable the coupling challenge test (remove `.disabled` attribute from `CouplingShrinkingChallenge`).
- `swift test --filter "couplingChallenge"` — should shrink to `[1, 0]`.
- `swift test --filter "Shrinking"` — all existing challenges pass with identical or better results.
- Budget: verify total property invocations do not regress for non-bind generators (no CDG edges → `runKleisliExploration` returns immediately).

---

## Phase 4: Concrete point encoders (deferred)

Replace `LegacyEncoderAdapter` wrappers with purpose-built `PointEncoder` conformances:
- `IntegralPointEncoder` — binary search ladder, works as base or fibre depending on position
- `FloatingPointEncoder` — float reduction
- `DeletionPointEncoder` — span deletion within a scope

These eliminate the existential overhead of `any AdaptiveEncoder` in the adapter. Not needed for correctness — the adapters work. Implement when moving the composition to a hotter path.

---

## Files changed

| File | Change | Phase |
|------|--------|-------|
| `Sources/ExhaustCore/Interpreters/Reduction/PointEncoder.swift` | **New** — protocol, ReductionContext, LegacyEncoderAdapter | 1 |
| `Sources/ExhaustCore/Interpreters/Reduction/GeneratorLift.swift` | **New** — GeneratorLift, LiftResult | 1 |
| `Sources/ExhaustCore/Interpreters/Reduction/KleisliComposition.swift` | **New** — KleisliComposition: AdaptiveEncoder | 1 |
| `Sources/ExhaustCore/Interpreters/Reduction/SequenceEncoder.swift` | Add `.kleisliComposition` to EncoderName | 1 |
| `Sources/ExhaustCore/Interpreters/Reduction/ChoiceDependencyGraph.swift` | Add `reductionEdges()`, `ReductionEdge` | 2 |
| `Sources/ExhaustCore/Interpreters/Reduction/ReductionState+Bonsai.swift` | Add `runKleisliExploration(budget:dag:)` | 3 |
| `Sources/ExhaustCore/Interpreters/Reduction/BonsaiScheduler.swift` | Wire exploration before relax-round | 3 |
| `Tests/ExhaustTests/Challenges/Shrinking/Coupling.swift` | Remove `.disabled` attribute | 3 |

## Verification summary

1. `swift build` after Phase 1 — purely additive, no existing code changed
2. Unit tests for `LegacyEncoderAdapter`, `GeneratorLift`, identity compositions after Phase 1
3. Unit test for `reductionEdges()` on bind/no-bind generators after Phase 2
4. Coupling challenge shrinks to `[1, 0]` after Phase 3
5. `swift test --filter "Shrinking"` — all challenges pass, no regressions
6. Budget: non-bind generators show zero overhead (early return from `runKleisliExploration`)
