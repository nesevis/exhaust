# Implementation Plan: Composable Encoder Refactoring

## Overview

The 20 implemented encoders are monolithic — each embeds both a search strategy and assumptions about where it operates. The compositional algebra (see "Fibrational Structure of the Encoder Algebra" in `reduction-planning.md`) separates these concerns: a composable encoder is a role-agnostic probe strategy, and the factory assigns it to a role (upstream, downstream, or standalone) based on CDG position. The same encoder can serve in any role — it does not know or care which one.

This refactoring makes encoders composable by migrating them to the `ComposableEncoder` protocol, then builds the scheduling infrastructure that assigns roles and processes descriptors.

## Encoder Classification

The role-based composition applies to the value-reduction and redistribution encoders. Structural deletion encoders (Phase 1) operate on the ChoiceTree before compositions are relevant — they remain unchanged.

### Structural (unchanged)

These operate on tree structure, not on the opfibration's base or fibres. They stay as `AdaptiveEncoder` / `BatchEncoder` and continue to run in Phase 1.

| Encoder | File |
|---------|------|
| `deleteByPromotingSimplestBranch` | `DeleteByBranchPromotionEncoder.swift` |
| `deleteByPivotingToAlternativeBranch` | `DeleteByBranchPivotEncoder.swift` |
| `deleteContainerSpans` | `DeleteContainerSpansEncoder.swift` |
| `deleteSequenceElements` | `DeleteSequenceElementsEncoder.swift` |
| `deleteSequenceBoundaries` | `DeleteSequenceBoundariesEncoder.swift` |
| `deleteFreeStandingValues` | `DeleteFreeStandingValuesEncoder.swift` |
| `deleteContainerSpansWithRandomRepair` | `DeleteContainerSpansWithRandomRepairEncoder.swift` |
| `deleteAlignedSiblingWindows` | `DeleteAlignedWindowsEncoder.swift` |

### Position-agnostic value encoders (migrate to PointEncoder)

These already work on any value coordinate. Their logic does not assume a CDG role — they binary-search, zero, or float-reduce whatever targets they receive. In a composition, the same encoder instance can serve as upstream (when targeting a bind-inner position) or downstream (when targeting a leaf position). The encoder does the same thing in both cases.

| Encoder | File | Notes |
|---------|------|-------|
| `zeroValue` | `ZeroValueEncoder.swift` | Two-phase: all-at-once then individual. Already position-agnostic. |
| `binarySearchToSemanticSimplest` | `BinarySearchToSemanticSimplestEncoder.swift` | Cross-zero probes, warm-start from convergence cache. Position-agnostic. |
| `binarySearchToRangeMinimum` | `BinarySearchToRangeMinimumEncoder.swift` | Downward-only binary search, warm-start. Position-agnostic. |
| `reduceFloat` | `ReduceFloatEncoder.swift` | Four-stage float pipeline. Position-agnostic. |
| `relaxRound` | `RelaxRoundEncoder.swift` | Speculative zero-and-redistribute. Position-agnostic. |
| `redistributeArbitraryValuePairsAcrossContainers` | `RedistributeAcrossValueContainersEncoder.swift` | Cross-container pair redistribution. Derives pair candidates at runtime. Position-agnostic. |

### Position-specific encoders (require adaptation)

These embed assumptions about CDG structure — bind-inner indices, sibling group membership, or fibre boundaries. They need targeted changes to conform to `PointEncoder` with their structural knowledge supplied via `ReductionContext` rather than baked in.

| Encoder | File | Structural assumption |
|---------|------|-----------------------|
| `productSpaceBatch` | `ProductSpaceEncoder.swift` | Requires `BindSpanIndex` to identify bind-inner axes. Cartesian product over bind-inner values. |
| `productSpaceAdaptive` | `ProductSpaceEncoder.swift` | Same — delta-debug over bind-inner coordinates. |
| `redistributeSiblingValuesInLockstep` | `RedistributeByTandemReductionEncoder.swift` | Requires sibling group structure. Per-tag index sets within groups. |
| `kleisliComposition` (FibreCoveringEncoder) | `FibreCoveringEncoder.swift` | Already conforms to `PointEncoder`. Requires `positionRange` for fibre boundary. |

