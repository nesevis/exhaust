# The Adaptive Scheduler: Signal-Driven Reduction

## Glossary

| Term | Definition |
|------|-----------|
| **Base point** | A particular choice tree shape — identified by the number of choice points, their domains, and their dependency edges. Two different bind-inner values produce the same base point if the bound generator's structure doesn't depend on the value (a structurally constant edge). Identity is captured by `StructuralFingerprint` (a hash of bind region count and per-region span lengths). |
| **Bind-inner** | The controlling value in a `bind` operation. Its value determines the structure of the downstream generator (the bound content). |
| **CDG** | Choice dependency graph. A directed acyclic graph where nodes are structural positions (bind-inners, branch selectors) and edges represent data dependencies between them. Built from the choice tree (bind structure, constancy classification), the choice sequence (container spans, leaf positions), and the bind span index (bind region ranges). |
| **Choice sequence** | A flat array of choice values representing every random decision made during generation. The reducer mutates this sequence and replays it through the generator to produce candidates. |
| **Choice tree** | A hierarchical representation of the generator's decision structure, preserving bind chains, branch points, and sequence boundaries. Richer than the flat choice sequence. |
| **Composition** | A `KleisliComposition` of two encoders through a `GeneratorLift`. The upstream proposes a base change; the lift materializes the downstream fibre; the downstream searches within the fibre. |
| **Convergence cache** | Per-coordinate cache of `ConvergedOrigin` entries. Stores the bound where a prior binary search converged, the signal it produced, and the encoder configuration. Supplies warm-start data to subsequent cycles. |
| **Cycle** | One iteration of the scheduler's main loop. Each cycle runs some combination of Phases 1-4, collects a `CycleOutcome`, and checks for stall. |
| **Descriptor chain** | An ordered list of `MorphismDescriptor` entries processed by the scheduler. Each descriptor bundles an encoder, a decoder factory, a probe budget, and dominance edges. Dominance suppression is per-chain-execution — not permanent across cycles. A chain is executed once per phase invocation, though a phase may invoke multiple chains (for example, the leaf-range loop runs one chain per leaf range). |
| **Dominance** | A relationship between descriptors where acceptance of one suppresses others for the remainder of that descriptor chain execution. For example, in a three-tier chain (guided → regime probe → PRNG retries), guided dominates the other two. |
| **Downstream** | The role in a composition that searches within a fibre. The downstream encoder receives a lifted `(sequence, tree)` produced by the upstream's base change and searches for a failure within that fibre. |
| **`DownstreamPick`** | Runtime strategy selection within a composition. A `pick` over the encoder space: at `start()` time, evaluates fibre characteristics (total space and parameter count) against each alternative's predicate, and selects the first match. The selected encoder handles all `nextProbe()` calls until the next `start()`. Generic over its alternatives — the factory configures which encoders and predicates are available. Currently configured with three alternatives for the downstream role: exhaustive enumeration (≤ 64 combinations), pairwise covering (2-20 parameters), and `ZeroValueEncoder` (catchall). |
| **Edge observation** | A `FibreSignal` recorded per CDG edge after the composition's downstream finishes. Carries what the downstream observed (`exhaustedClean`, `exhaustedWithFailure`, `bail`) and the upstream value. |
| **Encoder** | A `ComposableEncoder` that produces candidate mutations for a position range in the choice sequence. Role-agnostic — the factory assigns it to upstream, downstream, or standalone role. |
| **Fibre** | For a fixed base point (upstream value), the space of valid downstream configurations. The product of all possible choice values for each choice point in the bound content. |
| **Generator lift** | The `GeneratorLift` — replays the generator with a modified upstream value to produce a fresh `(sequence, tree)` for the downstream. This is the composition's bind operation: it connects the upstream encoder's output to the downstream encoder's input through the generator. |
| **Grothendieck opfibration** | The categorical structure behind the encoder algebra. The base category has upstream values as objects; for each, the fibre is the category of downstream configurations. The lift is the covariant reindexing functor. |
| **Materialization** | A generator lift — replaying the full generator from a choice sequence to produce a value and check the property. The dominant cost in reduction: encoder setup, span extraction, and convergence cache operations are O(n) bookkeeping; materializations involve full interpreter replay, which is orders of magnitude more expensive. |
| **Morphism** | In the S-J algebra, an (encoder, decoder) pair. The encoder proposes a candidate; the decoder validates it by materializing and checking the property. |
| **Phase 1: structural minimization** | Removes unnecessary structure — container spans, sequence elements, sequence boundaries, free-standing values, branch simplification. Formerly "base descent." |
| **Phase 2: value minimization** | Reduces values within the current structure — zero-value, binary search, float reduction, linear scan. Formerly "fibre descent." |
| **Phase 3: cross-level minimization** | Composes upstream and downstream encoders through a generator lift to find minima that per-coordinate search within a single level cannot reach. Requires coordinated changes across the bind hierarchy. Formerly "Kleisli exploration." |
| **Phase 4: speculative redistribution** | Temporarily worsens the sequence via value transfer between coordinates, then exploits via a full structural + value minimization pipeline. Checkpoint/rollback acceptance. Formerly "relax-round." |
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

### Structural minimization (Phase 1)

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

