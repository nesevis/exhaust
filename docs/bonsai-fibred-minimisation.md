# Bonsai as Alternating Minimisation over a Fibred Trace Space

An analysis of the categorical structure underlying BonsaiScheduler's two-phase pipeline, its relationship to Grothendieck fibrations, and three opportunities from that theory that the current implementation does not fully exploit.

---

## 1. The Fibred Structure of Trace Space

An execution trace records every random decision the generator made: which choices were taken, what values were chosen, and which values controlled the structure of subsequent choices. This trace space has a natural two-level structure.

The **trace structure** is the shape of an execution: how many choice points exist, which ones are controlled by an earlier value, and what domain each choice point draws from. The trace structure is fully determined by the values at controlling positions — changing any non-controlling value leaves the structure unchanged.

The **value assignment** is the concrete values chosen at each point within a fixed trace structure. For a given structure, the value assignment ranges over the Cartesian product of each choice point's domain.

This gives the trace space a **fibred structure**: the set of all trace structures is the base, and above each structure sits a fibre — the set of all value assignments compatible with that structure. The total trace space is the union of all fibres across all base points. Moving within a fibre (changing values) never changes the base point. Moving between fibres (changing structure) replaces the fibre entirely.

---

## 2. Bonsai as Alternating Minimisation

BonsaiScheduler reduces a failing trace by alternating between two phases until neither makes progress.

**Phase 1** minimises the base: it removes choice points, simplifies branch structure, and jointly reduces the controlling values that determine how many downstream choices exist and what domains they draw from. A smaller base point means a strictly shorter choice sequence — fewer coordinates in the fibre above it.

**Phase 2** minimises the value assignment within the base point that Phase 1 has fixed. With the structure held constant, the problem has fixed dimensionality and fixed domains; Phase 2 applies coordinate descent (binary search, zero encoders, float reduction) across the leaf positions.

This is **alternating minimisation** over the fibred space: alternate between minimising the base and minimising within the fibre, with each phase holding the other fixed.

The phase ordering is not a heuristic. Value changes are fibre-local — they cannot change which base points are structurally reachable, only which ones the projection heuristic manages to discover. Structural changes can invalidate value work by eliminating choice points or shrinking domains. Therefore exhausting structural reductions before value reductions reaches an equal or smaller base point than any interleaving. The structure-before-value ordering is the unique ordering that cannot be improved upon with respect to achievable base size.

---

## 3. Grothendieck Fibrations

The fibred structure of trace space is an instance of a **Grothendieck fibration** — a functor `p: E → B` from a total category `E` to a base category `B`, where every base morphism can be lifted to a **cartesian morphism** in the total category.

A morphism `f: e' → e` in `E` is cartesian over `g: b' → b` in `B` if it is the universal lift of `g`: any other morphism into `e` that factors through `g` below factors through `f` above, uniquely. Cartesian morphisms are the tightest possible lifts — they add no information beyond what the base morphism dictates.

`p` is a Grothendieck fibration if for every object `e` and every base morphism `g: b' → p(e)`, a cartesian lift of `g` to `e` exists. This guarantees that every structural reduction (a morphism in the base) can be lifted to a trace transformation (a morphism in the total trace space) in a canonical way.

The key laws that follow are:

1. **Existence**: cartesian lifts always exist.
2. **Uniqueness**: any two cartesian lifts of the same base morphism to the same object are uniquely isomorphic within the fibre. The canonical lift is essentially unique.
3. **Composition**: the composite of two cartesian morphisms is cartesian.
4. **Reindexing**: each base morphism `g: b' → b` induces a reindexing functor `g*: E_b → E_{b'}` carrying value assignments from the old fibre into the new one. These functors compose (up to natural isomorphism): `(g ∘ f)* ≅ f* ∘ g*`.

A fibration can also carry **cocartesian lifts** — the dual of cartesian lifts. Where a cartesian lift pulls a value assignment from the old fibre into the new one (`g*`), a cocartesian lift pushes in the opposite direction (`g!`): given a value assignment in the smaller fibre, find the canonical element in the original fibre that maps to it. A functor that has both cartesian and cocartesian lifts is a **bifibration**, and the two operations form an adjunction `g! ⊣ g*` — the image along `g` is left adjoint to reindexing along `g`.

---

## 4. Three Opportunities Bonsai Does Not Fully Exploit

### 4.1 Composition of Cartesian Morphisms

Phase 1 commits one structural reduction at a time and restarts from the top of the sub-phase loop on every acceptance. The composition law says that a sequence of structural reductions composes into a single valid structural reduction — if `f` is cartesian over `g` and `f'` is cartesian over `g'`, then `f ∘ f'` is cartesian over `g ∘ g'`.

