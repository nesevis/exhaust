# Bound5 V-Cycle Scheduling Gap

## Problem

The Kleisli V-cycle reducer cannot fully reduce the Bound5 shrinking challenge.
It reduces the 39-element array to 2 elements and pushes values toward the target,
but gets stuck at `[-32768, -31458]` instead of the optimal `[-32768, -1]`.
The legacy reducer achieves the optimal result in 388 property invocations.

## Root Causes

There are two interacting issues:

### 1. Stale tree after container span deletion

Container span deletion uses `.direct(strictness: .normal)` — tree-driven
materialization. This correctly produces the output but returns the **original tree**
in the `ShrinkResult`. After deletion reduces the sequence from 129 entries to ~24,
the tree still has 129 entries. All subsequent `.direct(strictness: .normal)`
materializations fail because the tree's positional mapping doesn't match the
shortened sequence.

The legacy reducer solves this with an **end-of-loop tree re-derivation step**:

```swift
// Legacy: end-of-depth-cycle re-derivation
let seed = currentSequence.zobristHash
if case let .success(value, seq, newTree) =
    GuidedMaterializer.materialize(gen, prefix: currentSequence, seed: seed,
                                   fallbackTree: currentTree),
   property(value) == false
{
    currentTree = newTree
    // ... merge logic for bind bound values ...
}
```

This re-derivation works in the legacy reducer because of the pass structure:
all deletion passes run first (making arrays empty), then value reduction runs.
By the time re-derivation happens, the sequence has empty array markers
(`.sequence(true)` immediately followed by `.sequence(false)`), and
GuidedMaterializer correctly produces 0-length arrays for them.

The V-cycle cannot simply copy this approach because **GuidedMaterializer
misaligns after container span deletion in zipped sequences**. The
`DeleteContainerSpansEncoder` removes the entire span including the
`.sequence(true/false)` markers. When GuidedMaterializer replays the shortened
candidate, the cursor finds the *next* array's markers where the deleted array's
markers used to be, producing misaligned values instead of empty arrays.

The legacy `deleteContainerSpans` strategy uses `.normal` strictness (tree-driven),
which navigates by the tree structure rather than cursor position. When the
candidate is shorter, the tree-driven materializer handles missing entries
gracefully. The `.guided` (prefix-driven) approach cannot do this.

### 2. Path-dependent dead end in redistribution

Even when deletion succeeds and the array reaches 2 elements, the V-cycle's
leg ordering creates a dead end for redistribution.

**V-cycle flow (per cycle):**
1. Contravariant sweep (depths max→1) — no-op for depth-0 generators
2. Deletion sweep — removes containers, elements
3. Covariant sweep (depth 0) — reduces values toward targets
4. Redistribution — moves mass between coordinates

**Problem:** The covariant sweep (step 3) runs to completion before redistribution
(step 4). Binary search pushes one value all the way to `-32768` (bitPattern64 = 0).
When redistribution finally runs, the pair is `(-32768, -31458)` with bit patterns
`(0, 1310)`. Both values need their bit patterns to *increase* toward the target
(32768, which represents value 0). Redistribution requires one side to decrease as
compensation — but bit pattern 0 cannot decrease. Dead end.

**Legacy flow (per loop):**
```
naiveSimplify → branches → deleteContainers → deleteElements →
deleteAligned → simplifyValues → reduceInTandem → reduceIntegral →
redistribute → speculativeDelete → normaliseSiblings
```

All passes run sequentially in a single loop. Critically:
- `reduceIntegralValues` only partially reduces values (it has a per-pass budget)
- `redistributeNumericPairs` runs immediately after, while values still have room
  to maneuver in bit-pattern space
- A successful pass moves to the front of the queue for the next loop

**Legacy trace (relevant steps):**
```
Loop 2: reduceIntegral → d=[0, -21362], e=[0,0,430,4853,9150,18335]
         redistribute  → e=[0,0,0,-32768]   (54 invocations)
Loop 3: deleteElements → e=[-32768]          (now 2 elements)
         reduceIntegral → d=[-21362], e=[-11407]
         normalise      → d=[-11407], e=[-21362]
Loop 4: redistribute   → d=[-1], e=[-32768]  (75 invocations)
```

The key: in loop 2, redistribution runs on 6 values in array e
(bit patterns spanning a wide range). It pushes mass into one value (-32768,
bp=0) while the others absorb via decrease. In loop 4, the pair is
`(-11407, -21362)` with bit patterns `(21361, 11406)` — both far from 0,
giving redistribution room to push one to bp=32767 (value -1) while the
other goes to bp=0 (value -32768).

The V-cycle never reaches this configuration because it reduces values fully
before redistribution gets a chance.

## Attempted Fixes and Why They Failed

### Moving redistribution into the covariant leg
Interleaving redistribution with value reduction sounds right, but causes
**oscillation**: tandem and cross-stage encoders keep accepting shortlex-improving
probes each cycle without converging. The stall budget never decreases, creating
an infinite loop. The legacy avoids this with a `recentSequences` window that
detects cycles.

