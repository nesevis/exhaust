# Principled Test Case Reduction: Implementation Plan

> Companion document to [kleisli-reducer-paper-audit.md](kleisli-reducer-paper-audit.md), which maps the
> Sepulveda-Jimenez categorical framework onto the current KleisliReducer implementation.
> This plan uses that audit's findings to redesign reduction from first principles.

## Context

The Sepulveda-Jimenez paper ("Categories of Optimization Reductions", 2026) provides a categorical framework for reasoning about optimization pipelines as composable `(enc, dec, grade)` morphisms. This plan applies that framework to redesign Exhaust's test case reduction from first principles: separating structural mutation from materialization, tracking approximation and resource grades compositionally, and ordering depth sweeps by the Gauss-Seidel principle for bind-dependent generators.

The goal is the most principled, maintainable, and effective reducer possible — one where:
- Adding a new tactic requires implementing only a pure encoding function
- Correctness guarantees compose automatically via the grade monoid
- Resource budgets decompose cleanly across phases
- The depth sweep order is theoretically justified, not empirically discovered

---

## 1. Architectural Principles

### 1.1 Separate `enc` from `dec`

The paper's core insight: a reduction morphism is a pair `(enc, dec)` where `enc` mutates the candidate and `dec` recovers a valid solution. These have different concerns and different parameter needs.

**Current state:** Every tactic bundles encoding, decoding, feasibility checking, and resource tracking into a single `apply()` method. This couples structural mutation to materialization strategy, making tactics hard to test, compose, and reason about.

**Target state:** `encode` is a pure function from (sequence, targets) → candidates. `decode` is a uniform materialization pipeline chosen by depth context. The scheduler orchestrates them and tracks grades.

### 1.2 One Decoder Per Depth Context

The paper requires all morphisms in the same hom-set to share the same `dec`. The current implementation has two decoding paths (TacticEvaluation and TacticReDerivation) with different fallback-tree behavior, meaning tactics don't form a uniform category.

**Target state:** The decoder is selected by a `DecoderContext` (depth, bind state, strictness). All encoders at a given depth share the same decoder. This eliminates the TacticEvaluation vs. TacticReDerivation split.

### 1.3 Grade Composition

Each morphism carries a grade `g = (γ, w)` where `γ = (α, β) ∈ Aff_≥0` is the approximation slack and `w ∈ ℕ` is the resource bound (property evaluations). Grades compose via `g₁ ⊗ g₂ = (γ₁ ⊗ γ₂, w₁ + w₂)` where `(α, β) ⊗ (α', β') = (αα', β + αβ')`.

This means:
- Exact passes have grade `((1, 0), w)` — no approximation slack
- Approximate passes (redistribution, speculative repair) have grade `((1, β), w)` with β > 0
- The scheduler can verify that a pipeline's aggregate grade is acceptable before running it
- Resource budgets decompose additively across phases

### 1.4 Covariant and Contravariant Passes

The paper defines covariant and contravariant functors on the reduction category (Section 4). This distinction maps directly to two natural categories of reducer passes, determined by their direction relative to the Kleisli chain:

**Contravariant passes** (against the chain: depth max → depth 1):
- Reduce bound values *within fixed ranges* — moving backward through the bind chain without disturbing the inner generators that determined those ranges.
- **Structure-preserving**: span boundaries, container groupings, sibling relationships are unchanged. The dominance lattice computed at sweep start remains valid throughout.
- **Exact**: no re-derivation needed. Grade: `((1, 0), w)`. The `dec` is `Interpreters.materialize()` with a fixed tree.
- **Can get stuck**: limited to the current feasible region. If the property failure requires a specific structural shape, contravariant passes can only minimize values within that shape, never escape it.
- In the paper's terms: these operate on the `Cand^op` functor (Section 4.2) — decoding maps candidates backward.

