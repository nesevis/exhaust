# Compositional Encoder Algebra for the Bonsai Reducer

## Context

### The arc from flat passes to closed-loop control

The starting point was MacIver's flat choice sequence with 15 organically accumulated passes and no feedback between them. Each pass runs, succeeds or fails, moves on. No pass knows how the previous pass's mutations survived materialization. No pass adjusts its strategy based on what the reducer has learned. The scheduling is static — the pass order is fixed, the budget per pass is fixed, the target selection is fixed.

Exhaust's first contribution was the **fibration**: the phase ordering is canonical (base before fibre), the dominance lattice prunes redundant encoders, and the DAG directs the sweep order. This replaced static heuristics with structural principles. But the principles are still static — they are properties of the generator's topology, computed once at the start of each cycle. They do not adapt to what happens during the cycle.

The **convergence cache** was the first adaptive element. It carries information across cycles — stall points from the previous fibre descent warm-start the next one. But it is a passive cache. It records and replays. It does not influence which encoders run or how they are configured.

The **lift report** changes the character of the whole system. It is not a cache — it is a *signal*. Every time the generator lift runs (the monad T — replaying a mutated sequence through the generator to produce a fresh tree), the lift report describes the quality of the passage. That signal can flow into encoder selection, budget allocation, composition strategy, exploration filtering, and phase transitions. Each of these is a feedback loop: encoder acts → T interprets → lift report describes → next encoder adapts. The reducer becomes a closed-loop control system rather than an open-loop pipeline.

The **composed reduction** is the architectural form that makes this feedback actionable. The current 20 encoders are monolithic maps from `(ChoiceSequence, ChoiceTree)` — or in some cases just `ChoiceSequence` — to `Stream<ChoiceSequence>`. The scheduler orchestrates them procedurally — which encoders run, in what order, with what scoping. Composition is implicit in the scheduler's control flow, not expressible at the encoder level. Some reductions require intermediate materialization: reducing a bind-inner value changes the structure of the bound subtree, so the next encoder needs a fresh tree before it can operate. Today this is handled by running base descent in one cycle and fibre descent in the next. The composition is invisible — buried in the scheduler's phase ordering.

The key insight is that the materialization between two encoders is a **Kleisli bind**, not a side effect of the scheduler. Making this explicit produces an algebra where:
- Encoders are composable units of computation
- Composition of two encoders implies a generator lift between them
- The CDG (`ChoiceDependencyGraph` — a DAG of structural dependencies derived from the `ChoiceTree`, which contains the full branch structure) finds the edges where composition is meaningful; the fibration names the operations
- The lift report provides per-coordinate feedback on how each mutation survived T
- Rollback semantics are configurable per composition

The destination: a reducer where the fibration provides the structure (what to do), the algebra provides the composition rules (how to combine), and the lift report provides the feedback (how well it is working). The reducer becomes a closed-loop control system — not "try everything and stop when nothing works" but "learn what works, do more of it, learn what does not, stop doing it, and terminate when the feedback confirms local minimality."

## Categorical Model

### S-J framework and Kleisli composition

Sepúlveda-Jiménez §7 lifts the full reduction morphism `(enc, dec): P → Q` into the Kleisli category `Kl(T)`, where T is a monad capturing nondeterminism in the reduction. A Kleisli morphism is `A → T(B)` — a reduction that produces its output through a monadic effect. Composition in the Kleisli category is `(b ⊙ a)(x) = μ(T(b)(a(x)))` — apply a, get a monadic result, bind b over it.

In the composed reduction, the monad T is the generator lift. The three components are:

```
upstream.enc:   ChoiceSequence → ChoiceSequence             (pure mutation)
lift:           ChoiceSequence → T(ChoiceSequence, Tree)     (the Kleisli lift)
downstream.enc: (ChoiceSequence, Tree) → ChoiceSequence      (pure mutation in the new fibre)
```

The upstream encoder proposes a sequence mutation (a pure operation — just changing values in the sequence). The generator lift replays that mutated sequence through the generator to produce a fresh `(sequence, tree)` pair. The downstream encoder operates on that fresh pair. The monadic effect is the replay — it takes a pure sequence and lifts it into the world of `(sequence, tree)` pairs by running the generator. The Kleisli bind is `lift` — the `μ: T²X → TX` that takes the upstream encoder's output and produces the downstream encoder's input.

### Factored composition: encoding-only Kleisli composite

S-J §7 composes full `(enc, dec)` morphisms in the Kleisli category — the decoder is applied at each stage. The composed reduction composes only the `enc` halves in the Kleisli category and defers the `dec` (property check) to the boundary:

```
(enc_composed, dec) = (enc_downstream ⊙_T enc_upstream, dec)
```

where `⊙_T` is Kleisli composition over the generator lift monad, and `dec` is applied once to the final output. The intermediate lift is the monadic bind, not a full decode-then-re-encode step.

This avoids the intermediate property check — the one cost Exhaust cannot make cheaper (see "The cost asymmetry" below). The intermediate lift is pure internal cost; the property check is external, unknown-cost. Deferring `dec` to the boundary trades internal cost (one extra lift) for external cost (one fewer property invocation at the intermediate step). The S-J framework allows this because the encoding and decoding inequalities are independent — the encoding inequality (`enc` does not worsen the objective) can be checked on the composite without checking it at each stage, as long as the final `dec` validates the result. The checkpoint guard at the exploration level is exactly this final validation.

### The generator lift monad and coverage

When the lift has coverage 1.0 (no PRNG fallback), T is the identity monad — the lift is deterministic, and the Kleisli composition degenerates to ordinary composition. When coverage < 1.0 (PRNG involved), T is genuinely nondeterministic — the same upstream mutation can produce different fibres on different lifts. The Kleisli structure is essential precisely when coverage is low, because it acknowledges that the intermediate step is effectful.

The coverage metric from the lift report measures how far T is from the identity monad — how much genuine monadic effect the generator lift introduces.

### Grade of the composite

In S-J's grading (Section 10), the composite morphism's grade combines the grades of its components. With the Kleisli bind in between, the lift's "grade" is its coverage — a high-coverage lift is nearly exact (the bind is nearly the identity), a low-coverage one is speculative (the bind introduces significant nondeterminism). The composite's grade is `min(grade(upstream), coverage(lift), grade(downstream))`. This is why coverage serves as the composition quality signal — it is the grade of the Kleisli bind itself.

### Fibration structure

