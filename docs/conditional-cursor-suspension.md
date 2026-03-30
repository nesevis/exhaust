# Conditional Cursor Suspension

## Context

The guided materializer suspends the cursor when entering bind-bound content. This ensures stale values are re-derived when the bind-inner changes. But it's a blanket policy — it blocks ALL modifications inside bound content, not just stale ones.

For self-similar generators (`Gen.recursive` and similar), the bind-inner selects the recursion depth. Values inside the selected layer (expression values like -10, 10) are independent of the depth. Suspending the cursor for these values prevents:

- Value redistribution inside binds (`add(-10, 10)` → `add(0, 0)`)
- Binary search / zero-value on bind-bound values
- Branch pivots inside bind content (the `exactThenGuided` workaround was needed only because of blanket suspension)

The `exactThenGuided` two-pass decoder is a per-encoder workaround for branch simplification. Conditional suspension solves the root cause and unblocks all encoders simultaneously.

## Current Behavior

In `handleTransform` for bind operations (guided mode):
1. Materializer reads the bind-inner value from the prefix
2. Cursor suspends via `skipBindBound()` / `suspendForBind()`
3. All entries in the bound subtree are re-derived from the fallback tree
4. Any modifications the encoder made to bound-content entries are lost

## Proposed Change

When entering a bind in guided mode, compare the prefix's inner value against the fallback tree's inner value at that bind site:

- **Inner value changed**: Structure is different. Suspend as today — bound content must be re-derived.
- **Inner value unchanged**: Structure is the same. Do NOT suspend — continue reading bound content from the prefix. Any modifications the encoder made are intentional and should be honored.

## Detection

The comparison happens in `handleTransform` (or the bind-specific handler) when processing a `._bound` operation in guided mode. At that point, the materializer has:

- The inner value just materialized from the prefix
- The fallback tree's inner value (from the `calleeFallback`)

If these match, the bound structure is unchanged. The cursor should remain active, reading from the prefix for both values and branch picks inside the bound region.

## Impact

### Unblocked (no longer need per-encoder workarounds)
- `RedistributeAcrossValueContainersEncoder` — can modify values inside bind-bound content
- `BinarySearchToSemanticSimplestEncoder` — can converge values inside binds
- `ZeroValueEncoder` — can zero values inside binds
- `BranchPickEncoder` / `BranchSimplificationEncoder` — branch pivots inside bind content work directly
- `exactThenGuided` decoder — may become unnecessary (the guided decoder would handle branch pivots correctly when the inner value hasn't changed)

### Preserved (suspension still applies)
- Kleisli composition upstream changes (bind-inner value changes → bound content must re-derive)
- Any encoder that modifies the bind-inner value itself

### Risk
- Re-derivation was a safety net: it ensured bound content was always consistent with the inner value. Removing it for same-inner cases means the bound content from the prefix must be valid. If the prefix contains stale entries from a previous reduction that changed the inner, those entries would be used instead of being re-derived.
- Mitigation: the comparison is per-materialization. Each materialization compares the prefix's inner against the fallback's inner at that specific bind site. If the inner hasn't changed in THIS candidate, the bound content was produced from the same structure and is consistent.

## Verification

1. Calculator shrinking challenge: `add(-10, 10)` should reduce to `add(0, 0)` via redistribution, giving `div(0, add(0, 0))` as the CE. Target: 1 unique CE across all 100 seeds.
2. BinaryHeap: should maintain 1 unique CE and ~325 probe count (no regression).
3. Full benchmark suite: all 13 challenges, same or better CE counts and probe counts.
4. Full ExhaustCore test suite: all tests pass.