**Covariant passes** (with the chain: depth 0):
- Reduce inner values or delete inner structure, causing bound content to be *re-derived forward* through the Kleisli chain via GuidedMaterializer (prolongation).
- **Structure-destroying**: deletion removes spans, value reduction changes bound ranges. Span structure can change radically — the dominance lattice must be rebuilt.
- **Speculative**: re-derivation is nondeterministic. Grade: `((1, β), w)` with β > 0. But can explore entirely new regions of the candidate space.
- **Can escape local minima**: re-derivation via PRNG/fallback may find shorter bound content than the current state. Deletion at depth 0 can eliminate entire bound subtrees.
- In the paper's terms: these operate on the `Cand` functor (Section 4.1) — encoding maps candidates forward.

### 1.5 The Multigrid V-Cycle

The optimal cycle structure interleaves the two pass types, following the multigrid V-cycle pattern from the paper's Section 14.4 on multilevel methods:

```
  Contravariant sweep (depth max → 1):
    Smooth the fine levels. Exact, structure-preserving, lattice-stable.
    Converges to local minimum within fixed bound ranges.
         │
         ▼
  Covariant sweep (depth 0):
    Correct the coarse level. Speculative, lattice-destroying.
    Can escape the contravariant local minimum by changing inner values.
    Re-derivation produces new bound content — but the fallback tree
    (containing contravariant improvements) minimizes β.
         │
         ▼
  Post-processing (natural transformation):
    Shortlex merge to recover contravariant improvements that
    re-derivation degraded. This is the Section 5.3 endotransformation.
         │
         ▼
  (repeat)
```

**Why this ordering minimizes the composed approximation grade:**
- Contravariant reductions at depth > 0 have exact grade `(1, 0)`.
- The subsequent covariant reduction at depth 0 has grade `(1, β)` — but β is minimized when the fallback tree contains already-reduced bound values from the contravariant sweep.
- If covariant ran first (top-down), β would be maximal: bound values are re-derived from PRNG before they've been optimized, destroying any prior contravariant work.

This is Gauss-Seidel ordering applied to block coordinate descent with one-directional dependencies (inner → bound): process unconstrained blocks (contravariant, bound depths) before constraining blocks (covariant, inner depth).

**The cat-stroking algorithm.** Smooth the fur, then ruffle. The contravariant sweep is the stroking — getting all bound values into their smoothest state. The covariant sweep is the ruffle — changing inner values, disrupting bound ranges. But because the fallback tree remembers the smooth state, re-derivation clamps back toward it. β is how much fur sticks up after the ruffle. Pre-stroking minimizes it. If you ruffle first (top-down), the fur goes everywhere — bound values are re-derived from PRNG before they've been optimized, and β is maximal.

> *Basin hopping.* The V-cycle is structurally equivalent to monotonic basin hopping: the contravariant sweep finds the basin bottom (local minimum within fixed bound ranges), the covariant sweep hops to a new basin (changes inner values, shifting the landscape), and the shortlex guard is a strict acceptance criterion (only downhill). Redistribution is the perturbation-strength increase when monotonic hopping stalls.

> *Exploitation–exploration.* The contravariant sweep is pure exploitation (extract all value from the current landscape). The covariant sweep is exploration (change the landscape at the cost of β). Redistribution is reshaping — neither exploiting nor exploring, but trying a different joint configuration within the current landscape. The V-cycle is a structured exploitation–exploration schedule: exploit fully, explore once, exploit the new landscape.

**Lattice stability implication:** During the contravariant sweep, the dominance lattice is computed once and remains valid — no span deletion or structural change occurs. The 2-cell pruning from Section 15 can safely skip dominated encoders throughout the entire sweep. During the covariant sweep, the lattice is rebuilt after each success (spans may have changed). This means lattice pruning is most valuable during the contravariant phase, where it avoids redundant property evaluations across many depths.

### 1.6 Local Minima and Termination

The covariant–contravariant distinction gives a precise characterization of local minima:

**A local minimum is a contravariant fixed point** — a state where `DirectMaterializerDecoder` rejects every candidate from every encoder at every bound depth. All exact, structure-preserving passes have stalled. The bound values are individually minimal within their current ranges, but those ranges are determined by the inner values at depth 0.

