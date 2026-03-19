# Proposal: Stall Cache and Lift Report for Bonsai's Reduction Pipeline

Constraint learning from binary search boundaries and materialiser resolution tiers, with implications for the fibred construction and the Sepúlveda-Jiménez reduction algebra.

---

## 1. The Problem

Every time fibre descent runs, each value encoder initialises its binary search from the reduction target (zero, range minimum, or semantic simplest). The encoder then spends probes rediscovering the failure surface boundary — the point where the property transitions from failing to passing as the value decreases. If fibre descent runs multiple times across cycles (which it does, after every successful base descent or relax-round), each run re-discovers the same boundaries from scratch.

The information is computed and then discarded. The binary search converges to a stall point — the smallest value at which the property still fails, given the current values of all other coordinates. That stall point is the most expensive piece of information the reducer produces per coordinate, and currently no subsequent cycle benefits from it.

---

## 2. The Proposal

Introduce a **stall cache**: a per-coordinate record of the last known failure boundary, keyed by coordinate index and direction.

### 2.1 What is cached

Each entry records:

- **Coordinate index** — which position in the choice sequence.
- **Direction** — floor (descent toward reduction target) or ceiling (ascent during redistribution).
- **Boundary value** — the stall point: the last value at which the binary search stalled because the next step toward the target was rejected by the property.
- **Structural generation** — the `StructuralFingerprint` generation counter at the time the boundary was recorded.

A **floor** entry means: "values below this were rejected when this coordinate was being reduced toward its target, with the structure and all other coordinates at their then-current values." A **ceiling** entry means: "values above this were rejected when this coordinate was being inflated as an absorber during redistribution."

### 2.2 How the cache is populated

When a `BinarySearchStepper` or `BinarySearchToSemanticSimplestEncoder` converges, the final interval boundary is written to the cache. No additional probes are required — the stall point is a byproduct of the encoder's normal operation.

When a `RedistributeAcrossValueContainersEncoder` or `RedistributeAcrossBindRegionsEncoder` stalls on the absorbing coordinate, the maximum accepted inflation is written as a ceiling.

### 2.3 How the cache is consumed

On the next fibre descent pass, each value encoder checks the cache before initialising its binary search:

- If a floor entry exists for this coordinate at the current structural generation, the binary search interval is initialised to `[cachedFloor, currentValue]` rather than `[reductionTarget, currentValue]`.
- If no entry exists, or the structural generation has changed, the search starts from the reduction target as before.

For redistribution encoders, a ceiling entry warm-starts the inflation search: the encoder knows not to propose absorber values beyond the cached ceiling.

### 2.4 Invalidation

**Conservative strategy (recommended for initial implementation):** Invalidate the entire cache on any structural acceptance — any change to the base point (branch simplification, structural deletion, bind-inner reduction). This is correct because a structural change alters the fibre, and stall points recorded in the old fibre have no guaranteed validity in the new one.

**DAG-aware strategy (future refinement):** Invalidate only the entries whose coordinates depend on the changed structure, as determined by the `ChoiceDependencyGraph`. A stall point at coordinate *i* is invalidated when any DAG ancestor of *i* changes. Coordinates with no dependency path to the changed structure retain their cached boundaries. This is correct because structural independence in the DAG means the coordinate's domain and the property's sensitivity to it are unaffected by the distant structural change.

**Materialiser-informed strategy (future refinement):** The `ReductionMaterializer` in guided mode knows exactly which coordinates were resolved by each of its three tiers: tier 1 (exact carry-forward from the old trace), tier 2 (fallback tree substitution), and tier 3 (PRNG). A coordinate resolved by tier 1 was not affected by the structural change — its value carried forward unchanged, and if the structural change was distant, the failure surface at that coordinate is likely unchanged. A coordinate resolved by tier 2 or 3 had its value replaced — the old value didn't fit the new domain. This gives a finer invalidation criterion than DAG-awareness: evict only entries for coordinates resolved by tier 2 or 3, retain entries for tier-1 coordinates. This is the most precise invalidation possible without running the property, because it uses the materialiser's actual computation rather than a structural approximation of it. See Section 5 for the full analysis.

