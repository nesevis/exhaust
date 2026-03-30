# Branch Pivot for Gen.recursive: Investigation Notes

This document records the investigation into structural simplification of `Gen.recursive` counterexamples, specifically removing unnecessary wrapper nodes when the branch pick ordering creates a shortlex trap.

## Problem Statement

For `Gen.recursive` generators, the choice sequence encodes branch selections (value/add/div) as `.branch` entries. The branch pick's position in the `validIDs` array is determined by the user's declaration order — not by structural complexity. When a wrapper branch (like `add`) has a smaller index than the structurally interesting branch (like `div`), shortlex ordering permanently prefers the wrapper. The reducer cannot remove `add(X, 0)` even when `X` alone is a valid counterexample.

The Calculator challenge seed `10334882580811088565` exemplifies this: the reducer converges to `add(div(0, div(0, -1)), 0)` and stalls. The minimal CE is `div(0, add(0, 0))`.

## Root Cause Chain

### 1. Branch picks participate in shortlex ordering

`Branch.shortLexCompare` compares the index of the selected ID within `validIDs`. Since `add` (index 1) < `div` (index 2), `add(X, Y)` is always shortlex-smaller than `div(X, Y)` with identical children. This blocks any promotion from `add` to `div`.

### 2. Fixed-length encoding from Gen.recursive

`Gen.recursive` unfolds eagerly to `maxDepth` layers via `._bound`. Each recursion level is a bind whose inner value controls which layer is selected. The total number of picks is determined by the bind-inner depth values, not by the tree shape visible in the output. Deletion encoders cannot shorten the sequence because the bind structure always consumes the same pattern of entries.

### 3. Bind-inner depth controls unfolding

The `._bound(forward: { depth in layers[Int(depth)] }, ...)` structure means the bind-inner value directly determines how many recursion levels the generator unfolds. Changing branch picks without adjusting the bind-inner depth creates a candidate sequence that doesn't match the generator's execution order — the materializer runs out of valid picks and rejects.

### 4. Existing encoders don't modify branch picks

The Kleisli fibre exploration covers VALUE combinations at each bind edge but never changes which BRANCH is selected. All exploration attempts produce trees with the same branch structure as the original (for example, always `add(...)`, never `div(...)`).

## Bugs Found and Fixed

### Fix 1: `handlePick` fallback extraction uses `children.first` instead of `.first(where: \.isSelected)`

**File**: `ReductionMaterializer+Handlers.swift`

The fallback branch extraction in `handlePick` used `children.first` to find the selected branch in the fallback tree's group:

```swift
let selected = children.first  // BUG: takes first child, not the selected one
```

When the selected branch is not the first alternative (for example, `div` at index 2 in a `[value, add, ✅div]` group), the pattern match `case let .selected(inner) = selected` fails because the first child is not `.selected`. The fallback branch ID is nil, and the guided materializer falls through to PRNG — selecting a random branch instead of honoring the fallback tree's selection.

**Fix**: `children.first(where: \.isSelected)`.

**Impact**: Affects all generators with bind-wrapped pick sites where the selected branch is not the first alternative. This is a general correctness fix for `exactThenGuided` decoding, not specific to `Gen.recursive`.

### Fix 2: `handlePick` fallback extraction doesn't unwrap `.bind` nodes

**File**: `ReductionMaterializer+Handlers.swift`

For `Gen.recursive`, the `calleeFallback` at the pick site is a `.bind` node (wrapping the actual `.group` with branch alternatives). The fallback extraction pattern-matches on `.group` directly:

```swift
case let .group(children, _) = calleeFallback  // FAILS: calleeFallback is .bind, not .group
```

**Fix**: Unwrap `.bind` to reach the bound child before pattern-matching:

```swift
let effectiveFallback: ChoiceTree?
if case let .bind(_, bound) = calleeFallback {
    effectiveFallback = bound
} else {
    effectiveFallback = calleeFallback
}
```

**Impact**: Affects `Gen.recursive` generators where the pick site is wrapped in a bind layer. Without this fix, the fallback branch is always nil for these generators, forcing PRNG selection in guided mode.

## Approaches Attempted

### A. Branch.shortLexCompare → .eq

Changed `Branch.shortLexCompare` to return `.eq`, making branch picks transparent to shortlex ordering. The comparison falls through to subtree content, where actual structural/value differences decide.

**Status**: Implemented. Necessary but not sufficient — it removes the ordering barrier but doesn't provide a mechanism to actually change branches.

### B. Direct sequence patching (bind-inner + branch pick)

Modified `promotionCandidates` to adjust the bind-inner depth value alongside the branch group substitution.

**Status**: Abandoned. The flattened candidate sequence from tree modification doesn't align with the generator's execution order. The materializer falls back to PRNG, producing garbage trees.

### C. Kleisli composition: depth reduction → branch pivot