## Phase 1: Protocol Migration

Migrate position-agnostic value encoders from `AdaptiveEncoder` to native `PointEncoder` conformance, eliminating the `LegacyEncoderAdapter` indirection for these encoders.

### For each position-agnostic encoder

The transformation is mechanical. The `LegacyEncoderAdapter` already shows the mapping:

| `AdaptiveEncoder` | `PointEncoder` |
|--------------------|----------------|
| `start(sequence:targets:convergedOrigins:)` | `start(sequence:tree:positionRange:context:)` |
| Target extraction from `TargetSet` | Target extraction from `positionRange` + sequence |
| `convergedOrigins` parameter | `context.convergedOrigins` |
| `estimatedCost(sequence:bindIndex:)` | `estimatedCost(sequence:tree:positionRange:context:)` |

**Changes per encoder:**

1. Replace `AdaptiveEncoder` conformance with `PointEncoder` conformance.
2. Replace `start(sequence:targets:convergedOrigins:)` with `start(sequence:tree:positionRange:context:)`. The body extracts value spans from `positionRange` (same logic as `LegacyEncoderAdapter.start`).
3. Replace `estimatedCost(sequence:bindIndex:)` with `estimatedCost(sequence:tree:positionRange:context:)`.
4. `nextProbe(lastAccepted:)` and `convergenceRecords` are unchanged — same signature in both protocols.
5. Remove the `phase` property if it was only used for slot assignment (the factory assigns roles now).

**Order:** ZeroValue first (simplest), then BinarySearchToRangeMinimum, BinarySearchToSemanticSimplest, ReduceFloat (most complex), then RedistributeAcross and RelaxRound.

**Testing:** After each encoder migration, run the full shrinking test suite (63 tests). The encoder's behaviour is identical — only the interface changes. Any test failure is a migration bug.

### Files changed

| File | Change |
|------|--------|
| `ZeroValueEncoder.swift` | `AdaptiveEncoder` → `PointEncoder` conformance |
| `BinarySearchToRangeMinimumEncoder.swift` | Same |
| `BinarySearchToSemanticSimplestEncoder.swift` | Same |
| `ReduceFloatEncoder.swift` | Same |
| `RelaxRoundEncoder.swift` | Same |
| `RedistributeAcrossValueContainersEncoder.swift` | Same |
| `PointEncoder.swift` | Remove `LegacyEncoderAdapter` once all consumers are migrated |

### Callers to update

The slot rotation in `ReductionState.swift` and `BonsaiScheduler.swift` instantiates encoders and calls `start()`. These call sites need to pass `ReductionContext` instead of individual parameters. The `ReductionContext` struct already exists and carries `bindIndex`, `convergedOrigins`, and `dag`.

## Phase 2: Position-Specific Encoder Adaptation — COMPLETE (2 of 3)

### ProductSpaceAdaptive — DONE

Conforms to `ComposableEncoder`. Reads `context.bindIndex` instead of caller-set instance variable. Delta-debug coordinate halving logic unchanged.

### RedistributeByTandemReduction — DONE

Conforms to `ComposableEncoder`. Self-extracts sibling groups via `ChoiceSequence.extractSiblingGroups()` in `start()`, consistent with Phase 1's self-extraction pattern.

### ProductSpaceBatch — DEFERRED TO PHASE 3

The current caller has a multi-tier pattern: guided decoder → regime probe → PRNG retries, all on the same pre-computed candidates. This orchestration doesn't fit `runComposable` (single encoder, single decoder). Phase 3 replaces it with a dominance chain of three `MorphismDescriptor` entries — same encoder with different decoder modes, connected by dominance edges. See "Decoder parameterisation as dominance chains" in Phase 3.

