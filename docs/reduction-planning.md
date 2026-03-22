# Reduction Planning: Structural Prediction and Validation

## The Six Signals

The CDG, ChoiceTree, and ChoiceSequence together provide six signals about the reduction landscape. They split into two categories: exact signals that drive hard decisions, and estimates that drive soft decisions.

### Exact signals (hard decisions)

**1. Domain ratio at dependency edges.** At a bind edge where the inner value is `n` with range `0...R`, and downstream elements have range `0...n`, reducing `n` to value `k` produces a fibre of size `(k+1)^count`. This is computable before any probe. It directly selects the downstream encoder in a `KleisliComposition`: below the exhaustive threshold (64), use `FibreCoveringEncoder` in exhaustive mode; above it, use pairwise covering. The coupling challenge at `n = 1` produces a 4-point fibre — the planner would route straight to exhaustive enumeration without trying anything first.

**3. Structural leverage.** A bind-inner that controls a large `scopeRange` has high leverage — reducing it eliminates many downstream entries. The CDG already has `scopeRange.count` per node. Ordering edges by leverage (largest scope first) within the same depth level prioritizes high-impact reductions. The topological sort handles cross-depth ordering; leverage handles within-depth prioritization.

**5. Fibre stability prediction.** For each downstream coordinate, check whether its current value equals the upper bound of its range (determined by the bind-inner value). If `value < n` for all downstream coordinates, reducing `n` by 1 leaves all values valid — tier 1 carry-forward, coverage 1.0 predicted. If any `value == n`, that coordinate will be clamped or PRNG-filled — coverage drops. This is a per-coordinate boolean check against sequence entries already held. It predicts the lift report before the lift, gating convergence transfer: high predicted coverage → warm-start from previous convergence points; low predicted coverage → cold-start.

### Estimates (soft decisions)

**2. Shortlex distance (reduction potential).** For each value position, the distance from the current bit pattern to the target (semantic simplest or range minimum) is computable. Summing across a scope gives a reduction potential — how much improvement is available. Useful as a tiebreaker between scopes of equal leverage. Not reliable as a primary budget allocator: high potential could mean "lots of easy wins" or "lots of coupled coordinates that resist per-coordinate reduction."

**4. Convergence cache correlation.** Two coordinates that converged in the same cycle are suggestively coupled — the property's boolean depends on both values jointly. Two coordinates that converged in different cycles are suggestively independent. The correlation is not causal: coordinates with similar-depth binary searches terminate on the same cycle regardless of coupling. Safe use: as a filter for the relax-round's redistribution pairs (prefer same-cycle pairs), not as a hard routing decision.

**6. Property sensitivity estimation.** If all values are at their convergence-cached floors and the property still fails, the failure is structural — skip fibre descent entirely. This is exact in one direction: it can eliminate fibre descent (saving 20–50 probes) but cannot eliminate base descent (non-floor values might still indicate structural failure). Asymmetric but valuable.

## Lazy Per-Decision Computation

The signals should be computed lazily at the point of decision, not as an upfront plan. A structural acceptance in Phase 1b changes the CDG, invalidating domain ratios and leverage scores for every downstream edge. An upfront plan would need rebuilding after every acceptance. Lazy computation uses the current state at each decision point and is naturally robust to mid-cycle changes.

The signals become a plan when decisions interact — when budget allocation for edge A depends on the domain ratio at edge B because the total exploration budget is shared. That global optimization requires centralized planning. For the first implementation, lazy per-decision computation delivers most of the benefit with less machinery.

## The Prediction-Validation Loop

The current reducer reacts: the lift report comes back, the next encoder adapts. The proposed reducer predicts *and* reacts.

**Prediction.** Before traversing a bind edge, compute the domain ratio and fibre stability. The domain ratio selects the downstream encoder. The fibre stability prediction gates convergence transfer.

**Validation.** The lift report confirms or contradicts the prediction. If predicted coverage was high but actual coverage was low, the domain ratio was wrong — the downstream's range depends on something other than the inner value (perhaps a nested bind, a filter, or a property-mediated coupling the CDG cannot see).