The `upstream → GeneratorLift → downstream` decomposition maps onto the fibration's structure. When the upstream encoder targets a controlling position (bind-inner, branch selector), it proposes a base change, and the generator lift computes the cartesian lift — carrying the fibre along the base morphism to produce the new fibre over the reduced base point. When the upstream targets a non-controlling position, there is no base change, and the lift is a plain re-materialization (validating the mutation, not transporting a fibre). The downstream encoder operates in whichever trace the lift produced. The property check happens only on the final output — the composite is evaluated as a unit.

The base/fibre distinction is not a property of the encoder — it is a property of the *position*. A binary search toward zero on a leaf position is a vertical morphism (the value changes, the structure does not, the fibre stays the same). The same binary search toward zero on a bind-inner position is a base morphism (the value changes, the downstream structure reshapes). The encoder does not know which role it plays. The position's relationship in the CDG — controlling or non-controlling — determines whether the lift between two encoders is substantial or trivial.

### The cost asymmetry

The factored composition — composing `enc` halves in the Kleisli category, deferring `dec` to the boundary — is not just categorically cleaner. It is built around a fundamental asymmetry in what Exhaust controls.

**The generator lift is internal cost.** Exhaust controls materialization — replaying a choice sequence through the generator to produce a `(sequence, tree)` pair. This cost is internal, measurable, and optimizable. The convergence cache, the lift report, the simplest-values probes, the coverage gating — all of these optimize materialization cost. Exhaust can make materialization cheaper, faster, and less frequent.

**The property is external cost.** The property is a user-provided `(T) -> Bool`. It could be a single integer comparison (nanoseconds) or a full compiler invocation (seconds). The cost is external, unknown, and not optimizable. Exhaust can only control how many times it *calls* the property, not how long each call takes.

Every architectural decision — the phase ordering, the convergence cache, the antichain search, the composed reduction — is ultimately about reducing the number of times the property oracle is called, because that is the one cost Exhaust can reduce but cannot make cheaper per call.

**The composed reduction's trade-off.** The generator lift is pure internal cost — no property check. The upstream encoder proposes candidates and the lift materializes each one, all without calling the property. Only the downstream encoder's final output gets property-checked. So the composed reduction trades *internal* cost (extra lifts) for *external* cost (fewer property evaluations across cycles, because the cross-level composition is discovered in one cycle instead of many).

This trade-off is always favorable when the property is expensive — every avoided cycle saves a full round of property evaluations. It is marginal when the property is trivial — the extra lifts may cost more than the property evaluations they avoid.

**Why convergence transfer matters.** Without convergence transfer, the downstream encoder runs a full search for each upstream candidate — many lifts and many property evaluations. With it, the downstream encoder converges in one or two probes per upstream candidate — the warm start eliminates the downstream's search cost. The composed reduction's total property evaluation count drops from `upstream_candidates × downstream_search_depth` to approximately `upstream_candidates × 1`. The internal cost (lifts) stays the same, but the external cost (property calls) drops dramatically.

## Motivating Example: The Coupling Challenge

The coupling challenge demonstrates a cross-level minimum that the current pipeline cannot reach. The generator produces a length `n` (bind-inner) and an array of integers in `0...n` (bound content):

```swift
#gen(.int(in: 0 ... 10))
    .bind { n in
        #gen(.int(in: 0 ... n)).array(length: 2 ... max(2, n + 1))
    }
    .filter { arr in arr.allSatisfy { arr.indices.contains($0) } }
```

The property rejects arrays containing a 2-cycle: `arr[arr[i]] == i` for some `i ≠ arr[i]`. The expected minimal counterexample is `[1, 0]` (at `n = 1`).

**Why the current pipeline misses it.** Suppose the initial counterexample is `n = 5, [3, 4, 1, 0, 2]` (2-cycle at positions 0 and 3).

Phase 1c (`runJointBindInnerReduction`) tries reducing `n`:
- `n = 0`: array range `0...0`, length fixed at 2, array `[0, 0]`. No 2-cycle possible (every element maps to itself). Property passes. Rejected.
- `n = 1`: array range `0...1`, length fixed at 2. The materializer fills the bound array via guided replay. If the fallback tree or PRNG fills `[0, 0]`, `[0, 1]`, or `[1, 1]`, no 2-cycle. Only `[1, 0]` creates one. All four points pass the filter (both indices 0 and 1 are valid), so the filter does not reduce the fibre — it is a single failing point in an unfiltered 4-element fibre. Guided replay is unlikely to hit it. Rejected.
- `n = 2`, `n = 3`: similar — the specific downstream values required for a 2-cycle are not discovered by single-shot materialization.

Phase 1c exhausts without reducing `n` below 5 (or wherever it stalls). Phase 2 (fibre descent) then reduces the array values within the `n = 5` fibre. It can shorten the 2-cycle or simplify element values, but it cannot change `n` — it operates within a fixed structure.

The minimal counterexample `[1, 0]` requires `n = 1` AND the specific array `[1, 0]`. Neither phase discovers this because they search independently: Phase 1c proposes base values without exploring the fibre, and Phase 2 explores the fibre without changing the base.

**How the composed reduction finds it.** The composed reduction searches both levels jointly:
1. Upstream encoder proposes `n = 1` (targeting the bind-inner position — a base morphism, because the CDG has a dependency edge from this position to the bound subtree).
2. Generator lift materializes: fresh tree with element range `0...1`, length `2...2`. No property check.
3. Downstream encoder reduces array values in the `n = 1` fibre (targeting the bound subtree — a fibre morphism at this position). It tries `[1, 0]`. Property fails (2-cycle at positions 0 and 1). Accepted.

The composition succeeds because the downstream encoder searches the fibre at the upstream encoder's proposed value, rather than relying on a single materialization to stumble onto the right combination.

## Key Types

### 1. PointEncoder (the primitive)

A point encoder operates on a specific position or range in the choice sequence. It is agnostic to its categorical role — the same encoder (for example, `BinarySearchStepper`) can serve as a base morphism when pointed at a controlling position or as a fibre morphism when pointed at a leaf position. The CDG determines the role, not the encoder.

```swift
/// Produces candidate mutations for a position (or range) in the choice sequence.
///
/// Point encoders are the composable primitives of the reduction algebra.
/// Each targets a specific point in the total space — agnostic to whether
/// that point is a base position (structural) or a fibre position (value).
/// The categorical role (base morphism vs vertical morphism) is determined
/// by the position's relationship in the CDG, not by the encoder itself.
protocol PointEncoder {
    var name: EncoderName { get }
    var phase: ReductionPhase { get }

    /// Initializes for the given positions in the sequence.
    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    )

    /// Returns the next candidate sequence, or nil when exhausted.
    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence?

    /// Convergence records from completed coordinates.
    var convergenceRecords: [Int: ConvergedOrigin] { get }
}
```

### Interface changes from `AdaptiveEncoder` to `PointEncoder`