Upstream: `BinarySearchToSemanticSimplestEncoder` on the outermost bind-inner (reduces recursion depth). Lift: guided mode materializes a valid tree at reduced depth. Downstream: `BranchPickEncoder` swaps branch picks in the lifted sequence.

The composition pipeline works end-to-end:
- Upstream produces probes (depth=1, depth=2)
- Lift succeeds (lifted_seq_len=13)
- Downstream generates candidates (1-2 per upstream)
- Candidates reach the decoder
- With Fix 1 and Fix 2, the `div` pivot materializes correctly through both exact and guided passes

**Status**: The `div` pivot now produces correct trees (for example, `div(value(-10), value(-2))`). But the property passes — `div(-10, -2) = 5`, no division by zero. At reduced depth, both children are simple values from the fallback. `div(value(X), value(Y))` only triggers div-by-zero if Y=0, which `containsLiteralDivisionByZero` catches.

### D. BranchPickEncoder at inner Kleisli edges

Added a parallel `KleisliComposition` with `BranchPickEncoder` as downstream alongside each existing fibre-covering composition. This explores branch alternatives at every CDG edge, not just the outermost.

**Status**: Inner edges produce branch-pivoted attempts (for example, `add(add(div(value(-10), value(9)), value(-8)), value(-9))`). But inner edge lifts produce same-length sequences (31 entries) because only a subtree shrinks. Without a length advantage, the branch pivot must preserve the property AND be shortlex-smaller — which the large PRNG values prevent.

### E. Pivot pre-filter relaxation

Changed `pivotCandidates` from strict `<` to `<=` (not-worse), allowing shortlex-equal candidates through. With `.eq` branches, `add(X, Y)` and `div(X, Y)` produce equal sequences when children are identical.

**Status**: Implemented. The tree-based pivot found the pick site but fallback-provided alternatives retained deep subtree content from the original tree, making candidates longer than the lifted sequence.

## Current Status

The composition pipeline is fully functional: depth reduction → lift → branch pivot → exact materialization → guided re-derivation → property check → shortlex check. The two materializer bugs (Fixes 1 and 2) are corrected. The `div` pivot produces correct trees at reduced depth.

The remaining issue is property-specific: the Calculator's `containsLiteralDivisionByZero` filter catches `div(X, value(0))`, and at reduced depth the only way to get non-literal division by zero is with a subexpression that evaluates to zero (for example, `add(0, 0)`). This requires both a branch change AND specific values in the children — which is the fibre search (C level) that's too expensive as a general strategy.

For most real-world properties, the depth-reduced branch pivot should work: a shorter sequence with a different branch selection is shortlex-smaller regardless of values, and most properties are robust enough to survive structural changes at reduced depth.

## Key Insight: Bottom-Up, Not Top-Down

The successful path is bottom-up: first change a deeper subtree to an equivalent form (for example, `div(0, -1)` → `add(0, 0)` — both evaluate to 0), then the structural path to the final CE becomes available. Working top-down (reducing depth first, then pivoting) runs into the fallback-content problem: the lift provides values appropriate for the original branch structure, not the pivoted one.

The `BranchPickEncoder` at inner Kleisli edges is the right mechanism for bottom-up branch pivots. The remaining issue is that the pivoted candidate needs both the branch change AND appropriate values to preserve the property — which is an A→B→C composition that exceeds the probe budget for general use.

## Artifacts

### New files
- `Sources/ExhaustCore/Interpreters/Reduction/Encoders/BranchPickEncoder.swift` — sequence-level branch pivot encoder

### Bug fixes (keep)
- `ReductionMaterializer+Handlers.swift` — `children.first(where: \.isSelected)` fix, `.bind` unwrap fix
- `ChoiceSequenceValue.swift` — `Branch.shortLexCompare` returns `.eq`
- `BranchSimplificationEncoder.swift` — `<=` pivot pre-filter

### Infrastructure (keep, evaluate probe cost)
- `BranchPickEncoder.swift` — sequence-level branch pivot encoder
- `ReductionState+BaseDescent.swift` — outermost `promoteAcrossBindDepth` composition
- `ReductionState+KleisliExploration.swift` — `BranchPickEncoder` composition at inner edges
- `SequenceEncoder.swift` — `.promoteAcrossBindDepth` case
- `EncoderDominance.swift` — dominance rule
- `GeneratorLift.swift` — `materializePicks` parameter

### Debug logging (clean up)
- `ReductionState+BaseDescent.swift` — xbind_setup logging
- `SequenceDecoder.swift` — xbind_pass1_rejected/failed logging
- `KleisliComposition.swift` — xbind_lift_rejected/ok/yielding logging
- `BinarySearchEncoder.swift` — xbind_targets_created logging
- `BranchSimplificationEncoder.swift` — xbind_downstream/pivot logging