**Update.** If contradicted, the reducer adjusts: discard the convergence transfer for this edge, cold-start the downstream, and flag the edge as "prediction-unreliable" for subsequent cycles. If confirmed, the prediction is reinforced: convergence transfer is safe, the downstream converges in one or two probes.

Over multiple cycles, the predictions converge on the actual dependency structure — including property-mediated couplings invisible to the CDG. The reducer learns the failure surface's dependency structure, not just its per-coordinate floors. This is a Bayesian update loop: the prior is the structural prediction, the likelihood is the lift report, the posterior is the updated confidence.

## What This Changes

The current reducer's cycle is: compute CDG → run base descent → run fibre descent → explore. Every cycle runs the same phases with the same encoders. The signals change what runs and how much budget it gets:

- **Signal 1 gates downstream encoder selection** in `KleisliComposition`. No trial and error — the domain ratio selects exhaustive vs covering before any probe.
- **Signal 3 orders edge traversal** within the exploration leg. High-leverage edges first, using the most budget.
- **Signal 5 gates convergence transfer** across adjacent upstream values. Predicted high coverage → transfer. Predicted low coverage → cold-start. Validated by the lift report.
- **Signal 6 gates fibre descent**. If the convergence cache says all coordinates are at their floors, skip Phase 2 entirely.
- **Signals 2 and 4 bias soft decisions** — budget tiebreaking and redistribution pair selection.

The prediction-validation loop is the qualitative shift: the reducer doesn't just try encoders and measure outcomes — it predicts which encoders will work based on structural analysis, tries them, and validates the predictions against the lift report. Over cycles, the predictions improve. The reducer learns.

## Implementation Steps

### Step 1: Domain ratio at edge selection (Signal 1)

**What it does.** Before `runKleisliExploration` constructs a `KleisliComposition` for a `ReductionEdge`, compute the downstream fibre size at the upstream encoder's target value. This selects the downstream encoder and decides whether the composition is worth running at all.

**Where it lives.** In `runKleisliExploration` in `ReductionState+Bonsai.swift`, between the edge iteration and the `KleisliComposition` construction.

**How to compute it.** For a `ReductionEdge` with `upstreamRange` and `downstreamRange`:
1. Read the upstream value's current bit pattern and valid range from `sequence[upstreamRange.lowerBound]`.
2. Compute the upstream target: `semanticSimplest` or `reductionTarget(in: validRange)`. Call this `targetValue`.
3. Walk the downstream value positions in `downstreamRange`. For each `.value` entry, read its `validRange`. The upper bound of each downstream range is typically `targetValue` (for generators like `.int(in: 0...n)`). Compute the domain size at the target: `min(currentDomainSize, targetValue + 1)` or more precisely, clamp the current range's upper bound to the target value.
4. Multiply the domain sizes across all downstream value positions. This is the predicted fibre size at the upstream target.

**What it decides.**
- Fibre size ≤ 64: construct `KleisliComposition` with `FibreCoveringEncoder` in exhaustive mode. Guaranteed to find any failure.
- Fibre size ≤ `coveringBudget` and ≥ 2 parameters: construct with `FibreCoveringEncoder` in pairwise mode.
- Fibre size > `coveringBudget` with < 2 parameters or > 20 parameters: skip this edge. The fibre is too large to cover within budget — structural encoders have more work to do.

**What changes.** Currently the `FibreCoveringEncoder` discovers the fibre size at `start()` time, after the lift has already happened. Moving the decision to edge selection time avoids the lift materialization entirely for edges where the fibre is too large. For the coupling challenge, the planner would see that `n = 1` produces a 4-point fibre and prioritize that edge.

**Nested binds.** The domain ratio is computed for the immediate downstream coordinates only. Nested binds within the downstream range are treated as opaque — their contribution to fibre size is discovered at lift time, not predicted. This underpredicts the fibre size for nested generators (the actual fibre is larger because the nested bind adds more coordinates), but the underprediction is conservative: it might route to exhaustive enumeration when pairwise covering would have been needed, which wastes probes but does not miss failures.

