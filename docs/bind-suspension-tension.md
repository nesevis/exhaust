# Bind Suspension Tension: Calculator vs BinaryHeap

## Background

The guided materializer suspends the cursor when entering a bind's bound region. Suspension forces all reads to fall back to the fallback tree (or PRNG), discarding any modifications the encoder made to values inside bound content. The conditional cursor suspension change (this branch) made suspension conditional on the bind-inner value changing between the candidate and fallback — when the inner is unchanged, the cursor stays active and encoder modifications to bound content are honoured.

## The Problem

There are three cases for the fallback tree's inner subtree at a bind site:

1. **Inner matches fallback**: `ChoiceSequence(innerTree) == ChoiceSequence(innerFallback!)`. Structure is the same. Cursor stays active. Encoder modifications are honoured. This is the intended path.

2. **Inner differs from fallback**: `ChoiceSequence(innerTree) != ChoiceSequence(innerFallback!)`. Structure changed. Cursor suspends. Bound content is re-derived. This is correct — the old bound content is stale.

3. **Fallback is nil**: `innerFallback == nil`. No prior state to compare against.

Case 3 is the tension point. It occurs when the fallback tree decomposition fails to find a matching `.bind(inner:, bound:)` node at the current bind site. This happens when:
- The fallback tree was produced by reflection (which may structure the tree differently from materialization).
- A higher-level structural change (branch pivot, deletion) altered the tree shape, and the fallback's subtree path no longer aligns with the candidate's bind nesting.
- The bind is inside a region that was re-derived in a prior pass, and the fallback tree predates that re-derivation.

## What Each Benchmark Needs

### Calculator: Nil fallback should NOT suspend

The Calculator challenge has `div(value(0), add(value(-10), value(10)))` as a stuck CE. The values -10 and 10 are inside bind-bound content at depth 1 and depth 0. The redistribution encoder modifies both values in the ChoiceSequence and submits the candidate to the guided decoder.

At the inner bind sites (depth 1 and depth 0), the fallback tree is nil because the fallback tree decomposition lost the path — the fallback tree has the selected branch's subtree, but the nested bind structure inside that subtree doesn't decompose into `innerFallback`/`boundFallback` correctly.

With the nil-fallback-suspends policy (old behavior):
- The cursor suspends at the inner binds.
- The modified values (-9, 9) are discarded.
- The materializer re-derives from PRNG, producing garbage expressions (`div(value(-8), add(value(-2), value(9)))`, and so on).
- The redistribution candidate is rejected. Every cycle, 8 probes, 0 accepted.
- The CE never reduces.

With the nil-fallback-trusts-cursor policy (new behavior):
- The cursor stays active at the inner binds.
- The modified values are read from the prefix.
- The materializer produces `div(value(0), add(value(-9), value(9)))`.
- The candidate is accepted. Values converge to `(0, 0)`.
- Calculator achieves 1 unique CE across 100 seeds.

### BinaryHeap: Nil fallback should suspend

The BinaryHeap challenge has a recursive tree structure where deletion encoders remove subtrees. When a branch is deleted (pivoted to `None`), the tree structure changes at a higher level. The fallback tree still has the old (pre-deletion) structure. When the materializer descends into the remaining subtree's binds, the fallback decomposition fails — `innerFallback` is nil because the fallback tree's path diverged at the deleted branch.

With the nil-fallback-suspends policy (old behavior):
- The cursor suspends at bind sites where the fallback is nil.
- The materializer re-derives bound content from the fallback tree (or PRNG).
- The re-derivation produces structurally clean subtrees that are consistent with the new (post-deletion) depth.
- BinaryHeap achieves 1-2 unique CEs.

With the nil-fallback-trusts-cursor policy (new behavior):
- The cursor stays active at bind sites where the fallback is nil.
- Stale bound content from the pre-deletion sequence is carried through.
- The materializer produces trees with extra nodes that should have been eliminated.
- The reducer gets stuck at 5-node CEs instead of the minimal 4-node CE.
- BinaryHeap regresses to 4 unique CEs.

## Why the Distinction is Hard

The nil-fallback case conflates two genuinely different situations:

**Situation A — Lost path, valid cursor.** The fallback tree decomposition failed because the tree was produced by a different path (reflection, prior reduction pass), but the candidate sequence's cursor is correctly positioned and the bound content entries are valid. The encoder intentionally modified these entries, and they should be honoured. Suspending discards useful work.

