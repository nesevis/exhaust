# Principled Test Case Reduction: Implementation Plan

> Companion document to [kleisli-reducer-paper-audit.md](kleisli-reducer-paper-audit.md), which maps the
> Sepulveda-Jimenez categorical framework onto the current KleisliReducer implementation.
> This plan uses that audit's findings to redesign reduction from first principles.

## Context

The Sepulveda-Jimenez paper ("Categories of Optimization Reductions", 2026) provides a categorical framework for reasoning about optimization pipelines as composable `(enc, dec, grade)` morphisms. The paper operates at the level of a *reduction framework* — it defines the algebra for composing, scheduling, and reasoning about reductions (enc/dec separation, grade composition, 2-cell dominance, resource additivity), but does not prescribe specific reduction strategies. The concrete encoders, decoders, and scheduling heuristics are determined by the problem domain.

This plan instantiates that framework for Exhaust's specific problem space: shortlex simplification of variable-length choice sequences with hierarchical bind structure. The framework contributions (from the paper) and the domain contributions (from Exhaust's representation) are distinct:

- **From the paper:** enc/dec separation, grade composition, 2-cell pruning, resource additivity, composition closure, relax-round pattern.
- **From the domain:** the specific encoders (deletion, binary search, redistribution, and others), the three-pass taxonomy (with deletion as a pragmatic addition — the paper assumes fixed-structure candidate spaces, while shortlex simplification optimizes over variable-length sequences), the V-cycle depth ordering for bind-dependent generators, the tiered decoder resolution, and the shortlex merge.

The result is a principled reduction framework applied to test case minimization — one where:
- Adding a new reduction strategy requires implementing only a pure encoding function
- Correctness guarantees compose automatically via the grade algebra
- Resource budgets decompose cleanly across phases
- The depth sweep order is theoretically justified, not empirically discovered

---

## 1. Architectural Principles

### 1.1 Separate `enc` from `dec`

The paper's core insight: a reduction morphism is a pair `(enc, dec)` where `enc` mutates the candidate and `dec` recovers a valid solution. These have different concerns and different parameter needs.

**Current state:** Every tactic bundles encoding, decoding, feasibility checking, and resource tracking into a single `apply()` method. This couples structural mutation to materialization strategy, making tactics hard to test, compose, and reason about.

**Target state:** `encode` is a pure function from (sequence, targets) → candidates. `decode` is a uniform materialization pipeline chosen by depth context. The scheduler orchestrates them and tracks grades.

### 1.2 One Decoder Per Depth Context

The paper allows each morphism to carry its own `dec` (Def 3.1, 7.7). But for 2-cell dominance (Def 15.3), comparing two morphisms requires comparing their decoders — if every encoder brings its own decoder, dominance relationships become intractable. Fixing the decoder per context is an engineering choice that simplifies 2-cell comparison to pure encoder comparison.

The current implementation has two decoding paths (TacticEvaluation and TacticReDerivation) with different fallback-tree behavior, making encoder comparison ill-defined.

**Target state:** The decoder is selected by a `DecoderContext` (depth, bind state, strictness). All encoders sharing a context share the same decoder. This eliminates the TacticEvaluation vs. TacticReDerivation split and makes 2-cell dominance well-defined within each hom-set.

**Hom-set key is (depth, strictness), not just depth.** This is the genuine decomposition, not a technicality. Deletion and value minimization have fundamentally different structural contracts: deletion shortens the sequence (the decoder must tolerate structural invalidity), while value minimization preserves length (the decoder expects the same structure, different values). Comparing "is DeleteContainerSpans better than ZeroValue?" through a single decoder is undefined — the candidates have different structural properties.

Concretely: structural deletion uses `.relaxed` / `.guided` (rebuilds tree from scratch), while value minimization at depth > 0 uses `.normal` / `.direct` (replays against the fixed tree). These are different hom-sets at the same depth. Cross-stage redistribution (depth -1) uses `.crossStage`, which routes per-candidate based on whether inner values changed — a third hom-set with its own decoder. The paper's uniformity requirement applies *within* each hom-set, not across them.

**The 2-cell dominance lattice has separate components per hom-set.** Within the deletion hom-set, all deletion encoders share `.guided(fallbackTree:, strictness: .relaxed)` and dominance is well-defined (e.g., `DeleteContainerSpans` ⇒ `SpeculativeDelete`). Within the value minimization hom-set, all value encoders share their decoder and dominance is well-defined (e.g., `ZeroValue` ⇒ `BinarySearchToZero`). Cross-hom-set dominance is not defined — the leg ordering (contravariant → deletion → covariant) replaces it.

### 1.3 Grade Composition

Each morphism carries a grade `g = (γ, w)` where `γ` is the approximation class and `w ∈ ℕ` is the resource bound (materializations).

**The paper's grade monoid vs. our implementation.** The paper uses quantitative approximation `(α, β) ∈ Aff_≥0` with monoidal composition `(α, β) ⊗ (α', β') = (αα', β + αβ')`. This requires concrete α, β values. In practice, the additive slack β (how much re-derivation regresses the candidate) is not concretely computable before the decode call — it depends on which tier resolves each position, which depends on whether bound ranges shifted, which depends on the specific candidate. The shortlex guard (`reDerivedSequence.shortLexPrecedes(original)`) is the actual runtime mechanism that bounds regression — a binary accept/reject filter, not a continuous value.

We therefore use a qualitative `ApproximationClass` enum (`exact`, `bounded`, `speculative`) with composition as lattice join (`max`). This captures the distinctions the scheduler actually needs — phase ordering, the V-cycle structure, and the constraint that speculative encoders run last — without pretending that approximation is quantified.

**Two levels of composition:**

1. **Encoder + decoder → morphism grade.** Each encoder declares a grade (approximation class + max candidates). Each decoder declares an approximation class. The morphism grade is `encoder.grade.composed(withDecoder: decoder.approximation)`. For phases 1–3, the encoder approximation is `.exact`, so the morphism class equals the decoder's. Phase 4 (redistribution) encoders declare `.bounded` — the morphism class is `.bounded` regardless of the decoder. Phase 5's `RelaxRoundEncoder` would be `.speculative`, which composes with any decoder class to produce `.speculative`.

2. **Morphism + morphism → pipeline grade.** Sequential morphisms compose via the same lattice join. The scheduler tracks the aggregate pipeline class across a cycle.

This means:
- **Exact morphisms** (`.exact`, w) — encoder exact, decoder `.direct`. Contravariant sweep value minimization/reordering.
- **Bounded morphisms** (`.bounded`, w) — shortlex-guarded. Two sources: (1) encoder `.exact` + decoder `.guided` — all deletion morphisms, all depth-0 bind morphisms; (2) encoder `.bounded` — redistribution (Phase 4), where the encoder itself introduces approximation.
- **Speculative morphisms** (`.speculative`, w) — Phase 5. May temporarily regress.
- Resource budgets decompose additively: `w₁ + w₂`.
- The scheduler verifies the pipeline class is acceptable before running a phase.

**Phase reordering.** Since approximation composition is lattice join (commutative, idempotent), all non-speculative phases can be freely reordered without affecting the composed class. **Phase 5 (`.speculative`) must run last** — not because of non-commutativity (the join is commutative), but because speculative morphisms require a different acceptance criterion (pipeline result must improve even if intermediate states regress). Mixing speculative and non-speculative morphisms in the same leg would require the speculative acceptance criterion everywhere, weakening the guarantees for the non-speculative phases.

### 1.4 Three Categories of Reduction Pass

The paper defines covariant and contravariant functors on the reduction category (paper §4): Cand is covariant (maps enc forward), Sol is contravariant (maps dec backward). We borrow this terminology for a related but distinct operational classification: "covariant" passes propagate changes *forward* through the Kleisli chain (inner → bound via re-derivation), "contravariant" passes reduce values *against* fixed ranges without forward propagation. This is an analogy to the paper's functorial direction, not a formal instantiation — the paper's covariant/contravariant is about functors on OptRed, while ours is about information flow in the bind chain. In practice, reducer passes fall into three operationally distinct categories, each with its own decoder, approximation class, and lattice implications. The V-cycle (Section 1.5) gives each category its own leg.

**Contravariant passes** (against the chain: depth max → depth 1):
- **Value minimization and reordering only.** Reduce bound values *within fixed ranges* — moving backward through the bind chain without disturbing the inner generators that determined those ranges.
- **Structure-preserving**: span boundaries, container groupings, sibling relationships are unchanged. The dominance lattice computed at sweep start remains valid throughout.
- **Exact**: no re-derivation needed. Grade: `(.exact, w)`. The `dec` is `Interpreters.materialize()` with a fixed tree.
- **Can get stuck**: limited to the current feasible region. If the property failure requires a specific structural shape, contravariant passes can only minimize values within that shape, never escape it.
- In the paper's terms: these operate on the `Cand^op` functor (paper §4.2) — decoding maps candidates backward.

**Deletion passes** (all depths, 0 → max):
- **Pragmatic addition beyond the paper's framework.** The paper models reductions over fixed-structure candidate spaces — candidates are fixed-dimensional vectors whose values are optimized within a fixed topology. Deletion is orthogonal: it changes the candidate's *structure* (length), not just its values. This operation arises because Exhaust optimizes under a shortlex order where length is the primary axis, unlike the fixed-structure optimization problems the paper addresses. Deletion has no analogue in the paper's covariant/contravariant functor framework — it operates on the sequence's shape, not on information flow through the bind chain.
- **Structure-destroying at every depth.** Deletion removes spans, invalidating the tree's positional mapping. Even at depth > 0, the tree must be rebuilt — `TacticEvaluation.evaluate()` routes all `.relaxed` strictness through `GuidedMaterializer` regardless of depth.
- **All depths, not just depth 0.** Deletion at depth 2 removes bound spans; deletion at depth 0 can eliminate entire bind regions. Both require the same decoder (`.guided`).
- **Bounded**: re-derivation produces new content for the gap left by deletion. The shortlex guard rejects regressions. Grade: `(.bounded, w)`.
- **Lattice-invalidating**: span positions shift after deletion, so the dominance lattice must be rebuilt after each success. This is why deletion cannot share a leg with the contravariant sweep (which depends on lattice stability).
- Categorically distinct from both contravariant (not structure-preserving, not exact) and covariant (not depth-0-specific, not about shifting bound ranges via inner-value changes). Deletion shares the covariant property of using GuidedMaterializer, but its operational characteristics — all-depth scope, shortening purpose, per-success lattice rebuild — justify a separate leg.

**Covariant passes** (with the chain: depth 0):
- **Value minimization and reordering at the inner level.** Reduce inner values, causing bound content to be *re-derived forward* through the Kleisli chain via GuidedMaterializer (prolongation).
- **Bounded**: re-derivation is nondeterministic, but the shortlex guard rejects regressions. Grade: `(.bounded, w)`. Can explore entirely new regions of the candidate space.
- **Can escape local minima**: by changing inner values (depth 0), the covariant sweep changes the bound ranges themselves — opening new territory for the next contravariant sweep. Re-derivation via PRNG/fallback may find shorter bound content than the current state.
- In the paper's terms: these operate on the `Cand` functor (paper §4.1) — encoding maps candidates forward.

### 1.5 The Multigrid V-Cycle

The optimal cycle structure interleaves the three pass categories. The structure is analogous to multigrid V-cycles (paper §14.4), though the mapping is loose: the paper's §14.4 treats literal discretization levels of a continuous problem, while Exhaust's "levels" are bind depths in a Kleisli chain. The shared pattern is "smooth fine levels → correct coarse level → re-smooth":

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
  Deletion sweep (depth 0 → max):
    Structure-destroying at ALL depths. GuidedMaterializer.
    Lattice rebuilt after each success. Separate from contravariant
    because deletion invalidates span structure even at depth > 0.
    Direction 0→max: depth-0 deletions can eliminate entire bind
    regions. The Gauss-Seidel argument does not apply — GuidedMaterializer
    re-derives from scratch regardless of depth.
         │
         ▼
  Covariant sweep (depth 0):
    Value minimization + reordering at the inner level.
    With binds: bounded (.bounded), lattice-invalidating. Changes bound
    ranges via inner value reduction. Fallback tree (containing
    pre-covariant improvements) minimizes re-derivation regression.
    Without binds: exact (.exact) — no re-derivation, no bound ranges.
         │
         ▼
  Post-processing (natural transformation):
    Shortlex merge to recover contravariant improvements that
    re-derivation degraded. Inspired by the paper §5.3
    endotransformation concept (representation-invariant
    post-processing), though the merge is technically a binary
    operation on (pre-covariant, post-covariant) states rather
    than a unary Cand → Cand natural transformation.
    NOT a budget leg — fixed per-cycle overhead (at most one
    materialization), gated by cheap pre-checks.
         │
         ▼
  Redistribution (if contravariant + deletion stalled, or deferral cap):
    Cross-stage mass transfer between coordinates.
    Bounded (.bounded). Operates at depth -1 on whole sequence.
    Addresses joint-configuration stalls orthogonal to inner-value progress.
         │
         ▼
  (repeat — dirty depths only, see Section 4.2)