The existing `AdaptiveEncoder` interface is:

```swift
mutating func start(sequence: ChoiceSequence, targets: TargetSet, convergedOrigins: [Int: ConvergedOrigin]?)
mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence?
var convergenceRecords: [Int: ConvergedOrigin] { get }
```

Three things change in `start()`. Two are motivated by composability; one is a cleanliness improvement. Everything else stays the same.

**`TargetSet` → `positionRange: ClosedRange<Int>`.** This is the composability-critical change. The CDG provides a range — the controlling position or the controlled subtree — not pre-computed spans. Currently the scheduler extracts spans via `SpanCache`, wraps them in a `TargetSet`, and passes them to the encoder. With `PointEncoder`, the encoder receives a position range and derives its own targets within that range. The encoder knows what kinds of entries it cares about (values for binary search, container openers for deletion) and extracts them.

This inverts the responsibility: target selection moves from the scheduler into the encoder. The `LegacyEncoderAdapter` bridges this by converting `positionRange` back to a `TargetSet(.spans(...))` for the wrapped encoder. All examined encoders (ZeroValue, BinarySearch, DeleteContainerSpans) use only `.spans` from `TargetSet`, so the adapter extracts spans within the range and wraps them.

**`tree: ChoiceTree` added.** Branch promotion and pivot encoders already read the tree — they inspect branch alternatives to produce candidates. Currently they receive it via a stored property (`currentTree`) set externally before the scheduler calls `start()`. Passing `tree` in `start()` eliminates that side channel and makes tree access part of the protocol contract. Value encoders (zero, binary search, float) do not read the tree — they get valid ranges and range explicitness from the `ChoiceSequence` entries — but the parameter is available if future point encoders need it.

**`convergedOrigins` → `context: ReductionContext`.** A bag that bundles `convergedOrigins` with `bindIndex` and `dag`. Not a composability requirement — a cleanliness improvement that reduces the stored-property wiring some encoders need.

**`nextProbe(lastAccepted: Bool) -> ChoiceSequence?` does not change.** The downstream encoder returns a full candidate sequence. The composition yields it to the scheduler for materialization and property check. No need for richer return types (mutation descriptors, changed-position sets). If the scheduler or composition needs to know what changed, it diffs.

**`lastAccepted: Bool` does not change.** The composition forwards the scheduler's acceptance feedback to the downstream encoder. No need for richer feedback (rejection reason, lift coverage). The encoder navigates its search tree based on accept/reject; it does not need to know why.

**`convergenceRecords` does not change.** The composition distinguishes upstream records (promotable) from downstream records (ephemeral) internally.

**`estimatedCost` aligns with `start()`.** Its signature should take `positionRange` instead of bare `bindIndex`, but the semantics are the same: estimate how many probes the encoder will produce for the given inputs.

**Batch and adaptive unify.** `BatchEncoder.encode(sequence:targets:)` produces all candidates upfront. This is adaptive encoding where feedback is ignored — the batch iterator returns candidates sequentially and disregards `lastAccepted`. `PointEncoder` subsumes both:

```swift
// A batch encoder wrapped as PointEncoder:
mutating func start(...) {
    self.candidates = batchEncode(sequence: sequence, ...).makeIterator()
}
mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
    return candidates.next()  // ignores lastAccepted
}
```

The composition does not care whether the upstream or downstream is batch or adaptive. Both produce `ChoiceSequence?` from `nextProbe()`.

**`start()` must be cheap to call repeatedly.** In a composition, the downstream encoder's `start()` is called once per upstream probe — not once per composition. The existing encoders' `start()` methods are O(s) in span count (walk spans, filter, build internal state). For a composition with k upstream candidates and a downstream scope containing s spans, `start()` is called k times at O(s) each — total O(k × s). For typical values (k ≤ 15 for a binary search ladder over a small range, s ≤ 50 for a bound subtree), this is sub-millisecond and negligible relative to the property evaluation cost.

### 2. GeneratorLift (the Kleisli bind)

The generator lift between two point encoders. Replays a mutated sequence through the generator to produce a fresh tree without checking the property. Exposes a lift report for convergence transfer gating.

```swift
/// Lifts a raw sequence mutation into a valid trace by replaying
/// through the generator.
///
/// Categorically, this is the Kleisli bind μ: T²X → TX. It takes
/// a mutated choice sequence and replays it through the generator
/// to produce a fresh (sequence, tree) pair. The property is NOT
/// checked — only structural validity.
struct GeneratorLift {
    let gen: ReflectiveGenerator<Any>
    let mode: LiftMode

    enum LiftMode {
        /// Exact replay — rejects out-of-range values.
        case exact
        /// Guided replay with fallback tree for bound content.
        case guided(fallbackTree: ChoiceTree)
    }

    /// Lifts the candidate sequence to produce a fresh tree
    /// and a lift report describing the fidelity of the cartesian lift.
    ///
    /// Returns nil if the lift rejected the candidate
    /// (out of range, structural mismatch).
    func lift(
        _ candidate: ChoiceSequence
    ) -> LiftResult?
}

/// The output of a generator lift.
struct LiftResult {
    let sequence: ChoiceSequence
    let tree: ChoiceTree
    let liftReport: LiftReport
}
```

### The lift report as proprioception

The `LiftReport` is the closest thing Exhaust has to seeing inside the opacity wall without calling the property. It describes what happened during the last generator lift — how much of the output was determined by the encoder's proposal versus improvised by the materializer's PRNG fallback.

It measures how far the generator lift monad T is from the identity monad — how much genuine monadic effect the lift introduces. Coverage 1.0 means the Kleisli composition degenerates to ordinary composition (T is the identity monad). Coverage < 1.0 means the same upstream mutation can produce different fibres on different lifts. The composite's grade is `min(grade(upstream), coverage(lift), grade(downstream))` — coverage is the grade of the Kleisli bind itself.

**Per-coordinate resolution tiers.** The lift report classifies each coordinate by how it was resolved:

- **Tier 1 (exact carry-forward)**: the encoder's proposal at this coordinate survived T unchanged. The encoder got what it asked for. The fibre at this coordinate is the one the encoder intended to operate in.
- **Tier 2 (fallback tree)**: the encoder's proposal did not fit. The materializer substituted a structurally-informed value. The encoder asked for one thing and got something reasonable but different. The fibre at this coordinate is approximated.
- **Tier 3 (PRNG)**: the materializer had no information. The encoder's proposal was irrelevant — this coordinate was filled randomly. The fibre at this coordinate is unknown.