**Skip gate for the entire composition.** If the domain ratio predicts that *every* upstream target value produces a fibre too large to cover, the entire `KleisliComposition` for this edge is futile — the downstream encoder cannot systematically explore any of the fibres the upstream would produce. Skip the edge entirely and leave the budget for the relax-round. This is a hard skip decision from an exact signal, saving the upstream encoder's probes and the lift materializations.

**Failure mode.** The domain ratio assumes downstream ranges scale linearly with the upstream value. For generators where the downstream range depends on the upstream value through a nonlinear function (for example, `.int(in: 0...n*n)`), the prediction is wrong. The lift report catches this: if predicted coverage was high but actual coverage was low, the domain ratio model is invalid for this edge. Fall back to the current unguided behavior.

### Step 2: Fibre stability prediction (Signal 5)

**What it does.** Before convergence transfer in the `KleisliComposition`'s inner loop, predict whether the downstream convergence points from the previous upstream iteration are still valid. Gate the transfer on the prediction instead of waiting for the lift report.

**Where it lives.** In `KleisliComposition.convergenceTransferOrigins(from:)`, replacing or supplementing the current coverage-threshold check.

**How to compute it.** After the upstream encoder proposes a new value `k` (reduced from `n`):
1. For each downstream value position in the lifted sequence, check: `currentValue < k`. If true, the value fits in the new range `0...k` — tier 1 carry-forward predicted. If `currentValue >= k`, the value will be clamped or PRNG-filled — tier 2 or 3.
2. Count the fraction of downstream coordinates where `currentValue < k`. This is the predicted coverage.

**What it decides.**
- Predicted coverage ≥ 0.7: transfer convergence points from the previous upstream iteration. The downstream encoder warm-starts and converges in one or two probes.
- Predicted coverage < 0.7: cold-start the downstream. The fibre changed too much for the old stall points to be valid.

**What changes.** Currently the `KleisliComposition` computes convergence transfer *after* the lift, using the lift report's actual coverage. The prediction moves the decision *before* the lift. For adjacent upstream values with high stability (most downstream values well below the range boundary), this is free — no lift needed to decide. For upstream values where stability is low, the prediction matches what the lift report would have said, so no change in behavior.

**Interaction with signal 1.** Signal 5 applies only when the downstream encoder is search-based (binary search, covering with pairwise). For exhaustive enumeration (signal 1 selected fibre ≤ 64), convergence transfer is unused — the exhaustive encoder enumerates everything regardless.

**Known limitation: coverage versus semantic stability.** Fibre stability predicts coverage, not semantic stability. Two fibres can have identical coverage (all tier 1) but different property behavior because the value interpretation changed. A generator like `Gen.int(in: n...n+10)` has downstream values that are always valid regardless of `n` — the range shifts rather than shrinks. Coverage is high (all tier 1), but a downstream value of 5 means something different at `n = 3` (5 is in `3...13`) versus `n = 1` (5 is in `1...11`). The convergence point is semantically stale despite high predicted coverage. The property check catches this (the transferred floor does not hold), but the probes are wasted. This requires understanding the generator's range function, not just the current range bounds — not worth implementing now but worth noting.

**Validation.** After the lift, compare predicted coverage against the lift report's actual coverage. If they diverge by more than 0.2, the stability model is wrong for this edge — the downstream ranges do not simply scale with the upstream value. Log the divergence and fall back to lift-report-based transfer for subsequent upstream iterations on this edge.

### Step 3: Structural leverage ordering (Signal 3)

**What it does.** Within the exploration leg, order the `ReductionEdge` traversal by structural leverage (scope size) instead of the CDG's topological order alone.

**Where it lives.** In `reductionEdges()` on `ChoiceDependencyGraph`, or in `runKleisliExploration` where edges are iterated.

**How to compute it.** For each `ReductionEdge`, `downstreamRange.count` is the leverage. Sort edges by leverage descending within each topological depth level. Edges at shallower depths still run first (topological order), but among edges at the same depth, higher-leverage edges run first.

**What it decides.** Budget allocation within the exploration leg. The first edge gets the full budget. If it succeeds and the cycle restarts, the remaining edges are re-evaluated on the new state. If it fails and returns budget, the next edge gets the remainder. High-leverage edges are more likely to produce shortlex-significant improvements, so they should get first access to the budget.