**Intra-fibre invalidation:** When a value encoder accepts a new value for coordinate *j*, stall points at coordinates that the property *might* couple with *j* could be invalidated. However, since coupling is opaque (it lives in the property, not the generator), the conservative choice is to leave other coordinates' entries intact. The worst case is that a warm-started search begins from a stale floor that is no longer the true boundary — the encoder will discover this within one or two probes (the first candidate below the stale floor will be accepted, and the search continues normally). Stale entries cost at most a few wasted probes; they never cause incorrect results.

---

## 3. Expected Impact

### 3.1 Probe savings

The binary search encoders converge in O(log(range)) probes per coordinate. For a 64-bit integer, that is up to 64 probes. A warm start from a cached floor skips the probes between the reduction target and the cached boundary. If the true boundary hasn't moved (common after a relax-round that perturbed distant coordinates), the savings are the full O(log(range)) — the encoder confirms the cached floor in one probe and terminates.

The savings multiply across cycles. A typical reduction run may cycle through fibre descent 5–15 times (once per successful base descent, plus restarts after relax-rounds). Each cycle currently re-discovers all boundaries. With the cache, only the first cycle pays the full discovery cost; subsequent cycles pay at most a confirmation probe per coordinate.

### 3.2 Where the savings are largest

- **After relax-rounds.** The relax-round perturbs one or two coordinates and then runs a full prune + train pass. The train pass (fibre descent) currently rediscovers all boundaries. With the cache, only the perturbed coordinates (and their DAG dependents, under DAG-aware invalidation) need fresh searches.
- **After localised structural changes.** A structural deletion that removes a single span invalidates boundaries only for coordinates within or dependent on that span. Under DAG-aware invalidation, distant coordinates retain their warm starts.
- **In generators with many independent coordinates.** A generator producing a list of 50 independent integers has 50 coordinates that are pairwise independent in the DAG. A structural change to one element invalidates only that element's boundary; the other 49 retain their caches.

### 3.3 Where the savings are smallest

- **Generators with a single bind depth and few coordinates.** The binary search cost per coordinate is already low, and the cache overhead (one dictionary lookup per encoder invocation) approaches the savings.
- **Properties that are highly sensitive to value interactions.** If every coordinate is coupled to every other by the property, each acceptance at one coordinate shifts the boundary at all others, making cached floors stale immediately. The encoder recovers in a few probes (the stale floor is too high; the search discovers the new, lower floor quickly), but the warm start provides minimal benefit.

---

## 4. Implications for the Fibred Construction

### 4.1 The stall cache as a partial section of the failure surface

In the fibred setting, the failure surface is a subset of the total space — the set of all (structure, values) pairs where the property fails. The projection of this surface onto any single coordinate axis, holding all other coordinates fixed, is an interval (or union of intervals) in that coordinate's domain. The stall point is an empirical observation of one endpoint of that projection.

A collection of stall points across all coordinates is a **pointwise sketch** of the failure surface's intersection with the current fibre. It describes, for each axis independently, where the surface's boundary lies. This is not a full description — the surface may have complex multi-coordinate structure that per-axis boundaries don't capture — but it is the most detailed description of the constraint surface that the reducer can extract without piercing the property's opacity wall.

In fibration terms: the stall cache is a **partial section** of the failure surface fibration — not the fibration of trace space, but the derived fibration whose base is the parameter space and whose fibres are the per-coordinate failure intervals. Each cached floor is a point in this derived fibration. The cache as a whole approximates a section — a coherent assignment of boundary values across coordinates. The approximation is imperfect because the entries are recorded at different times (different values of the non-cached coordinates), so they don't form a true section in the categorical sense. But they form a pragmatic one: a best-available estimate of the failure boundary that improves with each cycle.

### 4.2 Interaction with the cartesian-vertical factorisation

The factorisation says: first change the base (Phase 1), then adjust within the fibre (Phase 2). The stall cache operates entirely within Phase 2 — it records and reuses information about the fibre's internal structure. It does not cross the phase boundary.

However, the cache's **invalidation** is triggered by Phase 1. A structural acceptance changes the base point, which replaces the fibre entirely. Stall points recorded in the old fibre are meaningless in the new one. The conservative invalidation strategy (clear everything on structural acceptance) respects the factorisation by treating the phase boundary as an information barrier: nothing learned within one fibre is assumed to transfer to another.