**Guiding downstream encoder selection.** A coordinate that consistently resolves at tier 1 is *stable* — the encoder's proposals are reaching the fibre faithfully. The current strategy is working. A coordinate at tier 2 is *approximated* — the encoder is proposing values the new structure cannot accommodate exactly. The fallback tree is doing the encoder's job. An encoder aware of the new domain (from the lift report) could propose values that land at tier 1 instead. A coordinate at tier 3 is *unconstrained* — no data source exists. Any value the encoder proposes will be overwritten by PRNG. This coordinate should be excluded from the downstream encoder's target set entirely — probing it is pure waste, because the property's response at this coordinate is random regardless of what the encoder proposes.

**Guiding composition strategy.** The lift report between adjacent upstream values determines the composition's behavior:

- **High coverage, high fidelity** (most coordinates tier 1): the fibres are similar. Use convergence transfer — the downstream's stall points from the previous upstream value are valid warm starts. The downstream encoder converges fast.
- **High coverage, low fidelity** (many coordinates tier 2, none tier 3): the fibres are different but deterministic. Many coordinates shifted, but none are random. The downstream encoder should run a full search — no warm start — but its results are reproducible and cacheable.
- **Low coverage** (many coordinates tier 3): the fibre is partially random. The downstream encoder's results are non-reproducible. The composed reduction should either skip this upstream candidate (the joint evaluation is meaningless) or run with `.partial` rollback (accept the upstream change alone if the downstream search finds nothing, since the downstream fibre was too noisy to search reliably).

**Guiding standalone fibre descent.** After a structural acceptance, the lift report from the acceptance materialization tells Phase 2 which coordinates are worth targeting:

- Tier 1 coordinates: the convergence cache is likely valid. Warm-start the binary search.
- Tier 2 coordinates: the convergence cache is stale (the value changed). Cold-start the binary search, but the coordinate is deterministic — the stall point will be reproducible.
- Tier 3 coordinates: skip entirely on the first fibre descent pass. The value is random — reducing it optimizes a random number. Wait until the next structural acceptance produces a higher-coverage lift that resolves this coordinate deterministically.

This last point is the most actionable near-term change. The current fibre descent treats every coordinate equally — same binary search, same budget, same priority. The lift report says some coordinates are not worth touching yet because their values were invented by PRNG and will be overwritten on the next materialization. Skipping them saves probes that would be wasted optimizing noise.

**How tier 3 filtering reaches the encoder.** The encoder itself stays agnostic — it does not inspect the lift report. The filtering happens at the scheduler level: the scheduler consults the most recent lift report when building the position range for `start()`, excluding tier 3 coordinates from the range. The `ReductionContext` does not need a `lastLiftReport` field; the scheduler pre-filters before the encoder sees the targets. This keeps the `PointEncoder` interface clean and places the lift-report-aware logic where the scheduling decisions are made.

**Guiding the exploration leg.** The relax-round redistributes between value pairs. Some pairs are tier 1 × tier 1 (both coordinates stable — redistribution is meaningful). Some are tier 1 × tier 3 (one coordinate stable, one random — redistributing from a deterministic value to a random one is wasteful). The lift report could filter redistribution pairs to those where both coordinates are tier 1 or tier 2 — the pairs where redistribution has a deterministic effect.

**The meta-pattern.** Every encoder in the pipeline produces a mutation. Every mutation passes through T. Every T produces a lift report. The lift report describes the quality of the passage through T. Currently that quality information is logged and discarded. If it were fed back into encoder selection, every subsequent encoder decision would be informed by how well the previous mutation survived materialization. The lift report is the reducer's proprioception — its sense of how its own actions are landing. Without it, the reducer operates blind, proposing mutations and hoping they survive T. With it, the reducer can feel whether its proposals are reaching the fibre faithfully or being mangled by the materializer, and adjust its strategy accordingly.

### 3. KleisliComposition

Composes two point encoders through a generator lift. The upstream encoder's categorical role (base or fibre morphism) is determined by the CDG — if the upstream position has outgoing dependency edges to the downstream range, it is a base morphism and the lift is substantial. If not, the lift is trivial.

Conforms to `AdaptiveEncoder` so the scheduler can run it via the existing `runAdaptive` path.

```swift
/// Kleisli composition of two point encoders through a generator lift.
///
/// The upstream encoder proposes a mutation. The generator lift replays
/// through the generator to produce a valid (sequence, tree) — the
/// Kleisli bind. The downstream encoder operates in the lifted trace.
/// The property checks only the final output.
///
/// See ``GeneratorLift`` for the monadic structure this composition
/// operates within.
struct KleisliComposition: AdaptiveEncoder {
    var upstream: any PointEncoder
    var downstream: any PointEncoder
    let lift: GeneratorLift
    let rollback: RollbackPolicy

    /// Controls what happens when the downstream encoder exhausts
    /// without finding a failure.
    enum RollbackPolicy {
        /// Roll back the upstream change. The composition is atomic.
        case atomic
        /// Keep the upstream change. Partial success — upstream
        /// improved, downstream didn't.
        case partial
    }
}
```

**Rollback policy guidance.** `.atomic` is the correct default for the exploration leg — you are searching for a joint improvement, and a partial improvement (upstream reduced but downstream worse) may not be shortlex-smaller overall. `.partial` would be appropriate if the composition runs within base descent, where an upstream-only improvement is still a valid structural reduction that should be committed.

**`.partial` and property validation.** When the downstream exhausts and the rollback policy is `.partial`, the upstream's change is kept — but it has only been validated by the lift (structural consistency), not by the property. The kept state was never property-tested in isolation. This is acceptable because the exploration-level checkpoint will property-check the final state before committing. The checkpoint guard is the safety net: if the net result (upstream applied, downstream exhausted) is shortlex-worse than the pre-speculation checkpoint, the whole exploration leg rolls back. `.partial` is a local decision; the checkpoint is the global validation.

**The identity encoder.** `.identity` is a concrete type conforming to `PointEncoder` that always returns `nil` from `nextProbe` — zero proposals, accept whatever the input or lift produced. It exists so that the standalone phases (base descent, fibre descent) can be expressed in the same algebra as the exploration case. Whether the actual pipeline constructs `KleisliComposition` instances for standalone phases or continues running encoders via `runAdaptive` directly is an implementation choice. The identity encoder makes the algebra complete; the pipeline uses it where the uniformity is worth the abstraction cost.

**Standalone cases** become self-documenting:

