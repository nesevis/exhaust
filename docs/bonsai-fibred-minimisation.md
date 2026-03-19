# Bonsai as Alternating Minimisation over a Fibred Trace Space

An analysis of the categorical structure underlying BonsaiScheduler's two-phase pipeline: the fibred structure of trace space, the laws from Grothendieck fibration theory that the implementation exploits, and the Kleisli tower structure of bind-depth chains.

---

## 1. The Fibred Structure of Trace Space

An execution trace records every random decision the generator made: which choices were taken, what values were chosen, and which values controlled the structure of subsequent choices. This trace space has a natural two-level structure.

The **trace structure** is the shape of an execution: how many choice points exist, which ones are controlled by an earlier value, and what domain each choice point draws from. The trace structure is fully determined by the values at controlling positions — changing any non-controlling value leaves the structure unchanged.

The **value assignment** is the concrete values chosen at each point within a fixed trace structure. For a given structure, the value assignment ranges over the Cartesian product of each choice point's domain.

This gives the trace space a **fibred structure**: the set of all trace structures is the base, and above each structure sits a fibre — the set of all value assignments compatible with that structure. The total trace space is the union of all fibres across all base points. Moving within a fibre (changing values) never changes the base point. Moving between fibres (changing structure) replaces the fibre entirely.

---

## 2. Bonsai as Alternating Minimisation

Before the main loop, a one-shot **Phase 0** (`StructuralIsolator`) identifies value positions that are structurally independent — not inside any bind span or branch-containing group — and zeros them all to their domain minimum in a single probe. If the property still fails, the zeroed result is accepted. This is a retraction within the fibre, not a cartesian lift: no base change occurs, and the operation is the product of `semanticSimplest` over the independent coordinates composed with the identity on the coupled coordinates. Its correctness follows from structural independence alone — a simpler property than the fibration laws that the rest of this document develops — so it is not discussed further.

BonsaiScheduler then reduces the failing trace by alternating between two phases until neither makes progress.

**Phase 1** minimises the base: it removes choice points, simplifies branch structure, and jointly reduces the controlling values that determine how many downstream choices exist and what domains they draw from. A smaller base point means a strictly shorter choice sequence — fewer coordinates in the fibre above it. Phase 1c (joint bind-inner reduction) includes value-typed encoders (zero-value, binary search, float reduction) operating on bind-inner positions. These are base-coordinate reductions, not fibre-local value changes: a bind-inner value determines the structure of the bound generator downstream, so changing it changes which fibre the bound content lives in.

**Phase 2** minimises the value assignment within the base point that Phase 1 has fixed. With the structure held constant, the problem has fixed dimensionality and fixed domains; Phase 2 applies coordinate descent (binary search, zero encoders, float reduction) across the leaf positions.

This is **alternating minimisation** over the fibred space: alternate between minimising the base and minimising within the fibre, with each phase holding the other fixed.

When both phases stall, a **speculation leg** (`runRelaxRound`) searches for progress outside the current descent path before the stall counter decrements. The `RelaxRoundEncoder` zeros one value by redistributing its magnitude to another — a value-only mutation that may make the sequence shortlex-*larger* (the absorbing coordinate moves away from zero). If the redistributed values are bind-inner positions, the materialization can land in a different fibre, because a changed controlling value induces a different downstream structure. After redistribution, the leg runs base descent (structural) and fibre descent (value) passes on the relaxed state. The entire round-trip must shortlex-improve over a pre-speculation checkpoint or the state is rolled back. In the framework of Sepúlveda-Jiménez (2026, §11.2), this is an instance of a **relax-round** step: the structured encoder set defines an exact reduction problem that is locally exhausted, so the scheduler relaxes to a value redistribution that may worsen the objective, exploits the relaxed state with the standard two-phase pipeline, and accepts the result only if the pipeline recovers a net improvement. (The broader Sepúlveda-Jiménez framework — encoder/decoder separation, grade composition, 2-cell dominance — applies throughout the reducer's architecture but is documented separately; the relax-round pattern is the point of contact relevant to this document's fibred analysis.)