The current greedy restart strategy discovers composites only sequentially: accept reduction A, restart, accept reduction B, restart. This is order-dependent. A composite reduction `A ∘ B` that is jointly feasible may be unreachable by any sequential greedy path, because accepting A changes the value assignment that the projection heuristic uses when testing B, and that projected assignment may not fail the property even though some point in the new fibre does.

The composition law motivates replacing the relay race of individual attempts with an orchestration of mutations. Encoder results are framed as tree modifications rather than full candidate sequences. Tree modifications compose naturally — node references are stable under other deletions, and conflicts (one modification targeting a descendant of a node being deleted) resolve unambiguously in favour of the ancestor. Each sub-phase becomes a source of candidate modifications rather than a self-contained gate.

The categorical operation underlying this composition is the **pushout** in the category of trace structures (Bakirtzis, Savvas & Topcu, JMLR 26, 2025, Theorem 19). Given the current structure `T` and two independent reductions `r1: T → T1` and `r2: T → T2`, their composition is the pushout `T1 ∪_T T2` — the structure obtained by gluing `T1` and `T2` along their shared ancestor `T`. Non-overlapping deletions compose by pushout exactly: their effects touch disjoint parts of `T`, so the pushout is simply the structure with both removed. The ancestor-wins resolution rule for overlapping modifications is the universal property of the pushout: there is a canonical and unique morphism from `T1 ∪_T T2` into any further reduction that both `T1` and `T2` map to, which corresponds to the ancestor deletion subsuming the descendant deletion. This universal property also proves correctness of the composition: the pushout is the *smallest* structure consistent with both reductions having been applied, with no information added beyond what each individual reduction dictates.

The procedure is: run all encoders (cheap) to collect candidate modifications; compose pairs from the top-K candidates by estimated shortlex rank (also cheap, since shortlex impact can be estimated from modification metadata without materialisation — a deletion of a known span length, a value substitution at a known position); sort the full candidate pool by estimated shortlex rank; then materialise and test candidates in order, committing the first one for which the property still fails and moving to the next if it passes. The restart-on-success loop mostly disappears — combinations that previously required sequential rounds of greedy search appear directly in the pool.

Generating candidate modifications is cheap relative to materialisation, so the pool can be generated liberally. The bounding constraint is on pool size, not generation cost. Composing all pairs from the top-K individual candidates is sufficient: with K=20, the pool contains at most 20 individual candidates and 190 pairwise compositions — 210 total, all ranked and ready before the first materialisation. Triples offer diminishing returns relative to the list growth and are not worth generating.

This applies differently across the three sub-phases.

**Foliage (Phase 2) and structural deletion (Phase 1b)** are the natural fit. Value reductions do not shift positions — a value entry stays at the same index regardless of what value it holds — so position stability is not an issue at all. Deletion candidates are also composable: non-overlapping spans do not interact, and the tree representation handles nested cases. In both cases the mutations are homogeneous and the composition law applies cleanly.

**Branch simplification (Phase 1a)** is the exception. A branch promotion is not a deletion — it replaces a branch entry and its unchosen alternatives with the content of one alternative, which can have an entirely different length and internal topology. Composing two promotions is genuinely complex, and the restart-on-success pattern is correct there: accepting a promotion changes what branch structure is visible, which changes what the next promotion can target. The restarts are not inefficiency — they are the algorithm responding to newly revealed structure. Branch simplification should remain a sequential gate.

### 4.2 Uniqueness of Cartesian Lifts

When Phase 1 proposes a structural reduction, it needs a value assignment for the new fibre. The current materializer projects the old value assignment forward through a guided replay, then falls back to salted PRNG retries (up to four attempts in Phase 1c) when the guided projection does not fail the property.

The uniqueness law says that any two cartesian lifts of the same base morphism to the same object are uniquely isomorphic within the fibre. Since the fibre in Bonsai's setting is a product space with no non-trivial internal structure — a value assignment is just a tuple of values — "unique up to unique isomorphism" collapses to plain uniqueness. There is exactly one canonical projection of the old value assignment into the new fibre, and the guided materializer computes it. A second guided attempt would produce the same result. This validates the current design of doing exactly one guided attempt before falling back to PRNG.

The interesting implications emerge when the guided attempt passes the property. At that point the unique canonical lift has been tried and did not preserve the failure. Two situations are now possible.

**The failure is value-sensitive.** The property fails for some point in the new fibre, but not at the canonical projection. The failing point requires specific values that the projection heuristic did not reproduce. PRNG retries are sampling the fibre looking for this point — they are productive.

**The structural reduction eliminates the failure.** No point in the new fibre fails the property. The failure existed in the old fibre because of structural conditions that the reduction removes. PRNG retries will all pass — they are sampling a fibre that contains no witnesses, and no amount of sampling will find one.

