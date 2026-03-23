# Reduction Planning: Structural Prediction and Validation

## Why Composition, Not Tactics

The original 20 encoders were hand-crafted tactics — each embedded both a search strategy (binary search, exhaustive enumeration, lockstep redistribution) and the structural context where it applies (leaf values, branch selectors, container spans, sibling pairs). When a new generator shape exposes a reduction gap, the response is a round trip to the library maintainer: diagnose the gap, design a new encoder, implement it, add an `EncoderName` case, wire it into the slot rotation, define dominance rules, test it. Every novel reduction shape requires bespoke code.

The compositional encoder algebra changes this by separating *where to search* from *how to search*. The CDG identifies structural positions (bind-inner nodes, fibre boundaries, dependency edges). The lift materializes candidate fibres without checking the property. The downstream encoder searches the fibre using a generic primitive — exhaustive enumeration, pairwise covering, binary search per coordinate. These are reusable components, not generator-specific tactics.

A new generator shape — deeper nesting, conditional binds, non-monotonic fibres — does not require a new encoder type. The composition discovers the structure at runtime through the CDG, materializes candidate fibres through the lift, and searches them with whatever downstream is appropriate for the fibre's size and parameter count. The planning framework parametrizes this selection (domain ratio picks the downstream, leverage orders the edges, budget allocation funds them), but the underlying machinery is the same generic composition.

This reframes the encoder design space. Instead of monolithic tactics, the primitives are role-agnostic composable encoders — probe strategies that work on any position range. The same encoder can serve in any of three roles:

- **Upstream role**: your probes propose fibres. Each probe changes the context for something downstream — the composition lifts the output before anyone searches in it.
- **Downstream role**: you explore inside a fibre someone else proposed. The fibre you see was produced by a lift from the upstream probe.
- **Standalone role**: no composition. Your probes are evaluated directly. Most encoders in the current pipeline operate here — Phase 2 value reduction, redistribution, relaxation.

These are positions in the pipeline, not properties of the encoder. `BinarySearchEncoder(configuration: .semanticSimplest)` does not know or care which role it is in. It binary-searches toward the semantic simplest value in whatever position range it was given. If that range is a bind-inner, the composition treats its output as a base change and lifts it. If that range is a leaf, the output is evaluated directly. The encoder did the same thing in both cases.

The composition wires a composable encoder to the upstream role and another to the downstream role. A new reduction capability is a new composable encoder — not a monolithic tactic that re-implements scheduling, convergence tracking, and dominance logic from scratch. The factory assigns encoders to roles based on CDG position: bind-inner nodes get the upstream role, fibre positions get the downstream role, everything else is standalone.

The formal structure behind the role decomposition is a Grothendieck opfibration (see "Fibrational Structure of the Encoder Algebra" below). In the algebra, the upstream role contributes the opcartesian (horizontal) component of the morphism and the downstream role contributes the vertical component. Every reduction step in a composition decomposes uniquely into these two components.

## The Signals

The CDG, ChoiceTree, and ChoiceSequence provide signals about the reduction landscape. The set is empirical — not derived from a completeness argument.

### Potential seventh signal: probe history