In fibration terms, speculation is a **non-monotone endomorphism of the total space** — neither cartesian nor vertical, and not a descent step. When both redistributed coordinates are non-controlling, the redistribution is a fibre endomorphism that moves away from the shortlex minimum. When a bind-inner coordinate is redistributed, the base changes as a side effect of the value mutation — the move does not factor cleanly into cartesian-then-vertical because the base change is incidental, not an intentional structural reduction. The subsequent base descent and fibre descent passes apply the standard cartesian-vertical factorisation to the relaxed state, and the checkpoint guard imposes monotonicity on the round-trip. The two-phase pipeline preserves the factorisation at every step; speculation breaks it at the step level and recovers it at the pipeline level. Where Phase 0 is a trivially vertical retraction within the fibre, speculation is a perturbation of the total space whose correctness depends entirely on the checkpoint acceptance guard.

The phase ordering is not a heuristic. Value changes are fibre-local — they cannot change which base points are structurally reachable, only which ones the projection heuristic manages to discover. Structural changes can invalidate value work by eliminating choice points or shrinking domains. Therefore exhausting structural reductions before value reductions reaches an equal or smaller base point than any interleaving. The structure-before-value ordering is the unique ordering that cannot be improved upon with respect to achievable base size.

**Termination.** The shortlex order on choice sequences is a well-order: there are no infinite strictly descending chains. Since every accepted candidate is strictly shortlex-smaller than its predecessor, improving candidates must eventually exhaust. The stall counter (`maxStalls` consecutive cycles without improvement) bounds the cost of searching for them — the encoder set is incomplete and the PRNG retries may miss, so the real algorithm can fail to find an improving candidate even when one exists. The well-order guarantees that the idealized algorithm terminates; the stall counter guarantees that the real one does.

**Relation to block coordinate descent.** The alternation is a two-block coordinate descent: block 1 is the base point (trace structure), block 2 is the value assignment within the fibre. Tseng (2001, Theorem 4.1) guarantees that cluster points of the iterates are stationary under pseudoconvexity and an essentially cyclic selection rule. Bonsai's setting satisfies these conditions trivially because the dependency between blocks is one-directional (the dominance argument above). The phase ordering will be shown to be canonical in Section 5.1, via the cartesian-vertical factorisation of morphisms in a fibration.

**Fibred induction.** The shortlex well-order and the fibred decomposition could in principle be unified into a single fibred induction rule via Ghani, Johann & Fumex (2012), who derive generic induction principles from fibrations over initial algebras. The resulting rule would express "induction over trace structures (Phase 1) followed by induction within each fibre (Phase 2)" as a single principle. Working out this instantiation is future work.

---

## 3. Grothendieck Fibrations

The fibred structure of trace space is an instance of a **Grothendieck fibration** — a functor `p: E → B` from a total category `E` to a base category `B`, where every base morphism can be lifted to a **cartesian morphism** in the total category.

A morphism `f: e' → e` in `E` is cartesian over `g: b' → b` in `B` if it is the universal lift of `g`: any other morphism into `e` that factors through `g` below factors through `f` above, uniquely. Cartesian morphisms are the tightest possible lifts — they add no information beyond what the base morphism dictates.

`p` is a Grothendieck fibration if for every object `e` and every base morphism `g: b' → p(e)`, a cartesian lift of `g` to `e` exists. This guarantees that every structural reduction (a morphism in the base) can be lifted to a trace transformation (a morphism in the total trace space) in a canonical way.

The key laws that follow are:

1. **Existence**: cartesian lifts always exist.
2. **Uniqueness**: any two cartesian lifts of the same base morphism to the same object are uniquely isomorphic within the fibre. The canonical lift is essentially unique (Jacobs 1999, §1.1, Proposition 1.1.4).
3. **Composition**: the composite of two cartesian morphisms is cartesian (Jacobs 1999, §1.1, Exercise 1.1.4(ii); §1.5, Lemma 1.5.5).
4. **Reindexing**: each base morphism `g: b' → b` induces a reindexing functor `g*: E_b → E_{b'}` carrying value assignments from the old fibre into the new one. These functors compose (up to natural isomorphism): `(g ∘ f)* ≅ f* ∘ g*`.

