# The Adaptive Scheduler: Signal-Driven Reduction

## Glossary

| Term | Definition |
|------|-----------|
| **Base point** | A particular choice tree shape — identified by the number of choice points, their domains, and their dependency edges. Two different bind-inner values produce the same base point if the bound generator's structure doesn't depend on the value (a structurally constant edge). Identity is captured by `StructuralFingerprint` (a hash of bind region count and per-region span lengths). |
| **Bind-inner** | The controlling value in a `bind` operation. Its value determines the structure of the downstream generator (the bound content). |
| **CDG** | Choice dependency graph. A directed acyclic graph where nodes are structural positions (bind-inners, branch selectors) and edges represent data dependencies between them. Built from the choice sequence and tree. |
| **Choice sequence** | A flat array of choice values representing every random decision made during generation. The reducer mutates this sequence and replays it through the generator to produce candidates. |
| **Choice tree** | A hierarchical representation of the generator's decision structure, preserving bind chains, branch points, and sequence boundaries. Richer than the flat choice sequence. |
| **Composition** | A `KleisliComposition` of two encoders through a `GeneratorLift`. The upstream proposes a base change; the lift materializes the downstream fibre; the downstream searches within the fibre. |
| **Convergence cache** | Per-coordinate cache of `ConvergedOrigin` entries. Stores the bound where a prior binary search converged, the signal it produced, and the encoder configuration. Supplies warm-start data to subsequent cycles. |
| **Cycle** | One iteration of the scheduler's main loop. Each cycle runs some combination of Phases 1-4, collects a `CycleOutcome`, and checks for stall. |
| **Descriptor chain** | An ordered list of `MorphismDescriptor` entries processed by the scheduler. Each descriptor bundles an encoder, a decoder factory, a probe budget, and dominance edges. Dominance suppression is per-chain-execution — not permanent across cycles. A chain is executed once per phase invocation, though a phase may invoke multiple chains (for example, the leaf-range loop runs one chain per leaf range). |
| **Dominance** | A relationship between descriptors where acceptance of one suppresses others for the remainder of that descriptor chain execution. For example, in a three-tier chain (guided → regime probe → PRNG retries), guided dominates the other two. |
| **Downstream** | The role in a composition that searches within a fibre. The downstream encoder receives a lifted `(sequence, tree)` produced by the upstream's base change and searches for a failure within that fibre. |
| **`DownstreamPick`** | Runtime strategy selection for the downstream role in a composition. Selects exhaustive enumeration (≤ 64 combinations), pairwise covering (2-20 parameters), or `ZeroValueEncoder` as a fallback. The fallback always produces probes (it proposes the simplest value for each coordinate), guaranteeing downstream work even on fibres too large for enumeration or covering. |
| **Edge observation** | A `FibreSignal` recorded per CDG edge after the composition's downstream finishes. Carries what the downstream observed (`exhaustedClean`, `exhaustedWithFailure`, `bail`) and the upstream value. |
| **Encoder** | A `ComposableEncoder` that produces candidate mutations for a position range in the choice sequence. Role-agnostic — the factory assigns it to upstream, downstream, or standalone role. |
| **Fibre** | For a fixed base point (upstream value), the space of valid downstream configurations. The product of all possible choice values for each choice point in the bound content. |
| **Generator lift** | The `GeneratorLift` — replays the generator with a modified upstream value to produce a fresh `(sequence, tree)` for the downstream. This is the composition's bind operation: it connects the upstream encoder's output to the downstream encoder's input through the generator. |
| **Grothendieck opfibration** | The categorical structure behind the encoder algebra. The base category has upstream values as objects; for each, the fibre is the category of downstream configurations. The lift is the covariant reindexing functor. |
| **Materialization** | A generator lift — replaying the full generator from a choice sequence to produce a value and check the property. The dominant cost in reduction: encoder setup, span extraction, and convergence cache operations are O(n) bookkeeping; materializations involve full interpreter replay, which is orders of magnitude more expensive. |
| **Morphism** | In the S-J algebra, an (encoder, decoder) pair. The encoder proposes a candidate; the decoder validates it by materializing and checking the property. |
| **Phase 1 (base descent)** | Structural deletion — removes unnecessary structure (container spans, sequence elements, branch simplification). |
| **Phase 2 (fibre descent)** | Value minimization — reduces values within the current structure (zero-value, binary search, float reduction, linear scan). |
| **Phase 3 (Kleisli exploration)** | Cross-level minima — composes upstream and downstream encoders through a generator lift to find improvements that per-coordinate search cannot reach. |
| **Phase 4 (relax-round)** | Speculative redistribution — temporarily worsens the sequence via value transfer, then exploits via a full Phase 1 + Phase 2 pipeline. Checkpoint/rollback acceptance. |
| **Reduction target** | The simplest value a coordinate can hold: zero for unsigned integers, zero for signed integers (via zigzag encoding), the range minimum when zero falls outside an explicit valid range. Binary search converges toward the reduction target. |
| **S-J algebra** | The categorical framework from Sepulveda-Jimenez ("Categories of Optimization Reductions", 2026). Morphisms are (encoder, decoder) pairs; Kleisli composition wires two morphisms through a lift. |
| **Shortlex** | The ordering on choice sequences: shorter is better; among equal-length sequences, lexicographically smaller is better. A hard invariant enforced by the decoder — a candidate that does not shortlex-precede the current sequence is rejected before acceptance. |
| **Signal** | A typed observation produced by an encoder or phase, stored in the convergence cache or edge observations, and consumed by the factory or scheduling strategy on subsequent cycles. |
| **Span** | A contiguous range of positions in the choice sequence that forms a structural unit (container span, sequence element, free-standing value). Deletion encoders operate on spans. |
| **Upstream** | The role in a composition that proposes base changes. The upstream encoder mutates a controlling position (bind-inner), and its output is lifted through the generator to produce a new fibre for the downstream. |
| **Warm-start** | Using a prior cycle's convergence bound to narrow the search range on the current cycle. Instead of binary searching the full domain, start from the cached floor. |

## What it is

The `AdaptiveStrategy` is an alternative scheduling strategy for the Bonsai reducer that uses seven signals — observations from encoders, span extraction, and prior-cycle outcomes — to decide which phases to run, which to skip, and how to allocate budget. It operates through the `SchedulingStrategy` protocol alongside `StaticStrategy` (the fixed-order baseline). Both share the same orchestration skeleton, phase methods, encoder set, and feedback channels.