Bonsai currently allocates four PRNG retries per candidate without distinguishing these two situations. In the second case that budget is guaranteed waste. The uniqueness law clarifies why: once the canonical lift has passed, retries are not searching for a better projection — the canonical projection is the unique best one and it already failed. They are asking a different question entirely: does *any* point in this fibre fail? That is a sampling problem. Framing it that way opens the door to smarter strategies: after the canonical lift passes, probe the new fibre using the semantically simplest value assignment for each position — zero for integers, empty for collections, and so on. If that also passes, the signal is strong: neither the already-reduced canonical values nor the simplest possible values witness the failure in the new fibre, and the reduction is likely in the second regime. Abandon it and redirect the budget. If the probe fails, the first regime applies and the retries are warranted.

The cost of each probe is dominated by materialization, not property evaluation. The regime detector therefore costs one additional materialization and saves four (one per avoided PRNG retry) in the elimination regime. The break-even point is reached whenever more than one in four candidates is in the elimination regime.

### 4.3 The Unexploited Cocartesian Direction

Bonsai uses only the cartesian direction — the `ReductionMaterializer` in guided mode computes `g*`, projecting the current value assignment into the new fibre when a structural reduction is proposed. The cocartesian direction `g!` is entirely absent.

The cocartesian lift `g!` does the dual: given a value assignment in the smaller fibre, find the canonical element in the original fibre that maps to it. The adjunction `g! ⊣ g*` connects the two: the counit `ε: g! ∘ g* → id` captures the information loss of the round-trip — project into the new fibre and embed back, and you get something that is ≤ the original in shortlex order.

This is relevant to the regime detector described in Section 4.2. The current approach probes the new fibre with the semantically simplest value assignment. The cocartesian direction suggests a more principled alternative: apply `g!` to the simplest value assignment in the new fibre to obtain its canonical embedding in the original fibre, and compare that embedding to the current best trace. If the embedding is far from the current trace (large shortlex distance), the structural reduction is lossy — the current trace does not project cleanly into the new fibre, and the failure is unlikely to survive. If the embedding is close, the structural reduction is transparent and the projection is more likely to preserve the failure.

The adjunction also clarifies the relationship between the two regimes identified in Section 4.2. The value-sensitive regime corresponds to cases where `g!` and `g*` are far apart — the new fibre contains points that do not embed cleanly back to the current trace. The elimination regime corresponds to cases where `g! ∘ g*` is already near the identity — the structural reduction is essentially lossless and the current trace maps faithfully into the new fibre, but the failure does not survive because it depended on structural conditions that the reduction removes.

Concretely, computing `g!` requires knowing the canonical embedding of a new-fibre value assignment into the original fibre. In Bonsai's setting, this means: given a minimal value assignment (all positions at `semanticSimplest`) in the new structure, what is the "best" choice sequence in the original structure that would produce it? This is a replay in the forward direction — run the generator with the minimal values, observe which original-structure positions they correspond to, and construct the embedding. The cost is one additional materialisation, the same as the current regime detector probe.

---

## 5. Summary

Bonsai is correctly described as alternating minimisation over a fibred trace space, with a phase ordering justified by the structural dominance theorem. The formal home for this structure is Grothendieck fibrations and their associated laws.

Three opportunities from that theory are not yet exploited:

- **Composition** motivates replacing sequential sub-phase gates with a ranked mutation pool: encoders produce tree modifications, pairs are composed from the top-K candidates, the pool is sorted by estimated shortlex rank, and candidates are materialised and tested in order until one commits. Foliage and structural deletion participate naturally; branch simplification correctly remains a sequential gate. The composition of two reductions is a pushout in the category of trace structures (Bakirtzis, Savvas & Topcu, JMLR 26, 2025), whose universal property gives the ancestor-wins conflict resolution rule and proves that the composed reduction adds no information beyond what each individual reduction dictates.
- **Uniqueness** motivates budget-sensitive retry allocation: the canonical projection into a new fibre is unique, so PRNG retries are not searching for a better projection but sampling for any failing point in the new fibre. A lightweight regime detector — one additional materialization using the semantically simplest value assignment after the canonical lift passes — can identify when the new fibre contains no witnesses at all, saving four materializations per eliminated candidate.
- **The cocartesian direction** (`g!`, dual to the `g*` that the `ReductionMaterializer` computes) provides the canonical embedding of a new-fibre value assignment back into the original fibre. Bonsai has no equivalent. The adjunction `g! ⊣ g*` could sharpen the regime detector: compare `g!(semanticSimplest)` to the current best trace to measure how lossy the structural reduction is, and use that as a signal for whether the failure is likely to survive in the new fibre.