A fibration can also carry **cocartesian lifts** — the dual of cartesian lifts. Where a cartesian lift pulls a value assignment from the old fibre into the new one (`g*`), a cocartesian lift pushes in the opposite direction (`g!`): given a value assignment in the smaller fibre, find the canonical element in the original fibre that maps to it. A functor that has both cartesian and cocartesian lifts is a **bifibration**, and the two operations form an adjunction `g! ⊣ g*` — the image along `g` is left adjoint to reindexing along `g` (Jacobs 1999, §9.1, Definition 9.1.1 and Lemma 9.1.2; §1.9, Proposition 1.9.8).

---

## 4. Three Laws from Fibration Theory

### 4.1 Composition of Cartesian Morphisms — Implemented

Phase 1 commits one structural reduction at a time and restarts from the top of the sub-phase loop on every acceptance. The composition law (Jacobs 1999, §1.5, Lemma 1.5.5) says that a sequence of structural reductions composes into a single valid structural reduction — if `f` is cartesian over `g` and `f'` is cartesian over `g'`, then `f ∘ f'` is cartesian over `g ∘ g'`.

The sequential greedy restart strategy discovers composites only sequentially: accept reduction A, restart, accept reduction B, restart. This is order-dependent. A composite reduction `A ∘ B` that is jointly feasible may be unreachable by any sequential greedy path, because accepting A changes the value assignment that the projection heuristic uses when testing B, and that projected assignment may not fail the property even though some point in the new fibre does.

The categorical operation underlying this composition is the **pushout** in the category of trace structures. That category is a **poset** under structural inclusion: `T' ≤ T` when `T'` can be obtained from `T` by deleting spans. In any poset viewed as a category, the pushout of two reductions `r1: T → T1` and `r2: T → T2` from a common source is their join — the smallest `T'` that both `T1` and `T2` are at or below. For non-overlapping deletions the join is simply the structure with both span sets removed: the deleted positions are disjoint, so applying `removeSubranges` on the union of both range sets commits both reductions without conflict. The universal property of the join proves correctness: the composed structure is the *smallest* consistent with both reductions having been applied, and any trace structure that satisfies both reductions individually is at or below it.

**Implementation.** The composition law is exploited in Phase 1b (structural deletion) via `MutationPool`. After the sequential adaptive loop exhausts without accepting any candidate, `MutationPool.collect` gathers individual deletion candidates from the already-populated span cache across all scope × slot combinations. It returns up to 20 individuals ranked by deleted length. `MutationPool.composePairs` then tests all disjoint pairs — up to 190 compositions from C(20, 2) — filtering out any pair where a span from one entry overlaps a span from the other. The composed candidate applies `removeSubranges(RangeSet)` once, which is the canonical pushout of the two reduced structures. Individuals and pairs are merged and sorted by total deleted length before testing; the first accepted candidate commits.

The mutation pool is a fallback: the sequential adaptive loop runs first and handles the common case of independently-accepting candidates. The pool activates only when the loop finds nothing, addressing the composites that sequential search cannot discover. It is capped at `sequence.count ≤ 500` to bound span-cache traversal cost.

This applies differently across the three sub-phases. **Structural deletion (Phase 1b)** is the natural fit and the only sub-phase where the pool is currently active. Non-overlapping deletion spans compose exactly by union, and the pool handles both single-scope and cross-scope pairs. **Branch simplification (Phase 1a)** correctly remains a sequential gate: a branch promotion replaces a branch entry and its unchosen alternatives with the content of one alternative, which can have an entirely different length and internal topology — composing two promotions is genuinely complex, and the restart-on-success pattern is correct there. **Foliage (Phase 2)** iterates leaf positions individually; position-stability within a fixed structure means each position can be minimised in isolation, and the sequential per-leaf-range pass already discovers all independent value reductions.

### 4.2 Uniqueness of Cartesian Lifts — Implemented

When Phase 1 proposes a structural reduction, it needs a value assignment for the new fibre. The `ReductionMaterializer` in guided mode computes `g*`, projecting the old value assignment forward through a guided replay using a three-tier resolution: prefix carry-forward, fallback tree, then PRNG (Dagnino & Gavazzo, LMCS 20:2, 2024).