The user selects the adaptive strategy via `.adaptiveScheduling` on `ExhaustSettings`.

## The encoder set

Every reduction step is a morphism in the S-J algebra: an (encoder, decoder) pair where the encoder proposes a candidate mutation and the decoder validates it by replaying the generator. Encoders conform to the `ComposableEncoder` protocol — they are role-agnostic, meaning the same encoder type can serve as an upstream encoder (proposing base changes in a composition), a downstream encoder (searching within a fibre), or a standalone encoder (evaluated directly). The `EncoderFactory` assigns roles based on CDG position.

Two encoders can be composed through a `GeneratorLift` via `KleisliComposition`: the upstream encoder's output is lifted (materialized without property check) to produce a fresh `(sequence, tree)` for the downstream encoder. The property is checked only on the downstream's final output. The `DownstreamPick` selects the downstream strategy at runtime based on actual fibre characteristics.

### Structural deletion (Phase 1)

| Encoder | What it does |
|---------|-------------|
| `DeletionEncoder` | Removes contiguous spans from the choice sequence — container spans, sequence elements, sequence boundaries, or free-standing values. Parameterized by `DeletionSpanCategory`. |
| `BranchSimplificationEncoder` | Simplifies branch points (picks). `.promote` replaces a branch with its simplest child. `.pivot` replaces a branch with an alternative child. |
| `ContiguousWindowDeletionEncoder` | Finds the largest contiguous window of same-depth sibling spans that can be deleted while preserving the property. |
| `BeamSearchDeletionEncoder` | Bitmask subset expansion with beam search over non-contiguous sibling spans. Fallback when contiguous search exhausts. |

### Value minimization (Phase 2)

| Encoder | What it does |
|---------|-------------|
| `ZeroValueEncoder` | Sets each value to its semantic simplest (zero for numerics, range minimum when zero is out of range). Two phases: batch all-at-once, then individual. |
| `BinarySearchEncoder` | Binary searches each coordinate toward its reduction target. `.rangeMinimum` searches downward; `.semanticSimplest` searches bidirectionally with cross-zero phase for signed types. |
| `ReduceFloatEncoder` | Four-stage float pipeline: special-value short-circuit, precision truncation, integer-domain binary search, `as_integer_ratio` minimization. |
| `LinearScanEncoder` | Bounded exhaustive scan of a value range (≤ 64 values). Produced by the factory when `nonMonotoneGap` is detected. One-time intervention. |
| `ProductSpaceAdaptiveEncoder` | Joint reduction of multiple bind-inner coordinates via adaptive delta-debugging. For generators with more than three bind-inner coordinates. |

### Redistribution

| Encoder | What it does |
|---------|-------------|
| `RedistributeByTandemReductionEncoder` | Reduces one coordinate while increasing a sibling by the same delta. Preserves aggregate invariants (sum constraints). |
| `RedistributeAcrossValueContainersEncoder` | Transfers value magnitude between coordinates in different containers. Cross-scope redistribution. |

### Exploration (Phase 3 and Phase 4)

| Encoder | What it does |
|---------|-------------|
| `KleisliComposition` | Composes an upstream and downstream encoder through a `GeneratorLift`. The upstream proposes a base change; the lift materializes the fibre; the downstream searches within it. |
| `DownstreamPick` | Runtime strategy selection for the downstream role. Selects exhaustive (≤ 64), pairwise (2-20 params), or `ZeroValueEncoder` (fallback) based on fibre characteristics. |
| `FibreCoveringEncoder` | Searches a fibre via exhaustive enumeration or IPOG pairwise covering arrays. Used as a downstream within `DownstreamPick`. |
| `RelaxRoundEncoder` | Speculative value redistribution — proposes one-for-one value transfers between coordinates. Accepted only if the subsequent exploitation pipeline (full Phase 1 + Phase 2) produces a net shortlex improvement. |

## The scheduler's main loop

Each cycle follows this structure:

Planning is split into two stages because the fibre descent gate depends on Phase 1's outcome, which isn't known at cycle start. **Stage 1** contains Phase 1 (or is empty if Phase 1 is skipped). **Stage 2** contains Phases 2-4.

```
read prior CycleOutcome + ReductionStateView
│
├─ Stage 1: strategy.planFirstStage()
│   │  Decides: should Phase 1 run?
│   ├─ Check structural gate (span extraction: no deletion targets, no branch nodes)
│   ├─ Check behavioral gate (prior cycle's Phase 1 had zero structural acceptances)
│   ├─ If either gate fires → Phase 1 skipped (Stage 1 is empty)
│   └─ Otherwise → dispatch Phase 1
│
├─ Stage 2: strategy.planSecondStage(firstStageResult)
│   │  Decides: which of Phases 2-4 run, with what configuration?
│   │
│   ├─ Phase 2 gate: skip when ALL FOUR conditions hold:
│   │   (1) Phase 1 made no progress (or was skipped)
│   │   (2) Phase 2 made no progress in the PRIOR cycle
│   │   (3) Not the first cycle
│   │   (4) All value coordinates are at cached floors or reduction targets
│   │       (a coordinate is "at cached floor" if the convergence cache has an
│   │       entry and the current value ≤ the cached bound; "at reduction target"
│   │       if the current value equals the semantic simplest for its range;
│   │       coordinates with no cache entry and not at target are NOT converged
│   │       and prevent the gate from firing)
│   │   This prevents re-running value reduction when all coordinates are
│   │   already converged and no structural change could have shifted them.
│   │   Fires frequently — on the FibreDescentGate test, 7 of 9 cycles gate Phase 2.
│   │
│   ├─ Phase 3 (requiresStall: true):
│   │   Skipped if any prior phase in this cycle accepted (stall gate).
│   │   ALSO skipped if all edges were exhaustedClean in the prior cycle (signal gate).
│   │
│   └─ Phase 4 (requiresStall: !hasZeroingDependency):
│       Skipped if any prior phase accepted AND no zeroingDependency signals.
│       Runs regardless of progress when zeroingDependency is present.
│
├─ For each dispatched phase:
│   ├─ dispatchPhase() calls the phase method on ReductionState
│   └─ strategy.phaseCompleted() updates cross-cycle state
│
├─ Stall detection: bestSequence.shortLexPrecedes(cycleStartBest)?
│   ├─ Yes → reset stall budget
│   └─ No → decrement stall budget
│
├─ Collect CycleOutcome (per-phase dispositions, signal counts, improvement flag)
└─ Reset PhaseTracker
```

