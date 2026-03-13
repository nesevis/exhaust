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

**Target state:** The decoder is selected by a `DecoderContext` (depth, bind state, strictness). All encoders sharing a context share the same decoder. This eliminates the TacticEvaluation vs. TacticReDerivation split.

**Hom-set key is (depth, strictness), not just depth.** This is the genuine decomposition, not a technicality. Deletion and value minimization have fundamentally different structural contracts: deletion shortens the sequence (the decoder must tolerate structural invalidity), while value minimization preserves length (the decoder expects the same structure, different values). Comparing "is DeleteContainerSpans better than ZeroValue?" through a single decoder is undefined — the candidates have different structural properties.

Concretely: structural deletion uses `.relaxed` / `GuidedMaterializerDecoder` (rebuilds tree from scratch), while value minimization at depth > 0 uses `.normal` / `DirectMaterializerDecoder` (replays against the fixed tree). These are different hom-sets at the same depth. The paper's uniformity requirement applies *within* each hom-set, not across them.

**The 2-cell dominance lattice has separate components per hom-set.** Within the deletion hom-set, all deletion encoders share `GuidedMaterializerDecoder(.relaxed)` and dominance is well-defined (e.g., `DeleteContainerSpans` ⇒ `SpeculativeDelete`). Within the value minimization hom-set, all value encoders share their decoder and dominance is well-defined (e.g., `ZeroValue` ⇒ `BinarySearchToZero`). Cross-hom-set dominance is not defined — the leg ordering (contravariant → deletion → covariant) replaces it.

### 1.3 Grade Composition

Each morphism carries a grade `g = (γ, w)` where `γ = (α, β) ∈ Aff_≥0` is the approximation slack and `w ∈ ℕ` is the resource bound (materializations). Grades compose via `g₁ ⊗ g₂ = (γ₁ ⊗ γ₂, w₁ + w₂)` where `(α, β) ⊗ (α', β') = (αα', β + αβ')`.

**Two levels of composition.** The monoidal product applies at two levels:

1. **Encoder + decoder → morphism grade.** Each encoder declares a grade (approximation + max candidates). Each decoder declares an approximation. The morphism grade is `encoder.grade.composed(withDecoder: decoder.approximation)`. For current encoders (phases 1–4), the encoder approximation is `(1, 0)`, so the morphism approximation equals the decoder's. Phase 5's `RelaxRoundEncoder` would have `(α, 0)` with α > 1, which amplifies the decoder's β by α — this is why the full monoidal product is used, not a simpler combination.

2. **Morphism + morphism → pipeline grade.** Sequential morphisms in a pipeline compose via the same monoidal product. The scheduler tracks the aggregate pipeline grade across a cycle.

This means:
- Exact morphisms have grade `((1, 0), w)` — encoder exact, decoder exact (`DirectMaterializerDecoder`)
- Decoder-approximate morphisms have grade `((1, β), w)` — encoder exact, decoder approximate (`GuidedMaterializerDecoder`). This includes all deletion morphisms and all depth-0 bind morphisms.
- Encoder-approximate morphisms (Phase 5) have grade `((α, αβ), w)` — encoder amplifies decoder's approximation
- The scheduler can verify that a pipeline's aggregate grade is acceptable before running it
- Resource budgets decompose additively across phases

**Non-commutativity and phase reordering.** The affine composition is non-commutative in general: `(α, 0) ⊗ (1, β') = (α, αβ')` but `(1, β) ⊗ (α, 0) = (α, β)`. However, for all currently planned phases (1–4), α = 1. When α = 1, the composition reduces to additive β: `(1, β₁) ⊗ (1, β₂) = (1, β₁ + β₂)`, which *is* commutative. **The scheduler can freely reorder α = 1 phases without affecting the composed grade.** Non-commutativity only matters when Phase 5 (exploration, α > 1) is introduced — running it before other phases amplifies their β by α. This is why Phase 5 must be last within a leg: it's a consequence of grade non-commutativity, not just a heuristic ordering.

### 1.4 Covariant and Contravariant Passes

The paper defines covariant and contravariant functors on the reduction category (Section 4). This distinction maps directly to two natural categories of reducer passes, determined by their direction relative to the Kleisli chain:

**Contravariant passes** (against the chain: depth max → depth 1):
- **Value minimization and reordering only.** Reduce bound values *within fixed ranges* — moving backward through the bind chain without disturbing the inner generators that determined those ranges.
- **Structure-preserving**: span boundaries, container groupings, sibling relationships are unchanged. The dominance lattice computed at sweep start remains valid throughout.
- **Exact**: no re-derivation needed. Grade: `((1, 0), w)`. The `dec` is `Interpreters.materialize()` with a fixed tree.
- **Can get stuck**: limited to the current feasible region. If the property failure requires a specific structural shape, contravariant passes can only minimize values within that shape, never escape it.
- In the paper's terms: these operate on the `Cand^op` functor (Section 4.2) — decoding maps candidates backward.

**Important: deletion is NOT contravariant**, even at depth > 0. Deletion removes spans, which invalidates the tree structure. The current `TacticEvaluation.evaluate()` routes all `.relaxed` strictness through `GuidedMaterializer` regardless of depth. Deletion at depth 2 uses `GuidedMaterializerDecoder`, has grade `(1, β)`, and invalidates the lattice — it belongs in a separate deletion sweep, not in the contravariant leg.

**Covariant passes** (with the chain: depth 0, or deletion at any depth):
- Reduce inner values, delete structure, or modify span boundaries, causing content to be *re-derived forward* through the Kleisli chain via GuidedMaterializer (prolongation).
- **Structure-destroying**: deletion removes spans, value reduction at depth 0 changes bound ranges. Span structure can change radically — the dominance lattice must be rebuilt.
- **Speculative**: re-derivation is nondeterministic. Grade: `((1, β), w)` with β > 0. But can explore entirely new regions of the candidate space.
- **Can escape local minima**: re-derivation via PRNG/fallback may find shorter bound content than the current state. Deletion at depth 0 can eliminate entire bound subtrees.
- In the paper's terms: these operate on the `Cand` functor (Section 4.1) — encoding maps candidates forward.

### 1.5 The Multigrid V-Cycle

The optimal cycle structure interleaves the two pass types, following the multigrid V-cycle pattern from the paper's Section 14.4 on multilevel methods:

```
  Branch tactics (pre-cycle):
    Promote/pivot. May change tree shape at any depth.
    If any succeed, rebuild all derived structures (lattice, bind index).
         │
         ▼
  Lattice computation:
    Built on post-branch state. Valid for the entire contravariant sweep.
         │
         ▼
  Contravariant sweep (depth max → 1):
    Value minimization + reordering ONLY.
    Exact, structure-preserving, lattice-stable.
    Converges to local minimum within fixed bound ranges.
         │
         ▼
  Deletion sweep (depth max → 0):
    Structure-destroying at ALL depths. GuidedMaterializer.
    Lattice rebuilt after each success. Separate from contravariant
    because deletion invalidates span structure even at depth > 0.
         │
         ▼
  Covariant sweep (depth 0):
    Value minimization + reordering at the inner level.
    Speculative, lattice-destroying. Changes bound ranges via
    inner value reduction. Fallback tree (containing contravariant
    improvements) minimizes β.
         │
         ▼
  Post-processing (natural transformation):
    Shortlex merge to recover contravariant improvements that
    re-derivation degraded. This is the Section 5.3 endotransformation.
         │
         ▼
  (repeat — dirty depths only, see Section 4.2)
```

**Why this ordering minimizes the composed approximation grade:**
- Contravariant reductions at depth > 0 have exact grade `(1, 0)`.
- The subsequent covariant reduction at depth 0 has grade `(1, β)` — but β is minimized via two mechanisms:
  1. **Prefix mechanism (tier 1).** The candidate sequence carries contravariant-improved bound values directly. When a covariant encoder mutates inner values, bound positions retain their old (optimized) values in the prefix. If the bound ranges haven't shifted, GuidedMaterializer uses these directly — no approximation.
  2. **Fallback tree mechanism (tier 2).** For bound values that *are* out of range after an inner value change, GuidedMaterializer clamps to the fallback tree's value. When the fallback tree contains contravariant-improved values, clamping lands near the optimum rather than at a random point.
- If covariant ran first (top-down), *both* mechanisms have worse inputs: the prefix contains unoptimized bound values, and the fallback tree does too. β is maximal.

This is Gauss-Seidel ordering applied to block coordinate descent with one-directional dependencies (inner → bound): process unconstrained blocks (contravariant, bound depths) before constraining blocks (covariant, inner depth).

**The cat-stroking algorithm.** Smooth the fur, then ruffle. The contravariant sweep is the stroking — getting all bound values into their smoothest state. The covariant sweep is the ruffle — changing inner values, disrupting bound ranges. But because the fallback tree remembers the smooth state, re-derivation clamps back toward it. β is how much fur sticks up after the ruffle. Pre-stroking minimizes it. If you ruffle first (top-down), the fur goes everywhere — bound values are re-derived from PRNG before they've been optimized, and β is maximal.

> *Basin hopping.* The V-cycle is structurally equivalent to monotonic basin hopping: the contravariant sweep finds the basin bottom (local minimum within fixed bound ranges), the covariant sweep hops to a new basin (changes inner values, shifting the landscape), and the shortlex guard is a strict acceptance criterion (only downhill). Redistribution is the perturbation-strength increase when monotonic hopping stalls.

> *Exploitation–exploration.* The contravariant sweep is pure exploitation (extract all value from the current landscape). The covariant sweep is exploration (change the landscape at the cost of β). Redistribution is reshaping — neither exploiting nor exploring, but trying a different joint configuration within the current landscape. The V-cycle is a structured exploitation–exploration schedule: exploit fully, explore once, exploit the new landscape.

> *MCTS/UCB.* The scheduler navigates a tree of possible reduction sequences. The contravariant sweep is deepening a promising subtree (exploitation within known structure). The covariant sweep is backing up to the root and trying a different branch (exploration via landscape change). The 2-cell dominance lattice is static UCB pruning — provably dominated encoders are never visited. Within equivalence classes (where dominance gives no ordering), adaptive encoder selection via Thompson Sampling serves as the UCB exploration term (see Section 4.7).

**Lattice stability implication:** During the contravariant sweep, the dominance lattice is computed once and remains valid — no span deletion or structural change occurs. The 2-cell pruning from Section 15 can safely skip dominated encoders throughout the entire sweep. During the covariant sweep, the lattice is rebuilt after each success (spans may have changed). This means lattice pruning is most valuable during the contravariant phase, where it avoids redundant materializations across many depths.

### 1.6 Local Minima and Termination

The covariant–contravariant distinction gives a precise characterization of local minima:

**A local minimum is a contravariant fixed point** — a state where `DirectMaterializerDecoder` rejects every candidate from every encoder at every bound depth. All exact, structure-preserving passes have stalled. The bound values are individually minimal within their current ranges, but those ranges are determined by the inner values at depth 0.

**The covariant sweep is the only escape.** By changing inner values (depth 0), the covariant sweep changes the bound ranges themselves — opening new territory for the next contravariant sweep. Re-derivation via `GuidedMaterializerDecoder` produces new bound content that may be shorter than the contravariant fixed point.

**If the covariant sweep also stalls, the pipeline has reached a global fixed point** — no morphism in the category produces progress. This gives a clean termination criterion: the reducer is done when one full V-cycle produces zero accepted candidates across both legs. No stall counters, no heuristic patience — just "did any morphism fire?"

**Redistribution as a second-order escape.** Phase 4 (redistribution) addresses a different kind of stall: cases where inner values are already minimal and the covariant sweep can't improve them, but bound values are "stuck" because they're individually minimal even though their *joint* configuration isn't. Redistribution transfers mass between coordinates — it's approximate (grade `(1, β)`), but it can create new attack surfaces for the next contravariant sweep. In terms of the fixed-point hierarchy:

1. **Contravariant fixed point** → escape via covariant sweep (change inner values, re-derive bounds)
2. **Covariant fixed point** → escape via redistribution (transfer mass between coordinates)
3. **Redistribution fixed point** → global fixed point, reducer terminates

**Degenerate case: no binds.** When `maxBindDepth == 0` (no bind generators), the V-cycle collapses. The contravariant sweep has no depths to visit (zero iterations). The covariant/contravariant distinction doesn't exist — there are no bound ranges to shift, no Kleisli chain, no re-derivation for value minimization. The deletion sweep runs at depth 0 only (using `GuidedMaterializerDecoder` because deletion invalidates the tree, not because of binds). The covariant sweep also runs at depth 0 with `DirectMaterializerDecoder` (no bind re-derivation needed). The result is a flat sweep: delete → minimize → reorder → redistribute → done. This is the Hypothesis/QuickCheck regime. The scheduler doesn't need to detect this explicitly — empty legs cost zero iterations. The V-cycle's structural power comes entirely from the bind/Kleisli depth structure; without it, the scheduler is running phases in order at a single depth.