**Situation B — Lost path, stale cursor.** The fallback tree decomposition failed because a higher-level structural change (branch deletion, depth reduction) altered the tree shape. The candidate sequence's bound content at this position is stale — it was produced for a different structural context. The cursor entries are aligned in position but semantically invalid for the new structure. Trusting the cursor carries stale content through.

Both situations present as `innerFallback == nil` at the bind site. The materializer cannot distinguish them from the information available at that point.

## Possible Distinguishing Signals

### Outer suspension state
If an outer bind has already suspended the cursor, inner binds are inside re-derived content. The cursor entries at inner positions are from the PRNG or fallback, not from the encoder's modifications. In this case, nil fallback + outer suspension = stale cursor (Situation B). Nil fallback + no outer suspension = valid cursor (Situation A).

Signal: `context.cursor.isSuspended` at the point where we check the inner bind. If already suspended from an outer bind, this inner bind's cursor content is not from the encoder — suspension is correct. If not suspended, the cursor content is from the prefix (encoder's candidate) — trust it.

### Structural fingerprint
Compare the candidate's sequence structure (bind/group/branch markers) against the fallback tree's expected structure. If they match, the cursor is aligned. If they differ, a structural change occurred and the cursor may be stale.

### Fallback tree depth
Track how many bind levels have successfully decomposed. If the first bind has a valid fallback but the second doesn't, the path was lost at level 2 — likely due to a structural change at level 1. If no bind has a valid fallback (all nil), the entire tree is from a different source (reflection).

### Encoder phase
Structural deletion encoders (branch pivot, container spans) change the tree shape — nil fallback after these is likely Situation B. Value encoders (redistribution, binary search) don't change structure — nil fallback after these is likely Situation A. The decoder context could carry a "structural change" flag that the suspension logic checks.

## Current State

The nil-fallback-trusts-cursor policy is active on this branch. Calculator is solved (1 unique CE). BinaryHeap is regressed (4 unique CEs, was 1-2). The tension remains unresolved.

The `structureChanged` parameter is already passed to `runComposable` — it indicates whether the encoder may have changed the sequence structure. This is the most promising signal: when `structureChanged == false` (value-only encoders), nil fallback should trust the cursor. When `structureChanged == true` (structural encoders), nil fallback should suspend.

However, `structureChanged` is a property of the encoder phase, not of individual bind sites. A single materialization pass may encounter binds at multiple levels, some affected by structural changes and some not. Threading this information to the per-bind suspension decision requires propagating it through the materializer context.

## Investigation Findings (2026-03-30)

### All fallbacks are nil during branch simplification

Debug instrumentation at the bind suspension decision point revealed that `innerFallback` is **always nil** during the branch simplification phase — not sometimes nil, universally nil. The fallback tree's structure does not decompose via `case .bind(inner:, bound:)` at any bind site. This means:

1. The `innerValueChanged` check never fires (requires `innerFallback != nil`).
2. No suspension occurs during branch simplification regardless of the nil-fallback policy.
3. The suspension decision at bind sites is inert during the critical early reduction phase.

The fallback tree fails to decompose because BinaryHeap uses `Gen.recursive`, which wraps pick sites in bind nodes that don't match the materializer's expected `.bind(inner:, bound:)` pattern when decomposed from the top-level fallback tree. The fallback tree becomes usable only after `accept()` replaces it with a fresh materialized tree — which happens after the first structural acceptance (typically from `deleteContainerSpans`, not from branch simplification).

At pick sites, `fbBranchId` is also nil (same decomposition failure), so branch-level comparison between the candidate and fallback is impossible.

### `productSpaceAdaptive` also has nil fallbacks

The bind-inner reduction phase uses `usePRNGFallback: true`, which passes `nil` as the fallback tree to the materializer. All bind fallbacks are nil, all values come from the cursor or PRNG. The nil-fallback suspension policy has no effect here either.

### After the first structural acceptance, fallbacks become present

Once `accept()` fires and replaces the fallback tree with the fresh materialized tree, subsequent phases see `innerFallback=present` at bind sites. The existing `innerValueChanged` check then works correctly: it compares `ChoiceSequence(innerTree) != ChoiceSequence(innerFallback!)` and suspends when the inner value changed.

### Approaches tested and rejected

#### Branch divergence tracking

