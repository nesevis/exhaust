# Coupling Challenge: Findings and Recommendations

## Background

The [Coupling shrinking challenge](https://github.com/jlink/shrinking-challenge/blob/main/challenges/coupling.md) generates a list of integers where each element is a valid index into the list itself. The property under test rejects arrays containing 2-cycles (where `arr[arr[n]] == n`). The expected smallest counterexample is `[1, 0]`.

This challenge is difficult because it creates a dependency between array **length** and element **values** — shrinking one dimension affects the validity of the other.

## Generator Design

The generator uses `filter` + `arrayOf(within:)`:

```swift
let gen = Gen.arrayOf(Gen.choose(in: 0...19), within: 2...20)
    .filter { arr in arr.allSatisfy { $0 < arr.count } }
```

The `filter` combinator ensures generated arrays only contain valid indices. However, during reduction the filter predicate is not re-checked — the reducer operates on the flattened `ChoiceSequence` and replays through the materializer, which skips filter continuations. This means reduced candidates can contain out-of-bounds indices.

As a workaround, the property includes a guard:

```swift
guard arr.allSatisfy({ arr.indices.contains($0) }) else { return true }
```

This is ergonomically poor. The expectation is that `filter` constraints should flow through to the shrinking process.

## Fix 1: `arrayOf(within:)` Size Clamping

### Problem

`Gen.arrayOf(within:)` was pinning the sequence length to exactly `size` when `getSize()` fell within the range. This prevented the reducer from exploring shorter lengths.

### Solution

Changed to clamp `size` as an upper bound:

```swift
// Before
if range.contains(size) {
    return Gen.choose(in: size...size)
}

// After
let upper = min(size, range.upperBound)
let clamped = range.lowerBound...max(range.lowerBound, upper)
return Gen.choose(in: clamped)
```

This allows the reducer to shrink array length down to `range.lowerBound` regardless of the original size parameter.

## Finding: Reducer Pass Ordering

### Current Exhaust Pass Order

1. **Pass 1** — Container deletion (delete entire spans)
2. **Pass 2a** — Sequence boundary collapse
3. **Pass 2b** — Element deletion (individual elements within sequences)
4. **Pass 3** — Value simplification (zero/halve individual choice values)
5. **Pass 5** — Value reduction

### The Problem

For the coupling challenge, this ordering prevents effective shrinking:

1. **Pass 2b** tries to delete array elements, but the remaining elements still have large values (e.g., indices 15, 17) that would be out-of-bounds in a shorter array.
2. The materializer rejects these candidates because the values exceed the new array length.
3. **Pass 3** then simplifies values, but the array is still long — so it only reduces values to fit the current length, not the target length of 2.
4. Result: the array shrinks from length 20 to ~17, but never reaches length 2.

The core issue is a **chicken-and-egg problem**: elements can't be deleted while values are large, and values won't be simplified to fit a shorter array that doesn't exist yet.

### Hypothesis's Pass Order

From `hypothesis_shrinker.py`, Hypothesis runs passes in this order:

1. `try_trivial_spans` — zero out contiguous blocks of choices
2. `node_program` deletions — delete spans of size 5, 4, 3, 2, 1
3. `pass_to_descendant` — replace parent with child
4. `reorder_spans` — sort/reorder
5. `minimize_duplicated_choices` — shared-value minimisation
6. **`minimize_individual_choices`** — binary-search each choice toward zero
7. `redistribute_numeric_pairs` — balance adjacent numerics
8. `lower_integers_together` — jointly lower correlated integers

The critical difference: **value trivialization (`try_trivial_spans`) runs FIRST**, before any deletion. This means values are already small when deletion is attempted, so shortened arrays are more likely to contain valid indices.

Additionally, `minimize_individual_choices` includes explicit **size-dependency repair logic** — when a choice value is lowered and the result is invalid, it tries adjusting dependent choices to compensate.

## Recommendations

### 1. Reorder Passes: Value Simplification Before Deletion

Move value simplification (Pass 3) and/or a "try trivial" pass to run **before** element deletion (Pass 2b). This resolves the chicken-and-egg problem for constraints like the coupling challenge.

Proposed order:
1. **Value trivialization** — try zeroing contiguous spans of values
2. **Value simplification** — binary-search individual values toward zero
3. Container deletion
4. Sequence boundary collapse
5. Element deletion
6. Value reduction (fine-tuning)

### 2. Add a "Try Trivial Spans" Pass

Inspired by Hypothesis's `try_trivial_spans`: attempt to replace contiguous blocks of choice values with zeros. This is a high-impact, low-cost pass that can dramatically simplify values in one step, making subsequent deletion passes more effective.

### 3. Consider Joint Shrinking for Dependent Dimensions

For challenges like coupling where length and values are interdependent, consider a pass that jointly shrinks both dimensions. For example:
- When deleting an element at index `i`, also adjust any values that reference index `i` or indices beyond `i`.
- When lowering a value, check if the new value enables further element deletion.

This is analogous to Hypothesis's `redistribute_numeric_pairs` and `lower_integers_together` passes.

### 4. Long-term: Propagate Filter Predicates Through Reduction

The current workaround of duplicating filter logic in the property is fragile. Ideally, the reducer should be aware of filter predicates and reject candidates that violate them, without requiring the user to add guards to their property function.