### FibreCoveringEncoder

Already conforms to `ComposableEncoder`. No changes needed.

## Phase 3: Factory and Role Assignment

Build the factory that reads CDG structure and emits `MorphismDescriptor` arrays for the scheduler.

### MorphismDescriptor

```swift
struct MorphismDescriptor {
    let encoder: any ComposableEncoder
    let decoderMode: DecoderMode
    let probeBudget: Int
    let rollback: RollbackPolicy
    let role: CompositionRole
    let classification: PositionClassification
    let dominates: [MorphismDescriptor.ID]
}
```

`dominates` expresses priority ordering between descriptors. When a descriptor's encoder accepts a probe, all descriptors it dominates are suppressed by the scheduler. This replaces hand-coded multi-tier orchestration with a declarative dominance chain.

```swift
enum CompositionRole {
    case upstream    // Proposes fibres. Output is lifted before evaluation.
    case downstream  // Explores within a fibre. Output is evaluated directly.
    case standalone  // No composition. Output is evaluated directly.
}
```

### Decoder parameterisation as dominance chains

The two parameterisation axes (encoder configuration, decoder mode) interact through dominance. The same encoder with different decoder modes produces a family of morphisms. The factory orders them by reliability (exact > guided > PRNG) and connects them with dominance edges.

**Example: ProductSpaceBatch migration.** The current 170-line multi-tier orchestration block becomes three descriptors:

```
[
  (encoder: productSpaceBatch, decoder: .guided,   dominates: [regimeProbe, prng]),
  (encoder: regimeProbe,       decoder: .exact,    dominates: [prng]),
  (encoder: productSpaceBatch, decoder: .prng,     dominates: [])
]
```

The guided tier dominates both the regime probe and the PRNG tier. If guided succeeds, the scheduler suppresses both. If guided fails, the regime probe runs — if IT succeeds (elimination regime: failure is structural, not value-sensitive), the PRNG tier is suppressed. If the regime probe fails (value-sensitive regime), the PRNG tier runs.

This pattern generalises: any multi-tier reduction strategy is a dominance chain of decoder-parameterised morphisms over the same encoder. The factory emits the chain; the scheduler processes it generically. No per-strategy orchestration code.

### Factory logic

The factory walks CDG nodes and emits descriptors:

1. **Bind-inner with outgoing edges** → upstream role. Encoder selected by position classification (ProductSpace for multi-bind coordination, BinarySearch for single-bind). Budget from `leverage / requiredBudget` scoring.
2. **Value positions within a bind's downstream range** → downstream role, scoped to the fibre. Encoder selected by fibre size: exhaustive (≤ 64), pairwise (≤ 20 params), or per-coordinate search (> 20 params).
3. **Value positions outside any bind** → independent descriptor. Same encoder, no composition. Current Phase 2 behaviour.
4. **Branch selectors** → independent descriptor. Branch promotion/pivot, no composition.
5. **Bind-inner joint reduction (≤ 3 axes)** → dominance chain: `(ProductSpaceBatch, .guided)` → `(RegimeProbe, .exact)` → `(ProductSpaceBatch, .prng)`. Replaces the multi-tier orchestration in `runJointBindInnerReduction`.
6. **Bind-inner joint reduction (> 3 axes)** → single `(ProductSpaceAdaptive, .prng)` descriptor. No dominance chain needed.

The factory runs once per cycle, after structural deletion (Phase 1) stabilises the tree.

### RegimeProbe encoder

A minimal `ComposableEncoder` that emits a single probe: all values set to their semantic simplest (zero for numerics). If the property still fails, the failure is structural (elimination regime) — value assignments don't matter, and PRNG retries are waste. If the property passes, the failure is value-sensitive and retries are needed.

```swift
struct RegimeProbeEncoder: ComposableEncoder {
    // start(): build the all-zeroed probe from the sequence
    // nextProbe(): yield it once, then nil
}
```

