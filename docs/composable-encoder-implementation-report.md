# Implementation Report: Composable Encoder Refactoring

## What was accomplished

**The encoder algebra.** Every encoder in the reducer is now a `ComposableEncoder` — a role-agnostic probe strategy that works on any position range. The protocol replaces `PointEncoder` (renamed), and encoders no longer conform to `AdaptiveEncoder` for value reduction (only structural deletion's `AdaptiveDeletionEncoder` driver persists as an internal implementation detail). 42 files changed, ~2900 insertions, ~2100 deletions across 20 commits.

**Encoder consolidation.** 20 monolithic encoders became 13 composable ones:
- Four span-deletion encoders → one `DeletionEncoder` parameterised by `DeletionSpanCategory`
- Two binary search encoders → one `BinarySearchEncoder` parameterised by `Configuration`
- Two branch encoders → one `BranchSimplificationEncoder` parameterised by `Strategy`
- Aligned window deletion → split into `ContiguousWindowDeletionEncoder` + `BeamSearchDeletionEncoder` (dominance pair)
- Seven files deleted. Zero monolithic encoders remain.

**The factory and descriptor chains.** `EncoderFactory` centralises all encoder selection. `MorphismDescriptor` with dominance edges replaced hand-coded multi-tier orchestration. The ProductSpaceBatch three-tier pattern (guided → regime probe → PRNG retries) is declarative. Slot rotation is gone — `runDescriptorChain` processes factory-emitted descriptors.

**Fibre prediction.** Discovery lift at the upstream's reduction target predicts downstream fibre size. The factory splits prediction strategy on `isStructurallyConstant`:

- **Constant edges** (fibre shape invariant under upstream value changes): the prediction is a structural fact — the discovery lift at the target sees the same fibre as every other upstream value. The factory commits to the prediction and selects the downstream encoder at construction time. 5/5 accuracy, exact by construction.
- **Data-dependent edges** (fibre varies with upstream value): the prediction is an ordering heuristic only — the factory uses the current-sequence fibre size to prioritise which edges get budget first. The actual downstream encoder selection happens at runtime when `FibreCoveringEncoder` inspects the real fibre at `start()` time. 8/11 on the ordering; the 3 wrong orderings don't cause regressions — they mean a less-optimal edge ran first, not a wrong encoder selection.

Leverage ordering scores edges by `leverage / requiredBudget`.

**DownstreamPick.** Runtime strategy selection for the downstream role in a composition. A `pick` over the encoder space — internal to the morphism, not a branching composition (the S-J algebra does not allow branching). Three alternatives with fibre-based predicates: exhaustive (≤ 64 combinations), pairwise (2–20 parameters), ZeroValue (catchall). Selected at `start()` time based on actual fibre characteristics. `isConvergenceTransferSafe` returns `false` when the selected alternative changes between upstream iterations, gating convergence transfer in `KleisliComposition`. Closes the runtime bail gap — data-dependent edges where `FibreCoveringEncoder` would have bailed now fall through to `ZeroValueEncoder`.

**Three-way fibre telemetry.** `fibre=Xe/Yp/Zz` in `ExhaustReport.profilingSummary` reports exhaustive, pairwise, and ZeroValue downstream starts separately. `fibreZeroValueStarts` flows through `KleisliComposition` → `ReductionState` → `ReductionStats` → `ExhaustReport`, accumulated independently from `fibreExceededExhaustiveThreshold`.

**Fibre descent gating (Step 1).** Skips Phase 2 on stall cycles when all coordinates are converged. Fires on the FibreDescentGate test (7 of 9 cycles gated). Saves computational overhead — probe count unchanged because converged encoders already produce 0 materializations.

**Leverage ordering (Step 3).** Composition edges ordered by structural impact per probe. One comparator change.

**SearchMode — removed.** `SearchMode` (`reduceFromKnownFailure` vs `discoverFailure`) was introduced as infrastructure for the downstream role in compositions. Analysis showed no current encoder should consume it: `BinarySearchEncoder` assumes monotonic failure boundaries (a reduction morphism, not a discovery one); `RelaxRoundEncoder` and `ReduceFloatEncoder` are approximate reduction morphisms in the sense of Sepúlveda-Jiménez §11.2 — rounding toward simpler values has no semantic grounding when the failure status is unknown; `FibreCoveringEncoder` and `ZeroValueEncoder` are already inherently discovery-compatible. The reduce-vs-discover distinction is implicit in the composition structure itself (the outer decoder evaluates the composed probe, not the downstream's local improvement). Removed as premature infrastructure.

**Structural pathological test suite.** Eight tests exercising bind-dependent CDG topologies: threshold crossing, cross-level sum (composition-required), nested binds (2 and 3 levels), wide CDG, multi-parameter fibre, non-monotonic fibre, fibre descent gate.

## What the planning document prescribed vs what was built

| Planning document step | Status | Notes |
|---|---|---|
| Step 1: Fibre descent gating (Signal 4) | Implemented | Gates on stall + convergence. Saves overhead, not probes. |
| Step 2: Domain ratio / encoder selection (Signal 1) | Implemented | Constant edges: factory commits at construction time (100% accurate). Data-dependent edges: `DownstreamPick` selects at runtime from three alternatives (exhaustive/pairwise/ZeroValue). Discovery lift prediction used for leverage ordering (73% on data-dependent edges). |
| Step 3: Structural leverage ordering (Signal 2) | Implemented | Edges ordered by leverage / requiredBudget. |
| Steps 4+5: Fibre stability / prediction-validation loop (Signal 3) | Not implemented | Requires search-based downstream for convergence transfer. |
| Post-termination verification | Previously implemented | Unchanged. |
| Warm-start validation | Previously implemented | Unchanged. |
| Non-monotonicity detection (Signal 7) | Not implemented | Independent of composition framework. |

## Gaps

**Downstream encoder selection.** Closed. Constant edges: factory commits to prediction at construction time. Data-dependent edges: `DownstreamPick` selects the downstream encoder at `start()` time based on actual fibre characteristics — exhaustive (≤ 64), pairwise (2–20 params), or ZeroValue (catchall). The runtime bail gap (fibre too large for covering, no downstream search) is closed: `DownstreamPick`'s ZeroValue alternative catches fibres that `FibreCoveringEncoder` would have bailed on.

**Convergence transfer.** Still 0/0/0 across all tests. Requires a search-based downstream encoder that uses warm-start — `FibreCoveringEncoder` always cold-starts.

**`ReductionContext` as reference type.** Attempted `struct` → `final class` conversion to enable mid-chain span refresh for structural deletion. Caused snapshot/state issues. Reverted. Structural deletion uses per-encoder restart instead of descriptor chains (sequence length changes invalidate span positions). The reference-type context remains a future option for the closed-loop reducer.

**`runAdaptive` removal.** `runAdaptive` is dead code (no callers). `runBatch` removed. `BatchEncoder` protocol has no conformers. These could be deleted.

**Prediction accuracy reporting.** The 81% headline accuracy blends a 100% structural-fact metric with a 73% ordering-heuristic metric. These have different failure modes: wrong structural prediction → wrong encoder → regression; wrong ordering → suboptimal budget allocation → more probes, same quality. Three-way fibre telemetry (`fibre=Xe/Yp/Zz`) now reports ground truth; separate prediction accuracy reporting (constant vs data-dependent) is a future improvement.

## What worked well

- **Incremental migration.** Dual conformance (both `AdaptiveEncoder` and `ComposableEncoder`) allowed per-encoder migration with 138-test gate after each step. No big-bang rewrite.
- **Dominance chains.** The ProductSpaceBatch three-tier orchestration (170 lines of hand-coded control flow) became three declarative descriptors. The contiguous/beam split is a natural dominance pair.
- **Parameterised encoders.** `BinarySearchEncoder(.rangeMinimum)` vs `(.semanticSimplest)` proved the pattern. `DeletionEncoder`, `BranchSimplificationEncoder` followed the same shape.
- **Role-agnostic design.** The vocabulary correction (horizontal/vertical → upstream/downstream/standalone) clarified that encoders are probe strategies, not role-bound types. `DownstreamPick` is internal parameterisation — the S-J algebra does not allow branching compositions.

## What didn't work

- **Descriptor chain for structural deletion.** Deletions change sequence length, invalidating span positions for subsequent encoders. The chain crashed on stale indices. Per-encoder restart with fresh span extraction is required. The efficiency gain from multi-encoder-per-restart was real but unsafe.
- **`ReductionContext` as class.** The `structurallyStale` flag leaked across sections, corrupting reduction paths. Value type semantics (struct) are correct for context — each section gets its own copy. Shared mutable state needs explicit mechanisms (span cache, convergence cache), not implicit reference sharing.
- **Aggressive downstream selection.** Selecting `ZeroValueEncoder` for pairwise/tooLarge fibres based on the discovery lift prediction failed on CouplingScaling. The prediction is from the target value; the actual fibre at intermediate values can be orders of magnitude larger. Resolved: structural-constancy split for predictions, `DownstreamPick` for runtime selection.

## Next steps

1. **Non-monotonicity detection** (Signal 7) — `sawUnexpectedResult` flag on binary search steppers, bounded exhaustive scan of remaining range. Independent of composition. Correctness improvement.
2. **Delete dead code** — `runAdaptive`, `BatchEncoder` protocol, old `AdaptiveEncoder` `start()` methods kept for test compat.
3. **Closed-loop integration** — the composable toolbox is the component library for the closed-loop reducer. Each encoder is independently schedulable, gatable, and budgetable. The factory assigns roles; the loop evaluates results and adapts.