### Cross-level minimization and speculative redistribution (Phases 3 and 4)

| Encoder | What it does |
|---------|-------------|
| `KleisliComposition` | Composes an upstream and downstream encoder through a `GeneratorLift`. The upstream proposes a base change; the lift materializes the fibre; the downstream searches within it. |
| `DownstreamPick` | Runtime strategy selection for the downstream role. Selects exhaustive (≤ 64), pairwise (2-20 params), or `ZeroValueEncoder` (fallback) based on fibre characteristics. |
| `FibreCoveringEncoder` | Searches a fibre via exhaustive enumeration or pull-based pairwise covering (Bryce & Colbourn density algorithm). Each `nextProbe()` call lazily pulls the next greedy row. Used as a downstream within `DownstreamPick`. |
| `RelaxRoundEncoder` | Speculative value redistribution — proposes one-for-one value transfers between coordinates. Accepted only if the subsequent exploitation pipeline (full structural + value minimization) produces a net shortlex improvement. |

## The scheduler's main loop

Each cycle follows this structure:

Planning is split into two stages because the value minimization gate depends on the structural minimization outcome, which isn't known at cycle start. **Stage 1** contains structural minimization (or is empty if skipped). **Stage 2** contains value minimization, cross-level minimization, and speculative redistribution.