```

**Why this ordering minimizes re-derivation regression:**
- Contravariant reductions at depth > 0 are `.exact` — no regression possible.
- The subsequent deletion and covariant reductions are both `.bounded` — the shortlex guard rejects regressions, but re-derivation can still produce suboptimal values at bound positions. The quality of those values depends on the tiered resolution inputs:
  1. **Prefix mechanism (tier 1).** The candidate sequence carries contravariant-improved bound values directly. When a covariant encoder mutates inner values, bound positions retain their old (optimized) values in the prefix. If the bound ranges haven't shifted, GuidedMaterializer uses these directly — no regression.
  2. **Fallback tree mechanism (tier 2).** For bound values that *are* out of range after an inner value change, GuidedMaterializer clamps to the fallback tree's value. When the fallback tree contains contravariant-improved values, clamping lands near the optimum rather than at a random point.
- If covariant ran first (top-down), *both* mechanisms have worse inputs: the prefix contains unoptimized bound values, and the fallback tree does too. Re-derivation regresses more, and more candidates fail the shortlex guard (wasting materializations).

This is Gauss-Seidel ordering applied to block coordinate descent with one-directional dependencies (inner → bound): process unconstrained blocks (contravariant, bound depths) before constraining blocks (covariant, inner depth).

**The cat-stroking algorithm.** Smooth the fur, then ruffle. The contravariant sweep is the stroking — getting all bound values into their smoothest state. The deletion sweep then ruffles some of the groomed fur: values after a deletion site are structurally misaligned and may fall to tier 2 or tier 3 (see Section 4.3). The covariant sweep ruffles further — changing inner values, disrupting bound ranges. But because the fallback tree and prefix still carry surviving contravariant improvements, re-derivation clamps back toward them. The re-derivation regression is how much fur sticks up after both ruffles.

**The real claim is "contravariant before deletion before covariant," not "contravariant directly feeds covariant."** Deletion inserts noise between the two value-reduction sweeps. The Gauss-Seidel argument survives in weakened form:
- **Values before a deletion site** are fully preserved in the prefix (tier 1) — no degradation.
- **Values after a deletion site** may degrade, but the fallback tree (containing contravariant-optimized values) provides tier-2 clamping at structurally aligned positions. Without the contravariant sweep, the fallback tree would contain unoptimized values — strictly worse.
- **The net: contravariant-first is still better than any other ordering**, but the benefit is attenuated by deletion. The more deletions succeed (and the more content follows each deletion site), the more contravariant work is lost. The merge (post-processing step) exists precisely to recover what deletion and covariant re-derivation degraded.

If you ruffle first (top-down without pre-stroking), the fur goes everywhere — bound values are re-derived from PRNG before they've been optimized, and re-derivation regression is maximal. Pre-stroking reduces the regression even though deletion partially undoes it.

> *Basin hopping.* The V-cycle is structurally equivalent to monotonic basin hopping: the contravariant sweep finds the basin bottom (local minimum within fixed bound ranges), the covariant sweep hops to a new basin (changes inner values, shifting the landscape), and the shortlex guard is a strict acceptance criterion (only downhill). Redistribution is the perturbation-strength increase when monotonic hopping stalls.

> *Exploitation–exploration.* The contravariant sweep is pure exploitation (extract all value from the current landscape). The covariant sweep is exploration (change the landscape at the cost of re-derivation regression). Redistribution is reshaping — neither exploiting nor exploring, but trying a different joint configuration within the current landscape. The V-cycle is a structured exploitation–exploration schedule: exploit fully, explore once, exploit the new landscape.

> *MCTS/UCB.* The scheduler navigates a tree of possible reduction sequences. The contravariant sweep is deepening a promising subtree (exploitation within known structure). The covariant sweep is backing up to the root and trying a different branch (exploration via landscape change). The 2-cell dominance lattice is static UCB pruning — provably dominated encoders are never visited. Within equivalence classes (where dominance gives no ordering), adaptive encoder selection via Thompson Sampling serves as the UCB exploration term (see Section 4.7).

**Lattice stability implication:** During the contravariant sweep, the dominance lattice is computed once and remains valid — no span deletion or structural change occurs. The 2-cell pruning from paper §15 can safely skip dominated encoders throughout the entire sweep. During the deletion and covariant sweeps, the lattice is invalidated after each success (spans may have changed) and rebuilt before the next encoder is tried. This means lattice pruning is most valuable during the contravariant phase, where it avoids redundant materializations across many depths.

### 1.6 Local Minima and Termination

The three-category distinction gives a precise characterization of local minima:

**A local minimum is a contravariant fixed point** — a state where `.direct` rejects every candidate from every encoder at every bound depth. All exact, structure-preserving passes have stalled. The bound values are individually minimal within their current ranges, but those ranges are determined by the inner values at depth 0.

**Deletion and covariant passes escape the contravariant fixed point.** Deletion removes structure at any depth, potentially unlocking new value-minimization opportunities in the next cycle. The covariant sweep changes inner values (depth 0), shifting the bound ranges themselves — opening new territory for the next contravariant sweep. Re-derivation via `.guided` produces new bound content that may be shorter than the contravariant fixed point.

**If the covariant sweep also stalls, the pipeline has reached a deletion + covariant fixed point** — escape via redistribution. If redistribution also stalls, the pipeline has reached a global fixed point. This gives a clean termination criterion: the reducer is done when one full V-cycle produces zero accepted candidates across all legs (including redistribution and post-processing merge). No stall counters, no heuristic patience — just "did any morphism fire?"

**Redistribution as a second-order escape.** Phase 4 (redistribution) addresses a different kind of stall: cases where inner values are already minimal and the covariant sweep can't improve them, but bound values are "stuck" because they're individually minimal even though their *joint* configuration isn't. Redistribution transfers mass between coordinates — it's `.bounded` (shortlex-guarded), but it can create new attack surfaces for the next contravariant sweep. In terms of the fixed-point hierarchy:

1. **Contravariant fixed point** → escape via deletion + covariant sweep (change structure, change inner values, re-derive bounds). Branch tactics run unconditionally at the start of every cycle (Section 4.6), so they don't appear as a separate prerequisite — they're always tried before the hierarchy is evaluated.
2. **Contravariant + deletion fixed point** → escape via redistribution (transfer mass between coordinates). The covariant sweep may still be making progress — redistribution addresses an orthogonal stall mode (bound-value joint configurations vs. inner-value minima). The deferral cap (Section 3, Phase 4) ensures redistribution fires even when marginal contravariant/deletion progress would suppress the primary trigger.
3. **All fixed point** → global fixed point, reducer terminates. All legs including redistribution and merge produced zero acceptances.

**Branch tactics are part of the first level**, not a separate escape mechanism. They run at the start of every cycle (Section 4.6), so a redistribution success that enables a branch change is caught on the next cycle's branch pass. Branch tactics don't need their own tier in the hierarchy because they're tried unconditionally — the hierarchy describes *conditional* escalation (what runs when the previous level stalls), not the full per-cycle execution order.

**Cycling between levels is possible and expected.** Redistribution can unlock contravariant progress (transferred mass creates new minimization opportunities), which can enable covariant progress (inner values freed by the new contravariant state), which can enable further redistribution. This is a feature, not a bug — each round of the cycle explores new territory that was previously unreachable.

**Termination guarantee (theoretical).** Every accepted candidate is strictly shortlex-smaller than its predecessor. The shortlex order on choice sequences (finite length, bounded entries) is a well-order: any strictly decreasing chain is finite. The cycle above must terminate because each round strictly decreases the sequence. No stall counter or heuristic patience is needed for *correctness* — the reducer converges unconditionally.

**Termination guarantee (practical).** The theoretical bound is the cardinality of the shortlex-below set, which is exponential in (sequence length × entry range). This is finite but astronomically large. The practical backstop is the **total materialization budget** — a hard cap on the number of property evaluations across all cycles, all legs. When the budget is exhausted, the reducer returns the best result found so far. The per-leg budget allocation (Section 4.5) shapes how the budget is spent, but the total is the termination guarantee that matters in practice. The `cycleTerminated` check (zero acceptances across all legs) is the *fast* termination path; the budget cap is the *safe* termination path.

**Degenerate case: no binds.** When `maxBindDepth == 0` (no bind generators), the V-cycle collapses. The contravariant sweep has no depths to visit (zero iterations). The three-category distinction collapses — there are no bound ranges to shift, no Kleisli chain, no re-derivation for value minimization. The deletion sweep runs at depth 0 only (using `.guided` because deletion invalidates the tree, not because of binds). The covariant sweep also runs at depth 0 with `.direct` (no bind re-derivation needed). The post-processing merge is skipped entirely (pre-check 0: `bindIndex` is nil → no bound values to recover). Redistribution uses `.direct` (depth -1, no binds → no cross-stage routing needed). The result is a flat sweep: delete → minimize → reorder → redistribute → done. This is the Hypothesis/QuickCheck regime. The scheduler doesn't need to detect this explicitly — empty legs cost zero iterations, and the merge's pre-check 0 handles the no-bind case before any region logic is reached. The V-cycle's structural power comes entirely from the bind/Kleisli depth structure; without it, the scheduler is running phases in order at a single depth.

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
    /// `.direct` with structure-preserving mutations.
    case exact = 0

    /// Re-derivation may shift the result away from the candidate, but
    /// the shortlex guard rejects any regression. The runtime bound is
    /// binary (accept/reject), not quantitative.
    /// `.guided` for deletion and depth-0 bind mutations.
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

    /// Monoidal identity for grade composition — not a concrete resource
    /// declaration. The zero means "adds nothing" under the additive
    /// resource monoid, so `g.composed(with: .exact) == g`.
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

### 2.3 ReductionDepth

```swift
/// The bind depth a reduction pass targets.
///
/// Replaces the magic `depth: Int` convention where -1 means "global."
/// Exhaustive switching eliminates silent mishandling of depth categories.
enum ReductionDepth {
    /// Branch and cross-stage tactics — not filtered by bind depth.
    case global
    /// A specific bind depth: 0 = inner values, 1...max = bound depths.
    case specific(Int)
}
```

The three-way dispatch currently spread across `TacticReDerivation` and the scheduler (`depth == -1` / `depth == 0` / `depth > 0`) becomes exhaustive pattern matching. The compiler enforces that every new depth category is handled at every switch site.

### 2.4 Encoder Protocols

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
    ) -> any Sequence<ChoiceSequence>
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

**Swift implementation notes for `BatchEncoder`.** The `any Sequence` return type supports two lazy implementation approaches: `sequence(state:next:)` (returns `UnfoldSequence`) for encoders with simple iteration state (e.g., deletion walking a span list), and a custom `Sequence`/`IteratorProtocol` conformance for encoders with richer traversal state (e.g., beam search over sibling subsets). Both are pull-driven — the scheduler consumes only as many candidates as it evaluates.

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
    //
    // Adaptive probes bypass the reject cache. The `lastAccepted`
    // feedback drives the encoder's decision tree (e.g. binary
    // search narrows [lo, hi] based on acceptance/rejection). A
    // cache hit would feed `false` for a candidate that was never
    // evaluated in this context, potentially mis-directing the
    // search. Adaptive encoders have bounded probe counts
    // (O(log V) for binary search), so the cost of occasional
    // duplicate materializations is negligible.
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
- `rejectCache` — the scheduler wraps **batch** encoder output in a cache-filtering layer, checking at evaluation time with the most up-to-date cache. Adaptive encoder probes bypass the cache entirely (see scheduler dispatch above). Encoders are fully pure; cache filtering happens in exactly one place (the scheduler). The overhead of generating candidates that hit the cache is negligible — encoding is O(n) per candidate while decoding is dominated by materialization (running the generator on the candidate), which is much more expensive. Property evaluation itself is cheap by comparison; the cache's value is in avoiding wasted materializations for batch encoders.

### 2.5 Decoder

```swift
/// Materializes a candidate sequence and checks feasibility.
///
/// Selected by depth context, shared by all encoders at that depth.
/// This is the `dec` map from the paper.
///
/// Implemented as a concrete enum rather than a protocol. There are exactly
/// three decoder implementations (Direct, Guided, CrossStage) with no plan
/// to add more. A protocol existential would heap-allocate on every
/// `SequenceDecoder.for(_:)` call — the decoder types carry associated data
/// (fallback tree, bind index, strictness) that exceeds Swift's 3-word
/// inline existential buffer. As an enum with associated values, the decoder
/// stays on the stack and avoids ARC traffic in the scheduler's inner loops.
enum SequenceDecoder {
    /// Tree-driven materialization. Exact — preserves the candidate exactly.
    case direct(strictness: Interpreters.Strictness)