**The covariant sweep is the only escape.** By changing inner values (depth 0), the covariant sweep changes the bound ranges themselves — opening new territory for the next contravariant sweep. Re-derivation via `GuidedMaterializerDecoder` produces new bound content that may be shorter than the contravariant fixed point.

**If the covariant sweep also stalls, the pipeline has reached a global fixed point** — no morphism in the category produces progress. This gives a clean termination criterion: the reducer is done when one full V-cycle produces zero accepted candidates across both legs. No stall counters, no heuristic patience — just "did any morphism fire?"

**Redistribution as a second-order escape.** Phase 4 (redistribution) addresses a different kind of stall: cases where inner values are already minimal and the covariant sweep can't improve them, but bound values are "stuck" because they're individually minimal even though their *joint* configuration isn't. Redistribution transfers mass between coordinates — it's approximate (grade `(1, β)`), but it can create new attack surfaces for the next contravariant sweep. In terms of the fixed-point hierarchy:

1. **Contravariant fixed point** → escape via covariant sweep (change inner values, re-derive bounds)
2. **Covariant fixed point** → escape via redistribution (transfer mass between coordinates)
3. **Redistribution fixed point** → global fixed point, reducer terminates

---

## 2. Core Types

### 2.1 ReductionGrade

```swift
/// The grade monoid G = Aff_≥0 × W from Section 10 of the paper.
///
/// Tracks approximation slack (how much the round-trip can regress)
/// and resource cost (property evaluations consumed).
struct ReductionGrade {
    /// Multiplicative approximation factor. 1.0 = exact.
    let alpha: Double
    /// Additive approximation slack. 0.0 = exact.
    let beta: Double
    /// Maximum property evaluations this morphism will consume.
    let maxEvaluations: Int

    static let exact = ReductionGrade(alpha: 1, beta: 0, maxEvaluations: 0)

    var isExact: Bool { alpha == 1 && beta == 0 }

    /// Monoidal product: compose two grades.
    func composed(with other: ReductionGrade) -> ReductionGrade {
        ReductionGrade(
            alpha: alpha * other.alpha,
            beta: beta + alpha * other.beta,
            maxEvaluations: maxEvaluations + other.maxEvaluations
        )
    }
}
```

### 2.2 TargetSet

```swift
/// What positions in the sequence this encoder targets.
///
/// Replaces the proliferation of `targetSpans`, `siblingGroups`, `allValueSpans`
/// parameters with a single sum type.
enum TargetSet {
    case spans([ChoiceSpan])
    case siblingGroups([SiblingGroup])
    case wholeSequence
}
```

### 2.3 Encoder Protocol

```swift
/// A pure structural mutation: sequence + targets → candidates.
///
/// Encoders do not evaluate the property, do not materialize, and do not
/// access the generator or tree. They produce candidate sequences ordered
/// by expected quality (best first — angelic nondeterminism).
protocol SequenceEncoder {
    /// Human-readable name for logging.
    var name: String { get }

    /// Declared grade: approximation bound + resource bound.
    var grade: ReductionGrade { get }

    /// Which phase this encoder belongs to.
    var phase: ReductionPhase { get }

    /// Produce candidate mutations, best first.
    ///
    /// Returns a lazy sequence of candidates. The scheduler evaluates them
    /// in order, stopping at the first success (angelic resolution).
    ///
    /// The reject cache is read-only — the scheduler handles insertion.
    func encode(
        sequence: ChoiceSequence,
        targets: TargetSet,
        rejectCache: ReducerCache,
    ) -> AnySequence<ChoiceSequence>
}
```

**What encode does NOT receive** (and why):
- `gen` — encoding is structural, no materialization
- `tree` — the tree constrains decoding, not encoding
- `property` — feasibility is the decoder's job
- `bindIndex` — span filtering by depth is the scheduler's job (done before calling encode)
- `fallbackTree` — a decoding concern
- `rejectCache` as inout — the scheduler manages reject insertions

### 2.4 Decoder Protocol

