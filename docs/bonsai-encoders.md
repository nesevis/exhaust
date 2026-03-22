# Bonsai Encoders

Reference for all encoders used in the Bonsai reduction pipeline: their purpose, algorithm, probe budget, Bonsai phase, and dominance lattice position.

## Pipeline overview

```
Projection (one-shot)
  → [Base Descent ↔ Fibre Descent] × maxStalls
  → Relax Round (fallback when both stall)
```

- **Projection** — `StructuralIsolator` zeros values that no structural decision depends on. One shot before the loop.
- **Base Descent** — minimises the trace structure (fewer choices, simpler branching, shorter sequences). Restarts from the top on any acceptance.
- **Fibre Descent** — minimises the value assignment within the fixed structure. A `StructuralFingerprint` guard rolls back any probe that crosses a structural boundary.
- **Relax Round** — escapes local minima by temporarily worsening the sequence, then recovering.

Per-round budgets: base descent 1950, fibre descent 975, relax round 325.

---

## Dominance lattice

Within a hom-set (encoders sharing the same decoder), the dominance relation skips a less-aggressive encoder when a more-aggressive one has already succeeded. The lattice is invalidated at leg boundaries or after any structural acceptance.

```
Structural deletion
  deleteContainerSpans ─────────────────────┐
                                            ⇒ deleteContainerSpansWithRandomRepair (skip)
  deleteAlignedSiblingWindows ──────────────┘

Value minimization
  zeroValue ⇒ binarySearchToSemanticSimplest (skip)
  zeroValue ⇒ binarySearchToRangeMinimum    (skip)
  binarySearchToSemanticSimplest ⇒ binarySearchToRangeMinimum (skip)
```

No cross-phase dominance — the phase ordering handles inter-phase sequencing.

Reference: Sepúlveda-Jiménez, Def 15.3 (2-cell dominance).

---

## Encoder ordering

Within the deletion and value-minimization slots, ordering is cost-based (cheapest first) and adapts using **move-to-front**: when an encoder is accepted, it is promoted to the front of its slot order for subsequent cycles. This persists across cycles within a run.

---

## Base Descent encoders

### Sub-phase 1a — Branch simplification

Runs first each iteration. Restarts the entire base descent cycle on any acceptance. Requires a fresh materialization with `materializePicks: true` so non-selected branch alternatives are visible; the `branchTreeDirty` flag prevents redundant materializations.

---

#### `DeleteByBranchPromotionEncoder`

| | |
|---|---|
| **EncoderName** | `.deleteByPromotingSimplestBranch` |
| **Phase** | `.structuralDeletion` |
| **Encoder type** | `BatchEncoder` |
| **Dominance** | None |

Replaces a branch subtree with a simpler (lower-index) alternative from the same pick site, reducing the total branch complexity.

Iterates branch groups from most complex to least complex. For each target branch, tries every simpler source branch in shortlex order as a replacement. Validates that the candidate shortlex-precedes the current sequence before emitting it.

**Probes:** ~20 (fixed estimate).

---

#### `DeleteByBranchPivotEncoder`

| | |
|---|---|
| **EncoderName** | `.deleteByPivotingToAlternativeBranch` |
| **Phase** | `.structuralDeletion` |
| **Encoder type** | `BatchEncoder` |
| **Dominance** | None |

Moves the `.selected` marker to a non-selected alternative at each pick site, switching the active branch without replacing the full subtree.

Iterates pick sites (groups where exactly one element is `.selected`). For each site, tries non-selected alternatives in shortlex order, moving the `.selected` marker. Validates shortlex improvement before emitting.

**Probes:** ~10 (fixed estimate).

---

### Sub-phase 1b — Structural deletion

Runs as an inner loop that restarts on any acceptance until no further progress is possible. Iterates scopes in DAG topological order (bind roots first, depth-0 content last). After the sequential adaptive loop, a `MutationPool` fallback composes disjoint individually-rejected span pairs into joint candidates (sequences ≤ 500 entries only).

---

#### `DeleteContainerSpansEncoder`