### Files

| File | Change |
|------|--------|
| `MorphismDescriptor.swift` (new) | Descriptor type, `CompositionRole`, `PositionClassification`, dominance edges |
| `EncoderFactory.swift` (new) | CDG → descriptor array. Position classification. Encoder selection. Budget allocation. Dominance chain construction. |
| `RegimeProbeEncoder.swift` (new) | Single-probe encoder for elimination/value-sensitive regime detection |

## Phase 4: Scheduler Migration

Replace the slot rotation with descriptor-driven scheduling.

### Current flow

```
BonsaiScheduler.run():
  while stallBudget > 0:
    runBaseDescent()          // Phase 1: structural deletion (slot rotation)
    runFibreDescent()         // Phase 2: value minimisation (slot rotation)
    runRelaxRound()           // Phase 3: redistribution
    runKleisliExploration()   // Phase 4: composition (edge iteration)
```

### New flow

```
BonsaiScheduler.run():
  while stallBudget > 0:
    runBaseDescent()          // Phase 1: unchanged (structural encoders)
    descriptors = factory.build(sequence, tree, dag, cache)
    runDescriptors(descriptors)  // Phases 2-4: unified descriptor execution
```

`runDescriptors` processes descriptors in priority order (leverage / budget score):
- **Independent** descriptors: execute the encoder directly on the full sequence. Same as current Phase 2.
- **Upstream + downstream** descriptor pairs: wire into a `KleisliComposition`. The upstream encoder proposes fibres, the lift materialises, the downstream encoder explores the fibre.

### Transition strategy

Run both paths in parallel during development:

1. **Shadow mode**: the factory builds descriptors but does not execute them. Log the descriptors and compare with what the slot rotation actually ran. This validates the factory's classification without risking regressions.
2. **A/B mode**: run both paths, compare results. The descriptor path must produce equal or better counterexample quality (shortlex) with equal or fewer probes.
3. **Cut over**: remove the slot rotation. The descriptor path becomes the only path.

### Files changed

| File | Change |
|------|--------|
| `BonsaiScheduler.swift` | Add `runDescriptors()`. Shadow mode flag. A/B comparison hook. |
| `ReductionState.swift` | Remove `snipOrder`, `trainOrder` slot rotation state (after cut over). |
| `ReductionScheduler+EncoderSlots.swift` | Remove `ValueEncoderSlot`, `DeletionEncoderSlot`, `moveToFront` (after cut over). |
| `ReductionState+Bonsai.swift` | `runKleisliExploration` replaced by descriptor-driven composition in `runDescriptors`. |

## Phase 5: Cleanup

After the descriptor path is validated and cut over:

1. Remove `LegacyEncoderAdapter`.
2. Remove `AdaptiveEncoder` protocol (or keep for structural encoders if they remain on the old interface).
3. Remove slot rotation types (`ValueEncoderSlot`, `DeletionEncoderSlot`).
4. Consolidate `EncoderName` — some cases may merge (for example, `binarySearchToRangeMinimum` and `binarySearchToSemanticSimplest` might become parameterisations of a single `BinarySearchEncoder`).
5. Remove `ReductionPhase` if the factory handles all phase assignment.

## Testing Strategy

### Invariant: counterexample quality

The A/B success criterion from `reduction-planning.md`: equal or better counterexample quality (shortlex), same or fewer probes, no regression on any individual test case. The 63 shrinking tests (56 standard + 7 structural pathological) are the baseline.

### Per-phase testing

| Phase | Test approach |
|-------|---------------|
| 1 (protocol migration) | Per-encoder: migrate, run 63 tests. Pure interface change — any failure is a bug. |
| 2 (position-specific adaptation) | Per-encoder: adapt, run 63 tests. `ReductionContext` supplies what constructors previously received. |
| 3 (factory) | Shadow mode: factory builds descriptors, log and compare with actual slot rotation. No execution. Validate classification accuracy on all 63 tests. |
| 4 (scheduler migration) | A/B mode: run both paths, compare counterexample quality and probe count. Structural pathological tests are critical — they exercise composition edges. |
| 5 (cleanup) | Full suite after each removal. |