Phases terminate when their encoders exhaust all candidates (no more probes). The per-phase budget ceiling (2000 for adaptive, 1950/975/325 for static) is a safety limit, not the primary termination mechanism. No phase in the current test suite hits the ceiling.

When the stall budget reaches zero, the verification sweep runs (post-termination staleness detection), and the result is extracted.

## A reduction narrative: CrossLevelSum

To motivate the signal infrastructure, consider a generator that defeats per-coordinate reduction:

```swift
let gen = #gen(.int(in: 2...10)).bind { n in
    #gen(.int(in: 0...n)).array(length: 3)
}
// Property: arr[0] > 0 AND arr[1] > 0 AND arr[2] == arr[0] + arr[1] → fails.
```

A seed produces `n = 7, arr = [3, 4, 7]`. The property fails because `arr[2] == arr[0] + arr[1]`. The smallest counterexample is `[1, 1, 2]` at `n = 2`.

### The fibrational structure

This generator is a Grothendieck opfibration. The base category has objects `n ∈ {2, ..., 10}` — the bind-inner value. For each base point `n`, the fibre `F(n)` is the category of valid downstream configurations: three-element arrays with elements in `{0, ..., n}`. A base morphism `n → k` (reduction of the bind-inner) induces a reindexing functor `F(n) → F(k)`: the `GeneratorLift` materializes the downstream at `k`, clamping or regenerating entries that fall out of range.

The CDG identifies this structure at runtime: one bind-inner node (controlling `n`), one dependency edge to the downstream array. The composition framework decomposes each reduction step into an opcartesian (upstream) component and a vertical (downstream) component.

### Cycle 1: structure, values, and composition

**Phase 1** runs first. The deletion encoders extract container spans and sequence boundaries from the array. `DeletionEncoder` tries deleting array elements — but the property requires all three, so no deletion succeeds. Phase 1 produces the CDG and reports one structural acceptance (initial sequence normalization).

**Phase 2** runs next. `ZeroValueEncoder` tries zeroing all four values simultaneously — it fails because the all-zero array `[0, 0, 0]` doesn't satisfy the sum constraint. Individual zeroing of `arr[0]` to 0 also fails (the constraint requires `arr[0] > 0`). Zeroing `n` from 7 to 2 would change the downstream structure — this is a bind-inner reduction. Phase 2's fingerprint guard catches this: before accepting, it snapshots the `StructuralFingerprint` (hash of bind region count and per-region span lengths), accepts the probe, recomputes the fingerprint, and if it changed, rolls back the acceptance. Phase 2 only changes values; structural changes are Phase 1's responsibility.

**Signal produced**: `zeroingDependency` — batch zeroing failed but individual zeroing succeeded on some coordinates. The coordinates are coupled through the sum constraint.

`BinarySearchEncoder` searches each coordinate toward its minimum and converges. For coordinates where the convergence point is above the target and the remaining range is small (≤ 64), `nonMonotoneGap(remainingRange:)` is emitted. The factory will emit `LinearScanEncoder` for those coordinates on the next cycle.

**Phase 3** runs because neither Phase 1 nor Phase 2 made progress (`cycleImproved == false`). The composition framework builds a `KleisliComposition` for the CDG edge: upstream is `BinarySearchEncoder(.semanticSimplest)` operating on `n`, downstream is `DownstreamPick`.

The upstream binary-searches `n` downward. The first probe is `n = 4` (floor of the midpoint: `lo + (hi - lo) / 2` where `lo = 2, hi = 7`). The `GeneratorLift` materializes the array at `n = 4` — the fibre is `{0, ..., 4}³ = 125` values. `DownstreamPick` selects pairwise covering (three parameters, five values each). The covering array explores combinations but doesn't find a failure satisfying the sum constraint at this `n` value.

The upstream continues searching. At `n = 2`, the lift materializes a fibre of `{0, ..., 2}³ = 27` values. `DownstreamPick` selects exhaustive search (≤ 64). The exhaustive search finds `[1, 1, 2]` — the property fails. The composition accepts: the entire composed sequence (upstream `n = 2` + downstream `[1, 1, 2]`) replaces the current sequence in one atomic step, validated by the shortlex invariant.

**Edge observations produced**: The CDG has one edge; the composition tried multiple upstream values along it. One `EdgeObservation` is stored per CDG edge (keyed by region index), from the last upstream probe attempted. The observation is `exhaustedWithFailure` (the downstream at `n = 2` found a failure) — this overwrites the earlier `exhaustedClean` observations from higher `n` values. The profiling records `edges=2, futile=1` — the "two edges" are composition attempts (the profiling accumulates across all upstream probes, not per stored observation). The `bail` signal (`1bail`) comes from a composition attempt where the upstream budget exhausted before the downstream started — this contributes to the profiling counter `fibreBailCount` but does not affect `edgeObservations` (it was overwritten by the later probe).