```swift
/// Materializes a candidate sequence and checks feasibility.
///
/// Selected by depth context, shared by all encoders at that depth.
/// This is the `dec` map from the paper.
protocol SequenceDecoder {
    func decode<Output>(
        candidate: ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool,
    ) throws -> ShrinkResult<Output>?
}
```

### 2.5 DecoderContext and Factory

```swift
/// Determines which decoder to use based on depth and bind state.
struct DecoderContext {
    let bindIndex: BindSpanIndex?
    let depth: Int
    let fallbackTree: ChoiceTree?
    let strictness: Interpreters.Strictness
}

/// Returns the appropriate decoder for a given context.
///
/// One decoder per context = all encoders at the same depth share the
/// same `dec`, forming a uniform hom-set (paper Section 7).
enum DecoderFactory {
    static func decoder(for context: DecoderContext) -> SequenceDecoder {
        let needsReDerivation = context.depth == 0
            && context.bindIndex != nil
            && context.bindIndex?.isEmpty == false

        if needsReDerivation {
            return GuidedMaterializerDecoder(
                fallbackTree: context.fallbackTree,
                strictness: context.strictness
            )
        } else {
            return DirectMaterializerDecoder(strictness: context.strictness)
        }
    }
}
```

Two decoder implementations:
- **`DirectMaterializerDecoder`**: Wraps `Interpreters.materialize()`. Used at depth > 0, depth -1, and non-bind depth 0. Deterministic, exact.
- **`GuidedMaterializerDecoder`**: Wraps `GuidedMaterializer.materialize()` with fallback tree. Used at bind depth 0. Nondeterministic, approximate. Includes the shortlex round-trip guard.

### 2.6 ReductionPhase

```swift
/// The categorical type of a reduction phase.
///
/// Phases are ordered by guarantee strength. Within each phase,
/// encoders are ordered by the 2-cell preorder.
enum ReductionPhase: Int, Comparable {
    case structuralDeletion = 0     // Nondeterministic exact
    case valueMinimization = 1      // Nondeterministic exact
    case reordering = 2             // Deterministic exact
    case redistribution = 3         // Nondeterministic approximate, grade (1, β)
    case exploration = 4            // Nondeterministic approximate, grade (α, β)
}
```

---

## 3. The Phase Pipeline

### Phase 1: Structural Deletion (Exact)

**Goal:** Make the sequence as short as possible.

**Encoders** (ordered by aggressiveness, most first):
1. `DeleteContainerSpansEncoder` — removes whole subtrees
2. `DeleteSequenceElementsEncoder` — removes element groups within arrays
3. `DeleteSequenceBoundariesEncoder` — removes array start/end markers
4. `DeleteFreeStandingValuesEncoder` — removes individual loose values
5. `DeleteAlignedWindowsEncoder` — beam-search over sibling subsets
6. `SpeculativeDeleteEncoder` — delete + flag for GuidedMaterializer repair

**2-cell relationships:**
- 1 ⇒ 6 (container deletion is strictly more aggressive than speculative single-span deletion)
- 2 ⇒ 4 within elements (element deletion removes enclosed values), but 4 targets values *outside* elements — not a strict dominance
- All others: no formal 2-cell. Run all, don't prune.

**Strictness:** `.relaxed` for boundary/element deletion (structural changes), `.normal` for container/value deletion.

**Grade:** `((1, 0), n)` where n = target count. All exact.

### Phase 2: Value Minimization (Exact)

**Goal:** Minimize each entry at its position (lexicographic improvement, fixed length).

**Encoders:**
1. `ZeroValueEncoder` — set each value to 0. Grade: `((1, 0), n)`.
2. `BinarySearchToZeroEncoder` — binary search each value toward 0. Grade: `((1, 0), n·log V)`.
3. `BinarySearchToTargetEncoder` — binary search toward a target from another depth. Grade: `((1, 0), n·log V)`.
4. `ReduceFloatEncoder` — multi-stage float pipeline. Grade: `((1, 0), n·stages·log V)`.

**2-cell chain:** 1 ⇒ 2 ⇒ 3. Zero is the best binary-search-to-zero can achieve. Binary-search-to-zero finds values ≤ any nonzero target.