```swift
// Phase 1: upstream targets a structural position, downstream is identity
let structural = KleisliComposition(
    upstream: deletionEncoder,
    downstream: .identity,  // accept whatever the lift produces
    lift: generatorLift,
    rollback: .partial
)

// Phase 2: upstream is identity, downstream targets leaf values
let value = KleisliComposition(
    upstream: .identity,     // no structural change
    downstream: binarySearchEncoder,
    lift: generatorLift,
    rollback: .atomic
)

// Exploration: both non-trivial — same encoder type, different positions
let crossLevel = KleisliComposition(
    upstream: binarySearchEncoder(for: bindInnerPosition),  // base morphism
    downstream: binarySearchEncoder(for: boundLeafPosition), // fibre morphism
    lift: generatorLift,
    rollback: .atomic
)
```

In the exploration case, both encoders are `BinarySearchToSemanticSimplestEncoder`. Both propose value reductions. But the upstream's reduction is categorically a base morphism because the bind-inner position controls the downstream structure. The lift between them is substantial — the upstream's new value produces a different fibre for the downstream, with potentially different domain, coordinate count, and valid ranges.

**Iteration semantics** (in `nextProbe`):

```
outer loop: for each probe from upstream
    apply upstream's mutation to the sequence
    lift.lift → LiftResult or nil
    if nil: upstream's candidate was structurally invalid, advance upstream

    initialize downstream on the fresh (sequence, tree)
    inner loop: for each probe from downstream
        yield downstream's candidate as the composed probe
        if accepted: composition succeeded, advance upstream (or converge)
        if rejected: advance downstream

    downstream exhausted:
        if .atomic: roll back upstream's change, advance upstream
        if .partial: keep upstream's change (lift-validated), advance upstream
```

**Convergence record lifecycle.** `KleisliComposition` conforms to `AdaptiveEncoder`, so `runAdaptive` harvests its `convergenceRecords` and manages warm starts. The composed reduction's convergence records must distinguish the upstream encoder's from the downstream encoder's: upstream records are promotable to the global cache (they describe the upstream coordinate's converged value), while downstream records are ephemeral (valid only for one upstream value and managed internally for convergence transfer). The `convergenceRecords` property should expose only the upstream encoder's records. Downstream records are handled internally by the composed reduction's convergence transfer logic.

`runAdaptive` also sets warm starts on the encoder before calling `start()`. For a `KleisliComposition`, warm starts feed through to the upstream encoder only. The downstream encoder receives its warm starts internally from the convergence transfer logic (gated by lift report coverage), not from `runAdaptive`.

### 4. ReductionContext

Carries shared state without coupling to `ReductionState`.

```swift
struct ReductionContext {
    let bindIndex: BindSpanIndex?
    let convergedOrigins: [Int: ConvergedOrigin]?
    let dag: ChoiceDependencyGraph?
}
```

## Scope: What the Composed Reduction Targets