---

## 2. Core Types

### 2.1 ReductionGrade

```swift
/// Qualitative approximation class for a morphism.
///
/// The paper's grade monoid uses (α, β) ∈ Aff_≥0 for quantitative
/// approximation tracking. In practice, β (additive slack from
/// re-derivation) is not concretely computable before the decode call —
/// it depends on which tier resolves each position, which depends on
/// whether bound ranges shifted, which depends on the specific candidate.
/// The shortlex guard (`reDerivedSequence.shortLexPrecedes(original)`) is
/// the actual runtime mechanism that bounds regression — a binary
/// accept/reject filter, not a continuous value.
///
/// This enum captures the qualitative distinctions the scheduler actually
/// uses: phase ordering, the V-cycle structure, and the constraint that
/// speculative encoders must run last. The monoidal product degenerates
/// to a lattice join.
enum ApproximationClass: Int, Comparable {
    /// No regression possible. The decoder reproduces the candidate exactly.
    /// `DirectMaterializerDecoder` with structure-preserving mutations.
    case exact = 0

    /// Re-derivation may shift the result away from the candidate, but
    /// the shortlex guard rejects any regression. The runtime bound is
    /// binary (accept/reject), not quantitative.
    /// `GuidedMaterializerDecoder` for deletion and depth-0 bind mutations.
    case bounded = 1

    /// The intermediate state may be shortlex-LARGER than the input.
    /// Requires a different acceptance criterion (pipeline result must
    /// improve, even if intermediate states regress). Phase 5 only.
    case speculative = 2

    /// Lattice join: the composed approximation is the worst of the two.
    func composed(with other: ApproximationClass) -> ApproximationClass {
        max(self, other)
    }
}

/// The grade of a morphism: approximation class + resource bound.
///
/// The resource bound (`maxMaterializations`) is concrete and computable.
/// The approximation class is qualitative — it determines phase ordering
/// and the V-cycle structure, not quantitative budget decisions.
///
/// **Encoder grades vs. morphism grades.** An encoder's grade tracks its
/// own approximation class (usually `.exact`) and resource bound (max
/// candidates). The *morphism* grade is the composition of the encoder's
/// grade with the decoder's approximation class.
struct ReductionGrade {
    let approximation: ApproximationClass
    /// Maximum materializations this encoder/morphism will consume.
    let maxMaterializations: Int

    static let exact = ReductionGrade(
        approximation: .exact, maxMaterializations: 0
    )

    var isExact: Bool { approximation == .exact }

    /// Compose two grades (e.g. two morphism grades in a pipeline).
    func composed(with other: ReductionGrade) -> ReductionGrade {
        ReductionGrade(
            approximation: approximation.composed(with: other.approximation),
            maxMaterializations: maxMaterializations + other.maxMaterializations
        )
    }

    /// Compose an encoder grade with a decoder's approximation class
    /// to produce the morphism grade.
    func composed(withDecoder decoder: ApproximationClass) -> ReductionGrade {
        ReductionGrade(
            approximation: approximation.composed(with: decoder),
            maxMaterializations: maxMaterializations
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

### 2.3 Encoder Protocols

Two interaction patterns require two protocols. A single protocol with an `isAdaptive` flag would force every conformer to implement a dead method: batch encoders would have a meaningless `nextProbe()`, adaptive encoders a meaningless `encode()`. Splitting makes the contract explicit: each conformer implements exactly the methods it uses.

**Why a flat `AnySequence` can't model binary search.** Binary search is a decision tree, not a list: after probing `v/2`, acceptance means probe `v/4`, rejection means probe `3v/4`. A flat sequence would need to precompute all `2^(log V)` paths upfront. The adaptive protocol instead lets the encoder navigate the decision tree one step at a time, with the scheduler providing feedback.

```swift
/// Shared metadata for all encoders.
protocol SequenceEncoderBase {
    /// Human-readable name for logging.
    var name: String { get }

    /// Declared grade: approximation bound + resource bound.
    var grade: ReductionGrade { get }

    /// Which phase this encoder belongs to.
    var phase: ReductionPhase { get }
}

/// Batch encoding: all candidates upfront, scheduler picks first success.
///
/// Pure and stateless. The scheduler evaluates candidates in order,
/// stopping at the first success (angelic resolution).
protocol BatchEncoder: SequenceEncoderBase {
    /// Produce candidate mutations, best first.
    ///
    /// Returns a lazy sequence of candidates. The scheduler filters
    /// through the reject cache and decodes each until one succeeds.
    func encode(
        sequence: ChoiceSequence,
        targets: TargetSet,
    ) -> some Sequence<ChoiceSequence>
}

/// Adaptive encoding: one probe at a time, feedback-driven.
///
/// Conformers are **stateful** — they maintain internal search state
/// (e.g. `[lo, hi]` bounds per target for binary search). The scheduler
/// drives the loop; the encoder navigates a decision tree based on
/// acceptance/rejection feedback.
///
/// **Ownership boundary:** The encoder never sees the decoded/re-derived
/// sequence. It works entirely in candidate space. When a probe is
/// accepted, the encoder learns only that fact (via `lastAccepted`),
/// not what the decoder produced. The scheduler separately records the
/// decoded result. The encoder's next probe is determined by its
/// internal state, not by the decoder's output.
protocol AdaptiveEncoder: SequenceEncoderBase {
    /// Initialize internal state for a new encoding pass.
    ///
    /// Called once by the scheduler before the probe loop begins.
    /// The encoder captures the starting sequence and targets, and
    /// builds whatever internal state it needs (e.g. `[lo, hi]` per
    /// target position for binary search).
    mutating func start(sequence: ChoiceSequence, targets: TargetSet)