**Note:** Binary search is inherently adaptive (each step depends on the prior result). The `encode` function for binary search returns a single candidate per invocation — the scheduler calls it repeatedly, feeding back the last accepted sequence. This models binary search as iterated Kleisli composition.

### Phase 3: Reordering (Exact)

**Goal:** Sort siblings into ascending order (lexicographic improvement, same multiset).

**Encoder:** `ReorderSiblingsEncoder`. Grade: `((1, 0), n)`.

Single encoder, no 2-cell structure needed.

### Phase 4: Redistribution (Approximate)

**Goal:** Transfer numeric mass between coordinates to unlock future improvements.

**Encoders:**
1. `TandemReductionEncoder` — reduce value pairs together. Grade: `((1, β), w)`.
2. `CrossStageRedistributeEncoder` — move mass between bind depths. Grade: `((1, β), w)`.

**Constraint:** The scheduler only runs Phase 4 when:
- Phases 1–3 made no progress in this cycle
- The accumulated pipeline grade would remain acceptable: `pipeline_grade.composed(with: encoder.grade).isExact` or the round-trip is empirically exact (shortlex guard)

### Phase 5: Exploration (Approximate, Future)

**Goal:** Break local optima via speculative perturbation.

**Encoder:** `RelaxRoundEncoder` — temporarily increase one value to enable a larger deletion. Grade: `((α, β), w)` with α > 1 or β > 0.

**Not implemented initially.** This is infrastructure-in-waiting, justified by the paper's relax-round framework (Section 11.2).

### Post-Processing (Natural Transformation)

After every successful reduction:
1. **Shortlex merge of bound entries** — for each bound position, keep min(old, new). This is a natural endotransformation on `Cand` (Section 5.3).
2. **Tree relaxation** — update the choice tree to reflect the shortened sequence.

Applied uniformly, not stall-triggered. No property evaluation needed (the merge is speculative; if the merged result fails materialization, fall back to the unmerged result).

---

## 4. The Scheduler

### 4.1 Cycle Structure: The Multigrid V-Cycle

Each cycle has three legs:

```
for each cycle:
    // ── Leg 1: Contravariant sweep (fine → coarse) ──
    // Structure-preserving, exact, lattice-stable.
    // Compute lattice ONCE — it's valid for the entire sweep.
    let lattice = buildLattice(sequence)

    for depth in (1 ... maxBindDepth).reversed():
        context = DecoderContext(depth, bindIndex, fallbackTree, .normal)
        decoder = DirectMaterializerDecoder(strictness: .normal)
        targets = extractTargets(sequence, depth, bindIndex)

        for phase in [.structuralDeletion, .valueMinimization, .reordering]:
            for encoder in lattice.encoders(for: phase):
                // ... encode, decode, accept if successful
                // On success: update sequence/tree, continue sweep
                //   (lattice remains valid — no structural change)

    // ── Leg 2: Covariant sweep (depth 0) ──
    // Speculative, lattice-destroying, can escape local minima.
    context = DecoderContext(0, bindIndex, fallbackTree, .normal)
    decoder = GuidedMaterializerDecoder(fallbackTree: fallbackTree)
    targets = extractTargets(sequence, 0, bindIndex)

    for phase in [.structuralDeletion, .valueMinimization, .reordering]:
        for encoder in encoders(for: phase):
            // ... encode, decode, accept if successful
            // On success: rebuild lattice (spans may have changed)

    // ── Leg 3: Post-processing (natural transformation) ──
    // Shortlex merge to recover contravariant improvements
    // degraded by covariant re-derivation.
    applyShortlexMerge(sequence, fallbackTree)

    // ── Cross-cutting: redistribution if both legs stalled ──
    if no improvement:
        run Phase 4 (redistribution) with approximate grade tracking

    // Stall logic, termination
```