```
read prior CycleOutcome + ReductionStateView
│
├─ Stage 1: strategy.planFirstStage()
│   │  Decides: should structural minimization run?
│   ├─ Check structural gate (span extraction: no deletion targets, no branch nodes)
│   ├─ Check behavioral gate (prior cycle's structural minimization had zero acceptances)
│   ├─ If either gate fires → structural minimization skipped (Stage 1 is empty)
│   └─ Otherwise → dispatch structural minimization
│
├─ Stage 2: strategy.planSecondStage(firstStageResult)
│   │  Decides: which of Phases 2-4 run, with what configuration?
│   │
│   ├─ Value minimization gate: skip when ALL FOUR conditions hold:
│   │   (1) Structural minimization made no progress (or was skipped)
│   │   (2) Value minimization made no progress in the PRIOR cycle
│   │   (3) Not the first cycle
│   │   (4) All value coordinates are at cached floors or reduction targets
│   │       (a coordinate is "at cached floor" if the convergence cache has an
│   │       entry and the current value ≤ the cached bound; "at reduction target"
│   │       if the current value equals the semantic simplest for its range;
│   │       coordinates with no cache entry and not at target are NOT converged
│   │       and prevent the gate from firing)
│   │   This prevents re-running value reduction when all coordinates are
│   │   already converged and no structural change could have shifted them.
│   │   Fires frequently — on the FibreDescentGate test, 7 of 9 cycles gate value minimization.
│   │
│   ├─ Cross-level minimization (requiresStall: true):
│   │   Skipped if any prior phase in this cycle accepted (stall gate).
│   │   ALSO skipped if all edges were exhaustedClean in the prior cycle (signal gate).
│   │
│   └─ Speculative redistribution (requiresStall: !hasZeroingDependency):
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

**Structural minimization** runs first. The deletion encoders extract container spans and sequence boundaries from the array. `DeletionEncoder` tries deleting array elements — but the property requires all three, so no deletion succeeds. Structural minimization produces the CDG and reports one structural acceptance (initial sequence normalization).

**Value minimization** runs next. `ZeroValueEncoder` tries zeroing all four values simultaneously — it fails because the all-zero array `[0, 0, 0]` doesn't satisfy the sum constraint. Individual zeroing of `arr[0]` to 0 also fails (the constraint requires `arr[0] > 0`). Zeroing `n` from 7 to 2 would change the downstream structure — this is a bind-inner reduction. Value minimization's fingerprint guard catches this: before accepting, it snapshots the `StructuralFingerprint` (hash of bind region count and per-region span lengths), accepts the probe, recomputes the fingerprint, and if it changed, rolls back the acceptance. Value minimization only changes values; structural changes are structural minimization's responsibility.

**Signal produced**: `zeroingDependency` — batch zeroing failed but individual zeroing succeeded on some coordinates. The coordinates are coupled through the sum constraint.

`BinarySearchEncoder` searches each coordinate toward its minimum and converges. For coordinates where the convergence point is above the target and the remaining range is small (≤ 64), `nonMonotoneGap(remainingRange:)` is emitted. The factory will emit `LinearScanEncoder` for those coordinates on the next cycle.

**Cross-level minimization** runs because neither structural nor value minimization made progress (`cycleImproved == false`). The composition framework builds a `KleisliComposition` for the CDG edge: upstream is `BinarySearchEncoder(.semanticSimplest)` operating on `n`, downstream is `DownstreamPick`.

The upstream binary-searches `n` downward. The first probe is `n = 4` (floor of the midpoint: `lo + (hi - lo) / 2` where `lo = 2, hi = 7`). The `GeneratorLift` materializes the array at `n = 4` — the fibre is `{0, ..., 4}³ = 125` values. `DownstreamPick` selects pairwise covering (three parameters, five values each). The pull-based generator lazily produces rows exploring pairwise combinations but doesn't find a failure satisfying the sum constraint at this `n` value.

The upstream continues searching. At `n = 2`, the lift materializes a fibre of `{0, ..., 2}³ = 27` values. `DownstreamPick` selects exhaustive search (≤ 64). The exhaustive search finds `[1, 1, 2]` — the property fails. The composition accepts: the entire composed sequence (upstream `n = 2` + downstream `[1, 1, 2]`) replaces the current sequence in one atomic step, validated by the shortlex invariant.

**Edge observations produced**: The CDG has one edge; the composition tried multiple upstream values along it. One `EdgeObservation` is stored per CDG edge (keyed by region index), from the last upstream probe attempted. The observation is `exhaustedWithFailure` (the downstream at `n = 2` found a failure) — this overwrites the earlier `exhaustedClean` observations from higher `n` values. The profiling records `edges=2, futile=1` — the "two edges" are composition attempts (the profiling accumulates across all upstream probes, not per stored observation). The `bail` signal (`1bail`) comes from a composition attempt where the upstream budget exhausted before the downstream started — this contributes to the profiling counter `fibreBailCount` but does not affect `edgeObservations` (it was overwritten by the later probe).

This means per-edge budget adaptation on cycle 2 sees `exhaustedWithFailure` for this edge (the last probe's observation), not the earlier `exhaustedClean`. The profiling counters and the stored observation diverge — the counters reflect all probes, the stored observation reflects only the last.

**Speculative redistribution** does not run — `cycleImproved` is true (the composition found `[1, 1, 2]`), and phases with `requiresStall: true` are skipped when any prior phase accepted.

### Cycle 2: signals guide the search

The sequence is now `n = 2, [1, 1, 2]` — already the global minimum. Cycle 2 exists because the stall budget requires consecutive non-improving cycles before termination. This cycle confirms no further reduction is possible.

The adaptive strategy reads the prior cycle's signals:

1. **Structural minimization gate**: the behavioral gate checks structural minimization's acceptances in cycle 1. There was one — structural minimization runs.

2. Structural minimization finds no further work. **Signal for cycle 3**: zero structural acceptances.

3. Value minimization runs. `LinearScanEncoder` scans the small ranges flagged by `nonMonotoneGap`. Binary search re-confirms the coordinate floors with warm-start from the convergence cache. No improvement.

4. **Cross-level minimization gating**: the adaptive strategy checks whether all edges were `exhaustedClean`. The stored observation for the single CDG edge is `exhaustedWithFailure` (from the last upstream probe at `n = 2`). Not all clean — cross-level minimization runs but finds no improvement.

5. **Per-edge budget**: the stored observation is `exhaustedWithFailure`, so this edge gets 150 materializations (+50%).

6. **`zeroingDependency` escalation**: the prior cycle produced `zeroingDependency` signals. Speculative redistribution's gate is an OR: run when stalled OR when `zeroingDependency` is present (`requiresStall: hasZeroingDependency == false`). Even if value and cross-level minimization made progress, speculative redistribution runs — but finds no improvement on the already-optimal sequence.

### Cycle 3: convergence

Structural minimization is **skipped** — the behavioral gate fires (zero structural acceptances in cycle 2). No materializations wasted.

Value minimization, cross-level minimization, and speculative redistribution run and find no improvement. The stall budget decrements to zero. The scheduler terminates. The counterexample is `[1, 1, 2]` — the global minimum that per-coordinate search alone cannot reach.

### What the signals accomplished

| Signal | When observed | Effect |
|--------|-------------|--------|
| `zeroingDependency` (×3) | Cycle 1 | Speculative redistribution escalation on cycle 2: runs regardless of prior progress |
| `nonMonotoneGap` | Cycle 1 | `LinearScanEncoder` on cycle 2 resolves whether lower floors exist |
| `exhaustedWithFailure` (stored) | Cycle 1 | Per-edge budget increased to 150 for this edge on cycle 2 |
| `exhaustedClean` (profiling only) | Cycle 1 | Accumulated in profiling counters; overwritten in stored observation by the later `exhaustedWithFailure` |
| `bail` (profiling only) | Cycle 1 | Accumulated in profiling counters; overwritten in stored observation |
| `scanComplete` | Cycle 2 | Factory reverts to binary search on cycle 3 |
| Structural work absence | Cycle 2 | Structural minimization skipped on cycle 3 — no wasted lifts |

Without these signals, the `StaticStrategy` runs structural minimization on every cycle (wasting lifts when no structural work exists), gives every edge 100 materializations (overallocating to futile edges, underallocating to productive ones), and gates speculative redistribution only on full stall (delaying redistribution for coupled coordinates).

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
     Either gate firing → structural minimization skipped.
```

### Per-coordinate signals (convergence cache)

These signals are produced by value encoders at convergence and stored in `ConvergedOrigin` alongside the warm-start bound. The `EncoderFactory` pattern-matches on them to select the recovery encoder for the next cycle.

**1. `nonMonotoneGap(remainingRange: Int)`**

Produced by `BinarySearchEncoder` when it converges above the target and the remaining range is within the scan threshold (≤ 64 values). Binary search cannot distinguish a genuine floor from a gap in a non-monotone failure surface. A non-monotone surface is one where the property alternates between pass and fail across a coordinate's range — for example, failing at values `{0, 1, 5, 6, 7}` but passing at `{2, 3, 4}`. Binary search from 7 downward converges at 5, missing the true minimum at 0.

