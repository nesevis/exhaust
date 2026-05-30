# How reduction works

When a property fails, Exhaust reduces the failing input to the smallest counterexample that still triggers the failure. Reduction operates on the generator's recorded choices rather than the output value, making it type-agnostic and preserving all generator invariants. No custom reduction logic is needed.

## Shape and values

A failing test case has two independent aspects: its *shape* (how many values exist and how they depend on each other) and its *values* (what those values are). The reducer treats these as separate problems.

Each cycle first simplifies the shape: removing elements, flattening branches, shortening sequences. Then it simplifies the values within that fixed shape, driving numbers toward zero.

This repeats until neither makes progress. When both stall, the reducer tries to escape by searching shape and values jointly along dependency edges, or temporarily worsening one value to unlock progress elsewhere.

## Reading reduction output

When Exhaust reports a counterexample, the output includes:

- **Counterexample**: a textual representation of the reduced value.
- **Property invoked: N times**: the total number of property invocations across coverage, sampling, and reduction.
- **Reproduce: .replay("seed")**: a seed that deterministically reproduces the reduced counterexample.

With `.includeDiff` enabled, the output also includes a structural diff between the original failing value and the reduced counterexample, showing exactly what the reducer removed or simplified.

# Worked example: large union list

> [!Note]
> This example is from the [Shrinking Challenge](https://github.com/jlink/shrinking-challenge/blob/main/pbt-libraries/exhaust/reports/largeUnionList.md), a cross-library benchmark for test case reduction, or "shrinking".

Consider a property about nested lists of integers:

```swift
Set(list.flatMap(\.self)).count <= 4
```

The union of all values, across every sublist, contains at most four distinct members. A generator produces random instances: between one and ten sublists, each containing one to ten integers drawn from the full range of the type. The generator runs, and the property fails. For one particular seed, the initial counterexample is:

```
[[-31, 111, 405], [-32, 545, 537], [-643]]
```

Three sublists, seven elements, seven distinct values. The property asked for at most four. This input is a valid counterexample, but it is an unhelpful one. What you as the developer need is the *simplest* input that still fails. The reducer's task is to find it.

## Three representations

The reducer maintains three co-evolving views of the counterexample, each serving a different purpose.

The *choice tree* is a hierarchy of nested decisions that mirrors the generator's composition. For our nested list, the root is a sequence node (the outer list) with three children (the sublists), each itself a sequence node whose children are integer value leaves. The tree knows that a particular integer is "the third element of the second sublist." It distinguishes a length choice from an element value, a constant from a random draw.

The tree's hierarchy is a problem for reduction. Collapsing two sublists into one, or deleting elements across structural boundaries, requires coordinated edits that the tree makes difficult. So the tree is flattened into a *choice sequence*: an ordered array of entries where those operations become simple splicing.

```swift
[[VVV][VVV][V]]
```

Each `V` is a value entry. Each bracket pair delimits a sequence. Lengths are implicit in how many entries sit between the markers, so deleting an element is just removing an entry. Collapsing two sublists is just removing a pair of close-open markers.

The flat sequence is editable but structureless. The tree is structured but hard to query across distant nodes. The reducer needs a third view: the *choice graph*, which captures the tree's hierarchy plus derived relationships the tree does not represent. For our nested list the graph is straightforward: sequence nodes for the outer list and each sublist, value leaves for each integer. But the graph also computes edges that connect value leaves of the same type (channels for magnitude redistribution) and branch selectors that share a structural fingerprint (candidates for substitution). These derived edges let the reducer reason about relationships that are implicit in the tree.

The three representations stay in sync. When an encoder mutates the sequence, the `Materializer` replays the generator using both the sequence and the tree to produce a fresh tree. When the tree structure is changed, the graph is rebuilt. Convergence records (bounds per-leaf the value encoder has already discovered) transfer across rebuilds so work is not repeated.

## What "simpler" means

The choice sequence defines a natural ordering: *shortlex*. A shorter sequence is simpler than a longer one. Between sequences of equal length, the one whose values are smaller (in a type-aware sense) is simpler.

For signed integers, "smaller" means closer to zero: 0 is simplest, then −1, then 1, then −2, then 2, and so on outward in both directions. This zigzag ordering ensures the reducer gravitates toward human-readable values rather than toward the most negative representable number.

The reducer accepts a candidate if and only if the property still fails *and* the candidate is strictly simpler in shortlex order. This monotonicity guarantee means reduction never regresses.

## The journey

Starting from `[[-31, 111, 405], [-32, 545, 537], [-643]]`, the reducer converges around a millisecond later, after two cycles and 84 property invocations. 

During this time, the scheduler interleaves operations by estimated improvement, so deletion, migration, and value search all run within the first cycle.

**Deletion.** The deletion encoder proposes removing elements from the sublists. The first four proposals are rejected: each would drop the distinct-value count below five, and the property would pass. The fifth succeeds, reducing the choice sequence from 15 entries to 12. The graph is rebuilt.

**Migration.** The migration encoder consolidates elements from one sublist into another, enabling further deletion. One migration is accepted. The sequence is further reduced to 10 entries.

**More deletion.** With elements consolidated, one more element can be removed. The sequence is reduced to to 9. Seven more deletion proposals follow, all rejected. The structure has reached its minimum: one sublist, five elements, five distinct values.

**Value search.** The value encoder targets each integer leaf and drives it toward zero. Out of 58 probes, 30 are accepted, 11 hit a rejection cache — a hash of previously rejected mutations that avoids re-testing them — and 17 are rejected by the property because the candidate is equal to another value. When a leaf cannot go below a certain value without the property passing, the encoder records that bound and stops.

**Redistribution and lockstep** attempt to adjust values further by transferring magnitude between leaves or changing two values in lockstep. All probes either hit the cache or are rejected. The first cycle ends.

The second cycle confirms convergence. Every probe is rejected or cached. No improvements are possible.

**Reordering** runs once after convergence. It sorts the elements into their natural numeric order: `[−2, −1, 0, 1, 2]`. This does not change the set of distinct values, so the property still fails.

## The result

```
[[-2, -1, 0, 1, 2]]
```

A single sublist containing five integers. The minimum number of distinct values needed to exceed the property's threshold of four. The values are the five integers closest to zero. The structure is the simplest nesting that can hold them. Across a thousand random seeds, the reducer converges to this exact counterexample every time.

The reducer knew nothing about the requirement for distinct values, nothing about why five matters and four doesn't. It operated on the choice tree and its flat projection, replaying the generator after each rewrite to check whether the property still failed. Each encoder sees only its local scope. The global trajectory, from seven elements to five, from three sublists to one, emerges from their interaction with the property's yes-or-no verdict.

The counterexample the reducer produces is not an answer. It is a question, now phrased as simply as possible: 

> Here are five values. You said four was supposed to be the maximum. How did that happen?
