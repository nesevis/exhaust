# Implementation Plan: Phase 2 — Position-Specific Encoder Migration

## Context

Phase 1 migrated six position-agnostic value encoders to `ComposableEncoder`. Three position-specific encoders remain on the old protocols (`BatchEncoder` / `AdaptiveEncoder`). Each embeds structural assumptions — bind-inner axes, sibling group membership, dependent domains — that Phase 1 encoders don't need.

This phase migrates all three to `ComposableEncoder`, completing the encoder-side refactoring. After Phase 2, every value-reduction encoder in the system conforms to `ComposableEncoder`. Structural deletion encoders (Phase 1 of the scheduler) remain on `BatchEncoder`/`AdaptiveEncoder` by design.

## Encoders

### 1. ProductSpaceBatchEncoder → ComposableEncoder

**Current state:** conforms to `BatchEncoder`. The `encode()` method pre-computes a Cartesian product of bind-inner value candidates (for ≤ 3 bind axes) and returns them as a lazy sequence. The caller wraps this in `PrecomputedBatchEncoder` (an `AdaptiveEncoder`) and runs it through `runBatch()`.

**Instance variables set by caller before `encode()`:**
- `bindIndex: BindSpanIndex?` — identifies bind regions
- `dag: ChoiceDependencyGraph?` — topological order for enumeration
- `dependentDomains: [Int: [UInt64: ClosedRange<UInt64>]]?` — per-upstream-value ranges for dependent axes, pre-computed by `computeDependentDomains()`

**targets parameter:** `.wholeSequence` — completely ignored.

**Migration:** Convert to `ComposableEncoder`. `start()` pre-computes the batch (same logic as current `encode()`), `nextProbe()` yields candidates one at a time. All caller-set instance variables move to `ReductionContext` or are computed internally:

- `bindIndex` → already in `ReductionContext`
- `dag` → already in `ReductionContext`
- `dependentDomains` → computed inside `start()` (the `computeDependentDomains` function moves into the encoder or becomes a static helper; it only needs `bindIndex`, `dag`, and the current sequence, all available in `start()`)

Removes the `PrecomputedBatchEncoder` wrapper and `runBatch()` call site. The caller uses `runComposable()` directly.

### 2. ProductSpaceAdaptiveEncoder → ComposableEncoder

**Current state:** conforms to `AdaptiveEncoder`. The `start()` method extracts bind-inner axes from `bindIndex` (instance variable). Implements delta-debug coordinate halving for > 3 bind axes.

**Instance variable set by caller:** `bindIndex: BindSpanIndex?`

**targets parameter:** `.wholeSequence` — completely ignored.

**Migration:** Straightforward. `start()` reads `context.bindIndex` instead of the instance variable. The axis extraction logic is unchanged. `positionRange` is ignored (the encoder always works on bind-inner positions identified by the bind index).

### 3. RedistributeByTandemReductionEncoder → ComposableEncoder

**Current state:** conforms to `AdaptiveEncoder`. The `start()` method extracts sibling groups from `targets: .siblingGroups(groups)`. Builds window plans for tandem reduction across siblings.

**No instance variables set by caller.** All information comes through `targets`.

**Migration:** Self-extraction pattern (consistent with Phase 1). The encoder's `start()` calls `ChoiceSequence.extractSiblingGroups(from: sequence)` internally, filtered to `positionRange`. No `ReductionContext` changes needed.

## ReductionContext Changes

No new fields required. Phase 2 relies on `bindIndex` and `dag` (already present) and `depthFilter` (added in Phase 1). The `dependentDomains` computation moves into `ProductSpaceBatchEncoder.start()`.

## Steps

### Step 1: Move `computeDependentDomains` to a shared location

- [ ] Extract `computeDependentDomains(bindSpanIndex:dag:sequence:)` from `ReductionState+Bonsai.swift` into a static method accessible to `ProductSpaceBatchEncoder`
- [ ] Verify it only depends on `BindSpanIndex`, `ChoiceDependencyGraph`, and `ChoiceSequence` (no `ReductionState` access)
- [ ] Test: 139 tests pass

### Step 2: ProductSpaceBatchEncoder → ComposableEncoder

- [ ] Change conformance from `BatchEncoder` to `ComposableEncoder`
- [ ] Replace `encode(sequence:targets:)` with `start(sequence:tree:positionRange:context:)` — compute dependent domains internally, pre-compute the batch, store as `[ChoiceSequence]`
- [ ] Add `nextProbe(lastAccepted:)` — yield from pre-computed batch (feedback ignored, same as current `PrecomputedBatchEncoder` semantics)
- [ ] Add `estimatedCost(sequence:tree:positionRange:context:)` — delegate to existing cost logic using `context.bindIndex`
- [ ] Remove `bindIndex`, `dag`, `dependentDomains` instance variables (read from context in `start()`)
- [ ] Update caller in `ReductionState+Bonsai.swift`: replace `runBatch(PrecomputedBatchEncoder(...))` with `runComposable(productSpaceBatchEncoder, ...)`
- [ ] Remove `PrecomputedBatchEncoder` wrapper if no other users
- [ ] Test: 139 tests pass