    /// Produce the next probe given feedback on the previous one.
    ///
    /// - Parameter lastAccepted: Whether the previous probe was accepted
    ///   by the decoder (property failed on the materialized output).
    ///   Ignored on the first call after `start()`.
    /// - Returns: The next candidate to try, or `nil` when converged
    ///   (no more probes — search space exhausted).
    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence?
}
```

**Scheduler dispatch by protocol conformance:**

```swift
switch encoder {
case let batch as any BatchEncoder:
    // Batch: evaluate candidates in order, accept first success.
    for candidate in batch.encode(sequence: sequence, targets: targets)
        where rejectCache.contains(candidate) == false
    {
        if let result = decoder.decode(candidate: candidate, ...) {
            accept(result)
            break
        } else {
            rejectCache.insert(candidate)
        }
    }

case var adaptive as any AdaptiveEncoder:
    // Adaptive: scheduler drives the loop, encoder navigates the
    // decision tree. The encoder never sees the decoded output —
    // only whether the probe was accepted.
    adaptive.start(sequence: sequence, targets: targets)
    var lastAccepted = false
    while let probe = adaptive.nextProbe(lastAccepted: lastAccepted) {
        if let result = decoder.decode(candidate: probe, ...) {
            accept(result)
            lastAccepted = true
        } else {
            lastAccepted = false
        }
    }
}
```

**What encoders do NOT receive** (and why):
- `gen` — encoding is structural, no materialization
- `tree` — the tree constrains decoding, not encoding
- `property` — feasibility is the decoder's job
- `bindIndex` — span filtering by depth is the scheduler's job (done before calling encode)
- `fallbackTree` — a decoding concern
- `rejectCache` — the scheduler wraps batch encoder output in a cache-filtering layer, checking at evaluation time with the most up-to-date cache. Encoders are fully pure; cache filtering happens in exactly one place (the scheduler). The overhead of generating candidates that hit the cache is negligible — encoding is O(n) per candidate while decoding is dominated by materialization (running the generator on the candidate), which is much more expensive. Property evaluation itself is cheap by comparison; the cache's value is in avoiding wasted materializations.

### 2.4 Decoder Protocol

```swift
/// Materializes a candidate sequence and checks feasibility.
///
/// Selected by depth context, shared by all encoders at that depth.
/// This is the `dec` map from the paper.
///
/// The decoder's `approximation` is its intrinsic contribution to the
/// morphism grade. The scheduler composes it with the encoder's grade
/// via `encoder.grade.composed(withDecoder: decoder.approximation)`.
protocol SequenceDecoder {
    /// The approximation this decoder introduces per decode call.
    ///
    /// `DirectMaterializerDecoder` returns `.exact` — tree-driven
    /// materialization preserves the candidate exactly.
    /// `GuidedMaterializerDecoder` returns `(1, β)` — re-derivation
    /// can shift bound values away from the candidate's intent.
    var approximation: ReductionApproximation { get }

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
/// One decoder per context = all encoders sharing a context share the
/// same `dec`, forming a uniform hom-set (paper Section 7).
///
/// Two independent reasons trigger `GuidedMaterializerDecoder`:
/// 1. **Bind re-derivation** (depth 0, binds present): bound content must
///    be re-derived after inner value changes.
/// 2. **Structural invalidity** (`.relaxed` strictness): deletion at any
///    depth invalidates the tree's positional mapping — even without binds,
///    the tree must be rebuilt from the generator.
enum DecoderFactory {
    static func decoder(for context: DecoderContext) -> SequenceDecoder {
        let needsBindReDerivation = context.depth == 0
            && context.bindIndex != nil
            && context.bindIndex?.isEmpty == false

        let needsTreeRebuild = context.strictness == .relaxed

        if needsBindReDerivation || needsTreeRebuild {
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

- **`DirectMaterializerDecoder`**: Wraps `Interpreters.materialize()`. Tree-driven: the tree's element scripts determine how the sequence is interpreted. Used for structure-preserving mutations at depth > 0 (contravariant sweep). Deterministic, exact. `approximation = .exact`.

- **`GuidedMaterializerDecoder`**: Wraps `GuidedMaterializer.materialize()`. Sequence-driven with tiered value resolution. Used whenever the tree must be rebuilt: deletion at any depth (even without binds — the tree's positional mapping is invalidated), and value minimization/reordering at depth 0 with binds (bound content must be re-derived). Nondeterministic, approximate. `approximation = ReductionApproximation(alpha: 1, beta: β)` where β represents the maximum shortlex regression from re-derivation. Includes the shortlex round-trip guard (`reDerivedSequence.shortLexPrecedes(originalSequence)`).

  **Tiered value resolution** (this is the mechanism that makes the Section 1.5 ordering argument work):

  1. **Tier 1 — candidate prefix.** GuidedMaterializer replays the generator using the candidate sequence as a prefix. At each choice point, the candidate's value is used if it falls within the current valid range. For bound positions that the encoder didn't modify, the candidate still carries the old (potentially contravariant-optimized) values. If the bound ranges haven't shifted, these are used directly — no approximation.

  2. **Tier 2 — fallback tree.** When a prefix value is out of the current valid range (e.g., an inner value change shifted the bound range), or when the prefix is exhausted (deletion shortened it), GuidedMaterializer clamps to the fallback tree's value for that position. The fallback tree is the tree from the last accepted state — if the contravariant sweep already optimized bound values, clamping lands near the optimum.

  3. **Tier 3 — PRNG.** When neither the prefix nor the fallback tree has a value (new positions created by re-derivation), a seeded PRNG provides the value. The seed is derived from the candidate's zobrist hash for determinism.

  **Why contravariant-first minimizes β:** After the contravariant sweep, the candidate prefix (tier 1) carries optimized bound values, and the fallback tree (tier 2) contains the same optimized values. Both tiers feed the `GuidedMaterializerDecoder` with good starting points. If the covariant sweep ran first, both tiers would contain unoptimized values — tier-2 clamping would land at arbitrary points, and tier-3 PRNG would be reached more often. β (the shortlex regression from re-derivation) is the distance between what the encoder intended and what the tiered resolution produced. Better tier-1 and tier-2 inputs → smaller distance → smaller β.

### 2.6 ReductionPhase

```swift
/// The categorical type of a reduction phase.
///
/// Phases are ordered by guarantee strength. Within each phase,
/// encoders are ordered by the 2-cell preorder.
enum ReductionPhase: Int, Comparable {
    case structuralDeletion = 0     // Encoder exact; morphism approximate via decoder
    case valueMinimization = 1      // Encoder exact; morphism exact or approximate via decoder
    case reordering = 2             // Encoder exact; morphism exact or approximate via decoder
    case redistribution = 3         // Encoder approximate, grade (1, β)
    case exploration = 4            // Encoder approximate, grade (α, β)
}
```

---

## 3. The Phase Pipeline

### Phase 1: Structural Deletion (Encoder-Exact)

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

**Strictness:** All deletion uses `.relaxed` uniformly. Any deletion — whether removing a whole container subtree or a single free-standing value — invalidates the tree's positional mapping. `GuidedMaterializerDecoder` rebuilds the tree from the generator using the shortened candidate as a prefix. Strictness is a decoder concern determined by the sweep leg (Section 4.3), not an encoder property.

**Encoder grade:** `((1, 0), n)` where n = target count. All deletion encoders are exact — they produce structurally valid shorter candidates with no approximation. The *morphism* grade depends on the decoder: `((1, 0), n)` with `DirectMaterializerDecoder`, `((1, β), n)` with `GuidedMaterializerDecoder`. In the deletion sweep (Section 4.3), the decoder is always `GuidedMaterializerDecoder`, so the morphism grade is approximate despite the encoder being exact. The approximation comes entirely from re-derivation, not from the structural mutation itself.

### Phase 2: Value Minimization (Encoder-Exact)

**Goal:** Minimize each entry at its position (lexicographic improvement, fixed length).

**Encoders:**
1. `ZeroValueEncoder` — set each value to 0. Grade: `((1, 0), n)`.
2. `BinarySearchToZeroEncoder` — binary search each value toward 0. Grade: `((1, 0), n·log V)`.
3. `BinarySearchToTargetEncoder` — binary search toward a target from another depth. Grade: `((1, 0), n·log V)`.
4. `ReduceFloatEncoder` — multi-stage float pipeline. Grade: `((1, 0), n·stages·log V)`.

**2-cell chain:** 1 ⇒ 2 ⇒ 3. Zero is the best binary-search-to-zero can achieve. Binary-search-to-zero finds values ≤ any nonzero target.

**Note:** Binary search and float reduction conform to `AdaptiveEncoder` (see Section 2.3). Each probe depends on the outcome of the previous one — binary search maintains `[lo, hi]` per target and narrows based on acceptance/rejection. The scheduler calls `start()` once, then `nextProbe(lastAccepted:)` in a loop, modeling binary search as iterated Kleisli composition. The encoder never sees the decoded output — only whether each probe was accepted. `ZeroValueEncoder` conforms to `BatchEncoder` — it returns all zero-candidates upfront via `encode()`.

### Phase 3: Reordering (Encoder-Exact)

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

After the covariant sweep, before the next cycle. Two cheap pre-checks gate the merge to avoid a wasted `GuidedMaterializer` call:

0. **Pre-check 1 — covariant progress.** If the covariant sweep made no progress, the post-covariant state equals the pre-covariant state. Nothing to merge. O(1) check on a flag the scheduler already tracks.

0. **Pre-check 2 — bound regression scan.** The merge can only help if some post-covariant bound value is *larger* than its pre-covariant counterpart (re-derivation regressed that position). If re-derivation only decreased or preserved values at every bound position, the merge can't improve anything. O(n) scan over bound positions — essentially free compared to a materialization.

If both pre-checks pass (covariant sweep changed something, and at least one bound position regressed):

1. **Shortlex merge of bound entries** — for each bound position, keep min(old, new). This is a natural endotransformation on `Cand` (Section 5.3). The merged sequence is a Frankenstein: bound values cherry-picked from different states, not produced by running the generator.

2. **Tree re-materialization** — the merged sequence has no corresponding tree. Run `GuidedMaterializer` on the merged sequence to produce a consistent (sequence, tree, output) triple. This may change span boundaries relative to the pre-merge tree — the next cycle's lattice (computed fresh at cycle start) reflects whatever structure the re-materialization produces.

3. **Fallback on merge failure** — if `GuidedMaterializer` can't materialize the merged sequence (bound values from different states are incompatible), keep the unmerged state. The merge is speculative; failure is expected when the covariant sweep changed bound ranges significantly. The pre-checks filter definite no-ops but can't predict consistency failures — the cherry-picked combination may still be structurally invalid.

At most one `GuidedMaterializer` call per cycle, and only when the pre-checks indicate the merge has a chance of recovering lost contravariant improvements.

---

## 4. The Scheduler

### 4.1 Cycle Structure: The Multigrid V-Cycle

Each cycle has four legs plus pre/post processing:

```
for each cycle:
    // ── Pre-cycle: Branch tactics ──
    // Promote/pivot. May change tree shape at any depth.
    for branchEncoder in branchEncoders:
        if let result = tryBranch(branchEncoder, sequence, tree):
            accept(result)
            // Tree shape changed — rebuild ALL derived structures.

    // ── Lattice computation ──
    // Built on post-branch state. Valid for the entire contravariant sweep.
    let lattice = buildLattice(sequence)
    var dirtyDepths: Set<Int> = Set(1 ... maxBindDepth)  // all dirty on first cycle

    // ── Leg 1: Contravariant sweep (fine → coarse) ──
    // Value minimization + reordering ONLY. Structure-preserving, exact.
    // Depth-major: all phases at depth d before moving to d−1.
    for depth in (1 ... maxBindDepth).reversed() where dirtyDepths.contains(depth):
        context = DecoderContext(depth, bindIndex, fallbackTree, .normal)
        decoder = DirectMaterializerDecoder(strictness: .normal)
        targets = extractTargets(sequence, depth, bindIndex)

        runValueMinimization(lattice, targets, decoder, ...)
        let reorderingMadeProgress = runReordering(lattice, targets, decoder, ...)

        // Within-depth fixpoint: reordering can create new value-min
        // opportunities by moving values to different positions.
        if reorderingMadeProgress {
            runValueMinimization(lattice, targets, decoder, ...)
        }

    // ── Leg 2: Deletion sweep (all depths, fine → coarse) ──
    // Structure-destroying at ALL depths. GuidedMaterializer.
    for depth in (0 ... maxBindDepth).reversed():
        context = DecoderContext(depth, bindIndex, fallbackTree, .relaxed)
        decoder = GuidedMaterializerDecoder(fallbackTree: fallbackTree, strictness: .relaxed)
        targets = extractDeletionTargets(sequence, depth, bindIndex)

        for encoder in deletionEncoders:
            // ... encode, decode, accept if successful
            // On success: rebuild lattice (spans changed)

    // ── Leg 3: Covariant sweep (depth 0) ──
    // Value minimization + reordering at the inner level.
    // Speculative, lattice-destroying, can escape local minima.
    context = DecoderContext(0, bindIndex, fallbackTree, .normal)
    decoder = GuidedMaterializerDecoder(fallbackTree: fallbackTree)
    targets = extractTargets(sequence, 0, bindIndex)

    for phase in [.valueMinimization, .reordering]:
        for encoder in encoders(for: phase):
            // ... encode, decode, accept if successful
            // On success: mark affected chain's depths dirty
            //   (all depths for single-chain generators)

    // ── Leg 4: Post-processing (natural transformation) ──
    // Shortlex merge to recover contravariant improvements
    // degraded by covariant re-derivation.
    applyShortlexMerge(sequence, fallbackTree)

    // ── Cross-cutting: redistribution if all legs stalled ──
    if no improvement:
        run Phase 4 (redistribution) with approximate grade tracking

    // Dirty-depth tracking for next cycle (see Section 4.2)
    // Stall logic, termination
```

**Key difference from the current KleisliReducer:** The current implementation runs all phases at all depths in a single bottom-up sweep, breaking on first success. The V-cycle separates three structurally different operations: the contravariant sweep (value minimization at depths > 0, exact, lattice-stable), the deletion sweep (structure-destroying at all depths, GuidedMaterializer, lattice rebuilt), and the covariant sweep (depth 0, speculative, lattice-rebuilding). This lets the lattice be computed once for the contravariant leg, and makes subsequent legs' re-derivation benefit from the contravariant improvements.

### 4.2 Contravariant Sweep Details

The contravariant sweep handles value minimization and reordering at bound depths with exact guarantees:

- **Value minimization and reordering only.** Deletion is excluded — it invalidates span structure even at depth > 0 (see Section 1.4). This is what makes the lattice stable.

- **Lattice computed once** at sweep start and reused across all depths. Contravariant passes modify values within existing spans without changing span boundaries, so the lattice edges remain valid. 2-cell pruning is effective here: if `ZeroValueEncoder` succeeds at depth 2, `BinarySearchToZeroEncoder` can be skipped at depth 2 (dominated). This pruning carries across the entire sweep.

- **Decoder: `DirectMaterializerDecoder`** — uses `Interpreters.materialize()` with the fixed tree. No GuidedMaterializer, no re-derivation, no approximation slack. Grade: `((1, 0), w)`.

- **Depth-major ordering.** Both phases (value minimization, reordering) run at each depth before moving to the next depth. Depths in the contravariant sweep are independent — bound values at different depths are in separate bind regions with independently determined ranges, so cross-depth interaction doesn't exist. The ordering question (depth-major vs phase-major) is irrelevant at the cross-depth level; depth-major is chosen for locality.

- **Within-depth fixpoint.** Reordering at depth `d` can create new value-minimization opportunities at the same depth: it permutes values to different positions, and if the property has position-dependent behavior, values that were stuck may become reducible. After a successful reordering at depth `d`, the scheduler re-runs value minimization at depth `d` (one re-pass, not a full fixpoint loop — the interaction is unlikely to cascade). Without this, the opportunities would be lost: dirty-depth tracking won't mark depth `d` dirty (reordering doesn't change inner values, only permutes bound values), so the next cycle's contravariant sweep would skip it.

- **No break-on-success:** Unlike the current `break depthLoop`, a success at depth 3 does not restart the cycle. The contravariant sweep is a thorough "smoothing" pass — it extracts all available improvements from all bound depths before handing control to subsequent legs.

- **Dirty-depth tracking:** On cycle restart after a covariant or deletion success, re-sweep depths whose bound ranges or span structure may have changed.

  `BindSpanIndex` provides **per-region** precision, not per-depth precision. `bindRegionForInnerIndex(i)` identifies which `BindRegion` a depth-0 inner value feeds. But within a single bind chain, the cascade is structural: a depth-0 change shifts bound ranges at depth 1, which can shift ranges at depth 2 (if nested), and so on. **Within a chain, all depths are dirty.** The per-region precision only helps when there are **independent bind chains** — e.g. `(bind1, bind2)` where a change in bind1's inner values doesn't affect bind2's depths.

  For the common case (single bind chain), dirty-depth tracking degenerates to "any depth-0 change dirties all bound depths." The optimization buys nothing there. For generators with multiple independent binds, it avoids re-sweeping unaffected chains. The scheduler should use the per-region information when available but not assume it provides fine-grained depth skipping in general.

### 4.3 Deletion Sweep Details

The deletion sweep runs after the contravariant sweep, at all depths (max → 0):

- **Decoder: `GuidedMaterializerDecoder`** with `.relaxed` strictness. Deletion invalidates the tree's element scripts — GuidedMaterializer rebuilds a fresh tree from the generator using the shortened candidate as a prefix.

- **Lattice rebuilt after each success.** Deletion changes span structure (removes spans, shifts positions), invalidating the dominance lattice. The lattice is recomputed from the post-deletion state before the next encoder is tried.

- **Includes all deletion encoders:** container spans, sequence elements, boundaries, free-standing values, aligned windows, speculative delete.

- **Separate from the contravariant sweep** because deletion at depth > 0 is approximate (grade `(1, β)`) — re-derivation via GuidedMaterializer can produce different content for the gap left by the deleted span. Grouping it with the exact contravariant sweep would violate the lattice stability guarantee.

### 4.4 Covariant Sweep Details

The covariant sweep runs at depth 0 only, after the deletion sweep:

- **Value minimization and reordering only** (deletion at depth 0 is handled by the deletion sweep).

- **Decoder: `GuidedMaterializerDecoder`** with fallback tree containing the contravariant-improved bound values. Re-derivation uses tier-1 prefix values and tier-2 clamping to preserve those improvements where the new bound ranges permit.

- **On success:** Mark affected bind chains dirty. `BindSpanIndex.bindRegionForInnerIndex` identifies which bind region the mutated inner value feeds. All depths within that region's chain are dirty (bound ranges may have shifted at every nesting level). For generators with multiple independent bind chains, only the affected chain is dirtied — unaffected chains are skipped on the next contravariant sweep. For the common case (single bind chain), all bound depths are dirty and the next contravariant sweep is a full re-sweep. For deletion successes in the deletion sweep, all depths are dirty (span positions are invalidated globally).

- **Can escape local minima:** If the contravariant sweep converged (all bound values minimized within their ranges), the covariant sweep can change those ranges by reducing inner values. This opens new territory for the next contravariant sweep.

### 4.5 Resource Budget

The budget is organized by **leg**, not by phase — matching the execution model. Each leg has an independent budget, preventing the contravariant sweep from starving the covariant sweep. Within a leg, phases draw proportionally from the leg's allocation.

```swift
struct CycleBudget {
    let total: Int

    /// Per-leg allocation as fraction of total. Normalized to sum = 1.
    let legWeights: [ReductionLeg: Double]

    /// Within-leg phase splits (value minimization vs reordering).
    /// Only meaningful for legs that run multiple phases.
    let phaseWeights: [ReductionPhase: Double]

    func budget(for leg: ReductionLeg) -> Int {
        Int(Double(total) * (legWeights[leg] ?? 0))
    }

    func budget(for phase: ReductionPhase, in leg: ReductionLeg) -> Int {
        let legBudget = budget(for: leg)
        return Int(Double(legBudget) * (phaseWeights[phase] ?? 0))
    }
}

enum ReductionLeg {
    case branch
    case contravariant
    case deletion
    case covariant
    case redistribution
}
```

Default leg weights:
- Branch tactics: 5%
- Contravariant sweep: 30%
- Deletion sweep: 30%
- Covariant sweep: 25%
- Redistribution: 10%

Default within-leg phase weights (shared by contravariant and covariant legs):
- Value Minimization: 85%
- Reordering: 15%

The covariant sweep gets its own 25%, independent of how many depths the contravariant sweep processes. A 4-depth contravariant sweep consumes its 30% across 4 depths; the covariant sweep's 25% is reserved for the single depth-0 pass that escapes fixed points. Without per-leg budgets, the covariant sweep would starve whenever `maxBindDepth` is large.

Weights adapt over cycles: if a leg keeps succeeding, increase its share; if exhausted, redistribute to later legs. Adaptation is per-leg, not per-phase — the leg is the unit of budget accounting.

### 4.6 Branch Tactics

Branch manipulation (promote, pivot) operates on the tree, not on spans within a sequence. These run **once per cycle before lattice computation** — since branch tactics can change the tree shape at any depth, the lattice must be built on the post-branch state. If any branch tactic succeeds, all derived structures (lattice, bind index, depth map) are rebuilt from scratch. They use a separate protocol:

```swift
protocol BranchEncoder {
    var name: String { get }
    var grade: ReductionGrade { get }

    func encode(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
    ) -> some Sequence<ChoiceSequence>
}
```

The tree is **read-only input** — branch encoders need it to identify branch points and available alternatives (which branches exist, what children can be promoted), but they return candidate sequences only. The scheduler passes each candidate through `GuidedMaterializerDecoder(.relaxed)`, which rebuilds the tree from the generator using the candidate as a prefix. This keeps tree construction lazy (only the candidate the scheduler accepts is fully materialized) and maintains the enc/dec separation: the encoder proposes structural mutations, the decoder materializes the consistent `(sequence, tree, output)` triple. Branch encoders don't need targets — they operate on the full tree structure.

### 4.7 Adaptive Encoder Selection Within Equivalence Classes

The 2-cell dominance preorder (Section 15) determines *which* encoders can be pruned after a success — but within an equivalence class (encoders that mutually dominate each other), the preorder gives no ordering. This is where adaptive selection operates.

**Algorithm: Thompson Sampling with decaying Beta priors.**

Thompson Sampling over UCB, ε-greedy, or SoftMax because it has no exploration parameter to tune. Exploration emerges naturally from posterior uncertainty — wide posteriors (uncertain encoders) are explored; narrow posteriors (confident) are exploited. With equivalence classes of 2–4 encoders, this is the best-understood algorithm for small action spaces.

**Structure:**

The dominance preorder quotients into equivalence classes, forming a partial order (DAG) on the quotient. Three levels of ordering:

1. **Between equivalence classes** (quotient DAG): fixed, structural. If class [A] dominates class [B], prune [B] after any member of [A] succeeds.
2. **Within equivalence classes**: adaptive, via Thompson Sampling. The preorder says these encoders are interchangeable; the bandit learns which performs best in the current context.
3. **Incomparable classes**: all tried, no pruning.

**Binary rewards:**

Each encoder maintains a Beta(α, β) distribution, updated after every attempt with binary outcomes:

| Outcome | Update |
|---|---|
| Accepted | α += 1 |
| Not accepted (any reason) | β += 1 |

Binary rewards preserve the conjugate prior relationship: the Beta distribution is the exact Bayesian posterior for a Bernoulli likelihood. This gives the standard Thompson Sampling regret bound — O(√(KT log T)) — which guarantees convergence to the best encoder within the equivalence class. Shaped rewards (fractional updates based on rejection reason) would encode more domain knowledge but break conjugacy, turning the posterior into a heuristic tracking rule with no formal guarantees. With 2–4 encoders and decay γ = 0.8, binary rewards converge in 2–3 cycles — the information loss from collapsing failure reasons is negligible at this scale. If empirical evidence later shows that binary rewards are insufficient (e.g., the selector persistently picks the wrong encoder), shaped rewards can be introduced as an explicitly heuristic optimization.

**Non-stationarity handling:**

At each cycle boundary, decay all priors toward Beta(1,1):

```
α ← γα + (1 − γ)
β ← γβ + (1 − γ)
```

With γ = 0.8, the last ~5 cycles dominate the posterior. After a successful reduction changes the landscape, old observations fade and the selector re-explores. The decay target Beta(1,1) is the uniform prior — "no information, try anything."

**Cold start:** Beta(1,1) samples uniformly on [0,1], so the first cycle tries encoders in arbitrary order. After one round of observations, the posterior already differentiates.

**No cross-depth signal sharing (RAVE).** Adjacent depths can have structurally unrelated content (Int values at depth 2, Float values at depth 3), so encoder success at one depth is not reliable evidence for adjacent depths. With equivalence classes of 2–4 encoders and decay γ = 0.8, Thompson Sampling converges in 1–2 cycles without cross-depth sharing. RAVE would add complexity and a misleading-signal risk for marginal benefit.

**Overhead:** O(1) per update, O(k) per ranking where k is the equivalence class size. For typical classes (2–4 encoders), this is negligible compared to a single materialization.

### 4.8 Parallelism

The scheduler is single-threaded. The property closure is `@Sendable` at the public API boundary, so speculative parallel decoding (evaluating multiple batch candidates concurrently) is architecturally possible — nothing in the enc/dec separation prevents it.

In practice, the near-term upside is small. Materialization dominates single-candidate cost, not property evaluation, and the batch encoder path already stops at the first success (angelic resolution). Parallel decoding would speculatively materialize candidates that are never used. More importantly, test suites are typically run in parallel at the suite level — each test case reduction runs independently, so the execution is holistically parallel even with a single-threaded scheduler. Adding intra-reduction parallelism would compete for the same cores.

If profiling later shows that single-candidate materialization is the bottleneck (e.g., generators with expensive bind chains), parallel decoding can be introduced without changing the encoder or decoder protocols — it's a scheduler-internal optimization.

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

`TacticEvaluation` and `TacticReDerivation` remain temporarily for backward compatibility with the existing KleisliReducer. Removed in Step 7 once the new scheduler is verified.

### Step 3: Encoder Extraction

For each existing tactic, extract the encoding logic into a `BatchEncoder` or `AdaptiveEncoder` conformance. The existing tactic's `apply()` becomes: call `encode()` / the `start()`+`nextProbe()` loop, then call the shared decoder.

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

### Step 7: Legacy Removal

Once the new scheduler passes the full test suite and shrinking challenge benchmarks at parity or better, remove the old code paths:

- Delete `TacticEvaluation` and `TacticReDerivation` (replaced by `SequenceDecoder` conformances)
- Delete the four tactic protocols (`ShrinkTactic`, `BranchShrinkTactic`, `SiblingGroupShrinkTactic`, `CrossStageShrinkTactic`) and all conformances in `Tactics/`
- Delete `ReducerStrategies` method implementations that have been extracted into encoders
- Remove the old tactic-dispatch logic from `KleisliReducer` (now fully delegating to `ReductionScheduler`)
- Delete `EvaluationCounter` (the scheduler tracks materializations directly via the grade)

**Gate:** All shrinking challenge benchmarks produce equal or better results (same or smaller final counterexample, same or fewer materializations). No test assertion changes.

---

## 6. Verification

### 6.1 Testability by Component

The enc/dec separation makes the most complex logic (structural mutation) the easiest to test. Contrast with the current architecture, where every tactic's `apply()` bundles encoding, decoding, and resource tracking — testing a single tactic requires a full `ReflectiveGenerator`, `ChoiceTree`, property closure, and `ReducerCache`.

**Encoders** — pure functions, no generator or tree needed. Tests use only `ChoiceSequence` and `TargetSet` fixtures:

- **Candidate correctness.** "Given this sequence and these target spans, the encoder produces these specific candidates." Deterministic, snapshot-testable.
- **Shortlex invariant.** Every candidate is shortlex ≤ the input. Universal property, testable with Exhaust itself across random sequences.
- **2-cell dominance.** "Every candidate from encoder A is also produced by encoder B" (for A ⇒ B). Structural property, verifiable without a property closure — just compare candidate sets.
- **Adaptive convergence.** Feed a `BinarySearchToZeroEncoder` a sequence of `lastAccepted` values and assert the probe trajectory. Binary search converges in ⌈log₂ v⌉ steps regardless of the property.
- **Empty targets.** Encoder returns an empty sequence when given no targets. Boundary case.

**Decoders** — heavier fixtures (generator + tree), but isolated from encoder logic:

- **DirectMaterializerDecoder.** Output sequence equals the candidate (exact). Deterministic given the same tree. Assert `result.sequence == candidate` for valid candidates.
- **GuidedMaterializerDecoder tiered resolution.** Construct candidates with specific out-of-range positions and verify: tier 1 uses the prefix value when in range, tier 2 clamps to the fallback tree when out of range, tier 3 falls back to PRNG when neither has a value.
- **Shortlex guard.** Candidate that's shortlex-larger than the original → decoder returns `nil`.
- **Approximation property.** `decoder.approximation` is `.exact` for `DirectMaterializerDecoder`, `(1, β)` for `GuidedMaterializerDecoder`.

**DecoderFactory** — pure function from `DecoderContext` → decoder type. Exhaustive case testing:

- `.relaxed` strictness → `GuidedMaterializerDecoder` (regardless of bind state)
- depth > 0, no binds, `.normal` → `DirectMaterializerDecoder`
- depth 0, binds present, `.normal` → `GuidedMaterializerDecoder`
- depth 0, no binds, `.normal` → `DirectMaterializerDecoder`

**ReductionGrade / ReductionApproximation** — value types with pure arithmetic. Property-testable:

- Associativity: `(a ⊗ b) ⊗ c == a ⊗ (b ⊗ c)`
- Identity: `a ⊗ .exact == a`
- Commutativity when α = 1: `a ⊗ b == b ⊗ a` (all current phases)
- Non-commutativity when α > 1: `a ⊗ b != b ⊗ a` (Phase 5)
- `composed(withDecoder:)` consistent with `composed(with: ReductionGrade(decoder, 0))`

**Thompson Sampling** — stateful but deterministic given a fixed seed:

- Binary update: accepted → α grows, not accepted → β grows
- Decay: after decay with γ = 0.8, priors move toward Beta(1,1)
- Cold start: Beta(1,1) produces no ordering preference
- Convergence: after N successes on one arm, that arm is ranked first with high probability (testable with a fixed seed)

**Scheduler** — the scheduler's decisions are all derivable from concrete inputs. Each decision is exposed as a static, deterministic function testable without mocks:

- `dirtyDepths(bindIndex:mutatedIndices:) -> Set<Int>` — given a `BindSpanIndex` and the indices that changed, which depths need re-sweeping? Testable with `BindSpanIndex` fixtures and index sets.
- `mergePreCheck(preCovariant:postCovariant:bindIndex:) -> Bool` — did any bound position regress? Pure scan over two sequences.
- `shortlexMerge(old:new:bindIndex:) -> ChoiceSequence` — per-position min of bound entries. Pure function over two sequences.
- `allocateBudget(total:legWeights:phaseWeights:) -> CycleBudget` — pure arithmetic from weights to per-leg, per-phase budgets.
- `canAfford(budget:leg:grade:) -> Bool` — does the remaining budget accommodate this encoder's declared grade?
- `selectEncoder(equivalenceClass:posteriors:seed:) -> EncoderIndex` — Thompson Sampling ranking. Deterministic given a fixed seed.
- `updatePosterior(prior:accepted:) -> BetaParameters` — binary Bayesian update. Pure arithmetic.
- `decayPosteriors(priors:gamma:) -> [BetaParameters]` — cycle-boundary decay toward Beta(1,1). Pure arithmetic.
- `shouldRerunValueMinimization(reorderingSucceeded:) -> Bool` — within-depth fixpoint decision. Trivially testable.
- `cycleTerminated(acceptedThisCycle:) -> Bool` — zero acceptances across all legs → done.

The scheduler loop itself is thin glue: iterate legs, call these functions, dispatch to encoders/decoders. The logic lives in the functions, not in the loop.

### 6.2 Integration Testing

- Run the full existing test suite (`Tests/ExhaustTests/`) at each migration step. No test assertion changes.
- The shrinking challenge benchmarks (`Tests/ExhaustTests/Challenges/Shrinking/`) are the primary correctness gate — they verify that the reducer finds the same (or better) minimal counterexamples.

### 6.3 Performance

- `Tests/ExhaustTests/Integration/BindAwareReducerBenchmark.swift` — the bind-aware benchmark. The V-cycle ordering should show improvement here.
- Compare materialization counts between old and new scheduler on the challenge suite.

### 6.4 Maintainability

- A new encoder should require: one `BatchEncoder` or `AdaptiveEncoder` conformance, one file, no changes to the scheduler or decoder.
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