    /// GuidedMaterializer with tiered resolution. Bounded — re-derivation
    /// can shift bound values, but the shortlex guard rejects regressions.
    case guided(fallbackTree: ChoiceTree?, strictness: Interpreters.Strictness)

    /// Per-candidate routing for cross-stage tactics (depth -1, binds present).
    /// Routes to direct if only bound values changed, guided if inner values changed.
    case crossStage(bindIndex: BindSpanIndex, fallbackTree: ChoiceTree?, strictness: Interpreters.Strictness)

    var approximation: ApproximationClass {
        switch self {
        case .direct: .exact
        case .guided, .crossStage: .bounded
        }
    }

    func decode<Output>(
        candidate: ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool,
    ) throws -> ShrinkResult<Output>? {
        // Each case delegates to the corresponding materialization pipeline.
        // Implementation elided — each case delegates to the
        // corresponding materialization pipeline in the current code
        // for the decode logic that each case wraps.
    }
}
```

### 2.6 DecoderContext and Selection

```swift
/// Determines which decoder to use based on depth and bind state.
struct DecoderContext {
    let bindIndex: BindSpanIndex?
    let depth: ReductionDepth
    let fallbackTree: ChoiceTree?
    let strictness: Interpreters.Strictness
}

extension SequenceDecoder {
    /// Returns the appropriate decoder for a given context.
    ///
    /// One decoder per context = all encoders sharing a context share the
    /// same `dec`, forming a uniform hom-set (paper §7).
    ///
    /// Three independent reasons trigger non-Direct decoders:
    /// 1. **Bind re-derivation** (`.specific(0)`, binds present): bound
    ///    content must be re-derived after inner value changes.
    /// 2. **Structural invalidity** (`.relaxed` strictness): deletion at any
    ///    depth invalidates the tree's positional mapping — even without binds,
    ///    the tree must be rebuilt from the generator.
    /// 3. **Cross-stage routing** (`.global`, binds present): redistribution
    ///    may or may not change inner values — routing is per-candidate.
    static func `for`(_ context: DecoderContext) -> SequenceDecoder {
        switch context.depth {
        case .global:
            // Cross-stage: per-candidate routing based on whether inner
            // values changed. Only relevant with binds; without binds,
            // DirectMaterializer is sufficient.
            if let bindIndex = context.bindIndex, bindIndex.isEmpty == false {
                return .crossStage(
                    bindIndex: bindIndex,
                    fallbackTree: context.fallbackTree,
                    strictness: context.strictness
                )
            }
            return .direct(strictness: context.strictness)

        case .specific(0):
            let needsBindReDerivation = context.bindIndex != nil
                && context.bindIndex?.isEmpty == false
            if needsBindReDerivation || context.strictness == .relaxed {
                return .guided(
                    fallbackTree: context.fallbackTree,
                    strictness: context.strictness
                )
            }
            return .direct(strictness: context.strictness)

        case .specific:
            if context.strictness == .relaxed {
                return .guided(
                    fallbackTree: context.fallbackTree,
                    strictness: context.strictness
                )
            }
            return .direct(strictness: context.strictness)
        }
    }
}
```

Three cases:

- **`.direct`**: Wraps `Interpreters.materialize()`. Replays the full generator at materialization time — the tree provides navigation structure (which branch to take, which pick to select), while ranges are computed dynamically from the current sequence values. Used for structure-preserving mutations at depth > 0 (contravariant sweep). Deterministic. `approximation = .exact`.

- **`.guided`**: Wraps `GuidedMaterializer.materialize()`. Sequence-driven with tiered value resolution. Used whenever the tree must be rebuilt: deletion at any depth (even without binds — the tree's positional mapping is invalidated), and value minimization/reordering at depth 0 with binds (bound content must be re-derived). Nondeterministic. `approximation = .bounded`. The shortlex guard (`reDerivedSequence.shortLexPrecedes(originalSequence)`) is the runtime enforcement — it rejects any re-derivation that regresses past the original.

- **`.crossStage`**: Per-candidate routing for cross-stage tactics (redistribution, tandem). These operate at depth -1 on the whole sequence and may or may not modify inner values — the re-derivation need is a property of the *specific candidate*, not the decoder context. On each `decode` call, the decoder compares the candidate against the original sequence at inner positions (via `BindSpanIndex.regions[*].innerRange`). If only bound values changed: `.direct` path — the strategy's carefully redistributed values are authoritative, and re-derivation would replace them with PRNG noise. If inner values changed: `.guided` path — bound ranges have shifted, re-derivation is needed. `approximation = .bounded` (conservative — some candidates take the exact path, but the decoder can't promise this statically).

  **BindIndex staleness after redistribution.** The `.crossStage` case routes using `BindSpanIndex.regions[*].innerRange` to classify positions as inner vs bound. After redistribution changes values, could the `innerRange` indices be stale? No — the inner/bound classification is a *structural* property of the generator's bind sites, not a property of the values at those positions. The k-th bind in the generator always produces inner values at the same sequence positions (determined by the generator's evaluation order) and bound values at subsequent positions. Redistribution changes the *values* at those positions but not the positions themselves (it doesn't insert or delete). The `bindIndex` correctly classifies which positions the encoder intended to modify — the routing's purpose is to detect whether the encoder touched inner positions, not whether ranges are still valid. Range validation is the decoder's job (GuidedMaterializer handles it during materialization).

  **Mixed mutations (inner + bound changes in one candidate).** When a redistribution encoder modifies both inner and bound values, the inner-value-changed path triggers GuidedMaterializer re-derivation, which re-derives *all* bound content — overwriting the encoder's carefully chosen bound values. This is an accepted tradeoff: inner value changes potentially invalidate bound ranges, making the old bound values illegal regardless of how carefully they were chosen. The fallback tree's tier-2 clamping mitigates the damage — re-derived values clamp toward the pre-redistribution state where the new ranges permit. Constraining redistribution encoders to never modify both inner and bound values would eliminate the primary use case: the most valuable redistribution moves transfer mass *between* an inner value and a bound value (or vice versa), which inherently modifies both.

  **Tiered value resolution** (this is the mechanism that makes the Section 1.5 ordering argument work):

  1. **Tier 1 — candidate prefix.** GuidedMaterializer replays the generator using the candidate sequence as a prefix. At each choice point, the candidate's value is used if it falls within the current valid range. For bound positions that the encoder didn't modify, the candidate still carries the old (potentially contravariant-optimized) values. If the bound ranges haven't shifted, these are used directly — no approximation.

  2. **Tier 2 — fallback tree.** When a prefix value is out of the current valid range (e.g., an inner value change shifted the bound range), or when the prefix is exhausted (deletion shortened it), GuidedMaterializer clamps to the fallback tree's value for that position. The fallback tree is the tree from the last accepted state — if the contravariant sweep already optimized bound values, clamping lands near the optimum.

  3. **Tier 3 — PRNG.** When neither the prefix nor the fallback tree has a value (new positions created by re-derivation), a seeded PRNG provides the value. The seed is derived from the candidate's zobrist hash for determinism.

  **Why contravariant-first minimizes re-derivation regression:** After the contravariant sweep, the candidate prefix (tier 1) carries optimized bound values, and the fallback tree (tier 2) contains the same optimized values. Both tiers feed `.guided` with good starting points. If the covariant sweep ran first, both tiers would contain unoptimized values — tier-2 clamping would land at arbitrary points, and tier-3 PRNG would be reached more often. Better tier-1 and tier-2 inputs → smaller regression → fewer candidates rejected by the shortlex guard → fewer wasted materializations.

### 2.7 ReductionPhase

```swift
/// The categorical type of a reduction phase.
///
/// Phases are ordered by guarantee strength. Within each phase,
/// encoders are ordered by the 2-cell preorder.
/// Raw values match the prose numbering (Phase 1 = structuralDeletion, etc.)
/// to avoid off-by-one confusion during implementation.
enum ReductionPhase: Int, Comparable {
    case structuralDeletion = 1     // Encoder .exact; morphism .bounded via decoder
    case valueMinimization = 2      // Encoder .exact; morphism .exact or .bounded via decoder
    case reordering = 3             // Encoder .exact; morphism .exact or .bounded via decoder
    case redistribution = 4         // Encoder .bounded
    case exploration = 5            // Encoder .speculative
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
5. `DeleteAlignedWindowsTactic` — beam-search over sibling subsets (legacy tactic, not yet extracted to `AdaptiveEncoder`)
6. `SpeculativeDeleteEncoder` — delete + flag for GuidedMaterializer repair

**Note:** Deletion encoders 1–4 and 6 conform to `AdaptiveEncoder` (adaptive batch sizing), not `BatchEncoder`. Each deletion pass uses feedback-driven probing: after a successful deletion, the encoder can skip past the deleted region. `DeleteAlignedWindowsTactic` remains as a legacy `ShrinkTactic`, invoked directly by the scheduler.

**2-cell relationships:**
- 1 ⇒ 6 (container deletion is strictly more aggressive than speculative single-span deletion)
- 2 ⇒ 4 within elements (element deletion removes enclosed values), but 4 targets values *outside* elements — not a strict dominance
- All others: no formal 2-cell. Run all, don't prune.

**Strictness:** All deletion uses `.relaxed` uniformly. Any deletion — whether removing a whole container subtree or a single free-standing value — invalidates the tree's positional mapping. `.guided` rebuilds the tree from the generator using the shortened candidate as a prefix. Strictness is a decoder concern determined by the sweep leg (Section 4.3), not an encoder property.

**Encoder grade:** `(.exact, n)` where n = target count. All deletion encoders are `.exact` — they produce structurally valid shorter candidates with no approximation. The *morphism* grade depends on the decoder: `(.exact, n)` with `.direct`, `(.bounded, n)` with `.guided`. In the deletion sweep (Section 4.3), the decoder is always `.guided`, so the morphism is `.bounded` despite the encoder being `.exact`. The approximation class comes entirely from the decoder, not from the structural mutation itself.

### Phase 2: Value Minimization (Encoder-Exact)

**Goal:** Minimize each entry at its position (lexicographic improvement, fixed length).

**Encoders:**
1. `ZeroValueEncoder` — set each value to 0. Grade: `(.exact, n)`.
2. `BinarySearchToZeroEncoder` — binary search each value toward 0. Grade: `(.exact, n·log V)`.
3. `BinarySearchToTargetEncoder` — binary search toward a target from another depth. Grade: `(.exact, n·log V)`.
4. `ReduceFloatTactic` — multi-stage float pipeline (legacy tactic, not yet extracted to encoder protocol). Grade: `(.exact, n·stages·log V)`.

**2-cell chain:** 1 ⇒ 2 ⇒ 3. Zero is the best binary-search-to-zero can achieve. Binary-search-to-zero finds values ≤ any nonzero target.

**Note:** Binary search and float reduction conform to `AdaptiveEncoder` (see Section 2.3). Each probe depends on the outcome of the previous one — binary search maintains `[lo, hi]` per target and narrows based on acceptance/rejection. The scheduler calls `start()` once, then `nextProbe(lastAccepted:)` in a loop, modeling binary search as iterated Kleisli composition. The encoder never sees the decoded output — only whether each probe was accepted. `ZeroValueEncoder` conforms to `BatchEncoder` — it returns all zero-candidates upfront via `encode()`.

### Phase 3: Reordering (Encoder-Exact)

**Goal:** Sort siblings into ascending order (lexicographic improvement, same multiset).

**Encoder:** `ReorderSiblingsEncoder`. Grade: `(.exact, n)`.

Single encoder, no 2-cell structure needed.

### Phase 4: Redistribution (Approximate)

**Goal:** Transfer numeric mass between coordinates to unlock future improvements.

**Depth:** -1 (cross-stage). Redistribution operates on the **whole sequence**, not filtered by depth. Both encoders can modify values at any depth — inner values, bound values, or both. This is what makes them cross-stage: the interesting cases involve transferring mass between an inner value and a bound value, or between two bound values at different depths.

**Encoders:**
1. `TandemReductionEncoder` — reduce sibling value pairs together (both move toward zero simultaneously). Targets sibling groups across all depths. Grade: `(.bounded, w)`.
2. `CrossStageRedistributeEncoder` — move mass between coordinates (decrease one, increase another to compensate). Specifically targets pairs where reducing one value is blocked because a correlated value would need to increase. Grade: `(.bounded, w)`.

**Decoder:** `.crossStage` via `SequenceDecoder.for(_:)` (depth -1, binds present). Per-candidate routing: if only bound values changed, the strategy's redistributed values are authoritative (no re-derivation — would replace carefully chosen values with PRNG noise). If inner values changed, re-derives via `GuidedMaterializer` with fallback tree clamping. Without binds, `SequenceDecoder.for(_:)` returns `.direct` (no cross-stage concerns).

**Trigger criterion.** The scheduler runs redistribution when the *contravariant and deletion sweeps* made zero progress in the current cycle, **or** when a deferral cap has been reached.

The primary trigger checks `contravariantAccepted == 0 && deletionAccepted == 0`. If the covariant sweep also stalled, redistribution is the only escape before the global fixed point. If the covariant sweep made progress, redistribution still runs — the two address orthogonal stall modes (inner-value minima vs. bound-value joint configurations). The shortlex guard prevents redistribution from introducing regressions regardless.

**Deferral cap: redistribution starvation guard.** A subtle failure mode: marginal covariant progress (reducing one inner value by 1 per cycle) shifts bound ranges slightly, enabling marginal contravariant progress (reducing one bound value by 1). This keeps `contravariantAccepted > 0`, preventing the primary trigger from firing — even though redistribution could unlock a much larger bound-value improvement by transferring mass between coordinates. The covariant and contravariant sweeps are making progress, but they're grinding linearly through a landscape that redistribution could reshape in one step.

Fix: the scheduler tracks `cyclesSinceRedistribution` — incremented each cycle where redistribution was skipped, reset to 0 when redistribution runs. When `cyclesSinceRedistribution >= redistributionDeferralCap` (default: 3), redistribution fires regardless of contravariant/deletion progress. If redistribution finds an improvement, the deferral counter resets and normal triggering resumes. If redistribution finds nothing, the counter resets anyway — the cap is a periodic probe, not a persistent mode change. The cost of a fruitless redistribution probe is bounded by Phase 4's budget allocation (10%), which flows forward to subsequent legs if unspent (Section 4.5).

Why 3 cycles? Binary search halves the search space per cycle, so 3 cycles of binary-search-driven progress represent substantial exploitation. If the progress is slower than binary search (i.e., the sweeps are grinding), 3 cycles detects this before the budget cost becomes significant. The value is not critical — 2–5 all work. Empirical tuning may adjust it.

**Why not run redistribution unconditionally?** Redistribution's `.bounded` approximation class means each application risks tier-2/3 degradation at bound positions (for candidates that modify inner values). Running it when the contravariant sweep is still making progress wastes budget: the contravariant sweep's `.exact` morphisms are strictly cheaper per improvement. Running redistribution after contravariant stalls is the Pareto-efficient trigger — exact morphisms have been exhausted, so the `.bounded` cost is unavoidable.

### Phase 5: Exploration (Approximate, Future)

**Goal:** Break local optima via speculative perturbation.

**Encoder:** `RelaxRoundEncoder` — temporarily increase one value to enable a larger deletion. Grade: `(.speculative, w)`.

**Not implemented initially.** This is infrastructure-in-waiting, justified by the paper's relax-round framework (paper §11.2).

**Can `.speculative` be deferred without redesign?** Yes. The initial implementation needs only `.exact` and `.bounded`. Adding `.speculative` later requires: (1) a new enum case in `ApproximationClass`, (2) a new `ReductionLeg.exploration` case, (3) a new leg in the V-cycle after redistribution, and (4) a modified acceptance criterion for that leg (pipeline result must improve, not just each intermediate step). The grade algebra doesn't change — lattice join over three values instead of two. The V-cycle gains one more leg. No existing code needs modification except adding the new leg to the scheduler loop. The scheduling constraint ("speculative must run last") is enforced by leg ordering, not by special-casing in the grade algebra. The `ApproximationClass` enum is included now with three cases for completeness, but an initial implementation could define only `.exact` and `.bounded` and add `.speculative` when Phase 5 is built.

### Deferred

The following features are designed but not yet implemented:

- **Thompson Sampling** — Adaptive encoder selection within equivalence classes (Section 6). The `ReductionGrade.maxMaterializations` field and `ApproximationClass` enum provide the grade infrastructure. The scheduler currently runs all encoders in fixed order; Thompson Sampling would replace this with posterior-driven selection within each hom-set. Requires: `EncoderPosterior` state, `selectEncoder()` function, per-cycle posterior updates.

- **Dominance lattice** — 2-cell pruning of dominated encoders (paper Def 15.3). The one-decoder-per-context design (Section 1.2) ensures 2-cell comparison is well-defined within each hom-set. `ReductionGrade.maxMaterializations` carries the resource component of the grade needed for dominance comparison. Not yet wired into the scheduler — all encoders run unconditionally.

- **Phase 5 (Exploration)** — Speculative `RelaxRoundEncoder` for escaping local optima. The `.speculative` case exists in `ApproximationClass`. Requires: a new V-cycle leg after redistribution, a pipeline acceptance criterion (overall improvement, not per-step), and the `RelaxRoundEncoder` implementation.

### Post-Processing (Natural Transformation)

After the covariant sweep, before the next cycle. The merge recovers pre-covariant bound values that the covariant sweep's re-derivation degraded. ("Pre-covariant" = post-deletion state, which includes contravariant optimizations minus any degradation from the deletion sweep.)

**Alignment model.** The pre-covariant sequence `S_pre` and post-covariant sequence `S_post` may have different structures — re-derivation from changed inner values can produce different numbers of bind regions, different region sizes, and different absolute indices. Alignment uses **bind region ordinals**, not absolute indices: the k-th `bind` operation in the generator produces the k-th `BindRegion` in both sequences (GuidedMaterializer processes binds in generator order). Within matched regions, bound values align by relative offset within the bound range.

**Ordinal correspondence is not guaranteed.** The generator is a Freer Monad program where continuations can conditionally produce bind operations based on inner values (e.g., `bind { n in if n > 2 { ... } else { nested.bind { ... } } }`). The covariant sweep changes inner values but not branch choices — so if a changed inner value controls bind structure, the k-th bind in S_pre can correspond to a different generator site than the k-th bind in S_post. Two states with matching region counts may still have non-corresponding regions. The pre-checks below detect the common structural mismatches; the fallback (step 3) handles the rest.

Pre-checks gate the merge:

0. **Pre-check 0 — binds present.** If `bindIndex` is nil, skip the merge entirely. The merge exists to recover contravariant-optimized bound values that re-derivation degraded. No binds = no bound values = no re-derivation = nothing to recover. This makes the no-bind degenerate case (Section 1.6) clean: the merge step is a no-op, not a series of vacuously-passing checks.

0. **Pre-check 1 — covariant progress.** If the covariant sweep made no progress, the post-covariant state equals the pre-covariant state. Nothing to merge. O(1) check on a flag the scheduler already tracks.

0. **Pre-check 2 — region structural match.** Two checks:
   - **Region count:** If `preBindIndex.regions.count != postBindIndex.regions.count`, skip merge entirely (obvious structural divergence).
   - **Inner range sizes:** For each (k-th pre, k-th post) region pair, compare the inner range sizes. Each bind site in the generator has a fixed inner operation (e.g., `Gen.int(in: 0...5)` always produces 1 inner value). If inner range sizes differ, the regions can't be from the same generator site — skip that region. This catches the most common case of value-dependent bind structure, where a changed inner value causes a different bind to execute at ordinal k. It won't catch coincidental size matches from different sites, but those are filtered by the GuidedMaterializer fallback (step 3).

0. **Pre-check 3 — bound regression scan on aligned regions.** For each (k-th pre, k-th post) region pair with matching bound range sizes: check whether any post-covariant bound value is *larger* than its pre-covariant counterpart. Regions with mismatched bound range sizes are skipped (keep post-covariant values — can't align). If no aligned region has a regression, the merge can't improve anything. O(n) scan — essentially free compared to a materialization.

0. **Pre-check 4 — range validity filter.** For each aligned bound position where S_pre < S_post (the merge would substitute), check if S_pre falls within the post-covariant tree's range at that position. Three outcomes:
   - **No substitution is in-range** → merge is a guaranteed no-op. GuidedMaterializer would clamp every substitution back to S_post via tier-2 resolution. Skip materialization entirely.
   - **All in-range** → proceed to merge and materialization.
   - **Some in-range, some not** → pre-filter the merge: only substitute at in-range positions. Out-of-range substitutions would be clamped back by GuidedMaterializer anyway, so excluding them upfront produces a tighter candidate that's more likely to materialize successfully.

   **Caveat:** The tree ranges are static (computed during the post-covariant execution with S_post values). Substituting S_pre at position i can dynamically shift the range at position j > i (bound ranges depend on earlier values). So this check is necessary but not sufficient — it catches the common "ranges shifted completely past the old values" case, but GuidedMaterializer still handles dynamic range interactions. O(n) scan using tree range metadata.

If pre-checks 0–4 pass (and pre-check 4 has pre-filtered the merge candidates):

1. **Shortlex merge of bound entries** — start from `S_post` (inner values are authoritative — they're the covariant improvement). For each size-matched region pair, substitute `S_pre[offset]` only at positions that passed the range-validity filter. All other positions keep `S_post` values. This is inspired by paper §5.3 (representation-invariant post-processing), applied only where structural correspondence holds and the substitution is range-valid. Unlike the paper's §5.3 which defines a unary endotransformation h : Cand(P) → Cand(P), the merge is a binary operation on two states — it doesn't satisfy the naturality condition enc_a ∘ h_P = h_Q ∘ enc_a. Its correctness is instead guaranteed by the GuidedMaterializer re-materialization (step 2) and the shortlex acceptance check. The merged sequence is a Frankenstein: bound values cherry-picked from different states, not produced by running the generator.

2. **Tree re-materialization** — the merged sequence has no corresponding tree. Run `GuidedMaterializer` on the merged sequence with the **pre-covariant tree** as fallback (captured before the covariant sweep — see Section 4.1 pseudocode). This is critical: the merge's purpose is to recover pre-covariant bound values. If tier-2 clamping used the post-covariant tree, out-of-range positions would clamp to the values the merge is trying to improve upon. The pre-covariant tree (post-deletion state, including surviving contravariant optimizations) provides better clamping targets. The re-materialized triple may change span boundaries — the next cycle's lattice (computed fresh at cycle start) reflects whatever structure the re-materialization produces.

3. **Fallback on merge failure** — if `GuidedMaterializer` can't materialize the merged sequence (dynamic range interactions between cherry-picked positions make the combination inconsistent), keep the unmerged state. The merge is speculative; failure is expected when substitutions at earlier positions shift ranges at later positions beyond what the static pre-check could predict.

**Safety of the Frankenstein sequence.** The pre-checks can't catch all non-corresponding regions (coincidental inner-range-size matches from different generator sites pass pre-check 2). Could the hybrid accidentally succeed — property fails on a "malformed" output — producing a misleading counterexample? No. GuidedMaterializer doesn't blindly replay the cherry-picked values. It runs the actual generator with the merged sequence as a prefix, producing a fully consistent `(sequence, tree, output)` triple. If a cherry-picked value falls outside the generator's current valid range, GuidedMaterializer clamps it (tier 2) or replaces it (tier 3). The output is always a legitimate generator output — the generator ran, produced a value, and the property was evaluated on that value. If the property fails, that value is a genuine counterexample, not a "malformed" artifact. The merge can produce *surprising* counterexamples (values the user didn't expect from the generator), but never *invalid* ones. The shortlex guard further ensures the merged result is strictly simpler than the pre-merge state.

At most one `GuidedMaterializer` call per cycle, and only when the pre-checks indicate the merge has a realistic chance of recovering lost contravariant improvements. **This materialization is not charged to any leg's budget** — it's a fixed per-cycle overhead (at most one call), gated by cheap O(n) pre-checks that reject the vast majority of cycles. Charging it to a leg would either (a) penalize the covariant sweep for the merge's cost (unfair — the covariant sweep already ran), or (b) require a separate "merge budget" that's always 0 or 1 (overengineered). The cycle's hard cap (Section 4.5) accounts for total materializations including the merge.

---

## 4. The Scheduler

### 4.1 Cycle Structure: The Multigrid V-Cycle

Each cycle has five legs (one pre-cycle) plus post-processing:

```
for each cycle:
    // ── Mutable state ──
    // `sequence`, `tree`, `fallbackTree` are updated after every acceptance.
    // `fallbackTree` tracks the most recent consistent tree for tier-2
    // clamping in GuidedMaterializer (see "Fallback tree lifecycle" below).

    func accept(_ result: ShrinkResult, structureChanged: Bool) {
        sequence = result.sequence
        tree = result.tree
        fallbackTree = result.tree  // always freshest tree
        if structureChanged {
            // Deletion, branch tactics, and covariant re-derivation can
            // change span positions, region count, and depth assignments.
            // Stale bindIndex → wrong target extraction, wrong dirty-depth
            // tracking, wrong merge alignment.
            bindIndex = BindSpanIndex(tree)  // rebuild from new tree
            lattice = buildLattice(sequence) // span positions shifted
        }
    }

    // ── Pre-cycle: Branch tactics ──
    // Promote/pivot. May change tree shape at any depth.
    for branchEncoder in branchEncoders:
        if let result = tryBranch(branchEncoder, sequence, tree):
            accept(result, structureChanged: true)

    // ── Lattice computation ──
    // accept(structureChanged: true) already rebuilds the lattice after
    // each branch success. This explicit call is only needed when NO
    // branch tactic fired (lattice may be stale from the previous cycle).
    // When a branch tactic did fire, this is a no-op rebuild — harmless
    // but redundant. Gating on branchFired would save one O(n) scan in
    // the branch-success case, at the cost of a conditional. Not worth
    // optimizing — buildLattice is cheap relative to materialization.
    let lattice = buildLattice(sequence)
    // Note: 1 ... 0 is a fatal error in Swift. Guard the range.
    var dirtyDepths: Set<Int> = maxBindDepth > 0 ? Set(1 ... maxBindDepth) : []

    // ── Leg 1: Contravariant sweep (fine → coarse) ──
    // Value minimization + reordering ONLY. Structure-preserving, exact.
    // Depth-major: all phases at depth d before moving to d−1.
    var rejectCache = ReducerCache()  // fresh per leg
    // Note: same 1...0 guard as dirtyDepths — skip when maxBindDepth == 0.
    for depth in stride(from: maxBindDepth, through: 1, by: -1) where dirtyDepths.contains(depth):
        // Within-depth fixpoint: value-min and reordering interact.
        // Reordering permutes values to new positions where they may
        // have different local minima; value-min can break ascending
        // order, creating new reordering opportunities. Loop until
        // neither makes progress; the leg budget is the natural cap.
        //
        // DecoderContext is reconstructed per fixpoint iteration —
        // accept() updates fallbackTree, and the next iteration picks
        // up the fresh tree. (DirectMaterializer doesn't use it, but
        // the context stays current for consistency.)
        //
        // Targets are extracted per phase: value-min needs .spans,
        // reordering needs .siblingGroups. Both filter to the same
        // depth but return different TargetSet cases.
        var depthProgress = true
        while depthProgress {
            depthProgress = false
            let valueTargets = extractTargets(sequence, depth, bindIndex)  // .spans
            let siblingTargets = extractSiblingTargets(sequence, depth, bindIndex)  // .siblingGroups
            let context = DecoderContext(.specific(depth), bindIndex, fallbackTree, .normal)
            let decoder = SequenceDecoder.for( context)  // depth > 0, .normal → Direct
            depthProgress = runValueMinimization(lattice, valueTargets, decoder, ...) || depthProgress
            depthProgress = runReordering(lattice, siblingTargets, decoder, ...) || depthProgress
        }

    // ── Leg 2: Deletion sweep (all depths, coarse → fine) ──
    // Structure-destroying at ALL depths. GuidedMaterializer.
    // Direction 0→max: see Section 4.3 for justification.
    rejectCache = ReducerCache()  // fresh: different decoder than Leg 1
    for depth in 0 ... maxBindDepth:
        for encoder in deletionEncoders:
            // Targets, context, and decoder reconstructed per encoder.
            // accept(structureChanged: true) rebuilds bindIndex + lattice,
            // so targets must be re-extracted from the current state.
            let targets = extractDeletionTargets(sequence, depth, bindIndex)
            let context = DecoderContext(.specific(depth), bindIndex, fallbackTree, .relaxed)
            let decoder = SequenceDecoder.for( context)  // .relaxed → Guided
            // ... encode, decode, accept(result, structureChanged: true)

    // ── Leg 3: Covariant sweep (depth 0) ──
    // Value minimization + reordering at the inner level.
    // Speculative (for bind generators), can escape local minima.
    rejectCache = ReducerCache()  // fresh: different decoder than Legs 1–2
    // Snapshots for post-processing merge.
    // The merge aligns pre- and post-covariant bind regions by ordinal,
    // so it needs the pre-covariant sequence, bind index, and tree.
    let preCovariantSequence = sequence
    let preCovariantBindIndex = bindIndex
    let preCovariantTree = tree

    for phase in [.valueMinimization, .reordering]:
        for encoder in encoders(for: phase):
            // Targets, context, and decoder reconstructed per encoder.
            // For bind generators, accept(structureChanged: true) rebuilds
            // bindIndex, so targets must be re-extracted from current state.
            let targets = extractTargets(sequence, 0, bindIndex)
            let context = DecoderContext(.specific(0), bindIndex, fallbackTree, .normal)
            let decoder = SequenceDecoder.for( context)
            // With binds: needsBindReDerivation → .guided (.bounded)
            // Without binds: neither condition → .direct (.exact)
            // ... encode, decode:
            //   bind generators: accept(result, structureChanged: true)
            //     (re-derivation can change bound region structure)
            //   no binds: accept(result, structureChanged: false)
            // On success: mark affected chain's depths dirty
            //   (all depths for single-chain generators)

    // ── Post-processing (natural transformation) ──
    // NOT a leg — no ReductionLeg case, no budget allocation.
    // Shortlex merge to recover contravariant improvements
    // degraded by covariant re-derivation.
    //
    // Uses preCovariantTree as the merge's fallback tree, NOT the
    // continuously-updated fallbackTree. The merge's purpose is to
    // recover pre-covariant bound values. If tier-2 clamping used the
    // post-covariant tree, it would clamp to the exact values the
    // merge is trying to improve upon — defeating the purpose.
    // The pre-covariant tree contains pre-covariant values (post-deletion,
    // including surviving contravariant optimizations), so tier-2 clamping
    // lands near the desired recovery targets.
    if let mergeResult = applyShortlexMerge(sequence, preCovariantTree):
        accept(mergeResult, structureChanged: true)
        // Mark depths dirty: the merge substituted bound values that
        // may not be locally minimal within their (post-covariant) ranges.
        // The next contravariant sweep should re-optimize them.
        dirtyDepths.formUnion(mergeAffectedDepths)
        //
        // A successful merge counts as cycle progress. This can create
        // a ping-pong pattern: covariant degrades bound values → merge
        // recovers them → covariant degrades again → merge recovers.
        // Convergence is guaranteed by the shortlex well-order: every
        // accepted candidate (covariant or merge) is strictly shortlex-
        // smaller than its predecessor, and the shortlex order on finite
        // bounded sequences is a well-order — any strictly decreasing
        // chain is finite. The recovery amount per merge need not be
        // strictly decreasing each round (e.g., if the covariant sweep
        // reduces an inner value by 1 and bound ranges shift
        // proportionally, the merge may recover the same amount). But
        // the sequence itself is strictly smaller after each merge, so
        // the chain terminates unconditionally.
        //
        // Convergence rate: the ping-pong cost is bounded by the
        // covariant sweep's convergence rate, not by the inner value
        // range. BinarySearchToZeroEncoder converges in O(log V) cycles
        // (each cycle halves the search space). ZeroValueEncoder
        // converges in O(1). The pathological O(V) case requires a
        // strategy that reduces by 1 per cycle — which only happens
        // when the property failure depends on the inner value being
        // within a narrow band of its current level, defeating binary
        // search. In that scenario, each ping-pong cycle costs one
        // covariant materialization + one merge materialization = 2
        // evaluations. For V = 2^32 and linear-only progress, that's
        // ~8.6 billion evaluations — well beyond any practical budget.
        // The global materialization budget is the practical backstop.
        // Empirically, covariant sweeps almost always use binary search,
        // so ping-pong is O(log V) cycles in practice.
        //
        // Note: a successful merge does NOT reset
        // cyclesSinceRedistribution. The deferral counter is reset
        // only when redistribution actually fires. This is intentional:
        // in the ping-pong scenario where the covariant sweep makes
        // marginal progress and the merge recovers it, the merge
        // produces cycle progress but doesn't address the joint-
        // configuration stall that redistribution targets. The deferral
        // cap fires correctly after 3 such ping-pong cycles.

    // ── Cross-cutting: redistribution ──
    // Primary trigger: contravariant + deletion stalled (zero acceptances).
    // Deferral cap: even if contravariant/deletion made progress, fire
    // redistribution after `redistributionDeferralCap` consecutive cycles
    // of deferral (default 3). Prevents marginal covariant/contravariant
    // progress from starving redistribution indefinitely.
    let redistributionTriggered =
        (contravariantAccepted == 0 && deletionAccepted == 0)
        || cyclesSinceRedistribution >= redistributionDeferralCap
    if redistributionTriggered:
        cyclesSinceRedistribution = 0
        // Depth -1 (cross-stage): operates on whole sequence.
        // With binds: .crossStage (per-candidate inner-value check)
        // Without binds: .direct
        let context = DecoderContext(.global, bindIndex, fallbackTree, .normal)
        let decoder = SequenceDecoder.for( context)
        for encoder in redistributionEncoders:
            // ... encode, decode
            // structureChanged: true if inner values changed
            //   (.crossStage tracks this internally)
    else:
        cyclesSinceRedistribution += 1

    // Dirty-depth tracking for next cycle (see Section 4.2)
    // Stall logic, termination
```

**Key difference from the current KleisliReducer:** The current implementation runs all phases at all depths in a single bottom-up sweep, breaking on first success. The V-cycle separates three structurally different operations: the contravariant sweep (value minimization at depths > 0, exact, lattice-stable), the deletion sweep (structure-destroying at all depths, GuidedMaterializer, lattice rebuilt), and the covariant sweep (depth 0, speculative, lattice-rebuilding). This lets the lattice be computed once for the contravariant leg, and makes subsequent legs' re-derivation benefit from the contravariant improvements.

**Reject cache scoping.** The reject cache is **cleared at each leg boundary**. Within a leg, all encoders share the same decoder (same hom-set), so a rejection is valid for every encoder in that leg — the same candidate against the same decoder will produce the same result. Across legs, the decoder changes: a candidate rejected by `.direct` (tree says out-of-range at the existing structure) could succeed under `.guided` (rebuilds the tree from scratch, finds different valid ranges). Sharing the cache across legs would silently suppress valid candidates. The cost of clearing is negligible — different legs generate structurally different candidates (same-length for value minimization, shorter for deletion, re-derived for covariant), so cross-leg cache hits are rare.

**Stale entries within the deletion sweep.** Each deletion success triggers `accept(structureChanged: true)`, which rebuilds the tree and bindIndex. The post-deletion sequence is shorter and structurally different from any cached rejection. Stale entries (keyed on pre-deletion candidates) will never match a post-deletion candidate — the sequences differ in length and/or structure. The cost is only memory: the cache accumulates entries that can't be generated anymore. The cache is not explicitly cleared within a leg because: (1) pre-deletion rejections that happen to match a post-deletion candidate would still be valid rejections (same decoder, same candidate → same result), and (2) the memory cost is negligible — each deletion success is rare (at most a few per depth), and the cache contains at most O(encoders × targets) entries between successes. If memory becomes a concern for generators with many deletion targets, clearing the cache in `accept(structureChanged: true)` is a safe optimization — it only discards valid-but-unreachable entries.

**Fallback tree lifecycle.** The fallback tree is **updated after every accepted candidate** — the `accept()` function sets `fallbackTree = result.tree`. This gives tier-2 clamping the freshest possible targets at all times. Consequences by leg:

- **Contravariant sweep:** `.direct` doesn't use the fallback tree, so updates are a no-op in practice (structure-preserving — the tree doesn't change). But the variable stays current for subsequent legs.
- **Deletion sweep:** Each successful deletion produces a new tree via GuidedMaterializer. The next encoder's `DecoderContext` captures the post-deletion tree, so tier-2 clamping uses the most recent post-deletion structure. This matters because later deletions (at deeper depths in 0→max order) benefit from the updated tree — positions that shifted after an earlier deletion have a structurally corresponding fallback tree.
- **Covariant sweep:** Each successful value reduction at depth 0 re-derives bound content. The updated fallback tree contains the re-derived bound values, giving subsequent probes tier-2 clamping that reflects the latest inner-value state. This is where freshness matters most — stale clamping targets can cause regression.
- **Post-processing merge:** Uses the **pre-covariant tree** (captured before leg 3), NOT the continuously-updated `fallbackTree`. The merge's purpose is to recover pre-covariant bound values that re-derivation degraded. If tier-2 clamping used the post-covariant tree, it would clamp to the values the merge is trying to improve upon. The pre-covariant tree is the post-deletion state — it includes contravariant optimizations that survived deletion, so tier-2 clamping lands near the desired recovery targets. This requires a separate `preCovariantTree` variable, captured once at the start of leg 3.

The `DecoderContext` is reconstructed per encoder invocation (not per leg or per depth), as shown in the pseudocode. This ensures every decode call sees the current fallback tree. The cost is negligible — `DecoderContext` is a value type with no allocation.

**Target extraction.** The pseudocode uses `extractTargets` and `extractDeletionTargets` — both filter spans from the current sequence by bind depth, but return different span categories.

`extractTargets(sequence, depth, bindIndex)` — used by value-minimization and reordering phases:
- Walks the sequence, collecting all `.value`/`.reduced` entries as `ChoiceSpan` objects.
- Filters by `bindIndex.bindDepth(at: span.range.lowerBound) == depth`. When `bindIndex` is nil (no binds), returns all value spans unfiltered.
- Returns `TargetSet.spans(filteredValueSpans)` for value-minimization encoders. The reordering encoder receives `TargetSet.siblingGroups(filteredSiblingGroups)` instead — sibling groups are extracted from the same depth-filtered span set.
- "Targets at depth d" means: all value-bearing spans whose start position lies inside a bound subtree at nesting level d. Depth 0 = not inside any bound range (inner generator values). Depth 1 = inside the bound range of a top-level bind. Depth 2 = inside a bound range nested within another bound range.

`extractDeletionTargets(sequence, depth, bindIndex)` — used by the deletion sweep:
- Extracts spans of the appropriate **category** for the current encoder. Each deletion encoder targets a specific span category (see `DeletionSpanCategory` in Section 3): container spans, sequence elements, sequence boundaries, free-standing values, or mixed (for aligned-window and speculative deletion).
- Filters each category by bind depth, same as `extractTargets`.
- Container spans are full structural spans (e.g., `bind(true)...bind(false)`, `group(true)...group(false)`, `sequence(true)...sequence(false)`). Sequence elements are `group(true)...group(false)` spans that are direct children of a sequence container (array elements). Sequence boundaries are adjacent marker pairs where deleting merges two sequences. Free-standing values are bare `.value`/`.reduced` entries outside containers.
- The scheduler calls `extractDeletionTargets` per encoder (not per depth), because `accept(structureChanged: true)` can change the span structure between encoders.

Both functions are O(n) scans over the sequence with a bind-depth lookup per span. The bind-depth lookup is O(log r) where r is the number of bind regions (binary search over sorted region bounds).

### 4.2 Contravariant Sweep Details

The contravariant sweep handles value minimization and reordering at bound depths with exact guarantees:

- **Value minimization and reordering only.** Deletion is excluded — it invalidates span structure even at depth > 0 (see Section 1.4). This is what makes the lattice stable.

- **Lattice computed once** at sweep start and reused across all depths. Contravariant passes modify values within existing spans without changing span boundaries, so the lattice edges remain valid. 2-cell pruning is effective here: if `ZeroValueEncoder` succeeds at depth 2, `BinarySearchToZeroEncoder` can be skipped at depth 2 (dominated). This pruning carries across the entire sweep.

- **Decoder: `.direct`** — uses `Interpreters.materialize()` with the fixed tree. No GuidedMaterializer, no re-derivation. Grade: `(.exact, w)`.

- **Depth-major ordering, max→1.** Both phases (value minimization, reordering) run at each depth before moving to the next depth. The max→1 direction processes dependent values (deeper depths) before the values that determine their ranges (shallower depths). This avoids wasting work: reducing dependent values first means their current ranges are respected, and subsequent shallower reductions can tighten those ranges for the next cycle.

