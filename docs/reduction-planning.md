# Reduction Planning: Structural Prediction and Validation

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

### Step 1: Fibre descent gating (Signal 4)

Skip Phase 2 when all coordinates are at cached floors and no structural acceptance occurred this cycle.

**Precondition.** Profile: what fraction of Phase 2 probes re-confirm floors? Threshold is property-cost-dependent.

### Step 2: Domain ratio at edge selection (Signal 1)

Compute fibre size lower bound. Select downstream encoder. Allocate budget greedily by `leverage / requiredBudget`. Skip gate only for "structural" confidence edges.

**Precondition.** After implementing, measure decision accuracy (did the prediction select the correct encoder?). A prediction 3x off but on the same side of the threshold makes the same decision. Decision accuracy, not estimation accuracy.

### Step 3: Structural leverage ordering (Signal 2)

Sort edges by leverage within depth levels. One comparator change. No precondition.

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

## Deriving Encoders from Structure

### Position-level classification

| Tree node | CDG role | Primitive |
|---|---|---|
| `.choice` | Leaf | Binary search |
| `.choice` | Leaf, float | Float reduction |
| `.choice` | Bind-inner with outgoing edges | KleisliComposition |
| `.branch` | Branch selector | Branch promotion/pivot |
| `.sequence` container | Structural | Span deletion |
| `.bind` container | Structural | Span deletion |

For overlapping roles, the factory emits alternatives with a budget cap per alternative derived from `ceil(log₂(rangeSize)) + 1`.

### Morphism descriptors

```swift
struct MorphismDescriptor {
    let encoder: any PointEncoder
    let decoder: DecoderMode
    let probeBudget: Int
    let rollback: RollbackPolicy
    let classification: PositionClassification
}
```

`classification` preserves the factory's static knowledge through the existential boundary.

### Factory-primitive boundary

Signals modify the new types (KleisliComposition, FibreCoveringEncoder), not the 20 existing ones. The two systems operate in different phases — existing types run in base/fibre descent, new types run in the exploration leg. When the factory arrives, existing encoders' internal probe logic is unchanged, but the scheduling context changes — the factory adds metadata (classification, decoder mode, rollback policy) and the scheduler uses it for signal-based decisions. This IS a behavioral change at the system level: the factory changes which encoders run, in what order, with what budget.

Testing the factory transition as a behavioral change means: same counterexample quality (shortlex), same or fewer probes, same phase ordering for the common case (the factory's construction-time decisions should match the current slot rotation's runtime decisions). At least one generator per classification row catches row-level regressions. The success criterion (equal or better quality, ≥ 10% fewer probes, no individual regressions) applies.

The "construction-time dominance loses mid-phase adaptivity" concern: currently the dominance lattice suppresses an encoder during its run if a dominating encoder was accepted. The factory pre-selects at construction time, so a dominator's acceptance can't suppress already-constructed alternatives. The budget-cap mechanism handles this differently — each alternative runs until its cap, not until a dominator fires. This changes probe distribution but should produce the same final result. Whether it does is an empirical question. Signals first, factory later minimizes rework.

### Runtime vs construction-time dominance

Construction-time dominance loses mid-phase adaptivity. Self-termination replaces intra-encoder convergence. Budget-cap alternatives prevent fixed-order over-pruning. Per-edge invalidation is O(downstream coordinates) — negligible relative to materialization cost.

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

**Interleaved portfolio execution (Huberman et al. 1997, future work).** Running multiple algorithms with interleaved time shares and taking the first success outperforms the best single algorithm when failure cases don't overlap. For the current implementation, sequential execution scored by `leverage / requiredBudget` with early termination is preferred — principled and understandable. The upstream budget cap (10–15 candidates) bounds the pathological case where a top-scored edge is futile. If profiling shows that top-scored edges frequently fail while lower-scored edges would have succeeded, interleaving becomes justified. The `AdaptiveEncoder` protocol already supports suspension (`nextProbe` is stateful and resumable), but the implementation complexity (k parallel convergence transfer states) is not warranted until the sequential approach is demonstrably insufficient.

**Credit assignment (adaptive operator selection, Fialho et al. 2010).** When a prediction succeeds, distinguish model credit from luck. Credit the model only when the structural prediction matched the lift report AND the downstream found a failure. If the prediction diverged from the lift report but the downstream succeeded anyway, that is luck — do not promote. The promotion criterion becomes: prediction accuracy AND downstream productivity, not productivity alone.

Symmetric corollary for demotion: demote when the prediction was confident and wrong (predicted high coverage, got low coverage, downstream failed). Do not demote when the prediction was uncertain — the model did not claim to know, so the failure does not contradict it. The three-state confidence system handles this naturally: uncertain edges are exempt from credit assignment. They have insufficient observations for the model to be right or wrong.

**IPOG budget estimation vs exact computation.** The budget allocation uses `max_domain² × ceil(log₂(num_params))` as the required budget for pairwise covering. The actual IPOG array is almost always smaller (mixed domains, serendipitous coverage from greedy horizontal growth). The risk of under-allocation from over-estimation is low. The risk of over-allocation (wasted budget slots) is bounded by early termination.

If the actual IPOG row count computation is cheap enough for the scoring pass, use it instead of the estimate. IPOG row count is O(parameters × domains × log(parameters)) — much cheaper than generating the array. The `CoveringArray` library already has the `generate` function with `rowBudget` for early abort. A lightweight "dry run" that computes row count without generating the array would eliminate the estimation gap entirely. If the dry run is too expensive, the estimate is conservative and the early-termination mechanism handles the rest.