### Running redistribution every cycle (deferral cap = 0)
Redistribution runs too early (on 16+ values), pushing values to -32768
aggressively. Results in 4 elements instead of 2. The legacy's redistribution
also ran every loop but was gated by `candidates.count <= 16` — which only
helps when there are many values, not when redistribution runs too often on
few values.

### End-of-cycle tree re-derivation via GuidedMaterializer
GuidedMaterializer misaligns after container span deletion (cursor consumes
wrong sub-generator's data in zips), producing a sequence with the same or
greater length. The re-derivation condition rejects this, leaving the tree stale.

## Principled Solutions

### Option A: Tree reconstruction from ChoiceSequence (unflatten)

Write `ChoiceTree.unflatten(from: ChoiceSequence)` — a stack-based parser that
reconstructs the tree from structural markers (`.group`, `.sequence`, `.bind`,
`.value`, `.branch`). This is the inverse of `ChoiceSequence.flatten(_:)`.

After any structural change accepted by `.direct`, reconstruct the tree from the
accepted candidate sequence. This gives a consistent (sequence, tree) pair without
relying on GuidedMaterializer's prefix replay.

**Advantages:**
- Clean separation: decoder produces the output, unflatten produces the tree
- Works for all generator structures (zips, nested sequences, binds)
- O(n) in sequence length, no property invocations

**Disadvantages:**
- `flatten` is lossy: `.resize` and plain `.group` both produce `.group(true/false)`,
  `.getSize` produces nothing, `.selected` is transparent. The reconstructed tree
  won't have resize/getSize nodes. However, these nodes are only needed for
  re-execution (not span extraction or materialization), so the loss is acceptable
  for the reducer's purposes.
- Sequence metadata (e.g. `ChoiceMetadata.validRange`) is partially lost in
  flattening — the sequence entry stores `validRange` and `isRangeExplicit`, but
  the tree's `ChoiceMetadata` for sequences carries the length generator's metadata,
  not the elements'. Reconstruction would need to synthesize metadata from the
  sequence entries.

### Option B: Marker-preserving container deletion

Change `DeleteContainerSpansEncoder` to **empty** sequence containers rather than
remove them. For a sequence span `[.sequence(true), elements..., .sequence(false)]`,
remove only the interior elements, leaving the empty markers
`[.sequence(true), .sequence(false)]` in place.

This preserves cursor alignment for GuidedMaterializer, enabling correct tree
re-derivation after deletion. The decoder can use `.guided` for all deletion,
and the re-derived tree matches the sequence.

**Advantages:**
- Minimal code change (narrow span ranges in the encoder's `start` method)
- GuidedMaterializer correctly produces 0-length arrays for empty markers
- Tree re-derivation works because cursor alignment is preserved

**Disadvantages:**
- Only applies to sequence containers. Group and bind container deletion still
  removes markers, potentially causing misalignment for nested structures.
- The empty markers remain in the sequence (2 entries per empty array), slightly
  increasing sequence length compared to full removal. Subsequent deletion passes
  would need to clean these up.
- Conceptually changes what "container deletion" means — it becomes "container
  emptying" for sequences.

### Option C: Oscillation-aware pass interleaving

Move redistribution into the covariant leg (alongside value reduction) but add
the legacy reducer's **cycle detection** mechanism: track recent sequences in a
sliding window and terminate when the same sequence appears twice.

```swift
var recentSequences = [sequence]
// ... after cycle end:
if recentSequences.suffix(windowSize).contains(sequence) {
    break // oscillation detected
}
recentSequences.append(sequence)
```

This allows redistribution to interleave with value reduction (avoiding the
dead-end configuration) while preventing infinite oscillation.

**Advantages:**
- Directly addresses the path-dependence issue
- The legacy reducer uses this exact mechanism successfully

**Disadvantages:**
- `recentSequences.contains` is O(window × sequence_length) — expensive for
  large sequences. Could use Zobrist hashes for O(1) lookup.
- Doesn't fix the stale tree problem — still needs Option A or B for tree
  consistency after deletion.
- Changes the V-cycle's clean leg separation into a more ad-hoc structure.

### Option D: Two-phase covariant sweep

Split the covariant sweep into two sub-phases:
1. **Partial value reduction**: run value encoders with a fraction of the budget
2. **Redistribution**: run redistribution encoders
3. **Full value reduction**: run value encoders with remaining budget

This interleaves redistribution with value reduction without abandoning the
V-cycle structure. Redistribution gets a chance to run while values still have
room in bit-pattern space.

**Advantages:**
- Preserves the V-cycle's contravariant → deletion → covariant ordering
- Redistribution runs at the right time (after partial reduction, before full)
- No oscillation risk (each sub-phase runs once per cycle)

**Disadvantages:**
- Arbitrary budget split between partial and full value reduction
- Still needs tree consistency fix (Option A or B) for deletion
- More complex than the legacy's simple pass-list approach

## Recommendation

**Option A (unflatten) + Option C (cycle detection)** is the most principled
combination:

1. `unflatten` fixes tree consistency after any structural change, eliminating the
   stale-tree problem entirely. It's a general solution that doesn't depend on
   encoder-specific marker preservation.

2. Cycle detection prevents oscillation when structure-preserving encoders
   interleave, enabling redistribution to run at the right time.

Together, these address both root causes without compromising the V-cycle's
architectural principles.