The uniqueness law (Jacobs 1999, §1.1, Proposition 1.1.4) says that any two cartesian lifts of the same base morphism to the same object are uniquely isomorphic within the fibre. Since the fibre in Bonsai's setting is a product space — a value assignment is just a tuple of values — "unique up to unique isomorphism" collapses to plain uniqueness. There is exactly one canonical projection of the old value assignment into the new fibre, and the guided materializer computes it. A second guided attempt would produce the same result. This validates the current design of doing exactly one guided attempt before falling back to PRNG.

The interesting implications emerge when the guided attempt fails to find a failing point. At that point the unique canonical lift has been tried and did not preserve the failure. Three situations are now possible.

**The failure is value-sensitive.** The property fails for some point in the new fibre, but not at the canonical projection. The failing point requires specific values that the projection heuristic did not reproduce. PRNG retries are sampling the fibre looking for this point — they are productive.

**The structural reduction eliminates the failure.** No point in the new fibre fails the property. The failure existed in the old fibre because of structural conditions that the reduction removes. PRNG retries will all pass — they are sampling a fibre that contains no witnesses.

**The regime is unknown.** The simplest-values probe is rejected in exact mode because a value falls outside its valid range in the new structure. The regime cannot be determined without further information.

**Implementation.** The regime detector runs in Phase 1c (`runJointBindInnerReduction`) between Tier 1 (guided replay) and Tier 2 (PRNG retries), and only when Tier 1 finds no failing candidate. A simplest-values probe is constructed from the current best sequence by replacing each value entry with `ZeroValueEncoder.simplestTarget(for:)` — zero for integers, the minimum of the valid range for unsigned types, and so on. The probe is materialised in exact mode.

Three outcomes result. **Elimination regime**: the probe fails the property — the failure is structural, not value-sensitive. The probe is accepted directly (it is already shortlex-minimal relative to the canonical lift), and the four PRNG retries are skipped entirely. **Value-sensitive regime**: the probe passes the property — specific values are required to witness the failure. The four PRNG retries proceed. **Unknown regime**: the probe is rejected because a value is out of range in exact mode. The regime cannot be determined, and retries proceed as before.

The cost of the probe is one materialisation. In the elimination regime it saves four (one per avoided PRNG retry). The break-even point is reached whenever more than one in four Phase 1c candidates is in the elimination regime.

### 4.3 The Cocartesian Direction — Scaffolded, Not Yet Enabled

Bonsai uses only the cartesian direction — the `ReductionMaterializer` in guided mode computes `g*`, projecting the current value assignment into the new fibre when a structural reduction is proposed. The cocartesian direction `g!` is the dual: given a value assignment in the smaller fibre, find the canonical element in the original fibre that maps to it. The adjunction `g! ⊣ g*` (Jacobs 1999, §9.1, Lemma 9.1.2; §1.9, Proposition 1.9.8) connects the two: the counit `ε: g! ∘ g* → id` captures the information loss of the round-trip — project into the new fibre and embed back, and you get something that is ≤ the original in shortlex order.

This is directly relevant to the **unknown regime** identified in Section 4.2. When the simplest-values probe is rejected in exact mode, the regime cannot be determined and retries proceed conservatively. The cocartesian direction suggests a more principled alternative: apply `g!` to the simplest value assignment in the new fibre to obtain its canonical embedding in the original fibre, and compute the shortlex distance between that embedding and the current best trace. A large distance indicates that the structural reduction is lossy — the current trace does not project cleanly into the new fibre — and the failure is unlikely to survive. A small distance indicates a transparent reduction where the trace maps faithfully, which combined with the rejected exact probe suggests the failure depends on values outside the new structure's valid ranges, supporting the elimination regime conclusion.

In adjunction terms, the elimination regime is where `g! ∘ g*` is near the identity — the structural reduction is essentially lossless. The value-sensitive regime is where `g!` and `g*` diverge — specific values are needed that the canonical projection did not reproduce.