**What changes.** Currently `reductionEdges()` returns edges in pure topological order. Adding leverage ordering within depth levels is a sort key change — one line in the sort comparator. The effect is that the exploration leg tries the most impactful edges first.

### Step 4: Fibre descent gating (Signal 6)

**What it does.** Before fibre descent starts, check whether all value coordinates are at their convergence-cached floors. If so, skip Phase 2 entirely — the fibre is already at its per-coordinate minimum and no value encoder will make progress.

**Where it lives.** At the top of `runFibreDescent` in `ReductionState+Bonsai.swift`, before the leaf-range loop.

**How to compute it.** Walk all value positions in the sequence. For each position, check `convergenceCache.convergedOrigin(at: index)`. If every value position has a cached floor *and* the current value at that position matches the cached floor's bound, Phase 2 has nothing to do.

**What it decides.** Skip or run Phase 2. Skipping saves the full fibre descent budget (975 probes) worth of encoder invocations — zero-value, binary search, and redistribution all return immediately if their targets are already at floor. But currently they each spend a few probes re-confirming the floor before converging. The gate eliminates those re-confirmation probes.

**What changes.** A boolean check at the top of `runFibreDescent`. If all coordinates have converged and the values match, return `false` immediately. The convergence cache already holds the data; the check is O(n) in the number of value positions. The benefit scales with the number of coordinates — generators with many value positions (like Bound5 with 50+ coordinates) save the most.

**Failure mode.** A structural change in Phase 1 can invalidate convergence cache entries without clearing them (the cache invalidation is range-based, not total). If a structural change shifted a coordinate's range but did not invalidate its cache entry, the gate would incorrectly skip Phase 2 for a coordinate that now has room to improve. The fix: the gate only fires when `convergenceCache` has entries for *all* value positions, not just some. A partial cache (some entries missing) means Phase 2 should run to fill the gaps.

**Interaction with the exploration leg.** Phase 2 runs after Phase 1 and before the exploration leg. The exploration leg's structural changes (from `KleisliComposition`) happen after Phase 2. The convergence cache invalidation runs on structural acceptance, so by the time the next cycle's Phase 2 starts, invalidated entries are gone. The gate sees missing entries (not all coordinates converged) and runs Phase 2. The "all positions have entries" guard handles this correctly.

### Step 5: Prediction-validation per edge (Signals 1 + 5 combined)

**What it does.** Annotate each `ReductionEdge` with a prediction confidence that updates across cycles. The confidence starts at "structural" (the domain ratio model is assumed correct) and degrades to "empirical" if the lift report contradicts the prediction.

**Where it lives.** A new `EdgeConfidence` annotation on `ReductionEdge`, persisted across cycles in `ReductionState`.

**How it works.**
1. **Cycle 1.** For each edge, predict the domain ratio and fibre stability (steps 1 and 2). Run the composition. Compare the lift report against the prediction. If they match (within tolerance), the edge's confidence stays at "structural." If they diverge, downgrade to "empirical."
2. **Cycle 2+.** For "structural" edges, use the prediction to gate convergence transfer and select the downstream encoder without consulting the lift report. For "empirical" edges, fall back to lift-report-based decisions — no prediction, pure reaction.
3. **After a structural acceptance.** Reset edge confidences to "structural" for edges whose upstream or downstream ranges overlap with the structural change's affected range. Edges in unrelated branches of the CDG keep their learned confidence. The `BindSpanIndex` already provides this scoping for convergence cache invalidation — the same mechanism works for edge confidence invalidation.

**What changes.** This adds per-edge state to the reduction pipeline. Currently edge information is computed fresh each cycle from the CDG. The confidence annotation persists across cycles, carrying forward what the reducer learned about each edge's predictability. The state is lightweight — one enum per edge (`.structural` or `.empirical`), reset on structural changes.

**The long-term arc.** The confidence annotation is the seed of the Bayesian update loop described in the Prediction-Validation Loop section. Full Bayesian updating (continuous confidence scores, prior distributions on domain ratio models) is future work. The binary structural/empirical classification captures the essential distinction: does the structural prediction work for this edge, or does it need empirical measurement?