The signal triggers `LinearScanEncoder`, which scans the remaining range once (bounded at 64 probes) to either find a lower floor or confirm the binary search result.

The scan is a one-time intervention: `scanComplete(foundLowerFloor:)` tells the factory to revert to binary search on the next cycle. If the failure surface shifts (due to neighboring coordinate changes), binary search may emit another `nonMonotoneGap` — the scan-revert-scan loop converges naturally.

**2. `zeroingDependency`**

Produced by `ZeroValueEncoder` when batch zeroing (all coordinates to zero simultaneously) fails but at least one individual zeroing succeeds. This indicates coupled coordinates — zeroing one alone breaks an invariant that holds when neighbors are also zeroed. The factory suppresses `ZeroValueEncoder` for those coordinates on subsequent cycles. This suppression is per-cycle — the signal is refreshed each cycle, so if a neighboring coordinate changes and batch zeroing might now succeed, the signal won't be present and `ZeroValueEncoder` runs normally.

The adaptive strategy escalates to speculative redistribution, where redistribution encoders handle coupled coordinates through value transfer.

**3. `scanComplete(foundLowerFloor: Bool)`**

Produced by `LinearScanEncoder` when its bounded scan finishes. `foundLowerFloor: true` means the scan found a failure below the binary search convergence point — the non-monotonicity was real, and the new bound is the scan's discovery. `foundLowerFloor: false` means the scan confirmed the binary search floor — the remaining range was legitimately passing. Either way, the factory reverts to binary search on the next cycle.

### Per-edge signals (edge observations)

These signals are produced by the composition pipeline after each CDG edge completes and stored in `EdgeObservation` keyed by region index. The adaptive strategy reads them for per-edge budget adaptation and cross-level minimization gating.

**4. `exhaustedClean`**

The downstream encoder fully searched the fibre and found no failure. For structurally constant edges (fibre shape invariant under upstream value changes), the composition skips the edge at the observed upstream value on subsequent cycles. For data-dependent edges, the skip does not fire — value minimization may have changed downstream coordinates between cycles, altering the property's behavior within the fibre even at the same upstream value. However, the per-edge budget adaptation still applies: a `exhaustedClean` data-dependent edge gets 50% budget reduction (50 instead of 100 materializations), giving it less budget without skipping it entirely.

When all edges are `exhaustedClean`, the adaptive strategy gates cross-level minimization entirely — no edge has unexplored territory.

**5. `exhaustedWithFailure`**

The downstream found a failure in the fibre. The adaptive strategy increases this edge's sub-budget by 50% of the fixed 100-materialization base, giving it 150. The adaptation is one-step, not compounding — a persistently productive edge stays at 150 every cycle (not 150 → 225 → 337). Similarly, a persistently bailed edge stays at 50. This prevents a single edge from consuming the entire cross-level minimization budget.

**6. `bail(paramCount: Int)`**

The composition attempt produced zero downstream probes. The `bail` signal fires when `totalDownstreamStarts == 0` — the composition consumed all its upstream budget on lifts that either failed or exhausted the per-edge sub-budget before the downstream started searching. `DownstreamPick`'s `ZeroValueEncoder` fallback guarantees downstream probes once the downstream starts, so `bail` reflects upstream-side exhaustion, not downstream-mode inadequacy. The adaptive strategy reduces this edge's budget by 50%.

### Per-phase signal (span extraction + prior-cycle outcome)

**7. Structural work absence**

Two gates, checked at cycle start. Either gate firing skips structural minimization (they are ORed):

- **Structural gate**: `pruneOrder.isEmpty && tree.containsPicks == false` — span extraction (already computed by `computeEncoderOrdering()`) shows no deletion targets and the tree has no branch nodes. Catches scalar generators from cycle 1.
- **Behavioral gate**: the preceding cycle's structural minimization had zero acceptances (specifically `priorOutcome.baseDescent.structuralAcceptances == 0`). Only relevant when `pruneOrder` is non-empty (the structural gate already covers the empty case). Catches array generators where deletion targets exist but no deletion preserves the property. If structural minimization was gated (not run) in the prior cycle, this also evaluates to true — the skip perpetuates until structure changes.

  **Soundness note**: the structural gate is provably sound — if no spans exist, value minimization cannot create them (vertical morphism, base point invariant). The behavioral gate is a heuristic — value minimization changes values, and the property depends on values. A deletion that failed in cycle N might succeed in cycle N+1 after value minimization reduced the remaining elements. This manifested on Bound5: value minimization reduced an element to 0, but structural minimization was skipped, leaving a stray `0` in the counterexample.

  **Deletion probe**: to close this gap, when structural minimization is skipped, a lightweight structural pass (budget: 100) runs at the end of the cycle — after value minimization has settled values. The probe catches deletions enabled by value changes without running the full structural minimization pipeline. On Bound5, the probe deletes the stray `0` and produces the correct two-element counterexample. On BinaryHeap, the probe reduced materializations from 705 to 697.