  **Alternative: 1→max.** The reverse direction would reduce shallower depths first, immediately tightening ranges for deeper depths within the same sweep — cascade convergence in a single pass rather than the D−1 cycles that max→1 requires (see convergence bound below). The tradeoff: in max→1, deeper depths are processed first against un-tightened ranges. Their reductions are valid (within the ranges that exist at the time) but may become suboptimal when shallower values are later reduced in the same sweep, tightening the deeper ranges. In 1→max, deeper depths always see the tightest available ranges — no such staleness. The actual max→1 advantage is stability: each depth is processed against ranges that don't change during its processing (deeper ranges don't constrain shallower ones), so encoders never generate candidates against ranges that shift mid-sweep. For the common case (D = 1, no nested binds), both directions are equivalent. For D ≥ 2, max→1 trades slower cross-depth convergence (D−1 cycles) for per-depth range stability. This choice should be validated empirically — 1→max's single-pass convergence may outweigh the range-stability benefit for generators with deep nesting.

  **Cross-depth interaction for nested binds.** For generators with nested binds, depth d values determine depth d+1 ranges (e.g., `bind { d1 in Gen.int(in: 0...d1) }`). Reducing d1 at depth d during the contravariant sweep shrinks depth d+1's valid range. `Interpreters.materialize()` handles this correctly — it runs the full generator, computes ranges dynamically, and rejects candidates where deeper values are out of the new range. This is safe but suboptimal: a single max→1 pass may leave opportunities. After depth 2 is reduced (constrained by the already-processed depth 3), depth 3 could be further reduced within the new tighter range. This converges across cycles: the cycle repeats, and the next contravariant sweep re-reduces deeper depths within updated ranges. For non-nested binds (single bind, depths 0 and 1 only), there is no cross-depth interaction within the contravariant sweep — depth 0 is untouched, and depth 1 has no dependency on other bound depths.

  **Convergence bound for nested binds.** The max→1 direction processes deeper depths first, then the shallower depths that determine their ranges. Constraint tightening propagates one level per sweep: cycle 1 optimizes depth 1 (no constraint from other bound depths — depth 0 is untouched in the contravariant sweep), but depth 2 was optimized against the old depth 1 values. Cycle 2 re-optimizes depth 2 against the new depth 1 values, but depth 3 was still using the old depth 2 values. In general, for `maxBindDepth = D`, full contravariant convergence requires **D − 1 V-cycles** *from a fixed baseline*.

  **Interference from other legs.** The D − 1 bound counts cycles of *pure contravariant propagation* — it assumes the baseline (inner values, span structure) is stable. In practice, each cycle also runs deletion and covariant sweeps that can change the baseline:
  - A **covariant success** at depth 0 shifts bound ranges at all depths. The contravariant propagation restarts from the new baseline — the D − 1 counter resets. This is by design: the covariant sweep opened new territory that the contravariant sweep must explore from scratch.
  - A **deletion success** can shift span positions and degrade values at deeper depths. Again, the propagation restarts from the post-deletion baseline.
  - A **merge success** substitutes pre-covariant values at specific depths. These may not be minimal within their post-covariant ranges, so the propagation restarts for the affected chain.

  The D − 1 bound is therefore a *per-baseline* bound, not a global one. The total number of contravariant convergence restarts is bounded by the number of non-contravariant successes across all cycles, which is in turn bounded by the global materialization budget. In practice, the covariant sweep makes progressively smaller changes as it converges, and each restart of the contravariant propagation starts from a better baseline than the last. For the common case (D = 1), the bound is 0 restarts — single-bind contravariant convergence completes in one sweep regardless of other legs. For D = 2, each restart adds one extra cycle. D ≥ 3 is rare in practice — deeply nested bind chains are uncommon in real generators.

