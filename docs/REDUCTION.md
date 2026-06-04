# How reduction works

When a property fails, Exhaust reduces the failing input to a minimal counterexample that still triggers the failure. The reducer works below the level of types by simplifying the sequence of choices the generator made, so the same process handles integers, arrays, trees, or any composition of them.

## Shape and values

A failing test case has two independent aspects: its *shape* (how many values exist and how they depend on each other) and its *values* (what those values are). The reducer treats these as separate problems.

Each cycle prioritises simplifying the shape: removing elements, flattening branches, shortening sequences. Once the shape settles, it simplifies the values within it, driving values toward semantic simplicity.

This repeats until neither makes progress. When both stall, the reducer searches for cases where a structural change and a value change must happen together for either to succeed. This is rarer, but without it the reducer would stop short of many true minima.

## Worked example: large union list

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

Three sublists, seven elements, seven distinct values. The property asked for at most four. This input is a valid counterexample, but it is an obscured one. What you as the developer need is the *minimal* input that still fails. The reducer's task is to find it.

### Three representations

The reducer maintains three co-evolving views of the counterexample, each serving a different purpose.

The *choice tree* is a hierarchy of nested decisions that mirrors the generator's composition. For our nested list, the root is a sequence node (the outer list) with three children (the sublists), each itself a sequence node whose children are integer value leaves. The tree knows that a particular integer is "the third element of the second sublist". It distinguishes a length choice from an element value, a constant from a random draw.

The tree's hierarchy is a problem for reduction. Collapsing two sublists into one, or deleting elements across structural boundaries, requires coordinated edits that the tree makes difficult. So the tree is flattened into a *choice sequence*: an ordered array of choices where those operations become simple splicing. For our counterexample — three sublists of three, three, and one element — the choice sequence is:

```swift
[[VVV][VVV][V]]
```

Each `V` is a value choice. Each bracket pair delimits a sequence. Lengths are implicit in how many entries sit between the markers, so deleting an element is just removing an entry. Collapsing two sublists is just removing a pair of close-open markers.

The flat sequence is editable but structureless. The tree is structured but hard to query across distant nodes. The reducer needs a third view: the *choice graph*, which captures the tree's hierarchy plus derived relationships the tree cannot represent. For our nested list the graph is straightforward: sequence nodes for the outer list and each sublist, value leaves for each integer. 

But the graph also computes edges between nodes that are structurally distant but related: for example, two integers that could trade magnitude, or two branches with similar shape that could be substituted. These derived edges let the reducer reason about relationships that are implicit in the tree.

The three representations are kept in sync. When an encoder mutates the sequence, `materialize` replays the generator using both the sequence and the tree to produce a fresh tree. When the tree structure is changed, the graph is rebuilt. Convergence records (which values have already been simplified as far as possible) transfer across rebuilds so work is not repeated.

### What "simpler" means

The choice sequence defines a natural ordering: *shortlex*. A shorter sequence is simpler than a longer one. Between sequences of equal length, the one whose values are smaller (in a type-aware sense) is simpler.

For signed integers, closeness to zero is a natural measure of simplicity. The zigzag ordering (0, −1, 1, −2, 2, and so on) is the encoding that makes shortlex agree with that measure.

### The journey

The reducer accepts a candidate if and only if the property still fails *and* the candidate is strictly simpler in shortlex order.

Starting from `[[-31, 111, 405], [-32, 545, 537], [-643]]`, the reducer converges around a millisecond later, after two cycles and 84 property invocations.

During this time, the reducer interleaves operations by estimated improvement, so deletion, migration, and value search all run within the first cycle.

**Deletion.** The reducer proposes removing elements from the sublists. The first four proposals are rejected: each would drop the distinct-value count below five, and the property would pass. The fifth succeeds, reducing the choice sequence from 15 choices to 12. The graph is rebuilt.

**Migration.** The reducer consolidates elements from one sublist into another, enabling further deletion. One migration is accepted. The sequence is further reduced to 10 choices.

**More deletion.** With elements consolidated, one more element can be removed. The sequence is reduced to 9. Seven more deletion proposals follow, all rejected. The structure has reached its minimum: one sublist, five elements, five distinct values.

**Value search.** The reducer drives each integer toward zero. Some reach it; others cannot go further without duplicating another value, which would drop the distinct count below five and pass the property. Each value settles at the smallest integer not already taken.

The reducer attempts further coordinated value adjustments, but none succeed. The first cycle ends.

The second cycle confirms convergence. Every attempted simplification has been seen before and is rejected.

**Reordering** runs once after convergence. It sorts the elements into their natural numeric order: `[−2, −1, 0, 1, 2]`. This does not change the set of distinct values, so the property still fails.

### The result

```
[[-2, -1, 0, 1, 2]]
```

A single sublist containing five integers. The minimum number of distinct values needed to exceed the property's threshold of four. The values are the five integers closest to zero. The structure is the simplest nesting that can hold them. Across a thousand random seeds, the reducer converges to this exact counterexample every time.

The reduced counterexample says the same thing the original did. The difference is that now there is no noise to distract you.

### Why this works

Three properties of the approach make this outcome possible.

First, reduction operates on choices, not on values. The reducer never needs to know what an integer is or how a nested list works. It sees a sequence of choices and makes that sequence shorter and smaller. This is why no generator needs custom reduction logic.

Second, shape and values are separated. The reducer removes structure until no further removal is possible, then drives the remaining values toward their simplest forms. The final counterexample is minimal in both dimensions independently.

Third, committed progress is irreversible. Every accepted candidate is strictly simpler than the one before it. When reduction stalls at a local minimum, the reducer may explore a structurally different neighbourhood — but only keeps the result if it is strictly simpler than what came before. This is what allows the reducer to reach the same counterexample regardless of where it starts.