| | |
|---|---|
| **EncoderName** | `.deleteContainerSpans` |
| **Phase** | `.structuralDeletion` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | Dominates `.deleteContainerSpansWithRandomRepair` |

Removes whole container subtrees (groups, sequences, binds) using adaptive batch sizing.

Filters spans to container opener markers (`.sequence(true)`, `.group(true)`, `.bind(true)`). Uses `FindIntegerStepper` to binary-search for the largest contiguous batch of same-depth spans that can be deleted simultaneously.

**Probes:** ~10 × container-span count.

---

#### `DeleteSequenceElementsEncoder`

| | |
|---|---|
| **EncoderName** | `.deleteSequenceElements` |
| **Phase** | `.structuralDeletion` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | None |

Removes element groups within arrays using adaptive batch sizing.

Same adaptive deletion mechanism as `DeleteContainerSpansEncoder`, applied to pre-filtered sequence element spans.

**Probes:** ~10 × sequence-element-span count.

---

#### `DeleteSequenceBoundariesEncoder`

| | |
|---|---|
| **EncoderName** | `.deleteSequenceBoundaries` |
| **Phase** | `.structuralDeletion` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | None |

Removes sequence boundary marker pairs, merging adjacent sequences.

Same adaptive deletion mechanism, applied to pre-filtered boundary spans.

**Probes:** ~10 × boundary-span count.

---

#### `DeleteFreeStandingValuesEncoder`

| | |
|---|---|
| **EncoderName** | `.deleteFreeStandingValues` |
| **Phase** | `.structuralDeletion` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | None |

Removes individual values that are not enclosed in any container group.

Same adaptive deletion mechanism, applied to pre-filtered free-standing value spans.

**Probes:** ~10 × free-standing-value-span count.

---

#### `DeleteAlignedWindowsEncoder`

| | |
|---|---|
| **EncoderName** | `.deleteAlignedSiblingWindows` |
| **Phase** | `.structuralDeletion` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | Dominates `.deleteContainerSpansWithRandomRepair` |

Coordinated deletion across structurally aligned sibling containers — for example, deleting the same index slot from every array in a list of arrays simultaneously.

Two phases. Phase 1 (contiguous window search): per cohort, per slot position, `FindIntegerStepper` binary-searches for the largest contiguous batch. If the best batch size is zero, a non-monotone fallback tries targeted positions individually. Phase 2 (beam search): bitmask-encoded non-contiguous subsets, expanded layer-by-layer with bounded beam width, scored by heuristic and pruned. Each rejected candidate attempts PRNG repair before being discarded.

**Probes:** ~100 × container-span count.

---

#### `DeleteContainerSpansWithRandomRepairEncoder`

| | |
|---|---|
| **EncoderName** | `.deleteContainerSpansWithRandomRepair` |
| **Phase** | `.structuralDeletion` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | Dominated by `.deleteContainerSpans` or `.deleteAlignedSiblingWindows` — skipped if either has succeeded in the same hom-set. |

Speculatively deletes spans and relies on `GuidedMaterializer` PRNG fallback to repair any structure broken by the deletion.

Same adaptive batch-deletion as `DeleteContainerSpansEncoder`, but uses a speculative decoder (PRNG fallback enabled, no shortlex check). Runs after the guided encoders in slot order and is skipped by the dominance lattice if a guided encoder already succeeded — guided deletion subsumes what speculative deletion can offer on the same span pool.

**Probes:** ~10 × container-span count.

---

### Sub-phase 1c — Joint bind-inner reduction

Runs only when `hasBind`. Reduces the controlling values that determine downstream structure. Restarts the entire base descent cycle on any acceptance.

---

#### `ProductSpaceBatchEncoder`

| | |
|---|---|
| **EncoderName** | `.productSpaceBatch` |
| **Phase** | `.valueMinimization` |
| **Encoder type** | `BatchEncoder` |
| **Condition** | k ≤ 3 bind regions |
| **Dominance** | None |

Enumerates the joint product space of all bind-inner values, reducing all controlling values simultaneously.