This means per-edge budget adaptation on cycle 2 sees `exhaustedWithFailure` for this edge (the last probe's observation), not the earlier `exhaustedClean`. The profiling counters and the stored observation diverge — the counters reflect all probes, the stored observation reflects only the last.

**Phase 4** does not run — `cycleImproved` is true (the composition found `[1, 1, 2]`), and phases with `requiresStall: true` are skipped when any prior phase accepted.

### Cycle 2: signals guide the search

The sequence is now `n = 2, [1, 1, 2]` — already the global minimum. Cycle 2 exists because the stall budget requires consecutive non-improving cycles before termination. This cycle confirms no further reduction is possible.

The adaptive strategy reads the prior cycle's signals:

1. **Phase 1 gate**: the behavioral gate checks Phase 1's structural acceptances in cycle 1. There was one — Phase 1 runs.

2. Phase 1 finds no further structural work. **Signal for cycle 3**: zero structural acceptances.

3. Phase 2 runs. `LinearScanEncoder` scans the small ranges flagged by `nonMonotoneGap`. Binary search re-confirms the coordinate floors with warm-start from the convergence cache. No improvement.

4. **Phase 3 gating**: the adaptive strategy checks whether all edges were `exhaustedClean`. The stored observation for the single CDG edge is `exhaustedWithFailure` (from the last upstream probe at `n = 2`). Not all clean — Phase 3 runs but finds no improvement.

5. **Per-edge budget**: the stored observation is `exhaustedWithFailure`, so this edge gets 150 materializations (+50%).

6. **`zeroingDependency` escalation**: the prior cycle produced `zeroingDependency` signals. Phase 4's gate is an OR: run when stalled OR when `zeroingDependency` is present (`requiresStall: hasZeroingDependency == false`). Even if Phases 2-3 made progress, Phase 4 runs — but finds no improvement on the already-optimal sequence.

### Cycle 3: convergence

Phase 1 is **skipped** — the behavioral gate fires (zero structural acceptances in cycle 2). No materializations wasted.

Phases 2-4 run and find no improvement. The stall budget decrements to zero. The scheduler terminates. The counterexample is `[1, 1, 2]` — the global minimum that per-coordinate search alone cannot reach.

### What the signals accomplished

| Signal | When observed | Effect |
|--------|-------------|--------|
| `zeroingDependency` (×3) | Cycle 1 | Phase 4 escalation on cycle 2: redistribution runs regardless of prior progress |
| `nonMonotoneGap` | Cycle 1 | `LinearScanEncoder` on cycle 2 resolves whether lower floors exist |
| `exhaustedWithFailure` (stored) | Cycle 1 | Per-edge budget increased to 150 for this edge on cycle 2 |
| `exhaustedClean` (profiling only) | Cycle 1 | Accumulated in profiling counters; overwritten in stored observation by the later `exhaustedWithFailure` |
| `bail` (profiling only) | Cycle 1 | Accumulated in profiling counters; overwritten in stored observation |
| `scanComplete` | Cycle 2 | Factory reverts to binary search on cycle 3 |
| Structural work absence | Cycle 2 | Phase 1 skipped on cycle 3 — no wasted lifts |

Without these signals, the `StaticStrategy` runs Phase 1 on every cycle (wasting lifts when no structural work exists), gives every edge 100 materializations (overallocating to futile edges, underallocating to productive ones), and gates Phase 4 only on full stall (delaying redistribution for coupled coordinates).

## The seven signals

### Where signals come from

Every signal originates in the generator's structure, passes through the interpreter pipeline, and arrives at the scheduler as a typed observation. The full provenance for each signal class:

**Per-coordinate signals** (1-3):

```
ReflectiveGenerator<Value>
  contains .chooseBits(min:, max:, tag:, isRangeExplicit:) operations
  │
  ├─ ReductionMaterializer replays the generator from a ChoiceSequence,
  │  producing a value and a fresh ChoiceTree. Each .chooseBits becomes
  │  a ChoiceSequenceValue with a validRange and a bitPattern64.
  │
  ├─ ChoiceSequence.extractAllValueSpans() identifies value coordinates —
  │  contiguous positions holding .chooseBits-derived values.
  │
  ├─ EncoderFactory builds MorphismDescriptors. For value minimization,
  │  it reads ConvergedOrigin entries from the convergence cache (if any)
  │  and selects encoders: BinarySearchEncoder, ZeroValueEncoder, or
  │  LinearScanEncoder based on the prior signal.
  │
  ├─ BinarySearchEncoder.start() reads the validRange and bitPattern64
  │  from each value span. It computes the reduction target (semantic
  │  simplest or range minimum) and initializes a stepper per coordinate.
  │
  ├─ BinarySearchEncoder.nextProbe() drives the stepper. Each probe
  │  mutates one coordinate in the ChoiceSequence. The decoder materializes
  │  the candidate and checks the property.
  │
  └─ At convergence, BinarySearchEncoder writes a ConvergedOrigin:
     - bound: the stepper's bestAccepted (bit-pattern floor)
     - signal: .monotoneConvergence if bestAccepted == target;
               .nonMonotoneGap(remainingRange:) if bestAccepted > target
               and the gap is ≤ 64
     - configuration: .binarySearchRangeMinimum or .binarySearchSemanticSimplest
     - cycle: the current cycle number

     ZeroValueEncoder writes .zeroingDependency when batch zeroing fails
     but individual zeroing succeeds — detected by comparing the allAtOnce
     probe result against individual probe results within a single start/
     nextProbe cycle.

     LinearScanEncoder writes .scanComplete(foundLowerFloor:) after scanning
     a bounded range below the convergence point.
```

**Per-edge signals** (4-6):

```
ReflectiveGenerator<Value>
  contains .bind(inner:, bound:) operations via the .transform(.bind(...))
  reification. The bind creates a data dependency: the inner generator's
  value determines the bound generator's structure.
  │
  ├─ ValueAndChoiceTreeInterpreter (VACTI) evaluates the generator and
  │  produces a ChoiceTree with .bind(inner:, bound:) nodes recording
  │  the dependency.
  │
  ├─ ChoiceDependencyGraph.build() walks the ChoiceTree and BindSpanIndex
  │  to identify bind-inner nodes and their dependency edges. Each edge
  │  becomes a ReductionEdge with upstreamRange and downstreamRange.
  │
  ├─ EncoderFactory.compositionDescriptors() builds KleisliCompositions
  │  for each CDG edge. The upstream encoder operates on the bind-inner;
  │  the downstream encoder (via DownstreamPick) operates on the bound
  │  content.
  │
  ├─ KleisliComposition.nextProbe() drives the outer-inner loop:
  │  upstream proposes a base change → GeneratorLift materializes the
  │  fibre → downstream searches within the fibre.
  │
  └─ After the composition loop exhausts, runKleisliExploration writes
     an EdgeObservation per CDG edge:
     - signal: .exhaustedClean (downstream found no failure),
               .exhaustedWithFailure (downstream found a failure), or
               .bail (zero downstream probes — upstream budget exhausted)
     - upstreamValue: the last upstream bit-pattern attempted
     - cycle: the current cycle number
```

**Per-phase signal** (7):

```
ReflectiveGenerator<Value>
  contains .sequence(length:, gen:) and .pick(choices:) operations that
  produce structural spans (container spans, sequence boundaries, branch
  nodes) in the ChoiceSequence.
  │
  ├─ ChoiceSequence.extractContainerSpans() and extractAllValueSpans()
  │  identify deletion targets.
  │
  ├─ computeEncoderOrdering() computes pruneOrder from deletion span
  │  counts. If all counts are zero, pruneOrder is empty.
  │
  ├─ tree.containsPicks checks for branch nodes.
  │
  └─ AdaptiveStrategy.planFirstStage() reads:
     - Structural gate: pruneOrder.isEmpty && tree.containsPicks == false
     - Behavioral gate: priorOutcome.baseDescent.structuralAcceptances == 0
     Either gate firing → Phase 1 skipped.
```

### Per-coordinate signals (convergence cache)

These signals are produced by value encoders at convergence and stored in `ConvergedOrigin` alongside the warm-start bound. The `EncoderFactory` pattern-matches on them to select the recovery encoder for the next cycle.

**1. `nonMonotoneGap(remainingRange: Int)`**

Produced by `BinarySearchEncoder` when it converges above the target and the remaining range is within the scan threshold (≤ 64 values). Binary search cannot distinguish a genuine floor from a gap in a non-monotone failure surface. A non-monotone surface is one where the property alternates between pass and fail across a coordinate's range — for example, failing at values `{0, 1, 5, 6, 7}` but passing at `{2, 3, 4}`. Binary search from 7 downward converges at 5, missing the true minimum at 0.

The signal triggers `LinearScanEncoder`, which scans the remaining range once (bounded at 64 probes) to either find a lower floor or confirm the binary search result.

The scan is a one-time intervention: `scanComplete(foundLowerFloor:)` tells the factory to revert to binary search on the next cycle. If the failure surface shifts (due to neighboring coordinate changes), binary search may emit another `nonMonotoneGap` — the scan-revert-scan loop converges naturally.

**2. `zeroingDependency`**

Produced by `ZeroValueEncoder` when batch zeroing (all coordinates to zero simultaneously) fails but at least one individual zeroing succeeds. This indicates coupled coordinates — zeroing one alone breaks an invariant that holds when neighbors are also zeroed. The factory suppresses `ZeroValueEncoder` for those coordinates on subsequent cycles. This suppression is per-cycle — the signal is refreshed each cycle, so if a neighboring coordinate changes and batch zeroing might now succeed, the signal won't be present and `ZeroValueEncoder` runs normally.

The adaptive strategy escalates to Phase 4 (relax-round), where redistribution encoders handle coupled coordinates through value transfer.

**3. `scanComplete(foundLowerFloor: Bool)`**

Produced by `LinearScanEncoder` when its bounded scan finishes. `foundLowerFloor: true` means the scan found a failure below the binary search convergence point — the non-monotonicity was real, and the new bound is the scan's discovery. `foundLowerFloor: false` means the scan confirmed the binary search floor — the remaining range was legitimately passing. Either way, the factory reverts to binary search on the next cycle.

### Per-edge signals (edge observations)

These signals are produced by the composition pipeline after each CDG edge completes and stored in `EdgeObservation` keyed by region index. The adaptive strategy reads them for per-edge budget adaptation and Phase 3 gating.

**4. `exhaustedClean`**

The downstream encoder fully searched the fibre and found no failure. For structurally constant edges (fibre shape invariant under upstream value changes), the composition skips the edge at the observed upstream value on subsequent cycles. For data-dependent edges, the skip does not fire — Phase 2 may have changed downstream coordinates between cycles, altering the property's behavior within the fibre even at the same upstream value. However, the per-edge budget adaptation still applies: a `exhaustedClean` data-dependent edge gets 50% budget reduction (50 instead of 100 materializations), giving it less budget without skipping it entirely.

When all edges are `exhaustedClean`, the adaptive strategy gates Phase 3 entirely — no edge has unexplored territory.

**5. `exhaustedWithFailure`**

The downstream found a failure in the fibre. The adaptive strategy increases this edge's sub-budget by 50% of the fixed 100-materialization base, giving it 150. The adaptation is one-step, not compounding — a persistently productive edge stays at 150 every cycle (not 150 → 225 → 337). Similarly, a persistently bailed edge stays at 50. This prevents a single edge from consuming the entire Phase 3 budget.

**6. `bail(paramCount: Int)`**

The composition attempt produced zero downstream probes. The `bail` signal fires when `totalDownstreamStarts == 0` — the composition consumed all its upstream budget on lifts that either failed or exhausted the per-edge sub-budget before the downstream started searching. `DownstreamPick`'s `ZeroValueEncoder` fallback guarantees downstream probes once the downstream starts, so `bail` reflects upstream-side exhaustion, not downstream-mode inadequacy. The adaptive strategy reduces this edge's budget by 50%.

### Per-phase signal (span extraction + prior-cycle outcome)

**7. Structural work absence**

Two gates, checked at cycle start. Either gate firing skips Phase 1 (they are ORed):

- **Structural gate**: `pruneOrder.isEmpty && tree.containsPicks == false` — span extraction (already computed by `computeEncoderOrdering()`) shows no deletion targets and the tree has no branch nodes. Catches scalar generators from cycle 1.
- **Behavioral gate**: the preceding cycle's Phase 1 had zero structural acceptances (specifically `priorOutcome.baseDescent.structuralAcceptances == 0`). Only relevant when `pruneOrder` is non-empty (the structural gate already covers the empty case). Catches array generators where deletion targets exist but no deletion preserves the property. If Phase 1 was gated (not run) in the prior cycle, this also evaluates to true — the skip perpetuates until structure changes.

  **Soundness note**: the structural gate is provably sound — if no spans exist, Phase 2 cannot create them (vertical morphism, base point invariant). The behavioral gate is a heuristic. Phase 2 changes values, and the property depends on values. A deletion that failed in cycle N (the remaining elements satisfied the property) might succeed in cycle N+1 after Phase 2 reduced the remaining elements (the property now fails on the shorter sequence). In practice, this gap has not produced a missed improvement on any test in the suite. The risk is bounded: the skip perpetuates only until Phase 3 or Phase 4 changes structure, at which point the structural gate resets via `computeEncoderOrdering()`.

Phase 2 only changes values within a fixed structure — it cannot create structural deletion targets. If span extraction shows no targets, Phase 2 cannot change this. The skip is correct for all subsequent cycles until a phase that changes structure runs (Phase 3 or Phase 4 set `structureChanged: true` on acceptance, which invalidates the span cache and creates new deletion targets). When structure changes, the next cycle's `computeEncoderOrdering()` finds non-empty `pruneOrder`, and the structural gate does not fire — Phase 1 runs.

This signal produces the largest measured impact: BinaryHeap saves 117 materializations (17%) with a 36% wall-clock speedup by skipping Phase 1 on cycles where the structure is already minimal.

## Signal interaction

The signals gate different phases and don't conflict:

- `zeroingDependency` gates Phase 4 (removes `requiresStall`, so Phase 4 runs even when prior phases made progress).
- `exhaustedClean` gates Phase 3 (skips exploration when all edges are clean).
- Structural work absence gates Phase 1 (skips base descent).
- Per-edge budgets adjust within Phase 3 (not a phase gate).
- `nonMonotoneGap` and `scanComplete` affect encoder selection within Phase 2 (not a phase gate).

If `zeroingDependency` wants Phase 4 to run but all edges are `exhaustedClean`, both fire independently: Phase 3 is skipped (no edges to explore), Phase 4 runs (coupled coordinates need redistribution). There is no conflict.

**Within a phase**, signals also apply independently. If `nonMonotoneGap` triggers `LinearScanEncoder` for a coordinate and `zeroingDependency` suppresses `ZeroValueEncoder` for the same coordinate, both encoder-selection decisions are applied by the factory without interaction — they affect different encoders in the Phase 2 descriptor chain.

## Categorical foundations and what they enable

The reducer's architecture draws on two categorical frameworks. Each provides specific guarantees that the implementation relies on for correctness and composability. This section states what the frameworks are, what they guarantee, and what those guarantees concretely enable in the reducer.

### The S-J algebra: morphisms, composition, and grades

The framework is from Sepulveda-Jimenez ("Categories of Optimization Reductions", 2026). It models reduction as a category **OptRed** where:

- **Objects** are optimization problems (here: choice sequences paired with a property).
- **Morphisms** are (encoder, decoder) pairs. The encoder proposes a candidate sequence; the decoder validates it by materializing through the generator and checking the property.

**Rules and guarantees:**

1. **Encoder/decoder separation.** The encoder is a pure mutation — it produces a candidate sequence without running the generator. The decoder runs the generator (the expensive lift) and checks the property. This separation means encoders are cheap to compose and reason about; the expensive step happens once at the end.

2. **Kleisli composition.** Two morphisms can be composed through a lift: the first encoder's output is materialized (without property check) to produce fresh input for the second encoder. The property is checked only on the second encoder's final output. This is associative — compositions of compositions are well-defined.

3. **Grade structure.** Each morphism carries a grade that describes the strength of its guarantee:
   - **Exact**: the accepted candidate is strictly shortlex-smaller. No slack.
   - **Bounded**: the accepted candidate is shortlex-smaller after re-derivation, but re-derivation may introduce bounded slack (for example, bind-inner reduction changes downstream ranges).
   - **Speculative**: the accepted candidate may temporarily worsen before a subsequent exploitation phase recovers.

4. **Dominance ordering.** Morphisms can declare dominance: if morphism A accepts, morphism B is suppressed (for the current descriptor chain execution). This enables multi-tier strategies — guided search dominates regime probe dominates PRNG retries.

**What this enables in the reducer:**

- **`MorphismDescriptor`**: bundles encoder + decoder factory + budget + dominance edges into a single schedulable unit. The factory produces arrays of descriptors; `runDescriptorChain` processes them.
- **Phase ordering**: exact morphisms (Phase 1 structural deletion, Phase 2 value minimization) run before bounded (redistribution) before speculative (relax-round). The grade structure makes this ordering principled, not arbitrary.
- **`KleisliComposition`**: composes an upstream encoder and a downstream encoder through a `GeneratorLift`. The algebra guarantees this is well-formed — the composed morphism is itself a morphism in **OptRed**, with a grade derived from the component grades.
- **Role-agnosticity**: the `ComposableEncoder` protocol has no notion of "upstream" or "downstream." Any encoder can serve in any role because the algebra's composition rules handle the wiring. The factory assigns roles based on CDG position, not on encoder type.

### The Grothendieck opfibration: fibres, lifts, and unique factorization

The framework is the standard categorical structure for families of categories parameterized by a base. Applied to the reducer:

- **Base category *B***: objects are base points (choice tree shapes, identified by `StructuralFingerprint`). A morphism `n → k` is a reduction of a controlling value (bind-inner) from `n` to `k`.
- **Fibre *F(n)***: for each base point `n`, the category of valid downstream configurations — choice sequences where every bound entry is in range for the generator materialized at `n`.
- **Reindexing functor *F(n → k)***: a base morphism `n → k` induces a functor `F(n) → F(k)`. This is the `GeneratorLift` — it replays the generator at `k`, producing a fresh downstream sequence. The functor is covariant (pushforward), making this an opfibration, not a fibration.

**Rules and guarantees:**

1. **Opcartesian lifting.** For every base morphism `n → k` and every downstream configuration `x` in `F(n)`, there exists a canonical lift to a configuration in `F(k)`. The `GeneratorLift` computes this: it materializes the downstream at `k`, clamping or regenerating entries that fall out of range. This lift is *opcartesian* — it is the universal way to push a downstream configuration forward along a base change.

2. **Unique factorization.** Every morphism in a composition decomposes uniquely into an opcartesian (base change) component and a vertical (within-fibre) component. There is exactly one way to factor a composed reduction step into "which base change happened" and "which fibre reduction happened." This is a theorem, not a convention.

3. **Structural constancy.** When the bound generator contains no nested binds or picks (`isStructurallyConstant == true`), the fibre `F(n)` has the same number of coordinates and the same dependency structure for all `n`. The coordinate *domains* may still differ (for example, `{0, ..., n}` shrinks as `n` decreases), so the reindexing functor is not the identity — it maps between fibres of the same shape but potentially different domains. The key property: the fibre's *structure* (number of choice points, dependency edges) is invariant under upstream changes.

**What this enables in the reducer:**

- **CDG construction**: the `ChoiceDependencyGraph` identifies the fibrational structure at runtime — which positions are base points (bind-inners), which positions are fibre coordinates (bound content), and which edges represent reindexing functors.
- **Composition safety**: the unique factorization guarantees that the upstream and downstream encoders in a `KleisliComposition` cannot interfere. The upstream changes the base point; the downstream searches the fibre. These are independent concerns — the fibrational structure proves they don't interact.
- **`exhaustedClean` skip correctness**: the skip checks that the upstream value matches the observed value and that the edge is structurally constant. The `GeneratorLift` has its own resolution modes (distinct from the morphism grade "exact" — the lift mode controls how the materializer resolves sequence positions). In exact lift mode, all values are read from the prefix (the current sequence) — the PRNG fallback is unused when the prefix covers all positions. This means the fibre content depends on the full sequence, not just the upstream value: if Phase 2 changed downstream values, the prefix differs, and the lift reads different downstream values. The skip is therefore a heuristic, not a proof — the fibre's structure is invariant (structurally constant), but the specific values within the fibre may have shifted.

  In practice, the heuristic is conservative: Phase 2 moves values toward their targets (smaller), which typically makes the fibre's failure landscape harder to satisfy (the property is more likely to pass on smaller values). A prior exhaustive search that found no failure in a larger-valued fibre is unlikely to miss a failure in a smaller-valued one. No test in the suite exhibits a missed improvement from this gap.
- **Signal attribution**: the unique factorization gives a natural scope for each signal type. Per-coordinate signals (convergence cache) are vertical — they describe what happened within a fibre at a specific coordinate. Per-edge signals (edge observations) are opcartesian — they describe what happened when the base changed along a specific CDG edge. The decomposition ensures these don't overlap.
- **Phase 1 skip correctness**: Phase 2, the only intervening morphism between Phase 1 cycles, is vertical — it operates within a fibre without changing the base point. If the base point has no deletable structure (no spans, no branches), Phase 2 cannot create any because it never changes the base point. The fibrational structure proves this — it's not just an empirical observation.

### How they come together: framework, decomposition, policy

The reducer's architecture rests on three pillars, each with a distinct responsibility:

**1. The S-J algebra provides the framework** — the vocabulary of legal moves. It defines what a morphism is (an encoder/decoder pair), how morphisms compose (Kleisli composition through a lift), what guarantees each morphism provides (grades: exact, bounded, speculative), and how morphisms relate to each other (dominance ordering).

Without the algebra, encoders would be ad hoc functions. With it, every encoder is a typed morphism in a category, composition is associative and well-defined, and the grade structure gives a principled phase ordering (exact before bounded before speculative). The `MorphismDescriptor` type is the algebra's representation in code — it bundles the encoder, the decoder factory, the budget, and the dominance edges into a single schedulable unit.

**2. The Grothendieck opfibration provides the decomposition** — it defines which reduction steps are legal and where they operate. The fibrational structure decomposes the total space of choice sequences into a base (structural shapes) and fibres (value configurations within each shape). Every morphism in a composition factors uniquely into an opcartesian component (a base change — structural) and a vertical component (a fibre reduction — value-level).

Without the decomposition, a composition would be an opaque reduction step — the scheduler couldn't tell which part was structural and which was value-level. With it, the scheduler knows: Phase 1 morphisms operate on the base, Phase 2 morphisms operate on fibres, and Phase 3 morphisms factor into both. The CDG is the runtime discovery of this fibrational structure — it identifies which positions are base points (bind-inners), which are fibre coordinates (bound content), and which edges represent reindexing functors. The unique factorization guarantees that signal attribution is unambiguous: a per-coordinate signal is vertical, a per-edge signal is opcartesian, and these scopes cannot overlap.

**3. The seven signals provide the policy** — the dynamic decisions that neither the algebra nor the fibration prescribes. Given a CDG with three edges and five encoder types, the algebra says which compositions are well-formed. The fibration says which decompositions are canonical. But neither says: run this edge first, give it 150 materializations, skip Phase 1 this cycle, escalate to redistribution because coordinates are coupled.

The signals bridge this gap. Each signal has a categorical scope determined by the fibration, and a policy effect that selects, gates, or adjusts morphisms from the algebra's vocabulary:

| Signal | Categorical scope | What the fibration says about it | Policy decision |
|--------|------------------|----------------------------------|-----------------|
| `nonMonotoneGap` | Vertical (per-coordinate) | A fibre coordinate's search may have missed a floor | Replace binary search morphism with linear scan morphism |
| `zeroingDependency` | Vertical (per-coordinate) | Fibre coordinates are coupled through the property | Switch morphism class: per-coordinate search → redistribution |
| `scanComplete` | Vertical (per-coordinate) | The linear scan resolved the fibre coordinate's floor | Revert to binary search morphism |
| `exhaustedClean` | Opcartesian (per-edge) | The fibre at this base point was fully explored | Skip this base change (heuristic; see failure modes) |
| `exhaustedWithFailure` | Opcartesian (per-edge) | The fibre at this base point contains a failure | Increase budget for this base change |
| `bail` | Opcartesian (per-edge) | The upstream exhausted before reaching the fibre | Decrease budget for this base change |
| Structural work absence | Base category (global) | No base-change morphisms have applicable targets | Skip all opcartesian morphisms (Phase 1) |

The three pillars are layered: the algebra defines the moves, the fibration decomposes them, the signals choose among them. Each layer depends on the one below — the signals reference categorical scopes (vertical, opcartesian) that the fibration defines, and the fibration decomposes morphisms that the algebra defines. Removing any layer would collapse the architecture:

- Without the algebra: no composable morphisms, no grades, no dominance — the scheduler has a bag of ad hoc encoders with no structure.
- Without the fibration: no decomposition of composed morphisms, no signal scoping — the scheduler can't tell which signal affects which part of a composition.
- Without the signals: the algebra and fibration define the space of legal moves but provide no way to navigate it — the scheduler runs every legal move on every cycle (the `StaticStrategy`).

The `AdaptiveStrategy` is the first scheduling policy that reads all three layers: it uses the algebra's grade structure for phase ordering, the fibration's decomposition for signal attribution, and the signals themselves for gating, budgeting, and encoder selection.

### `DownstreamPick`: parameterization, not branching

The `DownstreamPick` is a pick over the encoder space — internal to the morphism, not a branching composition. The algebra sees it as a single opaque morphism; the pick is an implementation detail invisible to the composition framework.

This implementation does not use branching compositions because they produce multiplicative budget explosion: every branch multiplies the search space, and the budget for a branching composition grows as the product of the branch budgets rather than their sum. (The S-J algebra could formalize branching via coproducts, but the budget semantics make it impractical.) `DownstreamPick` avoids this by selecting one strategy at `start()` time based on the actual fibre, then executing only that strategy. The `isConvergenceTransferSafe` protocol property gates convergence transfer when the selected alternative changes between upstream iterations.

## Comparison: StaticStrategy vs AdaptiveStrategy

| Aspect | StaticStrategy | AdaptiveStrategy |
|--------|---------------|-----------------|
| Phase 1 | Always runs | Skipped when no structural work |
| Phase budgets | 1950 / 975 / 325 per phase | 2000 ceiling per phase |
| Per-edge budget | Fixed 100 per edge | Observation-driven: 50 / 100 / 150 |
| Phase 3 gating | Binary: "no progress" | Signal: all edges `exhaustedClean` |
| Phase 4 gating | Binary: "no progress after Phase 3" | Also runs on `zeroingDependency` |
| Non-monotonicity | Same (encoder-level, both strategies) | Same |
| Convergence signals | Same (encoder-level, both strategies) | Same |

Both strategies use independent per-phase budget allocations — not a shared pool. Unused budget is returned immediately when a phase exhausts its work. The static strategy's 1950/975/325 and the adaptive strategy's uniform 2000 are both ceilings, not shares. No phase in the current test suite exceeds 1100 materializations, so neither ceiling is the binding constraint.

The adaptive strategy's decisions are conservative — it only skips or adjusts when the signals provide positive evidence. No phase is skipped speculatively. The `StaticStrategy` remains available as a regression baseline.

### Measured results

From the `AdaptiveComparison` test suite (adaptive runs first on cold cache to avoid warm-cache bias):

| Test | Static mats | Adaptive mats | Saving | Static time | Adaptive time |
|------|------------|--------------|--------|------------|--------------|
| Difference | 3 | 3 | 0 | 0.5ms | 3.0ms |
| Replacement | 3 | 3 | 0 | 0.5ms | 3.0ms |
| Distinct | 38 | 32 | 6 (16%) | 2.9ms | 3.7ms |
| CoupledZeroing | 88 | 88 | 0 | 2.9ms | 4.9ms |
| Coupling | 188 | 178 | 10 (5%) | 4.6ms | 6.4ms |
| Bound5Path1 | 608 | 608 | 0 | 18.7ms | 25.1ms |
| **BinaryHeap** | **703** | **586** | **117 (17%)** | **140.9ms** | **89.5ms** |

Small tests show warm-cache bias (whoever runs second is faster — the static run benefits from the adaptive run's cache warming). **BinaryHeap is the honest signal**: 117 fewer materializations with the adaptive strategy running first on a cold cache. Same counterexample quality on every test — no regressions.

**BinaryHeap decomposition** (15 cycles, the largest test): Phase 1 drops from 548 to 431 materializations — all 117 savings come from the Phase 1 behavioral gate skipping structural deletion on cycles where the structure was already minimal. Phase 2 is unchanged (155 in both). Phase 3 shows `edges=0` in the adaptive run vs `edges=4` in static — but this is the `requiresStall` stall gate, not the signal-driven `exhaustedClean` gate. On cycles where Phase 1 or 2 accepted, Phase 3 was already skipped by the stall gate. The signal-driven Phase 3 gating and per-edge budget adaptation contributed zero savings on this test.

Tests with zero saving (Difference, Replacement, Bound5Path1) either run a single cycle (no prior-cycle signal to read) or have continuous structural work (Phase 1 never skipped).

## Failure modes and self-correction

Signals are observations about the prior cycle's state. If the state changes between cycles (due to other phases' acceptances), a signal can be stale. The scheduler self-corrects in all cases:

**Stale `exhaustedClean`**: The skip only fires for structurally constant edges at the same upstream value. The lift in exact mode reads downstream values from the current sequence prefix — if Phase 2 changed those values, the fibre content differs from when the observation was recorded. The skip is a heuristic: the fibre *structure* is invariant (structurally constant), but the specific values differ. In practice, Phase 2 moves values toward targets (smaller), making the fibre's failure landscape harder to satisfy — a prior exhaustive search that found no failure in a larger-valued fibre is unlikely to miss one in a smaller-valued fibre. For data-dependent edges, the skip does not fire — the edge runs with reduced budget (50 instead of 100). On the next cycle, a fresh observation replaces the stale one. No test in the suite exhibits a missed improvement.

**Stale `nonMonotoneGap`**: A coordinate was flagged for linear scan, but a neighboring coordinate changed between cycles, resolving the non-monotonicity. The scan runs (≤ 64 probes, one-time cost), confirms the floor, and emits `scanComplete`. The factory reverts to binary search. Cost: one unnecessary scan, bounded and non-recurring.

**Stale `zeroingDependency`**: Batch zeroing failed in cycle N, but a neighboring coordinate was reduced in cycle N, and batch zeroing might now succeed. The signal is refreshed each cycle — `ZeroValueEncoder` runs in cycle N+1 (the suppression is per-cycle, not permanent), batch zeroing is re-attempted, and if it succeeds, no `zeroingDependency` is emitted. Self-correcting within one cycle.

**Phase 1 skip when structural work appears**: Phase 1 was skipped on cycle N because the behavioral gate fired (zero structural acceptances in cycle N-1). But Phase 3 or Phase 4 in cycle N changed the structure (`structureChanged: true`), creating new deletion targets. The structural gate reads `pruneOrder` from `computeEncoderOrdering()`, which runs at cycle start. The invalidated span cache produces a non-empty `pruneOrder` — the structural gate does not fire, and Phase 1 runs on cycle N+1. Self-correcting within one cycle.

For `nonMonotoneGap`, `scanComplete`, and `zeroingDependency`, stale signals produce at most one cycle of suboptimal scheduling, after which the signal is refreshed from the current state. For the `exhaustedClean` skip and the Phase 1 behavioral gate, the signals are heuristics — they can theoretically miss an improvement that Phase 2's value changes enabled. In practice, no test in the suite exhibits this gap.

**When to suspect the gap**: properties where the failure condition becomes *easier* to satisfy with smaller values on shortened sequences — for example, a threshold that is *harder* to exceed when values are reduced. Most properties (sum bounds, size checks, ordering invariants) become easier to pass with smaller values, making the heuristic conservative. Properties involving lower-bound thresholds, minimum-count requirements, or exact-match constraints on reduced values are the risk cases.

**Diagnostic**: run both strategies on the same seed and compare the final counterexample. If `AdaptiveStrategy` produces a longer or shortlex-larger counterexample than `StaticStrategy`, the gap manifested. The `AdaptiveComparison` test suite performs this comparison for key generators. The `StaticStrategy` remains available as a fallback via omitting `.adaptiveScheduling`.