Added a `branchDiverged: Bool` flag to the materializer Context, set when `handlePick` in guided mode selects a branch that differs from the fallback tree's selected branch. At bind sites, nil fallback + branch diverged → suspend.

**Result**: The flag never fires during branch simplification because `fbBranchId` is also nil (the fallback tree doesn't decompose at pick sites either). The flag is correct but inert — it cannot detect divergence when the fallback tree is entirely absent.

#### Base/fibre descent distinction (`suspendOnNilBindFallback`)

Threaded a `suspendOnNilBindFallback: Bool` flag from `SequenceDecoder` through `ReductionMaterializer` to the Context. Base descent decoders set it to `true`; fibre descent decoders leave it `false`. At bind sites, nil fallback + `suspendOnNilBindFallback` → suspend.

**Result**: BinaryHeap CEs unchanged (3 four-node, 1 five-node — same set as baseline). Calculator regressed from 1 unique CE to 2 unique CEs — the flag caused unnecessary suspension in a later phase where a present fallback was involved, disrupting convergence. Net negative.

The base/fibre cut is too coarse. Bind-inner value changes are "value changes" but structurally consequential (they change the bound generator). The flag would need to be scoped more precisely, but the fundamental problem is that the nil-fallback path is inert during the phases where it would matter.

### Why the BinaryHeap regression persists

The BinaryHeap regression (4 unique CEs vs 1-2 with always-suspend) is **not caused by the nil-fallback policy change**. The nil-fallback path is inert during branch simplification (all fallbacks nil either way). The regression must come from a different mechanism — possibly the `ChoiceSequenceValue` comparison leniency change (commit `d99c131`), which only compares `choice` bit patterns and ignores `validRange` and `isRangeExplicit`. This could make the `ChoiceSequence(innerTree) != ChoiceSequence(innerFallback!)` comparison return `false` in cases where the old comparison returned `true`, preventing suspension at bind sites where fallback IS present.

### The 5-node CE is a genuine local minimum

The stuck 5-node CE `(0, (0, None, (1, None, None)), (0, (0, None, None), None))` was analyzed exhaustively. Every possible single-node deletion produces a tree where either all values are zero (property passes trivially) or the `1` sits in a position where the buggy `toSortedList` happens to sort correctly. No single-step reduction (deletion, value change, or sibling swap) reaches a 4-node CE that fails the property.

The known 4-node CEs (for example `(0, (0, (0, None, None), None), (1, None, None))`) require the `1` at a different structural position — typically at depth 1 as a direct child of the root. Reaching these from the 5-node tree requires repositioning the `1` (for example via sibling swap), but **swapping moves the `1` to an earlier sequence position, which is shortlex-larger**. The shortlex monotonicity constraint rejects the swap, trapping the reducer at the 5-node local minimum.

The two entangled dimensions that must change simultaneously:

1. **Branch structure** (which sites are Node vs Empty): every 4-node CE has a fundamentally different pick configuration than the 5-node tree. Deletion encoders change one pick at a time, but every single-site deletion from the 5-node tree produces a tree where the property passes.
2. **Value placement** (where the `1` sits): the `1` must end up in a position that creates a BFS-ordering conflict after merge — typically as a left child with a `0` sibling to its right at the same level. Moving the `1` is blocked by shortlex monotonicity and structural sensitivity (bind-inner values control child ranges).

Current encoders operate on one dimension at a time. Escaping the local minimum requires a simultaneous structure+value change.

### Relax round as escape hatch

The relax round can bypass the shortlex barrier because it accepts shortlex-larger intermediates and only checks shortlex at the pipeline level (after exploit passes). Two improvements were made:

1. **Source/sink pairing** (`RelaxRoundEncoder`): extended to pair non-zero sources with zero-valued sinks. Previously required both entries to be non-zero, so a single remaining `1` with all other values at zero produced zero probes.
2. **Bind-inner awareness** (`RelaxRoundEncoder` and `RedistributeAcrossValueContainersEncoder`): values tagged as bind-inner vs bound using `BindSpanIndex.bindRegionForInnerIndex`. Cross-category pairs (inner×bound) are skipped — modifying the inner changes the bound structure, making the bound modification meaningless. Inner-inner and bound-bound pairs are both valid. Pattern taken from stash `fd55489b`.

With the source/sink fix, the relax round in cycle 2 successfully relocates the `1` from position 17 to position 8 (leftward, but the only position that produces a tree the decoder accepts). The exploit phase (base descent) then deletes a node, reducing from 5 to 4 nodes.

### Rightward relocation blocked by property, not decoder

After the 5→4 reduction, cycles 3 and 4 attempt to further relocate the `1` rightward for a shortlex-smaller CE. The relax round's speculative decoder was switched from exact to guided mode (with `skipShortlexCheck: true`) to allow structurally-sensitive relocations where the bound content would be re-derived via PRNG. The rightward sink positions (delta +21, +16) are tried first (sort order prefers largest positional delta), but the relocated trees do not fail the property — the `1` in those positions produces a heap where the buggy `toSortedList` accidentally sorts correctly.

This is a property-level dead end, not a decoder-level one. No decoder mode can make the property fail for those tree shapes.

### Convergence exit (commit `54ab818`)

The reduction loop now breaks early when all values have converged to their reduction targets. This avoids spending budget on futile cycles for pathological generators where structural reduction is complete but the scheduler would otherwise continue probing.

### Benchmark: 4 unique CEs across 100 seeds

Across 100 seeds, BinaryHeap produces 4 unique CEs — the same set with and without the relax round improvements:

```
(0, (0, (0, None, None), None), (1, None, None))           — 4 nodes
(0, (0, None, (1, None, None)), (0, (0, None, None), None)) — 5 nodes
(0, (1, None, None), (0, (0, None, None), None))            — 4 nodes
(0, None, (0, (1, None, None), (0, None, None)))             — 4 nodes
```

Three of four CEs are optimal (4 nodes). The 5-node CE persists for some seeds regardless of relax round configuration or decoder mode.

### Guided decoder for relax round speculative phase

Switching the relax round's speculative decoder from exact to guided (with `skipShortlexCheck: true`) was tested. The hypothesis was that guided mode would re-derive bound content via PRNG when a relocated bind-inner value changes the bound structure, allowing structurally-sensitive rightward relocations that exact mode rejects. The result: identical 4 CEs across 100 seeds. The rightward relocations fail because the property passes for those tree shapes, not because the decoder rejects them. The guided decoder is retained as it is no worse than exact and marginally more permissive.

### Sibling substitution in BindSubstitutionEncoder

A sibling substitution strategy was added alongside the existing depth substitution. For each pair of sibling bind regions (direct children of the same parent), it overwrites the target's inner+bound with the donor's inner+bound, preserving both siblings. The result has two copies of the donor's content, giving subsequent deletion passes a shortlex-smaller starting point.

For BinaryHeap specifically this does not help — copying between siblings at the same level either duplicates content (Node→Node, same size) or expands content (Empty→Node, grows). But for generators with self-similar picks where branches have different sizes, copying the shorter branch's content into the longer position would shrink the sequence.

### External context: the challenge is underspecified

[jlink/shrinking-challenge#13](https://github.com/jlink/shrinking-challenge/issues/13) documents fundamental specification problems with the BinaryHeap challenge:

- Anthony Lloyd (CsCheck) found that `(1, None, (0, None, None))` — just 2 nodes — fails `toSortedList`. This is smaller than the documented 4-node minimum. The difference: this tree violates the heap invariant (1 > 0), and the challenge's property guards on the invariant. If the invariant check is removed, the minimal CE is 2 nodes, not 4.
- Kostis Sagonas argues the documented 4-node CE `(0, None, (0, (0, None, None), (1, None, None)))` is "not even a proper binary heap" — it lacks the "almost complete" and "fringe packed left" properties of a proper binary heap. The challenge uses "tree with heap ordering" as its definition, not the stricter data-structure definition.
- No consensus was reached on the specification. Different frameworks test subtly different properties depending on how they define "heap" and whether the invariant is checked.

This confirms that no PBT framework achieves a single unique CE for BinaryHeap across seeds. The 4-node minimum is specific to invariant-satisfying heaps, and the local minimum at 5 nodes is a known structural trap in the reduction landscape. Exhaust's result (3 of 4 seeds reaching optimal 4-node CEs) is competitive with the field.

### Closed questions

1. ~~Does reverting `d99c131` (comparison leniency) fix the BinaryHeap regression independently?~~ No. The leniency change had no effect on BinaryHeap results.

### Open questions

1. Is the 5-node CE eliminable at all, or is it a fundamental property of the reduction landscape for this seed's starting tree?