The DAG-aware invalidation strategy is more nuanced. It exploits the fact that the fibration is not monolithic — it has internal structure (the Kleisli tower) that makes some fibre coordinates independent of some base changes. A structural deletion at one end of the ChoiceSequence does not reshape the domain of a coordinate at the other end if there is no dependency path between them. This selective invalidation respects the fibration's local structure: the cartesian lift of a localised base change only reindexes the coordinates that the base change affects, leaving the rest of the fibre unchanged.

### 4.3 The contravariant sweep and cache coherence

Phase 2's contravariant depth sweep processes bind depths from the maximum downward. Each depth level's stall points are recorded after the deeper levels have already been processed. This means the shallowest coordinates' stall points are the freshest — they were recorded last, with the most up-to-date values at all deeper coordinates. The deepest coordinates' stall points are the stalest — they were recorded first, when shallower coordinates had not yet been reduced.

On the next cycle, if no structural change has occurred, the contravariant sweep runs again from the deepest level. The deep coordinates' stall points are consumed first — and they are the stalest. If shallower coordinates were reduced in the previous cycle, the deep coordinates' boundaries may have shifted. The warm start will be slightly off, and the encoder will adjust in a few probes.

This staleness gradient is inherent to the sweep direction and cannot be eliminated without changing the sweep order (which the dominance argument prohibits). The practical impact is small: the stalest entries are at the deepest bind levels, which typically have the fewest coordinates and the smallest domains.

---

## 5. The Materialiser as Cartesian Lift