Value minimization only changes values within a fixed structure — it cannot create structural deletion targets. If span extraction shows no targets, value minimization cannot change this. The skip is correct for all subsequent cycles until a phase that changes structure runs (cross-level minimization or speculative redistribution set `structureChanged: true` on acceptance, which invalidates the span cache and creates new deletion targets). When structure changes, the next cycle's `computeEncoderOrdering()` finds non-empty `pruneOrder`, and the structural gate does not fire — structural minimization runs.

This signal produces the largest measured impact: BinaryHeap saves 117 materializations (17%) with a 36% wall-clock speedup by skipping structural minimization on cycles where the structure is already minimal.

## Signal interaction

The signals gate different phases and don't conflict:

- `zeroingDependency` gates speculative redistribution (removes `requiresStall`, so it runs even when prior phases made progress).
- `exhaustedClean` gates cross-level minimization (skips when all edges are clean).
- Structural work absence gates structural minimization.
- Per-edge budgets adjust within cross-level minimization (not a phase gate).
- `nonMonotoneGap` and `scanComplete` affect encoder selection within value minimization (not a phase gate).

If `zeroingDependency` wants speculative redistribution to run but all edges are `exhaustedClean`, both fire independently: cross-level minimization is skipped (no edges to explore), speculative redistribution runs (coupled coordinates need redistribution). There is no conflict.

**Within a phase**, signals also apply independently. If `nonMonotoneGap` triggers `LinearScanEncoder` for a coordinate and `zeroingDependency` suppresses `ZeroValueEncoder` for the same coordinate, both encoder-selection decisions are applied by the factory without interaction — they affect different encoders in the value minimization descriptor chain.

## Categorical foundations and what they enable

The reducer's architecture draws on two categorical frameworks. Each provides specific guarantees that the implementation relies on for correctness and composability. This section states what the frameworks are, what they guarantee, and what those guarantees concretely enable in the reducer.

### The S-J algebra: morphisms, composition, and grades

The framework is from Sepulveda-Jimenez ("Categories of Optimization Reductions", 2026). It models reduction as a category **OptRed** where:

- **Objects** are optimization problems (here: choice sequences paired with a property).
- **Morphisms** are (encoder, decoder) pairs. The encoder proposes a candidate sequence; the decoder validates it by materializing through the generator and checking the property.

**Rules and guarantees:**

1. **Encoder/decoder separation.** The encoder is a pure mutation — it produces a candidate sequence without running the generator. The decoder runs the generator (the expensive lift) and checks the property. This separation means encoders are cheap to compose and reason about; the expensive step happens once at the end.

   *In practical terms*: you can build a new reduction strategy by writing an encoder that mutates the choice sequence — you never touch the generator, the property, or the materialization logic. The decoder handles all of that. If the encoder proposes a bad candidate, the decoder rejects it. The encoder cannot corrupt the reduction state.

2. **Kleisli composition.** Two morphisms can be composed through a lift: the first encoder's output is materialized (without property check) to produce fresh input for the second encoder. The property is checked only on the second encoder's final output. This is associative — compositions of compositions are well-defined. The generalization from ordinary function composition to Kleisli composition is §7 of Sepulveda-Jimenez: morphisms become *T*-effectful reductions `a = (enc_a : X → TY, dec_a : Y → TX)` where *T* is a monad, and composition uses the Kleisli bind `⊙` rather than ordinary `∘`. The `GeneratorLift` IS this monadic bind — it threads the generator's effects (PRNG, structure derivation) through the composition.

   *In practical terms*: you can take a "reduce the bind-inner" encoder and a "search the fibre" encoder and wire them together without writing any glue code. The composition handles the materialization between them — the `GeneratorLift` replays the generator at the upstream's proposed value, producing a fresh sequence and tree for the downstream. The upstream encoder doesn't know the downstream exists, and vice versa — they are independently testable.

3. **Grade structure.** Each morphism carries a grade that describes the strength of its guarantee:
   - **Exact**: the accepted candidate is strictly shortlex-smaller. No slack.
   - **Bounded**: the accepted candidate is shortlex-smaller after re-derivation, but re-derivation may introduce bounded slack (for example, bind-inner reduction changes downstream ranges).
   - **Speculative**: the accepted candidate may temporarily worsen before a subsequent exploitation phase recovers.

   *In practical terms*: the scheduler runs deletion and value reduction first (exact — every acceptance is guaranteed progress), then redistribution (bounded — progress after accounting for range changes), then relax-round (speculative — might get worse before getting better). This ordering falls out of the grade structure, not from hand-tuning.

4. **Dominance ordering.** Morphisms can declare dominance: if morphism A accepts, morphism B is suppressed (for the current descriptor chain execution). This enables multi-tier strategies — guided search dominates regime probe dominates PRNG retries.

   *In practical terms*: when a cheap strategy succeeds, the expensive fallback doesn't run. The factory declares the relationship; the scheduler enforces it. You don't need conditional logic in the scheduling loop — the dominance edges handle it.

**What this enables in the reducer:**