Concretely, computing `g!` means: run the generator with a minimal value assignment for the new structure, observe which original-structure positions those values correspond to, and construct the embedding. The cost is one additional materialisation — the same as the current regime detector probe.

**The counit test.** The regime classification reduces to testing whether the counit `ε: g! ∘ g* → id` is the identity in the fibre. Since the fibre is a product space, this is a coordinatewise check: compute `g*(e)` (the canonical projection), then `g!(g*(e))` (the round-trip embedding), and compare with `e` at each coordinate. Coordinates where the round-trip fails to recover the original value are points of information loss. If there are none, the reduction is transparent and the elimination regime applies. If there are some, the reduction is lossy and retries are warranted.

**Implementation status.** A code scaffold for the cocartesian computation exists as a commented-out block in `runJointBindInnerReduction`, attached to the unknown-regime branch. It is not yet enabled because the frequency of the unknown regime (probe rejection in exact mode) has not been measured in practice. If rejections are rare, the additional materialisation per unknown-regime candidate offers no meaningful benefit. The scaffold will be evaluated once instrumentation data on `bonsai_regime_probe` events establishes whether the unknown regime is common enough to warrant the extra cost.

---

## 5. The Kleisli Tower and Phase Factorisation

Each `_bind` in a generator creates a data-dependent chain: the inner generator produces a value, and that value determines the structure of the bound generator downstream. In the fibred setting, this is a **Kleisli composition step** — the bound generator's fibration depends on the inner's output. Nested binds create a **Kleisli tower**: bind A produces a value that determines bind B's structure, which produces a value that determines bind C's structure, and so on. The `BindSpanIndex` represents this tower explicitly: each `BindRegion` records the inner and bound ranges of a single bind, and `bindDepth(at:)` computes the nesting level at any position by counting enclosing bound ranges. The `ChoiceDependencyGraph` exposes the tower's dependency edges via `bindInnerTopology()`, which returns the bind-inner nodes in topological order.

### 5.1 Cartesian-Vertical Factorisation

In any fibration with a cleavage, every morphism `f: e' → e` in the total category factors as a cartesian morphism followed by a vertical morphism (Jacobs 1999, §1.4): first reindex along the base morphism `p(f)` to land in the correct fibre, then adjust within that fibre. This factorisation is unique given the cleavage.

BonsaiScheduler's two-phase pipeline is an instance of this factorisation:

- **Phase 1** (structural minimisation) is the **cartesian factor**. It changes the base point of the fibration — the trace structure. Branch simplification (1a) replaces a branch with one of its alternatives, altering the choice-point topology. Structural deletion (1b) removes spans, shrinking the base. Joint bind-inner reduction (1c) reduces the controlling values that determine downstream structure — these are base coordinates in the Kleisli tower, because changing an inner value changes which fibre the bound content lives in.

- **Phase 2** (value minimisation) is the **vertical factor**. It operates within the fibre above the base point that Phase 1 has fixed. The DAG leaf pass and the contravariant depth sweep both modify only non-controlling values — they cannot change the trace structure. The `StructuralFingerprint` guard between phases detects any accidental structural change during Phase 2 — a violation of the factorisation — and forces a restart from Phase 1.