The composed reduction targets the case where the upstream change alone is **rejected** by Phase 1c (the guided lift does not preserve the failure at the upstream encoder's reduced value) but a specific downstream reduction in the new fibre recovers the failure. This is the cross-level minimum escape that motivates the composed reduction.

Phase 1c (`runJointBindInnerReduction`) already handles the case where the upstream change alone works — it checks the property after each bind-inner reduction. The composed reduction adds value only when the product-space encoders have stalled: the current inner values are at their floors, but a different inner value opens a better fibre that neither encoder discovers independently.

## Mapping Existing Encoders

Every current encoder maps to a `PointEncoder`. The categorical role (base vs fibre) is determined by the position the encoder is pointed at, not by the encoder itself:

| Current encoder | Typical position | Notes |
|---|---|---|
| `ZeroValueEncoder` | Leaf range or bind-inner | Value reduction — base or fibre depending on position |
| `BinarySearchToSemanticSimplestEncoder` | Leaf range or bind-inner | Value reduction — same encoder, role from CDG |
| `BinarySearchToRangeMinimumEncoder` | Leaf range or bind-inner | Value reduction — same encoder, role from CDG |
| `ReduceFloatEncoder` | Leaf range | Float-specific value reduction |
| `DeleteContainerSpansEncoder` | CDG node scope range | Structural deletion — always a base morphism |
| `DeleteSequenceElementsEncoder` | CDG node scope range | Structural deletion |
| `DeleteSequenceBoundariesEncoder` | CDG node scope range | Structural deletion |
| `DeleteFreeStandingValuesEncoder` | CDG node scope range | Structural deletion |
| `DeleteAlignedWindowsEncoder` | CDG node scope range | Structural deletion |
| `DeleteContainerSpansWithRandomRepairEncoder` | CDG node scope range | Speculative structural deletion |
| `DeleteByPromotingSimplestBranch` | Branch selector position | Structural — replaces branch |
| `DeleteByPivotingToAlternativeBranch` | Branch selector position | Structural — pivots branch |
| `ProductSpaceBatchEncoder` | All bind-inner positions | Enumerates bind-inner product space |
| `ProductSpaceAdaptiveEncoder` | All bind-inner positions | Adaptive variant |
| `RedistributeByTandemReductionEncoder` | Sibling groups | Value redistribution |
| `RedistributeAcrossValueContainersEncoder` | Whole sequence | Cross-container redistribution |
| `RedistributeInnerValuesBetweenBindRegionsEncoder` | Bind regions | Cross-region redistribution |
| `BindRootSearchEncoder` | Bind-inner position | Bind root search |
| `RelaxRoundEncoder` | Whole sequence | Speculative exploration |

**Adapter** to bridge existing `AdaptiveEncoder` conformances:

```swift
struct LegacyEncoderAdapter: PointEncoder {
    var inner: any AdaptiveEncoder
    // Forwards start/nextProbe, translates positionRange to TargetSet
}
```

This is the right migration strategy. Wrapping existing encoders first means the composition infrastructure can be tested without rewriting any encoder internals. Concrete purpose-built `PointEncoder` conformances (Phase 4) are a separate concern that can happen incrementally.

**Performance note.** `LegacyEncoderAdapter` uses `any AdaptiveEncoder` (existential), which means dynamic dispatch and potential allocation per call. For the exploration leg (325 probes budget, not a hot path), this is fine. If the composed reduction ever moves to a hotter path (base descent), the adapter should become generic (`LegacyEncoderAdapter<Wrapped: AdaptiveEncoder>`) to avoid the existential overhead.

## Redundancies

KleisliComposition makes some existing encoders and scheduler paths redundant because they exist only to work around the lack of compositional structure.

### `DeleteContainerSpansWithRandomRepairEncoder` — fully redundant

This encoder is identical to `DeleteContainerSpansEncoder`. Same `AdaptiveDeletionEncoder` driver, same span filtering, same batch-size search. The only difference is that the *scheduler* pairs it with `makeSpeculativeDecoder()` (guided/PRNG) instead of `scopeDecoder` (exact/scoped). The "random repair" is not in the encoder — it is in the decoder choice.

With KleisliComposition, this distinction is a lift mode parameter, not a separate encoder type. The same deletion PointEncoder composed with `.guided` lift mode produces exactly the random-repair behavior. The separate encoder type exists only because the current architecture separates "what to mutate" (encoder) from "how to validate" (decoder) at the protocol level, forcing a new encoder type when you want a different decoder. One fewer encoder type, one fewer `EncoderName` case, one fewer `DeletionEncoderSlot`.

### Product-space Tier 2 (PRNG retries) — superseded

In `runJointBindInnerReduction`, when Tier 1 guided replay fails, Tier 2 re-tries the same candidates with PRNG-salted decoders, capped at 5 candidates. This is the brute-force approach to the coupling problem — hope that one of the PRNG seeds fills the downstream fibre with values that reproduce the failure.

KleisliComposition replaces this with active downstream search. Instead of retrying with different random seeds and hoping, the downstream PointEncoder systematically reduces values in the lifted fibre. The regime probe already detects whether this search is worth doing — in the elimination regime, the identity downstream suffices; in the value-sensitive regime, KleisliComposition's downstream encoder is strictly more powerful than multi-seed hope.

The Tier 2 path, the `sortByLargestFibreFirst` logic, and the retry cap can all be removed once KleisliComposition handles the value-sensitive regime in the exploration leg. Approximately 100 lines of scheduler code in `runJointBindInnerReduction`.

### `ProductSpaceBatchEncoder` for single-bind generators — partially redundant

For generators with a single bind region (one bind-inner value), `ProductSpaceBatchEncoder` computes a binary-search ladder over that one value and enumerates candidates. This is exactly what a PointEncoder (BinarySearch) pointed at the bind-inner position would produce. The product-space machinery (Cartesian products, dependent domains, DAG topology) adds nothing for the single-axis case.

For multi-bind generators (multiple bind-inner values), the product-space encoders still add value — they enumerate joint assignments that a single KleisliComposition cannot express. This would require the parallel composition operator (antichain composition across independent bind-inner positions), which is deferred.

### What does NOT decompose

- **`ProductSpaceAdaptiveEncoder`'s halve-all + delta-debug**: simultaneously halves multiple coordinates and uses delta-debugging to find the maximal subset that can be halved together. This is a multi-coordinate search strategy that is fundamentally not a sequential composition — it needs to see the joint effect of multiple simultaneous mutations.
- **Redistribution encoders**: tandem and cross-container redistribution operate on symmetric pairs (take from one, give to another). This is not an upstream→downstream relationship — neither position controls the other.
- **Deletion encoders** (the standard variants): already simple — they delete spans and check. They map directly to PointEncoders without any composition needed.

## CDG-Guided Composition

The CDG finds the dependency edges where composed reductions are meaningful. The CDG is the discovery mechanism; the fibration is the semantic framework. The position's role in the CDG — controlling or non-controlling — is the only thing that determines whether a lift between two encoders is substantial or trivial.

If two positions are connected by a CDG edge, the upstream is categorically a base morphism regardless of whether it uses zero-value, binary search, or float reduction. If they are not connected, no lift is needed between their encoders.

```swift
extension ChoiceDependencyGraph {
    /// Returns the dependency edges where composed reductions
    /// (upstream point encoder + generator lift + downstream point encoder)
    /// are meaningful.
    ///
    /// Each edge connects a controlling position to a controlled range.
    /// Ordered by topological sort (roots first).
    func reductionEdges() -> [ReductionEdge] {
        // For each bind-inner node with dependents:
        //   upstreamRange = node.positionRange (the controlling position)
        //   downstreamRange = node.scopeRange (the controlled subtree)
    }
}

/// A dependency edge in the CDG where a composed reduction can operate.
struct ReductionEdge {
    /// The controlling position — the upstream encoder operates here.
    /// Its mutation is a base morphism because the CDG has an outgoing
    /// dependency edge from this position.
    let upstreamRange: ClosedRange<Int>
    /// The controlled subtree — the downstream encoder operates here.
    /// Its mutation is a fibre morphism within the structure determined
    /// by the upstream value.
    let downstreamRange: ClosedRange<Int>
    let regionIndex: Int
    /// Whether the downstream structure is invariant under upstream
    /// value changes (the bind closure ignores its argument — no nested
    /// binds or picks in the bound subtree). When true, the lift is
    /// trivial regardless of the upstream value: the same fibre exists
    /// for every upstream candidate. The composed reduction is unnecessary
    /// at this edge — the sequential phases handle it fine. Computed
    /// statically from the generator's tree structure.
    let isStructurallyConstant: Bool
}
```

The scheduler uses this to assemble composed reductions:

```swift
for edge in dag.reductionEdges() {
    let upstream = makePointEncoder(for: edge.upstreamRange)
    let downstream = makePointEncoder(for: edge.downstreamRange)
    let composed = KleisliComposition(
        upstream: upstream,
        downstream: downstream,
        lift: GeneratorLift(gen: gen, mode: .guided(fallbackTree: tree)),
        rollback: .atomic
    )
    // Run composed reduction with budget
}
```

## Budget Accounting

From the paper (Section 9): resource usage composes via monoidal product. Here `W = (Int, ≤, +, 0)` — materialization count.

A composed reduction's cost is `cost(upstream) + intermediate lifts + cost(downstream)`. Each upstream probe triggers one lift plus the full downstream encoder pass. If the upstream encoder has `k` candidates and the downstream encoder takes `d` probes each, the total is `k` lifts + `k × d` downstream probes.

**Budget heuristic.** An equal split is too generous to the downstream. The upstream encoder's job is to propose inner values — it is cheap (one proposal, one lift per candidate). The downstream encoder is where the work happens. Give the upstream a fixed budget of 10–15 candidates — enough to explore the neighbourhood of the current inner value without exhausting the leg budget on lifts alone. Split the remaining leg budget equally across those upstream candidates for the downstream. For a 325-probe exploration leg with 10 upstream candidates, each downstream pass gets approximately 30 probes — sufficient for a binary search to converge on a small fibre.

**Convergence transfer across adjacent upstream values.** If the upstream encoder proposes inner value 5 and the downstream encoder converges, then the upstream encoder proposes inner value 4 (similar fibre), the downstream encoder can warm-start from the previous convergence points. The fibres for adjacent inner values are likely similar (small structural change — typically removing or adding one element, not a wholesale restructuring), so stall points transfer.

The lift report's coverage metric gates this: if the lift from upstream-5 to upstream-4 has high coverage (most coordinates carried forward), the convergence points are likely valid. If low coverage, discard them. This makes the composed reduction significantly more efficient on its second and subsequent upstream iterations — the downstream encoder converges quickly because it starts from a nearby stall point rather than from scratch.

## Interaction with Existing Infrastructure

- **Reject cache**: Keyed by `ZobristHash(candidate)`. Downstream candidates are novel (include upstream mutation + lift + downstream mutation), so collisions are unlikely.
- **Convergence cache**: Downstream convergence records are ephemeral within a composition by default — valid only for one upstream value. Do not promote to global cache. Upstream records can be cached normally. However, when the lift report indicates high coverage between adjacent upstream values, downstream convergence records from the previous upstream iteration can be carried forward as warm starts.
- **Span cache**: Invalidated after each generator lift (tree changed).
- **Dominance**: A `KleisliComposition` has its own `EncoderName`. Dominance tracks it as a unit.
- **Fingerprint guard**: Not needed within the composition — structural change is expected (that is the whole point). The guard applies at the boundary between the composition and the rest of the reducer.

## Composition Operators

The algebra has three composition operators, corresponding to the three graph structures in the CDG:

1. **Sequential** (`KleisliComposition`): `upstream → lift → downstream`. For dependency edges (vertical composition along CDG chains). This is the primary operator.

2. **Parallel** (`ParallelComposition`): `A ∥ B ∥ C → union ranges`. For antichains (horizontal composition across independent CDG nodes). Composes independent deletions via range-set union — exactly what `findMaximalDeletableSubset` does today, but expressed in the encoder algebra. The delta-debugging search strategy would be a property of the parallel composition, not of the individual point encoders. The parallel operator is specified in the antichain composition document (`docs/bonsai-antichain-composition-proposal.md`); this document covers only the sequential operator.

3. **Identity** (existing `AdaptiveEncoder` run standalone): no composition. For independent coordinates (isolated CDG nodes and leaf positions).

## Pipeline Placement

The composed reduction runs in the **exploration leg**, alongside the relax-round. Both are non-monotone operations gated by a checkpoint:
- The composed reduction targets cross-level minima (base-fibre coupling).
- The relax-round targets same-level minima (sibling value coupling).
- They search different subspaces and are complementary.

Running the composed reduction within base descent (Phase 1c) would conflict with the existing product-space encoders, which already handle the "reduce bind-inner values jointly" case. The composed reduction adds value only when the product-space encoders have stalled — when the current inner values are at their floors but a different inner value opens a better fibre. That is a speculation-time operation, not a base-descent operation.

**Generators without binds.** For generators without binds (pure zip of leaf generators, arrays of fixed structure), the CDG has no dependency edges, `reductionEdges()` returns empty, and no `KleisliComposition` is ever constructed. The exploration leg falls through to the relax-round only. This is correct — no binds means no cross-level minima to discover.

## Multi-Hop Composition

For nested binds (A controls B controls C), use **topological iteration**, not nesting. `compose(compose(A, B), C)` means: for each A proposal, lift, for each B proposal, lift again, for each C proposal, test. That is `O(|A| × lift × |B| × lift × |C|)` — the budget explodes at depth 3.

Topological iteration — run the composed reduction on the shallowest edge first, accept the result, then run a fresh composed reduction on the next edge — reuses the existing restart-on-acceptance pattern and keeps costs linear in the chain depth rather than multiplicative.

**Type-system constraint.** `KleisliComposition` conforms to `AdaptiveEncoder`, not `PointEncoder`. This means a `KleisliComposition` cannot be placed in another `KleisliComposition`'s `any PointEncoder` slot — the types do not align. This is intentional: topological iteration is the correct strategy for multi-hop, and nesting compositions would produce the multiplicative budget explosion described above. If a future need arises for expressing `compose(compose(A, B), C)` as a single type, `KleisliComposition` would need an additional `PointEncoder` conformance (or a `PointEncoder` adapter for `AdaptiveEncoder`). The current design deliberately prevents this to enforce linear-cost multi-hop.

## Implementation Phases

### Phase 1: Foundation (non-breaking)

**New file**: `Sources/ExhaustCore/Interpreters/Reduction/PointEncoder.swift`
- `PointEncoder` protocol
- `ReductionContext` type
- `LegacyEncoderAdapter` wrapper for existing encoders (existential for now; make generic if moved to a hot path)

**New file**: `Sources/ExhaustCore/Interpreters/Reduction/GeneratorLift.swift`
- `GeneratorLift` type with `LiftResult` including `LiftReport`
- Wraps `ReductionMaterializer.materialize` with lift-specific semantics (no property check)

**New file**: `Sources/ExhaustCore/Interpreters/Reduction/KleisliComposition.swift`
- `KleisliComposition` conforming to `AdaptiveEncoder`
- `RollbackPolicy` enum
- Iteration logic (outer-inner loop)
- Convergence transfer gated by lift report coverage
- `convergenceRecords` exposes only upstream records; downstream records are managed internally

**Modify**: `Sources/ExhaustCore/Interpreters/Reduction/SequenceEncoder.swift`
- Add `.kleisliComposition` to `EncoderName`

### Phase 2: CDG integration

**Modify**: `Sources/ExhaustCore/Interpreters/Reduction/ChoiceDependencyGraph.swift`
- Add `reductionEdges()` method returning `[ReductionEdge]`

### Phase 3: Scheduler integration

**Modify**: `Sources/ExhaustCore/Interpreters/Reduction/ReductionState+Bonsai.swift`
- Add scheduling method that builds and runs `KleisliComposition` instances from CDG reduction edges
- Wire into the exploration leg, before `runRelaxRound`

### Phase 4: Concrete point encoders

Implement purpose-built `PointEncoder` conformances for the common cases:
- `IntegralPointEncoder` (binary search ladder — works as base or fibre depending on position)
- `FloatingPointEncoder` (float reduction)
- `DeletionPointEncoder` (span deletion within a scope)

These replace the adapter for the most-used paths.

## Verification

1. **Unit tests**: Compose a point encoder (zero-value on bind-inner) with a point encoder (binary search on bound content) across a bind edge. Verify the composition finds reductions that neither encoder finds alone.
2. **Shrinking challenges**: `swift test --filter "Shrinking"` — all existing challenges pass.
3. **Coupling challenge** specifically: the composition should find `[1, 0]` (reduce upstream to 1, then reduce downstream to 0).
4. **Budget**: Verify total property invocations do not regress for non-bind generators.
5. **Rollback**: Test at two levels:
   - **Composition level**: a generator where the upstream change makes the sequence shortlex-larger (or equal), the downstream encoder brings it back down, and the composition is shortlex-smaller overall. With `.atomic`, the composition succeeds as a unit. With `.partial` and the downstream encoder exhausting, the upstream change is kept even though it worsened the sequence.
   - **Exploration level**: the checkpoint guard at the exploration leg catches the `.partial` case — if the final state (upstream applied, downstream exhausted) is shortlex-worse than the pre-speculation checkpoint, the whole exploration leg rolls back. Verify that the exploration-level checkpoint is the global safety net for `.partial` rollback.
6. **Convergence transfer**: Test that adjacent upstream values with high lift coverage reuse downstream convergence points, reducing total probes.
7. **Identity compositions**: Verify that `KleisliComposition(upstream: .identity, downstream: encoder, ...)` behaves identically to running the encoder standalone, and vice versa.
8. **Role agnosticism**: Verify that the same `PointEncoder` instance (for example, `BinarySearchToSemanticSimplest`) works correctly as upstream (base morphism on bind-inner) and as downstream (fibre morphism on leaf) within different `KleisliComposition` instances.

## The Measure

The honest measure of whether this algebra achieves its goal is the ratio: how many property invocations does it take to get from the initial failing trace to the minimal counterexample?

The theoretical floor is one property invocation per bit of information about the failure surface. Each invocation tells you one binary fact — this candidate fails or passes. The minimal counterexample is determined by some number of such facts. No reducer can beat that floor. The question is how close you can get.

Every proposal in this document attacks the above-floor waste from a different angle:

- **Convergence cache**: eliminates redundant fibre descent probes. Coordinates already at their floor do not need to be re-discovered. Savings are O(log(range)) probes per stalled coordinate per cycle.
- **Lift report**: eliminates wasted probes on tier 3 coordinates — probes that optimize noise. Savings depend on the PRNG fraction of the fibre.
- **Antichain search**: eliminates redundant cycles. k independently deletable spans are found in one cycle instead of ceil(k/2). Savings are entire pipeline traversals, not individual probes.
- **Composed reduction**: eliminates the gap between phases. Cross-level minima that the sequential pipeline cannot discover are found in a single exploration pass. Savings are the cycles that would have been spent with both phases stalled, decrementing the stall counter toward termination with a suboptimal result.
- **Lift report as feedback**: ties them all together. Every decision about whether to probe, which encoder to use, whether to transfer convergence, whether to invest downstream budget, is informed by how well the previous mutation survived T.

These compound. The convergence cache makes fibre descent cheaper, so cycles are faster. Faster cycles mean the antichain search's cycle savings translate to larger wall-clock improvements. The composed reduction finds reductions the pipeline would have missed entirely — reductions that would have appeared as "stall counter expired, accept suboptimal result."

## From Open-Loop to Closed-Loop

The current pipeline is open-loop. Each cycle runs the same phases in the same order with the same encoders at the same budgets. The only feedback is binary: did the cycle make progress (reset stall counter) or not (decrement stall counter). The reducer does not learn *how* it made progress or *why* it did not.

With the lift report flowing back, each cycle is informed by every previous cycle's outcomes:

**Cycle 1.** Base descent deletes spans. Fibre descent reduces values. The convergence cache records stall points. The lift report records per-coordinate resolution tiers. Both phases stall.

**Cycle 2.** Base descent consults structural classifications — skip necessary spans, try only productive ones. Fibre descent consults the convergence cache — warm-start from known floors. The lift report from this cycle's materializations tells the reducer which coordinates shifted (stale convergence entries) and which held (valid warm starts). The antichain search uses the CDG to compose independent deletions rather than enumerating pairs. Both phases stall again, but at a better point.

**Exploration leg.** The composed reduction consults the lift report from the most recent base descent — which dependency edges had high-coverage lifts? Those are the edges where joint upstream-downstream reduction is meaningful. It traverses them, using convergence transfer where adjacent upstream values produced similar fibres. The relax-round filters its redistribution pairs to tier 1 × tier 1 coordinates. The checkpoint evaluates the net result.

**Cycle 3.** Everything the exploration leg discovered flows back. New stall points from the composed reduction's downstream passes. New structural classifications for spans that became deletable after the exploration's perturbation. The convergence cache carries forward entries that the lift report says are still valid.

The reducer is not repeating the same computation hoping for a different result — it is narrowing its search based on accumulated evidence about the failure surface.

## Convergence of Frameworks

The fibration tells you the structure — what to do: base before fibre, covariant sweep, cartesian-vertical factorization. The S-J algebra tells you the composition rules — how to combine: Kleisli composition over the generator lift monad, encoding-only factored composites, grades that compose via monoidal product. The CDG tells you where — the dependency edges where composition is meaningful, the antichains where parallel composition is safe, the topological order that keeps multi-hop costs linear. The cost asymmetry tells you why — every architectural decision optimizes property invocation count, the one cost Exhaust can reduce but cannot make cheaper per call.

The lift report is what makes the system adaptive. Without it, the fibration provides static structure: compute the DAG once per cycle, run base descent then fibre descent, same budget allocation regardless of how the mutations land. With it, the structure becomes dynamic: the reducer sees how each mutation survived T and adjusts in real time. Skip tier 3 coordinates. Warm-start where coverage is high. Gate composition traversals on fidelity. Delay fibre descent when the fibre is too noisy. Redirect budget from unproductive coordinates to productive ones.

The composed reduction is the architectural form where all of these converge. The fibration provides the factorization (`upstream → lift → downstream`). The algebra provides the composition rule (Kleisli bind, deferred `dec`). The CDG provides the edges. The cost asymmetry justifies the trade-off (internal lift cost for external property-call savings). And the lift report closes the loop — the inner loop of the composition becomes adaptive, spending budget where the lift is faithful, skipping where it is noisy, transferring convergence where the fibres are similar.

## Termination

The open-loop reducer terminates because the stall counter hits zero. The closed-loop reducer terminates because the feedback confirms the reducer is at a local minimum — every coordinate is at its convergence-cached floor, every span is structurally classified, every composition site has been traversed, and the lift reports confirm that the current point is stable under materialization. The stall counter becomes a safety net, not the primary termination mechanism.

The progression from flat passes to closed-loop control:

1. **MacIver**: 15 static passes, no feedback, no structure. Terminates when passes exhaust.
2. **Fibration**: canonical phase ordering, DAG-guided sweep, dominance pruning. Static structure. Terminates on stall counter.
3. **Convergence cache**: cross-cycle memory. Passive adaptation. Terminates on stall counter, but faster.
4. **Lift report**: per-materialization signal. Active adaptation — the reducer's proprioception. Terminates when feedback confirms local minimality.
5. **Composed reduction**: the architectural form that makes the feedback actionable across dependency edges. Discovers reductions that the open-loop pipeline would have missed entirely.