- **Within-depth fixpoint.** Value minimization and reordering interact bidirectionally at each depth. Reordering permutes values to new positions where they may have different local minima (position-dependent property behavior). Value minimization can break ascending order by reducing some values more than others, creating new reordering opportunities. The scheduler loops value-min → reorder → value-min → ... at each depth until neither makes progress. The leg's stall patience and hard cap (Section 4.5) are the backstop — the fixpoint runs until natural convergence or budget exhaustion, whichever comes first. Each success within the fixpoint resets the consecutive-fruitless counter, so a depth with rich interactions can consume a large share of the leg's budget. This fixpoint is necessary because dirty-depth tracking won't mark depth `d` for re-visit (reordering and value-min at depth `d` don't change inner values, only bound values), so opportunities missed here are lost until some other leg's success happens to dirty `d`.

  **When does this interaction fire?** The interaction requires two conditions: (a) the generator produces sibling groups (arrays, tuples, multi-element containers), and (b) the property's behavior is position-dependent (the property treats the i-th element differently from the j-th). The canonical case is sorted-array properties: the property checks `array.isSorted`, so element position matters — reordering can move a large value from a constrained position to an unconstrained one. Other cases: tuple properties where the first element has a tighter valid range than the second, or multi-argument functions where argument order matters for the counterexample's minimality. For generators without sibling groups (single-value generators, deeply nested structures with no peer elements), reordering has no targets and the fixpoint trivially converges in one iteration. For generators with siblings but position-independent properties (e.g., `array.contains(x)`), reordering succeeds once (sorts ascending) and the fixpoint converges in two iterations (value-min → reorder → value-min finds nothing new). The multi-iteration fixpoint fires in practice for the current reducer's `ReorderSiblingsTactic` on sorted/ordered properties — typically 2–3 iterations before convergence. The cost is low: reordering is O(n) per pass, and the fixpoint adds at most one extra value-min pass per depth.

  **Interleaving granularity.** The fixpoint alternates at the *phase* level: all value-min encoders run to completion (including adaptive encoders like `BinarySearchToZeroEncoder`, which run their full probe loop — O(n × log V) across all targets), then all reordering encoders run to completion. There is no finer interleaving — the scheduler does not interrupt an adaptive encoder mid-convergence. Per-probe interleaving (one binary search step, then try reordering) would require breaking the `start()`/`nextProbe()` protocol, and is wasteful: reordering is only useful after multiple values have settled, not after each individual step. Per-target interleaving (converge one value, try reordering, converge next value) is expensive for the same reason. Binary search converges fast (O(log V) per target), so running to full convergence before reordering doesn't leave meaningful opportunities on the table — the fixpoint's second iteration catches anything reordering opens up.

