# Shrinking Challenge Benchmark Analysis (2026-03-30)

## Overview

Benchmark results for 14 shrinking challenges from [jlink/shrinking-challenge](https://github.com/jlink/shrinking-challenge), run with the adaptive scheduling strategy across 100 seeds per challenge (50 for Parser). Metrics: reduction invocations (median/mean), wall-clock time (median/mean ms), unique counterexamples, whether the covering array finds the failure, and iterations to first failure via random generation (median/mean across 100 seeds, max 500 iterations).

## Results

| Challenge | Invocations (med/mean) | Time ms (med/mean) | CEs | Coverage | IterToFail (med/mean) |
|---|---|---|---|---|---|
| Bound5 | 253 / 282 | 4.3 / 4.8 | 1 | true | 1 / 1.9 |
| BinaryHeap | 87 / 113 | 5.2 / 6.9 | 4 | false | 1 / 1.7 |
| Calculator | 298 / 310 | 2.9 / 3.0 | 1 | false | 26 / 37.2 |
| Coupling | 38 / 50 | 0.3 / 0.4 | 1 | false | 4 / 6.1 |
| Deletion | 9 / 9 | 0.2 / 0.2 | 1 | false | 16 / 18.4 |
| Diff: Zero | 80 / 79 | 0.2 / 0.2 | 1 | true | 200 / 190 |
| Diff: Small | 117 / 116 | 0.3 / 0.3 | 1 | true | 84 / 98 |
| Diff: One | 112 / 111 | 0.3 / 0.3 | 1 | true | 200 / 157 |
| Distinct | 178 / 185 | 1.5 / 1.6 | 1 | false | 3 / 2.6 |
| LargeUnionList | 644 / 656 | 7.3 / 7.4 | 1 | false | 21 / 21.6 |
| LengthList | 50 / 65 | 0.4 / 0.6 | 1 | false | 4 / 4.2 |
| NestedLists | 94 / 93 | 12.5 / 28.0 | 1 | false | 6 / 6.4 |
| Parser | 488 / 625 | 372 / 1315 | 15 | false | 1 / 1.0 |
| Reverse | 64 / 63 | 4.1 / 6.1 | 1 | false | 1 / 1.4 |

## Coverage phase effectiveness

Four challenges are found by the covering array: Bound5, Diff: Zero, Diff: Small, Diff: One. These have small, analyzable domains where the covering array systematically hits the failure. The Difference challenges are notable: despite coverage finding them, random generation struggles (median 84-200 iterations), confirming the coverage phase's value for sparse failures in small domains.

## Generation difficulty vs reduction difficulty

The challenges split into three categories:

**Easy to find, easy to shrink** (iterToFail low, CEs = 1): Reverse, Distinct, Coupling, LengthList. The failure is dense in the random space and the reduction landscape has a single basin.

**Easy to find, hard to shrink** (iterToFail low, CEs > 1): BinaryHeap (4 CEs), Parser (15 CEs). The failure is trivially found (median 1 iteration) but the reduction landscape has many local minima. Parser is the extreme case: 1315ms mean reduction time with 15 unique CEs.

**Hard to find, easy to shrink** (iterToFail high, CEs = 1): Calculator (median 26), Deletion (median 16), LargeUnionList (median 21), Difference variants (median 84-200). The failure requires specific value combinations that random sampling takes many iterations to hit, but once found, the reducer converges cleanly.

## BinaryHeap: 4 unique CEs

```
(0, (0, (0, None, None), None), (1, None, None))           -- 4 nodes (optimal)
(0, (0, None, (1, None, None)), (0, (0, None, None), None)) -- 5 nodes (stuck)
(0, (1, None, None), (0, (0, None, None), None))            -- 4 nodes (optimal)
(0, None, (0, (1, None, None), (0, None, None)))             -- 4 nodes (optimal)
```

3 of 4 CEs are the known optimal (4 nodes). The 5-node CE is a genuine local minimum in the reduction landscape: every single-node deletion produces a tree where the property passes. The `1` is trapped at depth 2, and moving it to depth 1 (where 4-node CEs have it) requires simultaneously restructuring the branch topology and repositioning the value. See `docs/bind-suspension-tension.md` for the full analysis.

This is consistent with [jlink/shrinking-challenge results](https://github.com/jlink/shrinking-challenge/blob/main/challenges/binheap.md) -- no PBT framework achieves a single unique CE for BinaryHeap across seeds.

## Parser: 15 unique CEs

The Parser challenge (round-trip `parse(serialize(lang)) == lang`) has the worst convergence in the suite. The 15 CEs decompose into three tiers by AST size:

**Size 3 (optimal, 2 CEs):**
```
Lang([], [Func(a, [And(Bool(false), Int(0))], [])])
Lang([], [Func(a, [Or(Bool(false), Bool(false))], [])])
```

**Size 4 (5 CEs):**
```
Lang([], [Func(a, [], [Alloc(a, And(Bool(false), Int(0)))])])
Lang([], [Func(a, [], [Alloc(a, Or(Bool(false), Bool(false)))])])
Lang([], [Func(a, [], [Assign(a, And(Bool(false), Int(0)))])])
Lang([], [Func(a, [], [Assign(a, Or(Bool(false), Bool(false)))])])
Lang([], [Func(a, [], [Return(And(Bool(false), Int(0)))])])
Lang([], [Func(a, [], [Return(Or(Bool(false), Bool(false)))])])
```

Wait -- the raw data shows `Return(And(...))` appears at size 4 but wasn't in the first 8-CE run. Including the full 15:

**Size 5 (7 CEs) -- leading empty function not deleted:**
```
Lang([], [Func(a, [], []), Func(a, [And(Bool(false), Int(0))], [])])
Lang([], [Func(a, [], []), Func(a, [Or(Bool(false), Bool(false))], [])])
Lang([], [Func(a, [], []), Func(a, [], [Alloc(a, And(Bool(false), Int(0)))])])
Lang([], [Func(a, [], []), Func(a, [], [Alloc(a, Or(Bool(false), Bool(false)))])])
Lang([], [Func(a, [], []), Func(a, [], [Assign(a, And(Bool(false), Int(0)))])])
Lang([], [Func(a, [], []), Func(a, [], [Assign(a, Or(Bool(false), Bool(false)))])])
Lang([], [Func(a, [], []), Func(a, [], [Return(Or(Bool(false), Bool(false)))])])
```

### Variation axes

Two independent axes produce the CE variants:

1. **Expression type**: `And(Bool(false), Int(0))` vs `Or(Bool(false), Bool(false))`. Both are minimal type-error expressions. `Or(Bool(false), Bool(false))` is all-zeros (shortlex-simpler). The reducer cannot convert between them because it requires changing the binary op branch AND one operand's type simultaneously.

2. **Expression position**: parameter list vs statement body (Alloc/Assign/Return). These are different branch selections at the same pick site. With branch-transparent shortlex, they're all `.eq` -- no shortlex signal to prefer one over another.

### Sequence element deletion gap

Every size-5 CE has a leading empty function `Func(a, [], [])` that should have been deleted. The corresponding size-3 or size-4 CE (without the empty function) exists and is reached by other seeds. The empty function contributes nothing to the failure.

Input/output analysis confirms: every two-function output comes from an input that already had two functions. The reducer successfully empties the first function (zeroes the variable name, deletes all args and body) but cannot delete the empty element from the function array.

This is a gap in sequence element deletion -- removing the first element of a 2-element sequence should produce a strictly shorter, shortlex-smaller result. The contiguous window deletion encoder may not handle this case, or the deletion span may cross bind boundaries that prevent clean excision.

### Comparison with known results

The [ECOOP 2020 artifact](https://github.com/mc-imperial/hypothesis-ecoop-2020-artifact/tree/master/smartcheck-benchmarks/evaluations/parser) documents optimal Parser CEs at size 3 and acceptable CEs at size 4. Exhaust reaches size 3 for 2 seeds, size 4 for 6 seeds, and gets stuck at size 5 for 7 seeds (due to the empty function deletion gap). Fixing the deletion gap would bring all 15 CEs to size 3 or 4.

## Parser timing

Parser is an outlier in wall-clock time: median 372ms, mean 1315ms. The property (`parse(serialize(lang)) == lang`) is expensive per invocation (~0.76ms median, ~2.1ms for pathological seeds). The generated counterexamples start large (deeply nested recursive expressions at depth 3), and each reduction probe re-serializes and re-parses the candidate. The mean is pulled up by a few seeds that start from especially deep trees.

At 50 seeds (reduced from 100 for time), the full Parser benchmark takes ~143 seconds. The generation is nearly instant (iterToFail median 1) -- all time is spent in reduction.