**Key difference from the current KleisliReducer:** The current implementation runs all phases at all depths in a single bottom-up sweep, breaking on first success. The V-cycle separates the contravariant sweep (depths > 0, exact, lattice-stable) from the covariant sweep (depth 0, speculative, lattice-rebuilding). This lets the lattice be computed once for the entire contravariant leg, and makes the covariant leg's re-derivation benefit from the contravariant improvements.

### 4.2 Contravariant Sweep Details

The contravariant sweep is the workhorse — it handles the majority of reductions with exact guarantees:

- **Lattice computed once** at sweep start and reused across all depths. Contravariant passes don't change span structure (they modify values within existing spans), so the lattice edges remain valid. 2-cell pruning is effective here: if `DeleteContainerSpans` succeeds at depth 2, `SpeculativeDelete` can be skipped at depth 2 (dominated). This pruning carries across the entire sweep.

- **Decoder: `DirectMaterializerDecoder`** — uses `Interpreters.materialize()` with the fixed tree. No GuidedMaterializer, no re-derivation, no approximation slack. Grade: `((1, 0), w)`.

- **On success within the sweep:** Update sequence/tree, continue to the next phase at the same depth. All phases (deletion, value minimization, reordering) run at each depth before moving to the next depth. This maximizes work per depth visit. The sweep completes the full range (depth max → depth 1) before the covariant leg runs.

- **No break-on-success:** Unlike the current `break depthLoop`, a success at depth 3 does not restart the cycle. The contravariant sweep is a thorough "smoothing" pass — it extracts all available improvements from all bound depths before handing control to the covariant leg. This makes 2-cell pruning maximally effective: if `DeleteContainerSpans` succeeds at depth 3, dominated encoders are skipped at depth 3 *and* the pruning state carries to depth 2 (same lattice).

### 4.3 Covariant Sweep Details

The covariant sweep runs at depth 0 only, after the contravariant sweep:

- **Decoder: `GuidedMaterializerDecoder`** with fallback tree containing the contravariant-improved bound values. Re-derivation uses tier-2 clamping to preserve those improvements where the new bound ranges permit.

- **On success:** The lattice must be rebuilt (deletion at depth 0 can remove spans, value reduction can change bound structure). If the covariant sweep succeeds, the cycle restarts — the contravariant sweep runs again on the newly derived bound values.

- **Can escape local minima:** If the contravariant sweep converged (all bound values minimized within their ranges), the covariant sweep can change those ranges by reducing inner values. This opens new territory for the next contravariant sweep.

### 4.4 Resource Budget

```swift
struct CycleBudget {
    var remaining: Int
    let phaseWeights: [ReductionPhase: Double]  // normalized to sum = 1

    func budget(for phase: ReductionPhase) -> Int {
        Int(Double(remaining) * (phaseWeights[phase] ?? 0))
    }
}
```

Default weights:
- Structural Deletion: 40%
- Value Minimization: 30%
- Reordering: 5%
- Redistribution: 15%
- Exploration: 10%

Weights adapt over cycles: if a phase keeps succeeding, increase its share; if exhausted, redistribute to later phases.

### 4.5 Branch Tactics

Branch manipulation (promote, pivot) operates on the tree, not on spans within a sequence. These run **once per cycle** before the depth loop, as they can change the tree shape at any depth. They use a separate protocol:

```swift
protocol BranchEncoder {
    var name: String { get }
    var grade: ReductionGrade { get }

    func encode(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
    ) -> AnySequence<(ChoiceSequence, ChoiceTree)>
}
```

Branch encoders return (sequence, tree) pairs because promotion/pivoting modifies the tree structure. They don't need targets — they operate on the full tree.

---

## 5. Migration Path

### Step 1: Core Types (No behavioral change)

Add `ReductionGrade`, `TargetSet`, `ReductionPhase`, `DecoderContext`.

**Files:** New file `Sources/ExhaustCore/Interpreters/Reduction/ReductionGrade.swift`.

### Step 2: Decoder Extraction

Extract the two materialization pipelines from `TacticEvaluation` and `TacticReDerivation` into `DirectMaterializerDecoder` and `GuidedMaterializerDecoder` conforming to `SequenceDecoder`.