- **No break-on-success:** Unlike the current `break depthLoop`, a success at depth 3 does not restart the cycle. The contravariant sweep is a thorough "smoothing" pass — it extracts all available improvements from all bound depths before handing control to subsequent legs.

  **Tree update after acceptance.** When a depth-2 value is reduced, `accept()` updates `sequence` and `tree`. But does the tree "know" about the tighter range at depth 3? The answer is that the tree doesn't store ranges — it stores branching structure and element metadata. `Interpreters.materialize()` (the `.direct` path) replays the full generator at materialization time, computing ranges dynamically from the current sequence values. So after a depth-2 acceptance, subsequent depth-3 encoders produce candidates with depth-3 values based on the old (pre-depth-2-change) ranges. When the scheduler decodes those candidates, `Interpreters.materialize()` replays the generator with the *updated* depth-2 values, computes the *new* (tighter) depth-3 range, and rejects any depth-3 value that's now out of range. This is safe (no invalid candidates accepted) but wasteful — the encoder generates candidates against stale ranges, and the decoder rejects them. The cost is bounded: binary search converges in O(log V) probes regardless, and the `lastAccepted: false` feedback steers the adaptive encoder away from the now-invalid region. The max→1 direction minimizes this waste by processing deeper depths first (before shallower changes tighten their ranges), at the cost of slower cross-depth convergence (Section 4.2, convergence bound).

- **Dirty-depth tracking:** On cycle restart after a covariant, deletion, or merge success, re-sweep depths whose bound ranges or span structure may have changed. A successful merge substitutes pre-covariant bound values at specific depths — those values may not be locally minimal within their post-covariant ranges, so the contravariant sweep should re-optimize them.

  `BindSpanIndex` provides **per-region** precision, not per-depth precision. `bindRegionForInnerIndex(i)` identifies which `BindRegion` a depth-0 inner value feeds. But within a single bind chain, the cascade is structural: a depth-0 change shifts bound ranges at depth 1, which can shift ranges at depth 2 (if nested), and so on. **Within a chain, all depths are dirty.** The per-region precision only helps when there are **independent bind chains** — e.g. `(bind1, bind2)` where a change in bind1's inner values doesn't affect bind2's depths.

  For the common case (single bind chain), dirty-depth tracking degenerates to "any depth-0 change dirties all bound depths." The optimization buys nothing there. For generators with multiple independent binds, it avoids re-sweeping unaffected chains. The scheduler should use the per-region information when available but not assume it provides fine-grained depth skipping in general.

### 4.3 Deletion Sweep Details

The deletion sweep runs after the contravariant sweep, at all depths (0 → max):