The property's internals are behind an opacity wall. But the reducer observes the property's boolean output at each probe. Non-monotone failure surfaces (where pass/fail alternates across a coordinate's range) defeat binary search: the search narrows to the last confirmed range and misses lower failures. Example: failure surface {0, 1, 3, 5, 6, 7, ...} with passes at {2, 4}. Binary search from 10 toward 0 converges at 5, missing floor 0.

**Detection.** The reducer's replay is deterministic — an unexpected result during binary search is never noise. Detect via `sawUnexpectedResult: Bool` on the stepper, harvested into the convergence cache. **Response.** Per-coordinate exhaustive scan of the remaining range, capped at ≤ 64 values. If binary search converged at floor 5, the remaining range is 0...4 (5 values, cheap). If binary search converged at floor 2³² on a 64-bit range, the remaining range is 0...2³² — exhaustive scan is impossible. Fall back to accepting the non-minimal floor with a diagnostic flag when the remaining range exceeds the cap. Joint non-monotonicity from inter-coordinate coupling is redistribution's domain. Rare in practice but simple to implement and prevents a subtle correctness issue.

### Signal classification

Computable (derivable from data held now, exact given model assumptions) vs inferential (requiring interpretation). "Computable" does not mean "always correct."

### Computable signals

**1. Domain ratio.** Reducing a bind-inner from `n` to `k` produces a downstream fibre of at least `(k+1)^count`. A lower bound when nested binds are present.

**2. Structural leverage.** `scopeRange.count` per CDG node.

**3. Fibre stability.** Per-coordinate check `currentValue < n`. Predicts coverage, not semantic stability. Search-based downstream encoders only.

**4. Property sensitivity.** All values at cached floors + no structural acceptance this cycle + property still fails → skip fibre descent. Conditional on cache freshness.

### Inferential signals

**5. Shortlex distance.** Tiebreaker only.

**6. Convergence correlation.** Weakest signal. Biases redistribution pair selection only.

## Budget Allocation

Greedy, not proportional. Partial coverage arrays waste every probe.

**Score: `leverage / requiredBudget`.** Required budget is the actual probe cost: fibreSize for exhaustive, IPOG estimate for pairwise (`max_domain² × ceil(log₂(num_params))`). NOT fibreSize — that is exponential in coordinates and systematically starves multi-coordinate edges.

A reliability factor (exhaustive = 1.0, pairwise < 1.0) could distinguish coverage guarantees, but there is no empirical basis for the pairwise reliability value. Measure it on the test suite first: for each edge where pairwise coverage runs, check whether the failure was found. The fraction is the reliability. Until measured, use reliability = 1.0 for both — no reliability penalty. Add the factor only after measurement establishes that pairwise misses failures at a measurable rate.

**Allocation order by score.** Give each edge its estimated required budget until the pool is exhausted. Skip edges that cannot get their minimum.

**Nested binds: two-phase allocation.** For edges where the downstream contains nested binds, the parameter count (and therefore IPOG budget) is unknown pre-lift. Allocate a "discovery budget" of one lift at the target upstream value (the smallest the encoder will try). The target value produces the best-case fibre (fewest parameters from nested binds in the common case where ranges shrink with the upstream value). Intermediate upstream candidates may produce larger fibres; the composition discovers this at lift time for each candidate and IPOG aborts individually if over budget.

The "smallest at target" claim is not safe for conditional nested binds that activate at intermediate values. A nested bind that activates at `n > 3` means `n = 4` has a larger fibre than `n = 0`. The discovery lift at the target sees the small fibre and the edge is scored on best-case cost. The early-abort feature handles the per-candidate cost overrun, but the edge's score overestimates its productivity for intermediate candidates. This is a best-case estimate — accurate for generators with monotonic fibre sizes, optimistic for generators with conditional nesting.

**Staleness after structural acceptance.** The scoring pass is a batch computation — stale after the first acceptance in the exploration leg. Within a CDG subtree, topological ordering guarantees that a shallow edge's acceptance changes the ranges for all deeper edges in the same subtree. Overlap is the common case, not rare. Fix: after a structural acceptance, re-score edges in the same subtree (scoped via `BindSpanIndex`). Re-scoring affects only the ordering of remaining unfunded edges. Budget already committed to funded-but-not-yet-started edges is not reclaimed — the funded edge keeps its priority position but unused probes flow to later edges at runtime (the edge self-terminates early and returns the remainder). This is a priority error (wrong execution order), not a probe waste error.

## Activation Regime

**Criterion: no structural acceptance from any phase in the current cycle.**

Steps 1–3 (fibre descent gating, domain ratio, leverage) are available from cycle 1. Step 1 first becomes active on cycle 2 or later — it requires the convergence cache to be populated, which happens after Phase 2 runs in cycle 1. Steps 2–3 are active from cycle 1 (they depend on the CDG and sequence, not the cache). Steps 4–5 activate after the first stall.

**Step 5 activation depends on user budget.** The prediction-validation loop needs multiple stall cycles to learn. The user's `ReductionBudget` determines `maxStalls` (`.fast` = 1, `.slow` = 8). At `.fast`, edges stay at "uncertain" and step 5 provides no value — only steps 1–4 run, with no skip gate. At `.slow`, the loop has enough cycles for promotion and demotion. Step 5 activates when the user's budget provides ≥ 3 stall cycles.

## The Prediction-Validation Loop

**Confidence states.** Structural / uncertain / empirical. Promotion requires three-region upstream diversity (low, middle, high thirds of the range). Scoped reset via `BindSpanIndex`.

**Decision point gate.** Step 5 requires both domain ratio decision accuracy > 70% AND stability prediction divergence < 0.2 for > 70% of edges. Each signal measured independently.

### Warm-start validation (implemented)

The warm-start validation fixes a pre-existing correctness issue in `KleisliComposition`, independent of the planning proposal. Implemented as a standalone bugfix. The validation lives in `runKleisliExploration` (the driver) — the composition exposes `pendingTransferOrigins` and `upstreamDelta`; the driver validates at `floor - 1` and calls `setValidatedOrigins`. See `docs/reduction-planning-implementation.md` for details.

**Problem: premature convergence.** A stale floor that still fails the property looks valid. The encoder converges to a non-minimal value.

**Fix.** Validate at `floor - 1`. If the property fails there, the floor is stale — discard all transferred convergence points and cold-restart. If the property passes, the floor is valid. At floor == rangeLowerBound, the floor is trivially valid — skip validation.

**Scope.** Search-based downstream encoders only.

**Upstream delta > 1.** Skip validation, cold-restart immediately.

**No skip gate without step 5.** The skip gate (< 0.3 → skip downstream) risks missing productive edges when the prediction is wrong. Without step 5's validation to catch and downgrade wrong predictions, the skip gate fires permanently on wrongly-predicted edges. At `.fast` budget (`maxStalls = 1`), no second chance. Step 4 without step 5 provides only cold-start/warm-start, not skip.

## Implementation Steps

The progression is a decision tree based on profiling data, not a fixed sequence.

### Step 1: Fibre descent gating (Signal 4) — implemented

Skip Phase 2 when all coordinates are at cached floors, no structural acceptance occurred this cycle, AND Phase 2 made no progress in the previous cycle. The stall condition prevents skipping when cross-zero or ZeroValue can still improve beyond cached binary search floors.

**Result.** Gates on stall cycles. Saves computational overhead (span extraction, encoder startup) but not property invocations — converged encoders already produce 0 probes. Fires on the FibreDescentGate test (7 of 9 cycles gated). Does not fire at `.fast` budget on tests where exploration invalidates the convergence cache each cycle.

### Step 2: Domain ratio at edge selection (Signal 1) — implemented, split on structural constancy

The prediction serves different purposes at different edges. The factory splits on `isStructurallyConstant`:

**Structurally constant edges** (fibre shape invariant under upstream value changes): discovery lift at the upstream's reduction target. The prediction is a structural fact — the target fibre IS the fibre at every upstream value. The factory commits and selects the downstream encoder at construction time. Skip gate for `tooLarge` predictions. **Accuracy: 5/5, exact by construction.**

**Data-dependent edges** (fibre varies with upstream value): current-sequence fibre size as an ordering heuristic only. The factory does NOT commit to a downstream encoder based on this — it defers to runtime. `FibreCoveringEncoder` inspects the actual fibre at `start()` and selects exhaustive or pairwise. The prediction is used only to prioritise which edges get budget first via `leverage / requiredBudget`. **Ordering accuracy: 8/11.** Wrong orderings don't cause regressions — a less-optimal edge runs first, same counterexample quality.

This split resolves the prediction accuracy problem: the original 75% headline number blended a 100% structural-fact metric with a 73% ordering-heuristic metric. These have different failure modes (wrong encoder selection vs suboptimal budget allocation), different severity, and different improvement paths.

**Remaining gap.** For data-dependent edges where `FibreCoveringEncoder` bails at runtime (fibre > 20 params), no downstream search happens. A runtime fallback (bail → retry with `ZeroValueEncoder` in discover mode) would close this. The `SearchMode` infrastructure is in place but wiring it to the composition's downstream context needs careful integration.

### Step 3: Structural leverage ordering (Signal 2) — implemented

Edges ordered by `leverage / requiredBudget` (descending). Leverage is `downstreamRange.count`. Required budget is the predicted fibre size capped at the covering budget. Cross-multiplication avoids division.

### Steps 4 + 5: Fibre stability prediction and validation (Signal 3)

Steps 4 and 5 are bundled — they share the implementation site (KleisliComposition's inner loop) and step 4's standalone value is marginal (15–40 probes saved at `.fast` budget, < 5% of the exploration budget). Step 4 is only worth implementing as part of the step 5 package, where the skip gate makes the modification high-value.

**At `.fast` budget**: cold-start/warm-start only, no skip gate. Activates after first stall. With the standalone warm-start validation fix in place (`floor - 1` probe catches stale transfers regardless), step 4's remaining `.fast` value is marginal efficiency: skipping the transfer and its validation probe saves ~1 probe per coordinate per upstream candidate. The `.fast` activation is incidental to the bundled implementation — the code exists, so it runs, but the correctness case is handled by the standalone fix.

**At `.slow` budget** (`maxStalls ≥ 3`): full prediction-validation loop with confidence states, skip gate, and convergence transfer gating.

**Alternative morphism budget cap.** Derived from `ceil(log₂(rangeSize)) + 1`. Adapts to each position's domain.

### Progression (decision tree)

- **If > 80% of wasted probes are floor re-confirmation** → step 1 only.
- **If > 30% of probe budget is wasted on wrong encoder selection** (probe-weighted, not event-count — a single wrong selection on a large fibre costs more than ten on tiny fibres) → steps 1 + 2 + 3.
- **If encoder selection is accurate but convergence transfer is wasteful, AND user budget is `.slow`** → steps 1 + 2 + 3 + 4/5 (bundled).
- **If all signals are accurate and the factory would simplify the codebase** → factory progression.
- **If profiling shows the current reducer is not measurably wasteful** → do nothing. The plan adds complexity without measurable benefit.

Each step has a measurable precondition. The "do nothing" branch is a valid outcome.

## Post-Termination Verification (implemented)

The reducer converges toward cached floors by design. If the cache is stale (floor higher than the true floor), the counterexample is at the cached floors — indistinguishable from the correct case during reduction. No in-cycle gate detects this. Implemented in `BonsaiScheduler.run()` after the main loop. See `docs/reduction-planning-implementation.md` for details.

**Post-termination sweep.** After the reducer terminates, probe `floor - 1` for each coordinate. Skip trivially valid floors (floor == rangeLowerBound).

If the property fails at any `floor - 1`, the cache is stale and the counterexample is non-minimal. Run a Phase-2-only verification cycle (skip base descent and exploration) with all gates disabled and `convergedOrigins: nil`. Phase 2 runs binary search on every coordinate from the current state without cached bounds — it probes below the cached floor and discovers new floors, including cascading staleness from property-mediated coupling. One Phase-2 cycle is sufficient — Phase 2's own convergence logic handles cascading changes.

**Budget for the verification cycle.** The fixed Phase-2 budget (975 probes) was calibrated for cached operation (most coordinates converge in 1–2 probes). The cache-free sweep is a fundamentally different workload — each coordinate needs up to `ceil(log₂(rangeSize))` probes. The verification cycle should use an expanded budget: `sum(ceil(log₂(rangeSize_i)))` across all value coordinates, computable from the sequence (walk value positions, read range sizes) at zero property-invocation cost.

**Re-entry on success.** If the verification Phase-2 cycle accepts any reduction, the stall was false — the cache was stale, not the reducer converged. Reset the stall counter and re-enter the main reduction loop. New floors may enable structural reductions previously blocked.

**Re-entry guard.** Limited to one occurrence. A `verificationSweepCompleted` flag on the scheduler prevents a second re-entry. If the second termination's sweep also detects staleness, the cache invalidation logic has a systematic defect — re-entry cannot fix it. Log the second detection as a diagnostic (indicates a cache invalidation bug to investigate), terminate without sweeping.

**Budget cap.** The sweep respects the user's `ReductionBudget`. At `.fast`: cap at the standard Phase-2 budget (975 probes) — the quality guarantee is best-effort, not complete. High-impact coordinates are validated first; low-impact coordinates may be unvalidated. `.slow` is needed for a full guarantee. At `.slow`: use the expanded budget (`sum(ceil(log₂(rangeSize_i)))` across all value coordinates). If the capped budget is insufficient, the sweep is partial — validates as many coordinates as budget allows, prioritized by shortlex impact (largest current values first).

The sweep fires only when staleness is detected — no cost in the common case.

## Signal Interaction and Priority

1. **Skip gates** (signal 3 < 0.3 for search-based encoders when step 5 is active, signal 4 all converged): override. Signal 3's skip does NOT override signal 1's exhaustive — exhaustive handles changed fibres by construction.
2. **Encoder selection** (signal 1).
3. **Budget allocation** (greedy by `leverage / requiredBudget`; reliability factor added after empirical measurement).
4. **Convergence transfer** (signal 3, search-based only).
5. **Soft biases** (signals 5, 6).

**Signal 4 / exploration leg interaction.** Signal 4 gates the Phase 2 that runs before the exploration leg. If the exploration leg makes structural progress (KleisliComposition acceptance), the convergence cache is invalidated, and the next cycle's signal 4 sees missing cache entries — Phase 2 runs. This is handled by signal 4's precondition ("no structural acceptance this cycle"). Worth calling out explicitly: if the precondition is ever relaxed, Phase 2 could be skipped based on stale cache state while the exploration leg changed the fibre underneath.

## Deriving Encoders from Structure — implemented

The factory and composable encoder toolbox are implemented. See `docs/composable-encoder-implementation-report.md` for the full outcome. This section summarises the implemented design.

### Composable encoder toolbox

20 monolithic encoders became 13 composable ones. Each is a role-agnostic `ComposableEncoder` — the factory assigns it to a role (upstream, downstream, standalone) based on CDG position.

| CDG role | Encoder | Configuration |
|---|---|---|
| Leaf value | `BinarySearchEncoder` | `.rangeMinimum`, `.semanticSimplest` |
| Leaf float | `ReduceFloatEncoder` | — |
| All values | `ZeroValueEncoder` | — |
| Bind-inner (upstream in composition) | `BinarySearchEncoder` | `.semanticSimplest` |
| Fibre (downstream in composition) | `FibreCoveringEncoder` | exhaustive (≤ 64) or pairwise (IPOG) at runtime |
| Branch selector | `BranchSimplificationEncoder` | `.promote`, `.pivot` |
| Container/sequence/boundary/value spans | `DeletionEncoder` | `.containerSpans`, `.sequenceElements`, `.sequenceBoundaries`, `.freeStandingValues` |
| Aligned siblings (contiguous) | `ContiguousWindowDeletionEncoder` | — |
| Aligned siblings (non-contiguous) | `BeamSearchDeletionEncoder` | beam tuning |
| Cross-container pairs | `RedistributeAcrossValueContainersEncoder` | — |
| Sibling pairs | `RedistributeByTandemReductionEncoder` | — |
| Speculative zero-and-redistribute | `RelaxRoundEncoder` | — |

### Morphism descriptors and dominance chains

```swift
struct MorphismDescriptor {
    let encoder: any ComposableEncoder
    let decoderFactory: () -> SequenceDecoder
    let probeBudget: Int
    let structureChanged: Bool
    let dominates: [Int]
    let maxRetries: Int
    let retrySaltBase: UInt64
    let fingerprintGuard: StructuralFingerprint?
}
```

`dominates` expresses priority ordering. When a descriptor accepts, the scheduler suppresses dominated descriptors. Multi-tier strategies are dominance chains — for example, ProductSpaceBatch guided → regime probe → PRNG retries. Contiguous window search dominates beam search. The same encoder with different decoder modes produces a family of morphisms connected by dominance edges.

### Factory and descriptor chains

`EncoderFactory` centralises all encoder selection via static methods. `runDescriptorChain` and `runDescriptorChainDetailed` process factory-emitted descriptors with dominance suppression and move-to-front promotion. The slot rotation is replaced — no `ValueEncoderSlot` or `DeletionEncoderSlot` switch statements remain in the scheduling path.

Structural deletion uses per-encoder `runComposable` calls with restart-on-acceptance (deletions change sequence length, invalidating span positions). Value reduction and redistribution use descriptor chains.

### Construction-time vs runtime encoder selection

For structurally constant edges (`isStructurallyConstant == true`), the factory commits to the downstream encoder at construction time — the prediction is a structural fact. For data-dependent edges, the factory defers to runtime — `FibreCoveringEncoder` inspects the actual fibre at `start()` and selects exhaustive or pairwise. The factory's prediction is used only for edge ordering (leverage / requiredBudget).

## The Optimization Target

The plan optimizes probe count as a proxy for wall-clock time. The user's primary goal is counterexample quality (smallest shortlex), with time as secondary.

**Tension.** Every skip gate trades quality risk for probe savings. Stale floors mean skipped probes might have found a lower floor. Probe savings that risk larger counterexamples are acceptable only when stale-floor probability is low AND property cost is high.

**Post-termination verification catches the dangerous case.** The in-cycle skip gates are aggressive — they trust the cache. The post-termination sweep is the safety net — it probes `floor - 1` for every coordinate after the reducer terminates. If any floor is stale, one Phase-2-only cycle runs with gates disabled. This separates the aggressive optimization (during reduction, skip what looks converged) from the quality guarantee (after reduction, verify the result).

## Open Questions

**Profiling.** Measure before implementing. Profiling categories overlap — use hierarchical primary attribution: (1) wrong encoder selection, (2) floor re-confirmation, (3) productive. "Wrong encoder" measurable in both directions without step 2's machinery: count fibre > 64 discoveries at `start()` time (exhaustive selected, fibre too large), and log actual fibre size when pairwise runs to check post-hoc how many were ≤ 64 (pairwise selected, exhaustive would have worked). Both measurements are byproducts of FibreCoveringEncoder's existing `start()` computation.

**Success criterion.** Two dimensions:
- **Efficiency**: across the test suite, equal or better counterexample quality in ≥ 10% fewer property invocations, with no regression on any individual test case.
- **Adaptability**: a new generator shape that exposes a reduction gap (like the coupling challenge's cross-level minimum) can be addressed by adding a row to the classification table or adjusting a signal threshold, not by implementing a new encoder type with its own file, `EncoderName` case, slot assignment, and dominance rules.

**Seed determinism.** The success criterion assumes fixed seeds for A/B comparison. Each shrinking challenge uses `.replay(seed)` — a fixed seed producing a deterministic initial failure. Counterexample size differences are attributable to the reducer, not seed variation. For batch tests without fixed seeds (Bound5Many with 52 random runs), the comparison uses aggregate statistics (mean and max invocation count) rather than per-run counterexample quality.

**Per-cycle overhead.** Steps 1–3 at `.fast` budget: step 1 is O(value positions), step 2 walks downstream coordinates per edge and sorts, step 3 is a comparator change. For a generator with 10 edges and 50 downstream coordinates, step 2 is ~500 comparisons per cycle — microseconds, negligible relative to a single materialization. The CDG has at most as many edges as bind regions, bounded by nesting depth (typically < 20). Steps 1–3 are free in practice.

**Budget-dependent features.** At `.fast` budget: steps 1–4 active, no skip gate, no prediction-validation loop. At `.slow` budget: full loop with validation, confidence tracking, and skip gates. The user's budget choice determines which reduction planning features activate.

**Non-monotonicity.** Detect via stepper flag. Per-coordinate exhaustive scan. Rare but prevents subtle correctness issue.

**Regression risk.** Runtime toggle + clean A/B testing (fresh caches, same initial state). At least one generator per classification row.

**Invalidation cost.** Per-edge: O(downstream coordinates), negligible. Per-signal: microsecond savings, not worth the complexity.

## Insights from Algorithm Selection Literature

The planning framework instantiates Rice's (1976) Algorithm Selection Problem: structural signals are instance features, primitives are the algorithm space, probe count is the performance measure, the classification table is the selection mapping. Three insights from the literature improve the plan:

**Feature computation cost (SATzilla).** Some features cost more to compute than the time they save. Signal computation for signals 1–4 is free (arithmetic on held data). But the discovery lift for nested-bind edges costs a materialization. Charge it against the edge's budget. In practice, the discovery lift is almost always worth its cost: if it reveals a small fibre, the edge succeeds quickly; if it reveals a large fibre, the "skip" outcome saves the much larger cost of attempting coverage on an infeasible fibre. The only case where charging matters is when the edge's total budget is so small that one materialization exhausts it — which means the edge was underfunded regardless.

**Interleaved portfolio execution (Huberman et al. 1997, future work).** Running multiple algorithms with interleaved time shares and taking the first success outperforms the best single algorithm when failure cases don't overlap. For the current implementation, sequential execution scored by `leverage / requiredBudget` with early termination is preferred — principled and understandable. The upstream budget cap (10–15 candidates) bounds the pathological case where a top-scored edge is futile. If profiling shows that top-scored edges frequently fail while lower-scored edges would have succeeded, interleaving becomes justified. The `ComposableEncoder` protocol supports suspension (`nextProbe` is stateful and resumable), but the implementation complexity (k parallel convergence transfer states) is not warranted until the sequential approach is demonstrably insufficient.

**Credit assignment (adaptive operator selection, Fialho et al. 2010).** When a prediction succeeds, distinguish model credit from luck. Credit the model only when the structural prediction matched the lift report AND the downstream found a failure. If the prediction diverged from the lift report but the downstream succeeded anyway, that is luck — do not promote. The promotion criterion becomes: prediction accuracy AND downstream productivity, not productivity alone.

Symmetric corollary for demotion: demote when the prediction was confident and wrong (predicted high coverage, got low coverage, downstream failed). Do not demote when the prediction was uncertain — the model did not claim to know, so the failure does not contradict it. The three-state confidence system handles this naturally: uncertain edges are exempt from credit assignment. They have insufficient observations for the model to be right or wrong.

**IPOG budget estimation vs exact computation.** The budget allocation uses `max_domain² × ceil(log₂(num_params))` as the required budget for pairwise covering. The actual IPOG array is almost always smaller (mixed domains, serendipitous coverage from greedy horizontal growth). The risk of under-allocation from over-estimation is low. The risk of over-allocation (wasted budget slots) is bounded by early termination.

If the actual IPOG row count computation is cheap enough for the scoring pass, use it instead of the estimate. IPOG row count is O(parameters × domains × log(parameters)) — much cheaper than generating the array. The `CoveringArray` library already has the `generate` function with `rowBudget` for early abort. A lightweight "dry run" that computes row count without generating the array would eliminate the estimation gap entirely. If the dry run is too expensive, the estimate is conservative and the early-termination mechanism handles the rest.

## Fibrational Structure of the Encoder Algebra

The separation of search methods from manipulations has a precise categorical description as a Grothendieck opfibration. This section states the structure; it is not required for implementing the planning framework, but it clarifies why the decomposition is canonical rather than an arbitrary design choice.

### Setup

**Base category B.** Objects are upstream values (bind-inner positions in the choice sequence). For a bind-inner with range `lo...hi`, the objects are the integers in that range. A morphism n → k (where n ≥ k) represents a reduction of the upstream value. An encoder assigned to the upstream role in a composition produces these morphisms.

**Fibre F(n).** For a fixed upstream value n, the fibre is the category of valid downstream configurations: choice sequences where every bound entry is in range for the generator materialised at n. An encoder assigned to the downstream role produces morphisms within F(n) — it does not change the upstream value.

**Reindexing F(n → k).** A base morphism n → k induces a functor F(n) → F(k): take a downstream configuration valid at n and materialise it at k, clamping or regenerating entries that fall out of range. This is the `GeneratorLift`. The reindexing is covariant (pushforward), making this an opfibration, not a fibration.

### The total category

The Grothendieck construction assembles B and the fibres into a total category ∫F. Objects are pairs (n, s) where s ∈ F(n). A morphism (n, s) → (k, t) in ∫F decomposes uniquely into:

1. A **horizontal** (opcartesian, between-fibre) component: the base morphism n → k and the induced lift F(n) → F(k), producing an intermediate configuration s' ∈ F(k).
2. A **vertical** (within-fibre) component: a morphism s' → t in F(k), the search step that finds the downstream configuration where the property fails.

This is the standard opcartesian/vertical factorisation. Every reduction step in the Kleisli composition follows this decomposition: the encoder in the upstream role proposes a base morphism, the `GeneratorLift` computes the opcartesian lift (materialisation without property check), and the encoder in the downstream role performs the vertical step (search within the reindexed fibre, with property checks). The same encoder type can serve in either role — the factorisation is a property of the morphism, not of the encoder.

### The materialisation monad

The lift is partial — materialisation can fail when the downstream structure at k is incompatible with the configuration at n (entries out of range, structural changes from conditional binds). This partiality is absorbed by the Kleisli category over the materialisation monad M on ∫F. M's unit embeds a configuration into its materialised form; M's bind composes two materialisation-dependent steps. The `KleisliComposition` type is a morphism in the Kleisli category of M — its name is literal.

### The cost boundary

The horizontal/vertical factorisation aligns with the cost model. The horizontal component (lift) is internal cost: materialisation without property invocation, controllable per-call. The vertical component (fibre search) is external cost: each probe invokes the property, whose cost is unknown and uncontrollable. The `dec` boundary in the composition — where the property is checked — sits at the junction between the two components. This is not a convention; it is forced by the factorisation. The lift cannot check the property (it operates in B, not on the predicate over ∫F), and the search must check the property (it needs to distinguish failing from passing configurations in the fibre).

### Why the existing encoders are hard to extend

Each existing encoder is a specific path through ∫F that fuses the opcartesian and vertical components into a single step. The encoder knows both what base morphism to apply and how to search the resulting fibre — but this knowledge is compiled into its implementation, not available as composable data. Adding a new generator shape requires a new fused path, because the factorisation was never exposed. The compositional algebra unfuses the path: the factory assigns one composable encoder to the upstream role and another to the downstream role, and the composition wires them through a lift. The same encoder type can serve in either role. The planning framework's encoder selection (step 2) operates on this unfused representation: it selects an encoder for the downstream role based on the fibre's structural properties, independently of which encoder produced the fibre from the upstream role.

## Addendum: Profiling Results (March 2026)

Profiling instrumentation was added to all single shrinking challenge tests and a new structural pathological test suite. The results evaluate the decision tree in "Implementation Steps" above. All data collected with `.onReport` at default (`.fast`) budget.

### Standard shrinking challenges

| Test | cycles | probes | mats | reconfirm | edges | futile | transfers | sweep |
|------|--------|--------|------|-----------|-------|--------|-----------|-------|
| Deletion | 2 | 32 | 8 | 0% | 0 | 0 | 0/0/0 | 0p/ok |
| Calculator | 2 | 17 | 53 | 0% | 0 | 0 | 0/0/0 | 0p/ok |
| Reverse | 2 | 19 | 16 | 25% | 0 | 0 | 0/0/0 | 1p/ok |
| Replacement | 2 | 87 | 82 | 0% | 0 | 0 | 0/0/0 | 2p/ok |
| Distinct | 3 | 42 | 34 | 22% | 0 | 0 | 0/0/0 | 2p/ok |
| DistinctReflected | 2 | 47 | 42 | 0% | 0 | 0 | 0/0/0 | 2p/ok |
| Difference1 | 2 | 77 | 73 | 50% | 0 | 0 | 0/0/0 | 2p/ok |
| Difference2 | 2 | 98 | 94 | 50% | 0 | 0 | 0/0/0 | 2p/ok |
| Difference3 | 2 | 81 | 78 | 50% | 0 | 0 | 0/0/0 | 2p/ok |
| LengthList | 2 | 30 | 21 | 50% | 0 | 0 | 0/0/0 | 1p/ok |
| NestedLists | 2 | 77 | 70 | 0% | 0 | 0 | 0/0/0 | 0p/ok |
| Parser | 2 | 84 | 338 | 0% | 0 | 0 | 0/0/0 | 0p/ok |
| LargeUnionList | 3 | 300 | 275 | 27% | 0 | 0 | 0/0/0 | 4p/ok |
| LargeUnionListPath1 | 4 | 656 | 649 | 40% | 0 | 0 | 0/0/0 | 4p/ok |
| LargeUnionListPath2 | 3 | 602 | 595 | 27% | 0 | 0 | 0/0/0 | 4p/ok |
| LargeUnionListPath3 | 3 | 298 | 291 | 27% | 0 | 0 | 0/0/0 | 4p/ok |
| Bound5Single | 4 | 368 | 503 | 18% | 0 | 0 | 0/0/0 | 1p/ok |
| Bound5Path1 | 4 | 389 | 688 | 17% | 0 | 0 | 0/0/0 | 1p/ok |
| Bound5Path2 | 4 | 268 | 385 | 40% | 0 | 0 | 0/0/0 | 1p/ok |
| Bound5Path4 | 17 | 912 | 1299 | 68% | 0 | 0 | 0/0/0 | 1p/ok |
| Coupling | 3 | 165 | 242 | 23% | 2 | 2 | 0/0/0 | 2p/ok |
| CouplingPath | 3 | 165 | 242 | 23% | 2 | 2 | 0/0/0 | 2p/ok |
| BinaryHeap | 14 | 688 | 857 | 0% | 4 | 0 | 0/0/0 | 1p/ok |

### Structural pathological tests

Purpose-built generators exercising bind-dependent CDG topologies that the standard challenges lack.

| Test | cycles | probes | mats | reconfirm | edges | futile | transfers | sweep |
|------|--------|--------|------|-----------|-------|--------|-----------|-------|
| FibreThreshold | 2 | 318 | 311 | 25% | 2 | 2 | 0/0/0 | 3p/ok |
| CrossLevelSum | 3 | 187 | 180 | 33% | 2 | 1 | 0/0/0 | 3p/ok |
| NestedBind2 | 2 | 195 | 191 | 62% | 2 | 2 | 0/0/0 | 4p/ok |
| NestedBind3 | 2 | 142 | 122 | 38% | 3 | 1 | 0/0/0 | 2p/ok |
| WideCDG | 2 | 222 | 212 | 75% | 2 | 2 | 0/0/0 | 4p/ok |
| MultiParamFibre | 2 | 218 | 222 | 58% | 1 | 1 | 0/0/0 | 6p/ok |
| NonMonotonicFibre | 2 | 130 | 125 | 67% | 1 | 1 | 0/0/0 | 3p/ok |

### Decision tree evaluation

**Branch 1: > 80% of wasted probes are floor re-confirmation → step 1 only.** Step 1 implemented. The gate fires on stall cycles when all coordinates are converged. Saves computational overhead but not property invocations (converged encoders already produce 0 probes). The gate's value scales with generator complexity — many coordinates = expensive span extraction skipped.

**Branch 2: > 30% of probe budget wasted on wrong encoder selection → steps 1 + 2 + 3.** Steps 1–3 implemented. Encoder selection is now split on structural constancy:
- Constant edges: factory-time selection, 100% accurate (5/5). No wrong selections possible — the prediction is a structural fact.
- Data-dependent edges: runtime selection via `FibreCoveringEncoder.start()`. The factory provides an ordering heuristic (73% accurate, 8/11) but does not commit to a downstream encoder. Wrong ordering = suboptimal budget allocation, not wrong encoder.

The branch 2 threshold ("> 30% of probe budget wasted on wrong encoder selection") is no longer applicable in its original form. For constant edges, there is no waste. For data-dependent edges, the factory defers — runtime selection eliminates selection waste at the cost of one discovery lift per constant edge.

**Branch 3: convergence transfer wasteful → steps 1 + 2 + 3 + 4/5.** Not triggered. Convergence transfer is 0/0/0 across every test. The transfer mechanism requires a search-based downstream encoder; the current downstream is always `FibreCoveringEncoder`, which cold-starts. `SearchMode.discoverFailure` is the infrastructure for search-based downstreams but wiring it triggered a regression on data-dependent edges (CouplingScaling). The remaining gap: runtime fallback when `FibreCoveringEncoder` bails (fibre > 20 params).

**Branch 4: not measurably wasteful → do nothing.** Steps 1–3 are implemented. The remaining waste is on data-dependent edges where `FibreCoveringEncoder` bails at runtime — the composition does 12 lifts and 0 downstream probes (CouplingScaling). A runtime bail → fallback mechanism would close this.

### What was built

Steps 1–3 and post-termination verification are implemented. The encoder algebra — 20 monolithic encoders consolidated into 13 composable ones, `EncoderFactory` with descriptor chains replacing the slot rotation, `MorphismDescriptor` with dominance edges replacing hand-coded multi-tier orchestration — is the infrastructure that makes steps 1–3 possible and steps 4–5 feasible. The `ComposableEncoder` protocol, `SearchMode` on `ReductionContext`, and the structural-constancy split in the factory's prediction logic are the extension points the closed-loop reducer will use.

See `docs/composable-encoder-implementation-report.md` for the full implementation outcome: what changed, what worked, what didn't, and next steps.

### Key observations

**Composition edges.** The standard challenges had `edges=0` on 21 of 23 runs (only Coupling and BinaryHeap had edges). The structural pathological tests have edges on all seven runs: 1–3 edges per test, exercising single-bind, nested two-level, nested three-level, and wide independent topologies.

**Productive composition.** CrossLevelSum is the first test in the suite where a composition edge produced an improvement (`edges=2, futile=1`). The composition found the global minimum [1, 1, 2] that Phase 2's per-coordinate search cannot reach — reducing any single coordinate of the Phase 2 result breaks the sum constraint. NestedBind3 also shows a productive edge (`edges=3, futile=1`).

**Verification sweep.** Clean across all tests (0–6 probes, zero staleness detected). Negligible overhead.

**Convergence transfer.** Dead in practice. The warm-start validation and transfer machinery exists but is never exercised because the only downstream encoder (`FibreCoveringEncoder`) always cold-starts. The structural pathological tests provide the generators that would exercise transfer (bind-dependent fibres with composition edges), but the search-based downstream encoder that would use transfer does not exist yet.

**Local minima from per-coordinate search.** Three structural pathological tests (WideCDG, MultiParamFibre, NonMonotonicFibre) converge to local minima because the property's failure surface requires cross-coordinate redistribution that per-coordinate binary search cannot perform. WideCDG requires cross-edge coordination (simultaneously reducing one bind-inner while increasing another). MultiParamFibre and NonMonotonicFibre require within-fibre redistribution across sum-constrained coordinates. These are not bugs — they are the expected behaviour of greedy per-coordinate search on coupled constraints, and they define the gap that future encoder improvements (cross-edge redistribution, within-fibre redistribution via composition) would address.

### Gaps remaining

1. **Runtime bail fallback.** For data-dependent edges where `FibreCoveringEncoder` bails at runtime (fibre > 20 params), the composition does lifts with 0 downstream probes — wasted materializations. A fallback to `ZeroValueEncoder` in discover mode would close this. `SearchMode` infrastructure is in place; wiring needs careful integration (CouplingScaling regression canary).
2. **Convergence transfer.** Still 0/0/0. Requires a search-based downstream that uses warm-start. `FibreCoveringEncoder` always cold-starts. Steps 4+5 depend on this.
3. **Prediction accuracy reporting.** The `predict=X/Y` field in `ExhaustReport` blends structural-fact accuracy (100%) with ordering-heuristic accuracy (73%). These should be reported separately — different failure modes, different severity.
4. **No `.slow` budget tests.** Steps 4 and 5 activate only at `.slow` budget (≥ 3 stall cycles). The FibreDescentGate test uses `.slow` but other tests run at default `.fast`.
5. **Non-monotonicity detection** (Signal 7). Independent of composition. `sawUnexpectedResult` flag on binary search steppers + bounded exhaustive scan. Correctness improvement, not yet implemented.