**Files:**
- New `Sources/ExhaustCore/Interpreters/Reduction/Decoders/DirectMaterializerDecoder.swift`
- New `Sources/ExhaustCore/Interpreters/Reduction/Decoders/GuidedMaterializerDecoder.swift`
- New `Sources/ExhaustCore/Interpreters/Reduction/Decoders/DecoderFactory.swift`

`TacticEvaluation` and `TacticReDerivation` remain for backward compatibility with the existing KleisliReducer.

### Step 3: Encoder Extraction

For each existing tactic, extract the encoding logic into a `SequenceEncoder` conformance. The existing tactic's `apply()` becomes: call `encode()`, then call the shared decoder.

Start with the simplest: `ZeroValueEncoder`, `DeleteContainerSpansEncoder`. Verify that the decomposed version produces identical results on the existing test suite.

**Files:**
- New `Sources/ExhaustCore/Interpreters/Reduction/Encoders/` directory
- One file per encoder (mirrors existing `Tactics/` structure)

### Step 4: The Scheduler

Build the new `ReductionScheduler` that orchestrates encoders + decoders + grades with Gauss-Seidel depth ordering.

**Files:**
- New `Sources/ExhaustCore/Interpreters/Reduction/ReductionScheduler.swift`
- Modify `KleisliReducer.swift` to delegate to the scheduler

### Step 5: Grade-Based Scheduling

Add resource tracking and phase-budget allocation. Measure against the existing shrinking challenge benchmarks.

**Files:** Modify `ReductionScheduler.swift`.

### Step 6: Approximate Passes

Enable redistribution and tandem reduction as approximate passes with explicit grade tracking. The shortlex guard becomes: accept if `pipeline_grade.isExact` or the round-trip is empirically exact.

**Files:** New `CrossStageRedistributeEncoder`, `TandemReductionEncoder`.

---

## 6. Verification

### Correctness
- Run the full existing test suite (`Tests/ExhaustTests/`) at each step. No test assertion changes.
- The shrinking challenge benchmarks (`Tests/ExhaustTests/Challenges/Shrinking/`) are the primary correctness gate — they verify that the reducer finds the same (or better) minimal counterexamples.

### Performance
- `Tests/ExhaustTests/Integration/BindAwareReducerBenchmark.swift` — the bind-aware benchmark. Bottom-up ordering should show improvement here.
- Compare evaluation counts (property invocations) between old and new scheduler on the challenge suite.

### Maintainability
- A new encoder should require: one `SequenceEncoder` conformance, one file, no changes to the scheduler or decoder.
- Verify by adding a trivial no-op encoder and confirming it integrates without touching other files.

---

## 7. What the Paper's Guarantees Buy Us

| Guarantee | Paper Reference | What It Means for Implementation |
|---|---|---|
| Composition closure | Prop 3.2, 7.8 | Composing two valid encoders gives a valid encoder. No interaction testing needed *if* `dec` is shortlex-non-increasing. |
| Grade composition | Prop 10.4 | Pipeline resource usage = sum of step resources. Pipeline approximation = monoidal product of step approximations. Verified structurally, not empirically. |
| Feasibility preservation | Lemma 3.3 | If we could make `enc` feasibility-preserving (e.g., for monotone properties), we could skip the property check. Performance win for special cases. |
| 2-cell pruning | Def 15.3 | If encoder A pointwise dominates encoder B (same or better on every input), B can be skipped after A succeeds. Derived from the encoder's structure, not declared manually. |
| Natural transformation | Prop 5.4 | Post-processing (shortlex merge) commutes with encoding. Can be applied after any successful step without breaking pipeline correctness. |
| Covariant/contravariant | Section 4.1, 4.2 | Contravariant passes (Cand^op, against the Kleisli chain) are structure-preserving and lattice-stable. Covariant passes (Cand, with the chain) are speculative and lattice-destroying. The V-cycle interleaves them optimally. |
| Multigrid V-cycle | Section 14.4 | Contravariant sweep (smooth fine levels) → covariant sweep (correct coarse level) → post-process. Minimizes composed approximation grade for bind generators. |