Computes a `BinarySearchLadder` of halving midpoints per axis (current → target). Builds the Cartesian product of these ladders (or a dependent product for nested binds, respecting DAG topology), sorted shortlex. Candidates are precomputed once and reused across two tiers:

- Tier 1: guided decoder (clamps bound entries to the current fallback tree).
- Tier 2: PRNG retries with largest-fibre-first ordering (up to four salted attempts). A regime probe runs first — if the simplest-values witness already satisfies the property in the elimination regime, the PRNG retries are skipped.

**Probes:** up to ladderSize^k, capped at 512.

---

#### `ProductSpaceAdaptiveEncoder`

| | |
|---|---|
| **EncoderName** | `.productSpaceAdaptive` |
| **Phase** | `.valueMinimization` |
| **Encoder type** | `AdaptiveEncoder` |
| **Condition** | k > 3 bind regions |
| **Dominance** | None |

Delta-debug coordinate halving for high-arity bind generators where full product enumeration is infeasible.

Phase 1 (halveAll): halves all active coordinates simultaneously toward their targets. On acceptance, updates coordinates and repeats. On rejection, enters Phase 2 (deltaDebug): partitions the active coordinate set in half and recursively finds the maximal accepted subset, converging each axis independently.

**Probes:** O(k · log(range) · log(k)).

---

#### Value encoders on bind-inner spans

`ZeroValueEncoder`, `BinarySearchToSemanticSimplestEncoder`, `BinarySearchToRangeMinimumEncoder`, and `ReduceFloatEncoder` run after the product-space encoders, scoped to bind-inner spans only (not all depth-0 spans), with `structureChanged: true`. Their algorithms are identical to the fibre descent instances described below.

---

## Fibre Descent encoders

Processes DAG leaf ranges first (bound leaves before independent leaves), then a covariant sweep at intermediate bind depths (depth 1 → max depth). Redistribution runs once at the end.

Value encoders run in `trainOrder` with move-to-front. A `StructuralFingerprint` guard fires per-acceptance for bound non-constant leaf ranges, rolling back any probe that causes a structural change.

### Value encoders

---

#### `ZeroValueEncoder`

| | |
|---|---|
| **EncoderName** | `.zeroValue` |
| **Phase** | `.valueMinimization` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | Dominates `.binarySearchToSemanticSimplest` and `.binarySearchToRangeMinimum` — both are skipped if this succeeds. |

Sets each target value to its semantic simplest form: zero for unsigned integers, zero for signed integers (crossing through zero if needed), the range's lower bound when zero falls outside an explicit valid range.

Two phases. Phase 1: tries setting all targets to simplest simultaneously — handles filter-coupled generators where values must move together. Phase 2: processes each span individually, updating the base sequence on each acceptance so later spans see the simplified state.

**Probes:** 1 + t (t = value span count).

---

#### `BinarySearchToSemanticSimplestEncoder`

| | |
|---|---|
| **EncoderName** | `.binarySearchToSemanticSimplest` |
| **Phase** | `.valueMinimization` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | Dominated by `.zeroValue`. Dominates `.binarySearchToRangeMinimum`. |

Binary-searches each target value toward zero, with a cross-zero phase for signed integers.

Per target, sequentially: (1) `BinarySearchStepper` narrows the bit-pattern interval toward zero; (2) cross-zero phase walks shortlex key space downward from the current value toward zero — essential for signed integers, which have a shortlex order that does not match numeric order near zero.

**Probes:** t × 80.

---

#### `BinarySearchToRangeMinimumEncoder`

| | |
|---|---|
| **EncoderName** | `.binarySearchToRangeMinimum` |
| **Phase** | `.valueMinimization` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | Dominated by `.zeroValue` and `.binarySearchToSemanticSimplest`. |

Binary-searches each target toward its range's `reductionTarget` (the range minimum, as determined by `ChoiceValue.reductionTarget(in:)`).

Per target, sequentially: `BinarySearchStepper` narrows the bit-pattern interval `[reductionTarget, currentBitPattern]`. Used when zero is not achievable but the range minimum is.

**Probes:** t × 64.

---