The cleavage in Bonsai's fibration is the `ReductionMaterializer` in guided mode: given a structural reduction `g: T' → T` in the base, the materializer computes the canonical projection `g*(e)` by replaying the old value assignment against the new structure. This cleavage is well-defined in the reduction direction (projecting away deleted coordinates), which is the only direction the algorithm uses. The reverse direction — adding structure — would require choosing canonical values for new choice points, and the choice between `semanticSimplest` and PRNG makes the cleavage non-canonical there. This asymmetry is relevant to the cocartesian direction (Section 4.3) but does not affect the implemented reduction path.

Hermida (1999, Theorem 4.3) proves a stronger result: adjunctions in the 2-category **Fib** factor into cartesian and vertical components. If the scheduling process were formalised as an adjunction between the space of reduction strategies and the space of reduced traces, Hermida's theorem would give a canonical factorisation at the adjunction level, not just the morphism level. Working out whether such an adjunction exists is future work.

### 5.2 The Kleisli Tower within Phase 2

The vertical factor is not internally flat. The Kleisli tower reappears inside Phase 2 as a chain of nested fibrewise adjustments, each conditioned on the level above.

The contravariant sweep in `runFibreDescent` iterates bind depths from the maximum downward: depth *d*, then *d* − 1, and so on to depth 1. At each level, value encoders reduce the bound-content values at that depth while holding all upstream structure fixed. This traversal order is dictated by the Kleisli tower's dependency direction: a bound value at depth *d* may depend on a controlling value at depth *d* − 1, so reducing depth *d* first ensures that upstream reductions at shallower depths do not invalidate work already done at deeper levels.

This mirrors the Phase 1 → Phase 2 ordering at a finer grain. By the same dominance argument (Section 2), the contravariant sweep exhausts deeper (more dependent) levels before shallower (more controlling) ones, ensuring no accepted reduction is invalidated by a later change to a coordinate it was conditioned on.

---

## 6. Summary

Bonsai is correctly described as alternating minimisation over a fibred trace space, with a phase ordering justified by the structural dominance theorem. The formal home for this structure is Grothendieck fibrations and their associated laws.

Three laws from that theory have been examined:

- **Composition** (Section 4.1) motivates exploiting the pushout law for non-overlapping deletions. This is implemented in Phase 1b as `MutationPool`: after the sequential adaptive loop exhausts, the pool collects up to 20 individual deletion candidates from the span cache, composes up to 190 disjoint pairs, and tests the full ranked pool. Branch simplification correctly remains a sequential gate; Phase 2 leaf-position minimisation is already position-stable and does not require a pool.

- **Uniqueness** (Section 4.2) motivates budget-sensitive retry allocation in Phase 1c. This is implemented as a three-regime probe between Tier 1 (guided replay) and Tier 2 (PRNG retries): build a simplest-values candidate from the current sequence; if the probe witnesses the failure, accept it and skip four retries (elimination regime); if it passes, the failure is value-sensitive and retries proceed; if it is rejected in exact mode, the regime is unknown and retries proceed conservatively.

- **The cocartesian direction** (Section 4.3) `g!`, dual to the `g*` that the `ReductionMaterializer` computes, provides the canonical embedding of a new-fibre value assignment back into the original fibre. The adjunction `g! ⊣ g*` could sharpen the unknown-regime branch of the regime detector: compute `g!(semanticSimplest)` and measure shortlex distance to decide whether the unknown probe rejection signals a lossy reduction (skip retries) or a transparent one (proceed). A code scaffold exists but is not yet active; the decision to enable it depends on measured frequency of the unknown regime in practice.

Beyond the three laws, the **Kleisli tower structure** of bind-depth chains (Section 5) connects BonsaiScheduler's two-phase pipeline to the cartesian-vertical factorisation of morphisms in a fibration (Jacobs 1999, §1.4): Phase 1 is the cartesian factor, Phase 2 is the vertical factor, and the decomposition is canonical given the cleavage. The same dependency-respecting ordering reappears within Phase 2 as the contravariant depth sweep, which processes bind depths from the maximum downward to avoid invalidating dependent reductions.

---

## References

- Ghani, N., Johann, P., & Fumex, C. (2012). Generic fibrational induction. *Logical Methods in Computer Science*, 8(2:12), 1–27.
- Hermida, C. (1999). Some properties of **Fib** as a fibred 2-category. *Journal of Pure and Applied Algebra*, 134(1), 83–109.
- Jacobs, B. (1999). *Categorical Logic and Type Theory*. Studies in Logic and the Foundations of Mathematics, vol. 141. North-Holland, Elsevier.
- Sepúlveda-Jiménez, A. (2026). Categories of optimization reductions. Preprint, January 2026.
- Tseng, P. (2001). Convergence of a block coordinate descent method for nondifferentiable minimization. *Journal of Optimization Theory and Applications*, 109(3), 475–494.
- Dagnino, F., & Gavazzo, F. (2024). A fibrational tale of operational logical relations: Pure, effectful and differential. *Logical Methods in Computer Science*, 20(2).