- **`MorphismDescriptor`**: bundles encoder + decoder factory + budget + dominance edges into a single schedulable unit. The factory produces arrays of descriptors; `runDescriptorChain` processes them.
- **Phase ordering**: exact morphisms (structural minimization, value minimization) run before bounded (redistribution) before speculative (speculative redistribution). The grade structure makes this ordering principled, not arbitrary.
- **`KleisliComposition`**: composes an upstream encoder and a downstream encoder through a `GeneratorLift`. The algebra guarantees this is well-formed — the composed morphism is itself a morphism in **OptRed**, with a grade derived from the component grades.
- **Role-agnosticity**: the `ComposableEncoder` protocol has no notion of "upstream" or "downstream." Any encoder can serve in any role because the algebra's composition rules handle the wiring. The factory assigns roles based on CDG position, not on encoder type.

### The Grothendieck opfibration: fibres, lifts, and unique factorization

The framework is the standard categorical structure for families of categories parameterized by a base. Applied to the reducer:

- **Base category *B***: objects are base points (choice tree shapes, identified by `StructuralFingerprint`). A morphism `n → k` is a reduction of a controlling value (bind-inner) from `n` to `k`.
- **Fibre *F(n)***: for each base point `n`, the category of valid downstream configurations — choice sequences where every bound entry is in range for the generator materialized at `n`.
- **Reindexing functor *F(n → k)***: a base morphism `n → k` induces a functor `F(n) → F(k)`. This is the `GeneratorLift` — it replays the generator at `k`, producing a fresh downstream sequence. The functor is covariant (pushforward), making this an opfibration, not a fibration.

**Rules and guarantees:**

1. **Opcartesian lifting.** For every base morphism `n → k` and every downstream configuration `x` in `F(n)`, there exists a canonical lift to a configuration in `F(k)`. The `GeneratorLift` computes this: it materializes the downstream at `k`, clamping or regenerating entries that fall out of range. This lift is *opcartesian* — it is the universal way to push a downstream configuration forward along a base change.

   *In practical terms*: when the upstream encoder proposes reducing the bind-inner from 7 to 4, the lift automatically produces a valid downstream sequence at `n = 4`. The reducer doesn't need to manually adjust array lengths, clamp out-of-range values, or re-derive dependent structure — the lift handles all of it by replaying the generator. There is exactly one canonical way to do this, and the `GeneratorLift` computes it.

2. **Unique factorization.** Every morphism in a composition decomposes uniquely into an opcartesian (base change) component and a vertical (within-fibre) component. There is exactly one way to factor a composed reduction step into "which base change happened" and "which fibre reduction happened." This is a theorem, not a convention.

   *In practical terms*: when a composition reduces `n` from 7 to 2 and simultaneously finds `[1, 1, 2]` in the fibre, the scheduler knows unambiguously that the structural part was "reduce n" (opcartesian) and the value part was "find [1, 1, 2]" (vertical). Signals about the structural part (edge observations) and signals about the value part (convergence records) are attributed to the correct scope automatically. There is no ambiguity about which signal describes which aspect of the reduction.

3. **Structural constancy.** When the bound generator contains no nested binds or picks (`isStructurallyConstant == true`), the fibre `F(n)` has the same number of coordinates and the same dependency structure for all `n`. The coordinate *domains* may still differ (for example, `{0, ..., n}` shrinks as `n` decreases), so the reindexing functor is not the identity — it maps between fibres of the same shape but potentially different domains. The key property: the fibre's *structure* (number of choice points, dependency edges) is invariant under upstream changes.

   *In practical terms*: for a structurally constant edge, the downstream encoder faces the same "shape" of search problem regardless of the upstream value. Three array elements are always three array elements, even if their ranges change. This lets the scheduler reuse observations about the fibre's structure across different upstream values — the `exhaustedClean` skip relies on this property.

**What this enables in the reducer:**

- **CDG construction**: the `ChoiceDependencyGraph` identifies the fibrational structure at runtime — which positions are base points (bind-inners), which positions are fibre coordinates (bound content), and which edges represent reindexing functors.
- **Composition safety**: the unique factorization guarantees that the upstream and downstream encoders in a `KleisliComposition` cannot interfere. The upstream changes the base point; the downstream searches the fibre. These are independent concerns — the fibrational structure proves they don't interact.
- **`exhaustedClean` skip correctness**: the skip checks that the upstream value matches the observed value and that the edge is structurally constant. The `GeneratorLift` has its own resolution modes (distinct from the morphism grade "exact" — the lift mode controls how the materializer resolves sequence positions). In exact lift mode, all values are read from the prefix (the current sequence) — the PRNG fallback is unused when the prefix covers all positions. This means the fibre content depends on the full sequence, not just the upstream value: if value minimization changed downstream values, the prefix differs, and the lift reads different downstream values. The skip is therefore a heuristic, not a proof — the fibre's structure is invariant (structurally constant), but the specific values within the fibre may have shifted.

  In practice, the heuristic is conservative: Value minimization moves values toward their targets (smaller), which typically makes the fibre's failure landscape harder to satisfy (the property is more likely to pass on smaller values). A prior exhaustive search that found no failure in a larger-valued fibre is unlikely to miss a failure in a smaller-valued one. No test in the suite exhibits a missed improvement from this gap.
- **Signal attribution**: the unique factorization gives a natural scope for each signal type. Per-coordinate signals (convergence cache) are vertical — they describe what happened within a fibre at a specific coordinate. Per-edge signals (edge observations) are opcartesian — they describe what happened when the base changed along a specific CDG edge. The decomposition ensures these don't overlap.
- **Structural minimization skip correctness**: Value minimization, the only intervening morphism between structural minimization cycles, is vertical — it operates within a fibre without changing the base point. If the base point has no deletable structure (no spans, no branches), value minimization cannot create any because it never changes the base point. The fibrational structure proves this — it's not just an empirical observation.