### New test coverage

- **Factory unit tests**: given a CDG with known topology, assert the factory emits the expected descriptors (role, encoder type, budget).
- **Role assignment tests**: for each encoder primitive, verify it produces correct probes when assigned to the upstream role (scoped to bind-inner) and the downstream role (scoped to fibre).
- **Composition integration tests**: the structural pathological suite, especially CrossLevelSum (composition-required) and NestedBind3 (three edges).

## Risks

**Dominance lattice interaction.** The current dominance lattice suppresses encoders based on acceptance during a phase. The factory replaces this with explicit `dominates` edges on `MorphismDescriptor`. When a descriptor accepts, the scheduler suppresses all descriptors it dominates. This is strictly more expressive than the current lattice — it handles multi-tier decoder-parameterised chains (for example, ProductSpaceBatch guided → regime probe → PRNG) that the current lattice cannot express. The A/B comparison verifies that the explicit dominance produces equivalent or better suppression decisions.

**Warm-start invalidation.** The convergence cache is populated by Phase 2 and consumed by subsequent cycles. If the factory changes which encoders run on which positions, the cache keys must still align. The `ConvergedOrigin` is keyed by sequence position, which is stable across encoder changes.

**Structural deletion interaction.** Phase 1 can change the tree structure (delete spans, promote branches), which invalidates the CDG. The factory must run after Phase 1 stabilises — the same timing as current `runKleisliExploration`. If Phase 1 accepts a deletion mid-cycle, the factory's descriptors are stale. Re-running the factory after each structural acceptance is the safe choice; the cost is one CDG walk per acceptance (microseconds).

**Performance of the factory.** The factory walks CDG nodes, classifies positions, and selects encoders. For a generator with 10 edges and 50 downstream coordinates, this is ~500 comparisons per cycle. Negligible relative to a single materialization.

## Non-Goals

- **Splitting structural deletion encoders.** Phase 1 encoders operate on tree structure, not on the opfibration. They remain as-is.
- **Merging encoder implementations.** The refactoring changes interfaces and scheduling, not internal search logic. Encoder consolidation (for example, unifying the two binary search variants) is a separate effort.
- **Prediction-validation loop (steps 4-5).** The factory is step 2-3 infrastructure. Steps 4-5 (fibre stability prediction, confidence tracking, skip gates) build on the factory but are not part of this refactoring.
- **Search-based downstream encoders.** The downstream role currently dispatches to FibreCoveringEncoder (exhaustive or pairwise). Adding a per-coordinate binary search encoder for the downstream role on large fibres is a future extension that the factory would accommodate by adding a row to the classification table.

## Sequencing

| Phase | Status | Scope |
|-------|--------|-------|
| 1: Protocol migration | DONE | `PointEncoder` → `ComposableEncoder`, six encoders migrated, `BinarySearchEncoder` merged, `runComposable` helper, caller migration |
| 2: Position-specific adaptation | DONE (2 of 3) | ProductSpaceAdaptive and TandemReduction migrated. ProductSpaceBatch deferred to Phase 3 (dominance chain). |
| 3: Factory + dominance chains | Next | `MorphismDescriptor` with `dominates` edges, `EncoderFactory`, `RegimeProbeEncoder`, ProductSpaceBatch as a three-descriptor dominance chain |
| 4: Scheduler migration | Pending | `runDescriptors` replaces Phase 2–4 slot rotation |
| 5: Cleanup | Pending | Remove `LegacyEncoderAdapter`, `AdaptiveEncoder` (structural only), slot rotation types |

Phase 3 subsumes the remaining Phase 2 work (ProductSpaceBatch) by expressing its multi-tier pattern as a dominance chain rather than a single `runComposable` call.