#### `ReduceFloatEncoder`

| | |
|---|---|
| **EncoderName** | `.reduceFloat` |
| **Phase** | `.valueMinimization` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | None (operates on float spans; value encoders above operate on integer spans). |

Hypothesis-style four-stage float reduction pipeline.

Per float target: (1) special-value short-circuit — tries a hardcoded set of candidates (0.0, 1.0, −1.0, and so on); (2) precision truncation via power-of-two scaling toward the nearest representable integer; (3) integer-domain binary search on the integral part; (4) numerator/denominator binary search using `as_integer_ratio`-style decomposition to reduce the rational representation.

**Probes:** t × 94 (~20 special values + truncation + ~64 binary search steps).

---

### Redistribution encoders (end of fibre descent)

---

#### `RedistributeByTandemReductionEncoder`

| | |
|---|---|
| **EncoderName** | `.redistributeSiblingValuesInLockstep` |
| **Phase** | `.redistribution` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | None |

Reduces sibling value pairs in lockstep — shifts all values in a suffix window toward their reduction target by the same delta. Handles coupled values where reducing one independently would violate a filter.

Builds suffix-window plans per same-tag index set (dropping the leading sibling each iteration to avoid the leader blocking progress). For each plan: attempts a direct full-distance shot first, then `MaxBinarySearchStepper` finds the optimal shared delta.

**Probes:** g × 65 (g = sibling group count; ~1 direct probe + ~64 binary search steps per group).

---

#### `RedistributeAcrossValueContainersEncoder`

| | |
|---|---|
| **EncoderName** | `.redistributeArbitraryValuePairsAcrossContainers` |
| **Phase** | `.redistribution` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | None |

Decreases one value while increasing another by the same delta — cross-container redistribution that moves magnitude from one coordinate to another.

Builds all oriented value pairs, sorted by lhs-distance descending (largest reduction opportunity first). Supports same-tag integer pairs, same-tag float pairs (via rational arithmetic), and cross-type float/integer pairs. Per orientation: monotone phase via `FindIntegerStepper`, then a fallback phase with targeted deltas (full distance, −1, ÷2, ÷4, wrapping boundary).

**Probes:** min(t², 240) × 20.

---

#### `RedistributeAcrossBindRegionsEncoder`

| | |
|---|---|
| **EncoderName** | `.redistributeInnerValuesBetweenBindRegions` |
| **Phase** | `.redistribution` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | None |

Same cross-redistribution logic as `RedistributeAcrossValueContainersEncoder`, scoped to bind-region inner values. The guided decoder with per-region maximization regenerates bound content after each inner-value change.

Extracts the inner numeric value per bind region, builds redistribution plans using rational arithmetic in the shared numerator space. Monotone phase via `FindIntegerStepper`, then fallback deltas as above. Uses a guided decoder with `maximizeBoundRegionIndices` to give the target region's bound subtree the best chance of reproducing the failure.

**Probes:** min(r², 32) × 20 (r = bind region count).

---

## Relax Round encoder

---

#### `RelaxRoundEncoder`

| | |
|---|---|
| **EncoderName** | `.relaxRound` |
| **Phase** | `.exploration` |
| **Encoder type** | `AdaptiveEncoder` |
| **Dominance** | None (exploration phase; no dominance relations defined). |

Escapes local minima by zeroing one value and absorbing its full magnitude into another, temporarily worsening the sequence, then exploiting the relaxed state with a prune pass and a train pass.

Builds all ordered same-tag value pairs, sorted by lhs-distance descending. Per pair: sets lhs to its reduction target and adds the full delta to rhs. Uses an exact speculative decoder (no shortlex check) so temporarily larger sequences are accepted. Rejects candidates that grow the sequence (PRNG fallback artefact). After any redistribution is accepted, runs `runBaseDescent` then `runFibreDescent` on the relaxed state. Accepts the full round only if the final sequence shortlex-precedes the pre-relaxation checkpoint; otherwise rolls back all state.

**Probes:** t × (t − 1) redistribution probes, plus the base descent and fibre descent budgets of the exploitation pass.