The `ReductionMaterializer` in guided mode is the mechanism that computes the cartesian lift in Bonsai's fibration. Given a structural reduction `g: T' → T` in the base and a current trace `e` in the total space, guided replay produces `g*(e)` — the canonical value assignment in the new fibre. But the materialiser currently operates as a black box: structural reduction in, candidate trace out. The fibration framework reveals that the materialiser produces information beyond the candidate itself — information that is currently computed and discarded, and that the stall cache is well-positioned to exploit.

### 5.1 The three resolution tiers as components of the lift

The materialiser resolves each coordinate in the new fibre through one of three tiers:

- **Tier 1 (prefix carry-forward):** the coordinate exists at the same position in both the old and new structures, and the old value fits the new domain. The value is carried forward unchanged. This is the *exact* component of the reindexing — the cartesian lift is faithful here.
- **Tier 2 (fallback tree):** the coordinate exists in the new structure but the old value doesn't fit (domain changed, position shifted). The materialiser substitutes from the fallback tree. This is the *approximate* component — the lift is informed by the old trace but cannot reproduce it exactly.
- **Tier 3 (PRNG):** the coordinate has no correspondent in the old structure. The materialiser generates a value randomly. This is the *random* component — the lift has no information from the old trace and is effectively sampling the fibre blind.

These tiers correspond to different degrees of information preservation in the reindexing functor `g*`. A purely tier-1 lift preserves all information. A purely tier-3 lift preserves none. The ratio of tier-1 to total coordinates is a **lift fidelity score** — a measure of how much of the old trace the structural reduction preserved.

### 5.2 Lift fidelity and the regime probe

The lift fidelity score answers the same question as the cocartesian counit test (Section 4.3 of the fibration document): "did this structural reduction preserve enough of the old trace that the failure is likely to survive?" But it answers it *before running the property* and at zero additional cost — the materialiser has already classified each coordinate during guided replay.

High fidelity (most coordinates tier 1) means the reindexing was nearly lossless. The canonical lift is close to the original trace, projected into the new fibre. The failure is likely to survive, and the guided attempt is worth testing.

Low fidelity (many coordinates tier 2 or 3) means the reindexing lost significant information. The candidate in the new fibre is distant from the original trace's projection. The failure may not survive. In this case, the regime probe's simplest-values test is less informative (the guided candidate was already semi-random), and the reducer might benefit from skipping the guided property evaluation entirely and proceeding directly to PRNG retries — sampling the fibre broadly rather than testing one low-confidence candidate.

This is a cheaper approximation of the cocartesian direction. The counit `ε: g! ∘ g* → id` measures information loss of the full round-trip. The fidelity score measures information loss of the forward direction alone. It doesn't compute `g!`, but it answers the same practical question: "is this lift likely to be useful, or should I sample instead?"

### 5.3 The lift report

The materialiser currently returns a candidate trace. The proposal is for it to additionally return a **lift report**: a per-coordinate record of which resolution tier was used. This is a lightweight addition — the materialiser already performs the tier classification internally to decide how to resolve each coordinate; the lift report simply makes this classification available to downstream consumers.

The lift report has three consumers:

**The regime probe** can use the aggregate fidelity score to decide whether the guided candidate is worth testing. Below a fidelity threshold, the guided evaluation is skipped and the reducer proceeds to PRNG retries. This saves one property evaluation per low-fidelity structural reduction — a meaningful saving in Phase 1c, where each bind-inner candidate triggers a guided replay.

**The stall cache** can use the per-coordinate tier classification for materialiser-informed invalidation (Section 2.4). Tier-1 coordinates retain their cached floors. Tier-2 and tier-3 coordinates have their entries evicted. This is finer than DAG-aware invalidation because it reflects what actually happened during the lift, not what the dependency structure says could have happened.

**The encoder selection logic** can use the tier distribution to inform budget allocation. A structural reduction with high fidelity is likely to preserve the failure and deserves a full value-minimisation pass in the new fibre. A structural reduction with low fidelity is a speculative probe into a largely unknown fibre — value minimisation may be premature until the property has been confirmed to fail somewhere in the new fibre.

### 5.4 Categorical interpretation

In fibration terms, the materialiser is the **cleavage** — the chosen system of cartesian lifts (Jacobs 1999, §1.3). A cleavage assigns to each base morphism a specific cartesian morphism in the total category. The lift report makes the cleavage's internal computation visible: it exposes how much of the cartesian morphism is structurally determined (tier 1) versus heuristically reconstructed (tier 2) versus arbitrary (tier 3).

The distinction between a faithful lift (high tier-1 ratio) and an unfaithful lift (high tier-3 ratio) has a categorical interpretation. A faithful lift is close to the *universal* cartesian morphism — it factors uniquely through any other lift of the same base morphism. An unfaithful lift contains arbitrary choices that could have been made differently — it is one of many possible lifts, and the specific choice is non-canonical. The uniqueness law (Section 4.2 of the fibration document) guarantees that any two cartesian lifts are isomorphic *within the fibre*, but the isomorphism may be non-trivial. A tier-3 coordinate is a coordinate where the particular choice within the isomorphism class is arbitrary.

In Sepúlveda-Jiménez's framework, the lift report enriches the decoder. The decoder is no longer a binary "produced a candidate / failed to produce a candidate" — it becomes a graded operation that reports the confidence of its output. A high-fidelity decode is a strong certificate that the encoder's structural mutation is compatible with the current failure. A low-fidelity decode is a weak certificate. The encoder selection logic (and the stall cache invalidation logic) can use this grading to make better-informed decisions.

### 5.5 Implications for the stall cache invalidation hierarchy

The three invalidation strategies now form a precision hierarchy:

1. **Conservative** (clear all on structural change): treats every structural acceptance as a complete fibre replacement. Correct, maximal information loss. No additional state required.
2. **DAG-aware** (selective eviction by dependency path): uses the `ChoiceDependencyGraph` to identify which coordinates *could* be affected. Correct, moderate information loss. Requires propagation of the changed structure's identity to the cache.
3. **Materialiser-informed** (selective eviction by resolution tier): uses the lift report to identify which coordinates *were actually* affected. Correct, minimal information loss. Requires the lift report from the materialiser.

Each strategy strictly refines the one above it. Conservative evicts everything; DAG-aware evicts a subset (coordinates reachable from the changed structure); materialiser-informed evicts a subset of that subset (coordinates that the materialiser couldn't carry forward exactly). The materialiser-informed strategy can never evict a coordinate that the conservative strategy would retain, and can never retain a coordinate that the DAG-aware strategy would evict.

The implementation path follows the same order: start with conservative (no additional state), measure the false invalidation rate, graduate to DAG-aware if the rate is high, and graduate to materialiser-informed if the lift report reveals that many DAG-reachable coordinates are in fact resolved by tier 1 and their eviction was unnecessary.

---

## 6. Implications for the Sepúlveda-Jiménez Framework

### 6.1 Stall points as grade annotations

In the reduction algebra, each encoder morphism carries a **grade** — a measure of approximation quality. The current grades are implicit: exact (guided decoder), bounded (PRNG retries with bounded count), speculative (relax-round). The stall cache introduces a new source of grading: each encoder invocation can be graded by whether it operates from a warm start (cached floor) or a cold start (reduction target).

A warm-started encoder is a **refined** version of its cold-started counterpart. It operates on a smaller search interval, consumes fewer probes, and is more likely to converge quickly. In Sepúlveda-Jiménez's terms, the warm-started encoder is a 2-cell that factors through the cold-started encoder — it dominates the cold start in both cost and precision, because it begins with strictly more information.

This suggests that the stall cache induces a **dynamic refinement** of the encoder hom-set. The initial cycle's encoders are cold-started (coarse grade). Subsequent cycles' encoders are warm-started (refined grade). The dominance lattice need not change — the refinement is within a single encoder across invocations, not between different encoders. But the grade structure becomes time-varying: the same encoder has different effective grades on its first and subsequent invocations.

### 6.2 Constraint learning as a decoder enrichment

The Sepúlveda-Jiménez framework separates encoders (structural mutations) from decoders (feasibility restoration). The stall cache sits between the two: it constrains the encoder's proposal space based on information gathered during previous decoding (property evaluation).

In the enc/dec framework, this is a **decoder-informed encoder** — the encoder consults historical decoding outcomes to restrict its proposals. The decoder itself (the `ReductionMaterializer` and the property oracle) is unchanged. The information flows backward: decoder outcomes → stall cache → encoder initialisation.

This backward flow is not part of Sepúlveda-Jiménez's current framework, which treats enc and dec as independent. But it is a natural extension: the stall cache is a **learned precondition** on the encoder, derived from the decoder's history. A principled treatment would extend the morphism structure to include a precondition annotation — a set of constraints that the encoder respects, derived from previous round-trips through the decoder. The grade would then incorporate not just the encoder's approximation quality but also the tightness of its learned preconditions.

### 6.3 Connection to the relax-round pattern

The relax-round (Sepúlveda-Jiménez §11.2) deliberately worsens the objective to escape a local minimum. After the relax-round, the standard two-phase pipeline re-reduces from the relaxed state. The stall cache interacts with this pattern in two ways:

**Before the relax-round:** The stall cache records the boundaries of the current local minimum. These boundaries are precisely the information that motivated the relax-round — fibre descent stalled because all coordinates are at their cached floors.

**After the relax-round:** The perturbation changes one or two coordinates, potentially shifting the failure surface. Under conservative invalidation, all cached floors are cleared, and the post-relaxation fibre descent rediscovers all boundaries from scratch. Under DAG-aware invalidation, only the perturbed coordinates and their dependents are cleared; independent coordinates retain their floors, giving the post-relaxation descent a partial warm start.

The DAG-aware strategy is more valuable here than elsewhere. A relax-round typically perturbs only 2 coordinates out of potentially dozens. Retaining the other coordinates' cached floors means the post-relaxation fibre descent spends its budget exploring the neighbourhood of the perturbation rather than re-establishing known boundaries at distant coordinates.

---

## 7. Analogy to CDCL Clause Learning

The stall cache is a weak form of conflict-driven clause learning (CDCL) adapted to the PBT setting.

| CDCL (SAT) | Stall cache (Bonsai) |
|---|---|
| Conflict clause: a conjunction of literals that is unsatisfiable | Floor entry: a per-coordinate lower bound on the failure surface |
| Learning: analyse the implication graph backward from a conflict to the first UIP | Learning: record the binary search's convergence point |
| Clause database: grows with conflicts, periodically garbage-collected | Stall cache: one entry per coordinate, invalidated on structural change |
| Unit propagation: a learned clause forces a variable assignment | No direct analogue (weak version: redistribution encoders avoid proposing pairs that violate both floors simultaneously) |
| Backtracking: undo assignments and choose a different branch | Phase 1 restart: structural change invalidates the fibre and all its cached boundaries |

The key difference is granularity. CDCL learns *relational* constraints (conjunctions of literals — "if x=1 and y=0 then z must be 1"). The stall cache learns *marginal* constraints (per-coordinate bounds — "coordinate 3 cannot go below 5"). Relational constraints would require observing which coordinate *combinations* cause rejection, which the property oracle doesn't reveal. The stall cache extracts the maximum learnable information from the binary search's convergence behaviour without any additional oracle queries.

A future extension — **pairwise stall analysis** — could learn relational constraints by decomposing rejected multi-coordinate changes. When a composite reduction (coordinates 3 and 7 both decreased) is rejected, test each coordinate's change independently. If coordinate 3's change is independently rejected but coordinate 7's is independently accepted, the stall cache records a floor for coordinate 3 and a "free" annotation for coordinate 7 (no floor constraint from this rejection). If both are independently accepted but the composite is rejected, record an **interaction annotation**: these coordinates are coupled by the property, and multi-coordinate encoders should treat them as a unit. This pairwise decomposition costs two additional probes per rejected composite but yields relational information that the current per-coordinate cache cannot capture.

---

## 8. Implementation Plan

### 8.1 Minimal viable version

**Data structure:** A dictionary `[Int: StallEntry]` keyed by coordinate index, where `StallEntry` holds `(direction: Direction, boundaryValue: UInt64, generation: UInt)`.

**Population:** At the end of `BinarySearchStepper.run()`, if the stepper converged (made at least one successful step before stalling), write the stall point to the cache.

**Consumption:** At the start of each value encoder's binary search, check the cache. If an entry exists at the current structural generation, use `cachedFloor` as the search lower bound instead of the reduction target.

**Invalidation:** Clear the entire cache in `acceptCandidate()` when `structureChanged == true`.

**Cost:** One dictionary read per encoder invocation per coordinate. One dictionary write per stall. One cache clear per structural acceptance. No additional property evaluations.

### 8.2 Instrumentation

Before implementing the cache, instrument the current reducer to measure:

- **Stall frequency:** How often does each binary search encoder stall (converge without reaching the reduction target)?
- **Stall stability:** When fibre descent runs again after a cycle, how often is the new stall point within ε of the previous one? This measures how much the failure surface moves between cycles.
- **Cycle count:** How many fibre descent passes occur per reduction run?

If stall frequency is low (most coordinates reach their target), the cache has little to cache. If stall stability is low (boundaries shift significantly between cycles), warm starts are rarely useful. If cycle count is low (fibre descent runs only once or twice), there are few opportunities to reuse cached boundaries.

The instrumentation would emit `bonsai_stall_cache` events with fields: `coordinateIndex`, `stallValue`, `previousStallValue` (if a prior entry existed), `stallDelta` (absolute difference), `structuralGeneration`, and `cycleNumber`. Analysis of these events across a test suite determines whether the cache is worth enabling.

### 8.3 DAG-aware invalidation (future)

Replace the dictionary clear with a selective eviction: on structural acceptance, query the `ChoiceDependencyGraph` for all coordinates reachable from the changed structure, and evict only those entries. Retain entries for coordinates with no dependency path to the change.

This requires the structural acceptance to carry information about *which* structure changed (which span was deleted, which bind-inner value was reduced), which the current `acceptCandidate` path already knows but does not propagate to the cache. The wiring is straightforward; the only question is whether the payoff justifies the added complexity, which the instrumentation data will answer.

### 8.4 Materialiser lift report and tier-informed invalidation (future)

Extend `ReductionMaterializer` to return a **lift report** alongside the candidate trace: a per-coordinate record of which resolution tier (1, 2, or 3) was used. The materialiser already classifies each coordinate internally during guided replay; the lift report makes this classification available to downstream consumers.

**Data structure:** An array `[ResolutionTier]` indexed by coordinate position in the new sequence, where `ResolutionTier` is `.exactCarryForward`, `.fallbackTree`, or `.prng`.

**Consumers:**

- **Stall cache invalidation:** On structural acceptance, evict only entries for coordinates resolved by tier 2 or 3. Retain entries for tier-1 coordinates. This replaces the conservative (clear all) or DAG-aware (clear reachable) strategies with the most precise invalidation available.
- **Regime probe:** Compute aggregate lift fidelity (tier-1 count / total coordinates). Below a threshold, skip the guided candidate's property evaluation and proceed directly to PRNG retries. Saves one property evaluation per low-fidelity structural reduction.
- **Encoder budget allocation:** A high-fidelity lift signals that the new fibre is structurally similar to the old one, warranting a full fibre descent pass. A low-fidelity lift signals that the new fibre is largely unknown, and value minimisation may be premature until the failure has been confirmed to exist in the new fibre.

**Cost:** One array allocation per materialisation (the tier classification is already computed; the cost is making it available rather than discarding it). The lift report is transient — it is consumed during the acceptance/invalidation step and not persisted across cycles.

---

## 9. Open Questions

1. **Cross-fibre transfer.** Can stall points from the old fibre ever be useful in the new fibre after a structural change? If a structural deletion removes a distant span that has no interaction with coordinate *i*, the failure surface at coordinate *i* is likely unchanged. The DAG-aware strategy exploits structural independence, but the property might couple coordinates that the DAG doesn't connect. Measuring false invalidation rates (entries evicted that would have been valid) would quantify the opportunity for less aggressive invalidation.

2. **Ceiling utility.** Floors are consumed by value encoders on every fibre descent pass. Ceilings are consumed only by redistribution encoders, which run once at the end of fibre descent. If redistribution is rare or usually succeeds on the first attempt, ceiling entries have low reuse value and could be omitted from the initial implementation.

3. **Interaction annotations.** The pairwise stall analysis (Section 7) could identify coupled coordinates that resist independent reduction. If the reducer learned which pairs are coupled, it could dynamically promote them to tandem-reduction targets without requiring the user to encode this knowledge in the generator. The question is whether the additional probes for decomposition are worth the information gained, given that most generators produce few coupled pairs.

4. **Stall cache as a termination signal.** If all coordinates are at their cached floors and no structural reductions are available, the reducer is at a local minimum. The stall cache makes this detectable in O(1) rather than requiring a full pass to confirm stalling. This could trigger the relax-round earlier, saving the budget currently spent on a fibre descent pass that confirms what the cache already knows.

5. **Lift fidelity threshold.** The regime probe could use the materialiser's lift fidelity score to skip low-confidence guided evaluations. But what is the right threshold? A fidelity of 1.0 (all tier 1) clearly warrants testing; a fidelity of 0.0 (all tier 3) clearly does not. The threshold depends on the property's sensitivity — some properties fail on nearly any value assignment (low sensitivity, low threshold is fine), while others require precise values (high sensitivity, high threshold needed). The threshold could be adaptive: start high (test only high-fidelity lifts), lower it when high-fidelity candidates are scarce, and track the acceptance rate at each fidelity level to calibrate. Alternatively, the existing regime probe (elimination vs value-sensitive vs unknown) already addresses this question — the lift fidelity score would supplement it with pre-oracle information rather than replace it.

6. **Discarded information beyond stall points.** The stall cache and lift report address two specific cases of information computed and discarded: binary search convergence points and materialiser resolution tiers. Are there other cases? The `MutationPool`'s rejection history (which span pairs were rejected as composites) carries information about which structural reductions interact destructively. The redistribution encoders' per-pair acceptance history carries information about which coordinates are coupled by the property. A systematic audit of discarded information across all encoders might reveal further caching opportunities beyond the stall cache.

---

## References

- Jacobs, B. (1999). *Categorical Logic and Type Theory*. §1.1–§1.5, §1.9, §9.1.
- Sepúlveda-Jiménez, A. (2026). Categories of optimization reductions. §7 (grades), §11.2 (relax-round), Def 15.3 (2-cell dominance).
- Marques-Silva, J. P. & Sakallah, K. A. (1999). GRASP: A search algorithm for propositional satisfiability. *IEEE Transactions on Computers*, 48(5), 506–521. (CDCL foundations.)
- Tseng, P. (2001). Convergence of a block coordinate descent method for nondifferentiable minimization. *JOTA*, 109(3), 475–494.