### How they come together: framework, decomposition, policy

The reducer's architecture rests on three pillars, each with a distinct responsibility:

**1. The S-J algebra provides the framework** — the vocabulary of legal moves. It defines what a morphism is (an encoder/decoder pair), how morphisms compose (Kleisli composition through a lift), what guarantees each morphism provides (grades: exact, bounded, speculative), and how morphisms relate to each other (dominance ordering).

Without the algebra, encoders would be ad hoc functions. With it, every encoder is a typed morphism in a category, composition is associative and well-defined, and the grade structure gives a principled phase ordering (exact before bounded before speculative). The `MorphismDescriptor` type is the algebra's representation in code — it bundles the encoder, the decoder factory, the budget, and the dominance edges into a single schedulable unit.

**2. The Grothendieck opfibration provides the decomposition** — it defines which reduction steps are legal and where they operate. The fibrational structure decomposes the total space of choice sequences into a base (structural shapes) and fibres (value configurations within each shape). Every morphism in a composition factors uniquely into an opcartesian component (a base change — structural) and a vertical component (a fibre reduction — value-level).

Without the decomposition, a composition would be an opaque reduction step — the scheduler couldn't tell which part was structural and which was value-level. With it, the scheduler knows: structural minimization morphisms operate on the base, value minimization morphisms operate on fibres, and cross-level minimization morphisms factor into both. The CDG is the runtime discovery of this fibrational structure — it identifies which positions are base points (bind-inners), which are fibre coordinates (bound content), and which edges represent reindexing functors. The unique factorization guarantees that signal attribution is unambiguous: a per-coordinate signal is vertical, a per-edge signal is opcartesian, and these scopes cannot overlap.

**3. The seven signals provide the policy** — the dynamic decisions that neither the algebra nor the fibration prescribes. Given a CDG with three edges and five encoder types, the algebra says which compositions are well-formed. The fibration says which decompositions are canonical. But neither says: run this edge first, give it 150 materializations, skip structural minimization this cycle, escalate to redistribution because coordinates are coupled.

The signals bridge this gap. Each signal originates in the `ReflectiveGenerator`'s structure, passes through the interpreter and encoder pipeline, and arrives at the scheduler as a typed observation with a categorical scope determined by the fibration:

**Vertical signals** (per-coordinate) originate in `.chooseBits` operations — the `ReflectiveGenerator`'s primitive for drawing a value from a bounded integer range. Each `.chooseBits` becomes a coordinate in the choice sequence with a `validRange` and a `bitPattern64`. Value encoders (`BinarySearchEncoder`, `ZeroValueEncoder`, `LinearScanEncoder`) operate on these coordinates. When they converge, they write a `ConvergenceSignal` into the `ConvergedOrigin` stored in the convergence cache. The `EncoderFactory` reads these signals on the next cycle to select the recovery encoder.

- `nonMonotoneGap` — binary search over a `.chooseBits` coordinate converged above its reduction target. The gap between the convergence point and the target may contain failures that binary search missed.
- `zeroingDependency` — batch zeroing of multiple `.chooseBits` coordinates failed, but individual zeroing succeeded. The property couples these coordinates — their values are constrained relative to each other.
- `scanComplete` — the linear scan over a `.chooseBits` coordinate's gap has finished. The question is resolved.

**Opcartesian signals** (per-edge) originate in `.transform(.bind(...))` operations — the `ReflectiveGenerator`'s reification of monadic bind, which creates a data dependency between an inner generator (the base point) and a bound generator (the fibre). The VACTI interpreter records these as `ChoiceTree.bind(inner:, bound:)` nodes. The `ChoiceDependencyGraph` walks the tree to identify dependency edges. `KleisliComposition` composes an upstream encoder (operating on the bind-inner) with a downstream encoder (operating on the bound content) through a `GeneratorLift`. After the composition loop exhausts, `runKleisliExploration` writes an `EdgeObservation` per CDG edge.

- `exhaustedClean` — the downstream fully searched the fibre at this base point and found no failure. The composition's vertical component is exhausted for this opcartesian step.
- `exhaustedWithFailure` — the downstream found a failure. The composition's vertical component was productive.
- `bail` — the upstream exhausted its budget before the downstream started. The opcartesian step consumed all resources without reaching the vertical component.

**The global signal** (structural work absence) originates in `.sequence(length:, gen:)` and `.pick(choices:)` operations — the `ReflectiveGenerator`'s structural primitives for collections and branches. These produce container spans, sequence boundaries, and branch nodes in the choice sequence. `computeEncoderOrdering()` extracts deletion span counts (`pruneOrder`) and checks `tree.containsPicks`. If both are empty, no base-change morphism (structural deletion or branch simplification) has applicable targets.

Each signal has a categorical scope from the fibration, a generator origin from the `ReflectiveGenerator`, and a policy effect that selects, gates, or adjusts morphisms from the algebra's vocabulary:

| Signal | Generator origin | Categorical scope | Policy decision |
|--------|-----------------|------------------|-----------------|
| `nonMonotoneGap` | `.chooseBits` | Vertical | Replace binary search with linear scan |
| `zeroingDependency` | `.chooseBits` (multiple, coupled) | Vertical | Escalate to speculative redistribution |
| `scanComplete` | `.chooseBits` | Vertical | Revert to binary search |
| `exhaustedClean` | `.transform(.bind(...))` | Opcartesian | Skip this base change (heuristic) |
| `exhaustedWithFailure` | `.transform(.bind(...))` | Opcartesian | Increase budget for this base change |
| `bail` | `.transform(.bind(...))` | Opcartesian | Decrease budget for this base change |
| Structural work absence | `.sequence`, `.pick` | Base (global) | Skip structural minimization |

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
| Structural minimization | Always runs | Skipped when no structural work |
| Phase budgets | 1950 / 975 / 325 per phase | 2000 ceiling per phase |
| Per-edge budget | Fixed 100 per edge | Observation-driven: 50 / 100 / 150 |
| Cross-level gating | Binary: "no progress" | Signal: all edges `exhaustedClean` |
| Redistribution gating | Binary: "no progress after cross-level" | Also runs on `zeroingDependency` |
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

**BinaryHeap decomposition** (15 cycles, the largest test): structural minimization drops from 548 to 431 materializations — all 117 savings come from the behavioral gate skipping structural deletion on cycles where the structure was already minimal. Value minimization is unchanged (155 in both). Cross-level minimization shows `edges=0` in the adaptive run vs `edges=4` in static — but this is the `requiresStall` stall gate, not the signal-driven `exhaustedClean` gate. On cycles where structural or value minimization accepted, cross-level minimization was already skipped by the stall gate. The signal-driven cross-level gating and per-edge budget adaptation contributed zero savings on this test.

Tests with zero saving (Difference, Replacement, Bound5Path1) either run a single cycle (no prior-cycle signal to read) or have continuous structural work (structural minimization never skipped).

## Failure modes and self-correction

Signals are observations about the prior cycle's state. If the state changes between cycles (due to other phases' acceptances), a signal can be stale. The scheduler self-corrects in all cases:

**Stale `exhaustedClean`**: The skip only fires for structurally constant edges at the same upstream value. The lift in exact mode reads downstream values from the current sequence prefix — if value minimization changed those values, the fibre content differs from when the observation was recorded. The skip is a heuristic: the fibre *structure* is invariant (structurally constant), but the specific values differ. In practice, value minimization moves values toward targets (smaller), making the fibre's failure landscape harder to satisfy — a prior exhaustive search that found no failure in a larger-valued fibre is unlikely to miss one in a smaller-valued fibre. For data-dependent edges, the skip does not fire — the edge runs with reduced budget (50 instead of 100). On the next cycle, a fresh observation replaces the stale one. No test in the suite exhibits a missed improvement.

**Stale `nonMonotoneGap`**: A coordinate was flagged for linear scan, but a neighboring coordinate changed between cycles, resolving the non-monotonicity. The scan runs (≤ 64 probes, one-time cost), confirms the floor, and emits `scanComplete`. The factory reverts to binary search. Cost: one unnecessary scan, bounded and non-recurring.

**Stale `zeroingDependency`**: Batch zeroing failed in cycle N, but a neighboring coordinate was reduced in cycle N, and batch zeroing might now succeed. The signal is refreshed each cycle — `ZeroValueEncoder` runs in cycle N+1 (the suppression is per-cycle, not permanent), batch zeroing is re-attempted, and if it succeeds, no `zeroingDependency` is emitted. Self-correcting within one cycle.

**Structural minimization skip when structural work appears**: two sub-cases:

1. *Cross-level or speculative redistribution changed structure*: `structureChanged: true` invalidates the span cache. The next cycle's `computeEncoderOrdering()` finds non-empty `pruneOrder` — the structural gate does not fire, and structural minimization runs. Self-correcting within one cycle.

2. *Value minimization enabled a deletion*: value minimization reduced a value to zero or a no-op, making a previously-failed deletion now viable. This manifested on Bound5 — a stray `0` element was left in the counterexample because structural minimization was skipped. **Fixed with a deletion probe**: when structural minimization is skipped, a lightweight structural pass (budget: 100) runs at the end of the cycle to catch deletions enabled by value changes. Self-correcting within the same cycle.

For `nonMonotoneGap`, `scanComplete`, and `zeroingDependency`, stale signals produce at most one cycle of suboptimal scheduling, after which the signal is refreshed from the current state. The `exhaustedClean` skip remains a heuristic — it can theoretically miss an improvement that value minimization's changes enabled. No test in the suite exhibits this gap.

**When to suspect the exhaustedClean gap**: properties where the failure condition becomes *easier* to satisfy with smaller values within a fibre — for example, a threshold that is *harder* to exceed when values are reduced. Most properties (sum bounds, size checks, ordering invariants) become easier to pass with smaller values, making the heuristic conservative.

**Diagnostic**: run both strategies on the same seed and compare the final counterexample. If `AdaptiveStrategy` produces a longer or shortlex-larger counterexample than `StaticStrategy`, a gap manifested. The `AdaptiveComparison` test suite performs this comparison for key generators.