- **Direction 0→max: most aggressive first.** Depth-0 deletions can eliminate entire bind regions — all spans at depths 1+ within that region cease to exist. Processing 0→max means we don't waste materializations trying to delete individual spans within a region that a depth-0 deletion will remove wholesale. This is the same principle as the encoder ordering within the deletion phase (container spans before free-standing values) — applied to depth ordering. The Gauss-Seidel dependency argument from the contravariant sweep does not apply here: GuidedMaterializer re-derives from scratch regardless of depth, so there's no constraint-propagation benefit to either direction. The alternative (max→0) would try small, low-impact deletions first. A depth-3 deletion that removes a small span preserves more contravariant work, but its shortlex impact is small. The 0→max ordering prioritizes shortlex impact — shorter sequences from aggressive deletions outweigh the value degradation that the next contravariant sweep will repair. Neither direction is categorically optimal; 0→max is the waste-avoidance heuristic.

- **Decoder: `.guided`** with `.relaxed` strictness. Deletion invalidates the tree's element scripts — GuidedMaterializer rebuilds a fresh tree from the generator using the shortened candidate as a prefix.

- **Lattice rebuilt after each success.** Deletion changes span structure (removes spans, shifts positions), invalidating the dominance lattice. The lattice is recomputed from the post-deletion state before the next encoder is tried.

- **Includes all deletion encoders:** container spans, sequence elements, boundaries, free-standing values, aligned windows, speculative delete.

- **Separate from the contravariant sweep** because deletion at depth > 0 is `.bounded` — re-derivation via GuidedMaterializer can produce different content for the gap left by the deleted span. Grouping it with the exact contravariant sweep would violate the lattice stability guarantee.

- **Deletion can degrade contravariant-optimized bound values.** When deletion at depth d removes a span, GuidedMaterializer re-derives the sequence using the shortened candidate as a prefix. Values *before* the deletion site are intact in the prefix (tier 1) — fully preserved. Values *after* the deletion site are structurally misaligned: they were optimized for their original generator request points, but are now consumed at shifted positions. If out of range for the new requests, they fall to tier 2 (fallback tree) — but the fallback tree also has the pre-deletion structure, so it may not align either, dropping to tier 3 (PRNG). The damage is proportional to how much content follows the deletion site. This is the inherent cost of structure-destroying operations — the payoff is a shorter sequence (shortlex improvement from deletion outweighs value degradation). The next cycle's contravariant sweep re-optimizes the post-deletion state.

- **Contravariant-before-deletion ordering is still correct.** The fallback tree containing contravariant-optimized values gives tier 2 the best possible clamping targets for structurally aligned positions (before the deletion site, and at positions where the shift happens to preserve structural correspondence). Running deletion first would mean the fallback tree has un-optimized values — strictly worse for the positions where tier 2 does apply.

### 4.4 Covariant Sweep Details

The covariant sweep runs at depth 0 only, after the deletion sweep:

- **Value minimization and reordering only** (deletion at depth 0 is handled by the deletion sweep).

- **Decoder:** With binds present: `.guided` with fallback tree containing the contravariant-improved bound values. Re-derivation uses tier-1 prefix values and tier-2 clamping to preserve those improvements where the new bound ranges permit. Grade: `(.bounded, w)`. Without binds: `.direct` — no re-derivation needed, no bound ranges to shift. Grade: `(.exact, w)`. `SequenceDecoder.for(_:)` handles the routing based on `DecoderContext(.specific(0), bindIndex, fallbackTree, .normal)`.

- **On success:** Mark affected bind chains dirty. `BindSpanIndex.bindRegionForInnerIndex` identifies which bind region the mutated inner value feeds. All depths within that region's chain are dirty (bound ranges may have shifted at every nesting level). For generators with multiple independent bind chains, only the affected chain is dirtied — unaffected chains are skipped on the next contravariant sweep. For the common case (single bind chain), all bound depths are dirty and the next contravariant sweep is a full re-sweep. For deletion successes in the deletion sweep, all depths are dirty (span positions are invalidated globally).

- **Can escape local minima:** If the contravariant sweep converged (all bound values minimized within their ranges), the covariant sweep can change those ranges by reducing inner values. This opens new territory for the next contravariant sweep.

### 4.5 Resource Budget

The budget is organized by **leg**, not by phase — matching the execution model. Each leg has an independent budget, preventing the contravariant sweep from starving the covariant sweep.

```swift
struct CycleBudget {
    let total: Int

    /// Per-leg allocation as fraction of total. Normalized to sum = 1.
    let legWeights: [ReductionLeg: Double]

    /// Initial budget for a leg, before unused-budget forwarding.
    func initialBudget(for leg: ReductionLeg) -> Int {
        Int(Double(total) * (legWeights[leg] ?? 0))
    }
}

enum ReductionLeg: CaseIterable {
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

**No within-leg phase splits.** The contravariant and covariant legs both run a fixpoint loop that alternates value minimization and reordering. Value-min and reordering draw from a single undivided leg budget — no per-phase allocation. Reordering is inherently cheap (one pass over sibling groups, O(n) candidates) and self-limits by exhaustion long before it could starve value-min. The fixpoint loop's natural termination (neither phase makes progress) is the scheduling mechanism; per-phase weights would conflict with the alternating structure and create the allocation problem described below.

> *Why not per-phase splits within the fixpoint?* A one-shot 85/15 split assumes value-min runs once, then reordering runs once. The fixpoint loop interleaves them: value-min → reorder → value-min → .... If value-min exhausts its 85% allocation on iteration 1, iteration 2's value-min gets zero budget — even though reordering just created new opportunities. Re-allocating the remaining leg budget at each iteration would work but adds complexity for no benefit: the leg budget already caps total spending, and reordering's cheapness means it can't starve value-min in practice.

The covariant sweep gets its own 25%, independent of how many depths the contravariant sweep processes. A 4-depth contravariant sweep consumes its 30% across 4 depths; the covariant sweep's 25% is reserved for the single depth-0 pass that escapes fixed points. Without per-leg budgets, the covariant sweep would starve whenever `maxBindDepth` is large.

**Leg weights are fixed across cycles — no cross-cycle adaptation.** The weights are structurally motivated: the covariant sweep gets 25% because it operates at a single depth while the contravariant sweep distributes its 30% across many. This rationale doesn't change between cycles, so adapting weights would undermine the starvation guarantee that justified the allocation.

**Intra-cycle unused-budget forwarding.** When a leg stalls before exhausting its allocation, the unused budget flows forward to subsequent legs in execution order. This makes the per-leg weights a *floor*, not a ceiling: the covariant sweep gets at least 25% of the cycle budget, plus whatever the contravariant and deletion legs didn't use. Forwarding is the only adaptation mechanism — it's stateless (no cross-cycle memory), monotonic (later legs can only gain), and preserves the structural invariant (earlier legs never lose budget to later ones). In the scheduler:

```swift
var remaining = cycleBudget.total
for leg in ReductionLeg.allCases {
    let target = cycleBudget.initialBudget(for: leg)
    let cap = remaining
    let used = runLeg(leg, budget: target, cap: cap)
    remaining -= used
}
```

**Budget semantics within `runLeg`.** Two counters govern a leg's execution:

1. **Hard cap** (`cap`): the maximum total materializations the leg may consume. This is `remaining` — can't exceed what the cycle has left. The leg stops unconditionally when it hits this.

2. **Stall patience** (`target`): the maximum *consecutive fruitless* materializations before the leg gives up. Each success resets the consecutive-fruitless counter to zero. This means a productive leg can spend up to `cap` materializations (it keeps resetting the counter), while an unproductive leg gives up after `target` consecutive failures.

**Stall patience does NOT scale with forwarded budget.** If the covariant sweep has target = 50 and cap = 200 (150 forwarded from earlier legs), it still gives up after 50 consecutive fruitless materializations. The forwarded budget helps productive legs continue longer — it doesn't make unproductive legs more persistent. The rationale: if 50 consecutive probes found nothing, 150 more from the same encoders at the same depth are unlikely to either. The forwarded budget's value is in extending legs that are making progress, not in extending fruitless search.

**Within-depth fixpoint budget.** The contravariant leg distributes its budget across depths. At each depth, the fixpoint loop (value-min → reorder → value-min → ...) consumes materializations from the leg's remaining budget. The fixpoint terminates when: (a) neither phase makes progress (natural convergence), or (b) the leg's hard cap is reached. The stall patience applies per-encoder within each fixpoint iteration — an encoder that exhausts its probe count (`O(n × log V)` for binary search) without success counts those probes toward the consecutive-fruitless counter. A success in reordering resets the counter, and the next value-min iteration starts with fresh patience.

```swift
func runLeg(_ leg: ReductionLeg, budget target: Int, cap: Int) -> Int {
    var used = 0
    var consecutiveFruitless = 0
    // ... per-depth/per-encoder loop:
    //   On materialization:
    //     used += 1
    //     if success: consecutiveFruitless = 0
    //     else: consecutiveFruitless += 1
    //   Stop when:
    //     used >= cap                        // hard cap
    //     || consecutiveFruitless >= target   // stall patience
    //     || natural termination              // no more encoders/depths
    return used
}
```

**Cross-cycle hard cap.** `CycleBudget.total` governs a single cycle. The scheduler also tracks a **global materialization budget** — the maximum total property evaluations across all cycles. When the global budget is exhausted, the reducer returns the best result found so far, regardless of whether a fixed point was reached. This is the practical termination guarantee (see Section 1.6). The per-cycle budget is carved from the remaining global budget at each cycle start: `cycleBudget = min(defaultCycleBudget, globalRemaining)`. The global budget defaults to the user-facing `maxIterations` setting.

### 4.6 Branch Tactics

Branch manipulation (promote, pivot) operates on the tree, not on spans within a sequence. These run **once per cycle before lattice computation** — since branch tactics can change the tree shape at any depth, the lattice must be built on the post-branch state. If any branch tactic succeeds, all derived structures (lattice, bind index, depth map) are rebuilt from scratch. They use a separate protocol:

```swift
protocol BranchEncoder {
    var name: String { get }
    var grade: ReductionGrade { get }