### Step 3: ProductSpaceAdaptiveEncoder → ComposableEncoder

- [ ] Change conformance from `AdaptiveEncoder` to `ComposableEncoder`
- [ ] Replace `start(sequence:targets:convergedOrigins:)` with `start(sequence:tree:positionRange:context:)` — read `context.bindIndex` instead of instance variable
- [ ] Add `estimatedCost(sequence:tree:positionRange:context:)` — delegate using `context.bindIndex`
- [ ] Remove `bindIndex` instance variable
- [ ] Update caller: replace `runAdaptive(productSpaceAdaptiveEncoder, ...)` with `runComposable(...)`, remove the `productSpaceAdaptiveEncoder.bindIndex = ...` assignment
- [ ] Test: 139 tests pass

### Step 4: RedistributeByTandemReductionEncoder → ComposableEncoder

- [ ] Change conformance from `AdaptiveEncoder` to `ComposableEncoder`
- [ ] Replace `start(sequence:targets:convergedOrigins:)` with `start(sequence:tree:positionRange:context:)` — extract sibling groups via `ChoiceSequence.extractSiblingGroups(from: sequence)` internally, filtered to `positionRange`
- [ ] Add `estimatedCost(sequence:tree:positionRange:context:)` — count sibling groups in range
- [ ] Keep the old `start(sequence:targets:convergedOrigins:)` as an internal method if the new `start()` delegates to it, or inline the extraction
- [ ] Update caller: replace `runAdaptive(tandemEncoder, targets: .siblingGroups(allSiblings), ...)` with `runComposable(tandemEncoder, positionRange: fullRange, ...)`
- [ ] Test: 139 tests pass

### Step 5: Remove `runAdaptive` for value encoders

After all three are migrated, verify no value/redistribution encoder calls `runAdaptive`:
- [ ] `runAdaptive` should only be called for structural deletion encoders
- [ ] Consider marking `AdaptiveEncoder` as deprecated or documenting its scope (structural encoders only)
- [ ] Test: 139 tests pass

### Step 6: Update encoder test files

- [ ] Update ProductSpaceEncoderTests to use `ComposableEncoder` interface
- [ ] Update any tests that pass `.siblingGroups` targets directly — migrate to positionRange
- [ ] Test: 139 tests pass

## Verification

After each step: `swift test --filter "Shrinking|StructuralPathological|KleisliComposition|ConvergenceCache|EncoderTests"` — 139 tests pass.

After Step 4: verify seeded profiling numbers are identical to Phase 1 baseline (same cycles, probes for BinaryHeap, Difference, Distinct, Reverse, Coupling). The migration is behavioral-preserving.

After Step 5: `grep -rn 'runAdaptive' ReductionState+Bonsai.swift` shows only structural deletion call sites (lines 192–232).

## Risks

**ProductSpaceBatch pre-computation in start().** The current `encode()` is a lazy sequence — probes are generated on demand. Converting to `start()` + `nextProbe()` requires pre-computing the full batch in `start()` (since `ComposableEncoder.nextProbe` has no access to the generator). For ≤ 3 bind axes with typical domains, the batch is small (< 1000 candidates). For pathological cases (3 axes × 100 domain = 10⁶), the batch could be large. The current `runBatch` already materializes the full lazy sequence into an array (`PrecomputedBatchEncoder`), so this doesn't change the peak memory — it's just more explicit.

**Sibling group extraction cost.** `extractSiblingGroups` walks the full sequence. If called inside `start()` for every `runComposable` invocation, this repeats the walk. Currently the caller extracts once and passes the result. The per-invocation cost is O(sequence length) — negligible relative to materialization cost. If profiling shows otherwise, the extraction can be cached in a SpanCache-like mechanism.

**`computeDependentDomains` extraction.** This function currently lives in `ReductionState+Bonsai.swift` and accesses `self` members. It needs to be factored into a pure function that takes its dependencies explicitly. If it accesses anything beyond `bindIndex`, `dag`, and `sequence`, additional parameters may be needed.

## Files Changed

| File | Change |
|------|--------|
| `ProductSpaceEncoder.swift` | Both encoders: `BatchEncoder`/`AdaptiveEncoder` → `ComposableEncoder` |
| `RedistributeByTandemReductionEncoder.swift` | `AdaptiveEncoder` → `ComposableEncoder`, self-extraction |
| `ReductionState+Bonsai.swift` | Caller updates: `runBatch`/`runAdaptive` → `runComposable`, remove instance variable assignments |
| `ReductionState.swift` | Extract `computeDependentDomains` to shared location |
| `ProductSpaceEncoderTests.swift` | Update to `ComposableEncoder` interface |
| `EncoderTests.swift` | Update tandem reduction tests |