    func encode(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
    ) -> any Sequence<ChoiceSequence>
}
```

The tree is **read-only input** — branch encoders need it to identify branch points and available alternatives (which branches exist, what children can be promoted), but they return candidate sequences only. The scheduler passes each candidate through `.guided(fallbackTree:, strictness: .relaxed)`, which rebuilds the tree from the generator using the candidate as a prefix. This keeps tree construction lazy (only the candidate the scheduler accepts is fully materialized) and maintains the enc/dec separation: the encoder proposes structural mutations, the decoder materializes the consistent `(sequence, tree, output)` triple. Branch encoders don't need targets — they operate on the full tree structure.

**Categorical status.** Branch tactics don't fit the three-category taxonomy (Section 1.4). They're structure-destroying (like deletion) and use `.guided(fallbackTree:, strictness: .relaxed)` (same decoder, `.bounded` approximation class). But they're not depth-filtered — a single promotion can change the tree shape at every depth simultaneously. They're not deletion (they don't shorten the sequence — they substitute one subtree for another). They're not covariant (they don't specifically target inner values). Branch tactics are a **fourth operational category**: global, structure-transforming, bounded. The pre-cycle position is a scheduling decision, not a categorical one: branch changes can invalidate the lattice, bind index, and depth assignments, so they must run before any of those structures are computed.

**Overlap with deletion.** Branch promotion can eliminate a subtree (the unpromoted child is discarded), which superficially resembles container deletion. But the mechanism is different: deletion removes spans from the existing tree, while promotion replaces the tree's branching structure. A promotion that eliminates a subtree also eliminates the *branch point itself*, something deletion can't do (deletion works within the existing branch structure). In practice, the overlap is small — branch tactics address a different fixed-point escape (the current branch choice is suboptimal, not the current structure length).

**Budget allocation (5%).** Based on the empirical observation that branch tactics fire rarely. The current reducer attempts promote and pivot at most twice per cycle. Typical generators have 0–3 branch points, each with 2–5 children. Promote tries O(branches × children) candidates; pivot tries O(branches) candidates. For a typical generator, this is 5–15 materializations per cycle — a tiny fraction of the total budget. The 5% allocation (typically 10–50 materializations for a 200–1000 cycle budget) is generous relative to the expected cost. If branch tactics fire more frequently for a specific generator class (e.g., deeply branching recursive generators), the unused-budget forwarding mechanism (Section 4.5) ensures subsequent legs aren't starved — branch's unused 5% flows forward to the contravariant sweep.

### 4.7 Adaptive Encoder Selection Within Equivalence Classes

The 2-cell dominance preorder (paper §15) determines *which* encoders can be pruned after a success — but within an equivalence class (encoders that mutually dominate each other), the preorder gives no ordering. This is where adaptive selection operates.

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

**Dirty-depth prior reset.** Cycle-boundary decay handles gradual landscape drift, but a covariant or deletion success mid-cycle can abruptly restructure bound ranges at specific depths. The next cycle's contravariant sweep re-visits those depths with priors shaped by the pre-restructuring landscape — the first re-sweep always uses stale priors, since decay only fires at cycle boundaries. For generators where a covariant success substantially restructures bound ranges (e.g., reducing an inner value that gates a branch, collapsing a subtree), the stale priors could persistently favour the wrong encoder for several probes.

Fix: when the scheduler marks depths dirty (from a covariant, deletion, or merge success), it also resets the Thompson Sampling priors at those depths to Beta(1,1). This is a local reset — only the affected depths lose their history. Unaffected depths retain their learned priors. The cost is negligible (O(k) per dirty depth, where k is the equivalence class size). The benefit is that the first re-sweep of a freshly-dirtied depth explores all encoders uniformly rather than persisting a stale preference. At worst, it re-learns the same ranking in one cycle (2–4 probes). At best, it avoids wasting probes on a newly-suboptimal encoder whose success was contingent on the old bound ranges.

For single-bind generators where inner-value changes shift all ranges proportionally, the relative encoder ranking is likely preserved — the reset is harmless but not critical. For multi-bind generators where a covariant change restructures one chain but not another, the reset affects only the restructured chain's depths (via dirty-depth tracking), preserving learned priors at unaffected depths.

**Cold start:** Beta(1,1) samples uniformly on [0,1], so the first cycle tries encoders in arbitrary order. After one round of observations, the posterior already differentiates.

**No cross-depth signal sharing (RAVE).** Adjacent depths can have structurally unrelated content (Int values at depth 2, Float values at depth 3), so encoder success at one depth is not reliable evidence for adjacent depths. With equivalence classes of 2–4 encoders and decay γ = 0.8, Thompson Sampling converges in 2–3 cycles without cross-depth sharing. RAVE would add complexity and a misleading-signal risk for marginal benefit.

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

Extract the two materialization pipelines from `TacticEvaluation` and `TacticReDerivation` into the `SequenceDecoder` enum cases (`.direct`, `.guided`, `.crossStage`).

**Files:**
- New `Sources/ExhaustCore/Interpreters/Reduction/SequenceDecoder.swift`
- The `SequenceDecoder.for(_:)` static method lives in the `SequenceDecoder` protocol file

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

Add resource tracking and per-leg budget allocation. Measure against the existing shrinking challenge benchmarks.

**Files:** Modify `ReductionScheduler.swift`.

### Step 6: Approximate Passes

Enable redistribution and tandem reduction as `.bounded` passes. The shortlex guard is the runtime enforcement for all `.bounded` morphisms.

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
- **2-cell dominance.** "Every candidate from encoder A is also produced by encoder B" (for A ⇒ B). Declared relationships, justified by structural arguments about encoder semantics. Testable by exhaustive comparison of candidate sets on small inputs — a property test can verify that A's candidates ⊆ B's candidates for random sequences and target sets.
- **Adaptive convergence.** Feed a `BinarySearchToZeroEncoder` a sequence of `lastAccepted` values and assert the probe trajectory. Binary search converges in ⌈log₂ v⌉ steps regardless of the property.
- **Empty targets.** Encoder returns an empty sequence when given no targets. Boundary case.

**Decoders** — heavier fixtures (generator + tree), but isolated from encoder logic:

- **`.direct` case.** Output sequence equals the candidate (exact). Deterministic given the same tree. Assert `result.sequence == candidate` for valid candidates.
- **`.guided` tiered resolution.** Construct candidates with specific out-of-range positions and verify: tier 1 uses the prefix value when in range, tier 2 clamps to the fallback tree when out of range, tier 3 falls back to PRNG when neither has a value.
- **Shortlex guard.** Candidate that's shortlex-larger than the original → decoder returns `nil`.
- **Approximation class.** `decoder.approximation` is `.exact` for `.direct`, `.bounded` for `.guided` and `.crossStage`.

**`SequenceDecoder.for(_:)`** — pure function from `DecoderContext` → decoder type. Exhaustive case testing:

- `.relaxed` strictness → `.guided` (regardless of bind state)
- `.specific(n)` where n > 0, no binds, `.normal` → `.direct`
- `.specific(0)`, binds present, `.normal` → `.guided`
- `.specific(0)`, no binds, `.normal` → `.direct`
- `.global`, binds present → `.crossStage`
- `.global`, no binds → `.direct`

**ReductionGrade / ApproximationClass** — value types with simple algebra. Property-testable:

- Associativity: `(a ⊗ b) ⊗ c == a ⊗ (b ⊗ c)` (lattice join is associative)
- Identity: `a ⊗ .exact == a` (`.exact` is the join identity)
- Commutativity: `a ⊗ b == b ⊗ a` (lattice join is commutative)
- Idempotency: `a ⊗ a == a`
- Resource additivity: `composed.maxMaterializations == a.maxMaterializations + b.maxMaterializations`
- `composed(withDecoder:)` consistent with `composed(with: ReductionGrade(decoder, 0))`

**Thompson Sampling** — stateful but deterministic given a fixed seed:

- Binary update: accepted → α grows, not accepted → β grows
- Decay: after decay with γ = 0.8, priors move toward Beta(1,1)
- Dirty-depth reset: after marking depths dirty, affected priors are Beta(1,1); unaffected depths retain their priors
- Cold start: Beta(1,1) produces no ordering preference
- Convergence: after N successes on one arm, that arm is ranked first with high probability (testable with a fixed seed)

**Scheduler** — the scheduler's decisions are all derivable from concrete inputs. Each decision is exposed as a static, deterministic function testable without mocks:

- `dirtyDepths(bindIndex:mutatedIndices:) -> Set<Int>` — given a `BindSpanIndex` and the indices that changed, which depths need re-sweeping? Testable with `BindSpanIndex` fixtures and index sets.
- `mergePreCheck(preCovariant:preBindIndex:postCovariant:postBindIndex:) -> Bool` — region count match + inner range size match + aligned regression scan (pre-checks 2–3). Pure function over two sequences and their bind indexes.
- `mergeRangeFilter(pre:post:postTree:postBindIndex:) -> Set<Int>` — range-validity filter (pre-check 4). Returns the set of bound positions where substitution is in-range. Pure function over two sequences and the post-covariant tree.
- `shortlexMerge(old:new:validPositions:newBindIndex:) -> ChoiceSequence` — substitutes `old` values only at positions in `validPositions`; keeps `new` values elsewhere. Pure function.
- `mergeAffectedDepths(preBindIndex:postBindIndex:validPositions:) -> Set<Int>` — which depths were modified by the merge, for dirty-depth tracking. Pure function over two bind indexes and the substitution positions.
- **Merge fallback tree invariant** — the merge's GuidedMaterializer call uses the pre-covariant tree (captured before leg 3), NOT the continuously-updated fallbackTree. Testable by verifying that tier-2 clamping lands on contravariant-optimized values rather than post-covariant values.
- `extractTargets(sequence:depth:bindIndex:) -> TargetSet` — filters value spans by bind depth. Pure function over sequence and bind index. Testable with BindSpanIndex fixtures.
- `extractDeletionTargets(sequence:depth:bindIndex:spanCategory:) -> TargetSet` — filters spans of a specific category by bind depth. Pure function. Testable with sequence fixtures containing known span structures.
- `shouldStall(consecutiveFruitless:target:) -> Bool` — stall patience check. Trivially testable.
- `allocateBudget(total:legWeights:) -> CycleBudget` — pure arithmetic from weights to per-leg initial budgets.
- `legBudget(target:cap:) -> (budget: Int, remaining: Int)` — unused-budget forwarding logic. Given a leg's initial target and the remaining cycle cap, returns the effective budget (= cap, hard upper bound) and stall patience (= target, consecutive-fruitless limit). Pure arithmetic.
- `canAfford(remaining:grade:) -> Bool` — does the remaining budget accommodate this encoder's declared grade?
- `redistributionTriggered(contravariantAccepted:deletionAccepted:cyclesSinceRedistribution:cap:) -> Bool` — redistribution trigger logic. Primary: both zero. Deferral cap: counter ≥ cap. Pure function, trivially testable.
- `selectEncoder(equivalenceClass:posteriors:seed:) -> EncoderIndex` — Thompson Sampling ranking. Deterministic given a fixed seed.
- `updatePosterior(prior:accepted:) -> BetaParameters` — binary Bayesian update. Pure arithmetic.
- `decayPosteriors(priors:gamma:) -> [BetaParameters]` — cycle-boundary decay toward Beta(1,1). Pure arithmetic.
- `resetDirtyPriors(priors:dirtyDepths:) -> [DepthPriors]` — resets affected depths to Beta(1,1), preserves unaffected. Pure function.
- `depthFixpointContinues(valueMinProgress:reorderingProgress:) -> Bool` — within-depth fixpoint loop condition. Continues while either phase made progress. Trivially testable.
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
| Grade composition | Prop 10.4 | Pipeline resource usage = sum of step resources. Pipeline approximation class = lattice join of step classes. Verified structurally, not empirically. |
| Feasibility preservation | Lemma 3.3 | If we could make `enc` feasibility-preserving (e.g., for monotone properties), we could skip the property check. Performance win for special cases. |
| 2-cell pruning | Def 15.3 | If encoder A pointwise dominates encoder B (same or better on every input), B can be skipped after A succeeds. Dominance relationships are declared by the developer and justified by structural arguments about encoder semantics (e.g., ZeroValue's output is BinarySearchToZero's fixed point). Not derived by static analysis — that would require proving subset relationships between candidate sets, which is undecidable for arbitrary encoders. |
| Natural transformation | Prop 5.4 | *Inspiration* for the shortlex merge (post-processing that doesn't break pipeline correctness). The merge is a binary operation on two states, not a unary Cand endotransformation — it doesn't formally satisfy the paper's naturality condition. Correctness is guaranteed by GuidedMaterializer re-materialization + shortlex acceptance. |
| Three pass categories | paper §4.1, §4.2 (loose analogy) | We borrow "covariant/contravariant" terminology for operational pass direction (forward propagation vs. fixed-range reduction), not as a formal instantiation of the paper's functors on OptRed. The three-category distinction is operationally justified by decoder requirements, not derived from the paper's functor theory. |
| Multigrid V-cycle | paper §14.4 (loose analogy) | The paper treats literal discretization levels of continuous problems; Exhaust's "levels" are bind depths in a Kleisli chain. The shared pattern is "smooth fine levels → correct coarse level → re-smooth." The Gauss-Seidel argument for sweep ordering is sound but domain-specific (bind chain dependencies), not a formal instantiation of the paper's coarsening/prolongation morphisms. |

---

## 8. Implementation Performance Guidelines

The architecture's primary performance lever is *reducing the number of materializations* via the dominance lattice and phase ordering. Materialization (running the generator on a candidate sequence) dominates the cost of every cycle. The guidelines below address the secondary concern: minimizing overhead in the scheduler, encoder dispatch, and lattice traversal so that the non-materialization cost stays negligible.

### 8.1 Dominance Lattice Storage

The lattice node arrays have sizes known at build time (e.g., 6 deletion encoders, 3 numeric encoders, 1 float encoder). Use `InlineArray` for these fixed-size collections to eliminate heap allocation. The lattice is built once per reducer invocation and traversed many times per cycle — stack allocation avoids retain/release traffic on every traversal step.

For dynamic collections whose maximum size is known but whose actual size varies (e.g., filtered target spans per depth), use `ContiguousArray` with `reserveCapacity` to avoid incremental reallocation. `ContiguousArray` guarantees contiguous storage without the bridging overhead of `Array` (which may use `NSArray` backing on Apple platforms).

### 8.2 Innermost Loop Iteration

In the scheduler's innermost loops — candidate iteration from batch encoders, span iteration within encoder `encode()` implementations, and lattice traversal — prefer `while` loops with manual index advancement over `for...in`. Swift's `for...in` desugars to `IteratorProtocol` calls, which are not inlined in debug builds (`-Onone`). Since the reducer is frequently run under debug conditions during test development, the protocol dispatch overhead on hot loops is measurable.

```swift
// Prefer this in hot paths:
var i = 0
while i < spans.count {
    let span = spans[i]
    // ... use span ...
    i += 1
}

// Over this:
// for span in spans { ... }
```

Each site should carry a brief comment explaining the choice: `// while-loop: avoiding IteratorProtocol overhead in debug builds`.

### 8.3 Documentation

All reducer code is internal to ExhaustCore. Follow `DOCUMENTATION_STYLE.md` with the internal API conventions: technical terminology (ChoiceTree, shortlex, Kleisli, dominance lattice) is expected without explanation. Summary lines on all types and non-trivial methods. `// MARK: -` with plain `//` for implementation notes (algorithm sketches, bit layouts, design rationale). No `///` on trivial private helpers under three lines called from a single site.
