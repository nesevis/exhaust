# Deterministic FIPOG-Style IPOG for Covering Array Generation

> **Historical note.** This document describes the batch FIPOG-style IPOG builder (`FIPOGBuilder` in `CoveringArray.swift`). As of March 2026, property-testing coverage uses the **pull-based density algorithm** (`PullBasedCoveringArrayGenerator` in `PullBasedCoveringArray.swift`), which emits rows lazily via `next()` and stops on first failure. FIPOG remains in the codebase for the contract-testing (SCA) pipeline. See `docs/pull-based-covering-array-generator.md` for the current design.

## Design Goals

| Constraint | Value |
|---|---|
| **Generation time** | Absolute fastest wall-clock |
| **Strength (t)** | 2, 3, or 4 |
| **Max rows (N)** | 2000 |
| **Determinism** | Fully deterministic — no randomisation |
| **Output order** | Shortlex (lexicographic, since all rows are equal width) |
| **Algorithm family** | One-parameter-at-a-time (IPOG) |

## Literature Basis

This design draws primarily from:

- **Lei, Kacker, Kuhn, Okun & Lawrence (2007)** — IPOG: the foundational one-parameter-at-a-time algorithm for arbitrary-strength covering arrays.
- **Forbes, Lawrence, Lei, Kacker & Kuhn (2008)** — IPOG-F: refined horizontal growth producing ~5% smaller arrays with 5–280× faster runtime.
- **Kleine & Simos (2018)** — FIPOG: the key engineering paper. Integer-packed coverage indices into bit vectors, precomputed strides, compile-time strength specialisation. Up to 146× faster than ACTS's IPOG. Implemented in Rust in the CAgen tool.
- **Colbourn (2024)** — Efficient Greedy Algorithms with Accuracy Guarantees: establishes that one-column-at-a-time (IPO) methods consume both less time and less storage than one-row-at-a-time approaches.

The design deliberately excludes:

- **AETG / row-at-a-time** — slower; searches the full product space per row.
- **Metaheuristic / SA / GA** — non-deterministic or slow convergence.
- **CPHF-based** — optimal for very large k at high t, but overkill for our parameter range and adds expansion overhead.
- **Two-stage / conditional expectation** — minimal storage but trades CPU time for it; not the fastest option.

## Algorithm Overview

IPOG builds a covering array incrementally by adding one parameter at a time:

1. **Initialisation**: construct the full factorial of the first t parameters.
2. **Horizontal growth**: for each existing row, choose the value for the new parameter that covers the most uncovered t-tuples. Ties broken by smallest value (deterministic, shortlex-biasing).
3. **Vertical growth**: add new rows to cover any t-tuples not covered by horizontal growth. Don't-care positions filled with 0 (shortlex bias).
4. **Final sort**: lexicographic sort of the ≤2000-row output array. Near-free because the smallest-value tiebreaking means rows are already nearly sorted.

### Complexity

For a covering array CA(N; t, k, v):

- **Horizontal growth** (dominates): N × v × C(i, t−1) bit-tests per parameter i. Each bit-test is a multiply-add plus a word-load-and-mask.
- **Vertical growth**: proportional to the number of uncovered tuples remaining, which is typically small after horizontal growth.
- **Final sort**: O(N log N) comparisons on rows of width k. For N ≤ 2000, this is microseconds.

### Why Not Direct Shortlex Generation?

True in-order shortlex generation is incompatible with IPOG. Horizontal growth appends a new column value to every existing row, which can arbitrarily reorder the shortlex ranking of the entire array. A one-row-at-a-time approach _could_ emit in shortlex order by iterating the candidate space lexicographically, but it is fundamentally slower — you search a product space of size ∏vᵢ per row instead of choosing among vᵢ options per cell.

The correct answer: deterministic FIPOG-style IPOG with smallest-value tiebreaking (which biases output strongly toward shortlex), followed by a final lexicographic sort of ≤2000 rows.

## Data Structures

### Coverage Slice (FIPOG Core)

The central insight from Kleine & Simos: pack each value-tuple into a flat integer index over a bit vector. One bit per possible value-tuple. No hashing, no set membership, no heap allocation in the hot path.

Each `CoverageSlice` tracks one specific combination of t parameter indices. For strength 2, each slice tracks one pair (pᵢ, p_new). For strength 3, each tracks one triple (pᵢ, pⱼ, p_new). For strength 4, one quadruple.

```
┌─────────────────────────────────────────────────────────┐
│ CoverageSlice                                           │
├─────────────────────────────────────────────────────────┤
│ params: [UInt16]        // which t parameters           │
│ strides: [UInt32]       // precomputed stride per param │
│ bits: UnsafeMutablePointer<UInt64>  // the bit vector   │
│ wordCount: Int          // number of UInt64 words       │
│ remaining: Int          // uncovered tuple count        │
├─────────────────────────────────────────────────────────┤
│ flatIndex(v₀, v₁) → Int            // t=2 hot path     │
│ flatIndex(v₀, v₁, v₂) → Int        // t=3 hot path     │
│ flatIndex(v₀, v₁, v₂, v₃) → Int    // t=4 hot path     │
│ mark(idx) → Bool                    // set bit, return  │
│                                     // true if new      │
│ isSet(idx) → Bool                   // test bit         │
└─────────────────────────────────────────────────────────┘
```

**Index computation** (the single hottest function):

For parameters with domain sizes d₀, d₁, ..., d_{t-1}:

```
stride[t-1] = 1
stride[i]   = stride[i+1] × d_{i+1}    (for i = t-2 down to 0)

flatIndex(v₀, v₁, ..., v_{t-1}) = Σ vᵢ × stride[i]
```

This is a standard row-major packing. For uniform alphabet v, stride[i] = v^(t-1-i).

**Memory per slice**: ⌈(∏dᵢ) / 64⌉ × 8 bytes. For v=4, t=2: 2 bytes. For v=6, t=4: 162 bytes.

### Column-Major Array

Store the covering array column-major: `columns[paramIndex][rowIndex]`. This layout means:

- Horizontal growth (appending a column) is a single array append — excellent cache behaviour.
- Reading all values for a given row across parameters requires k indexed lookups, but these are sequential and predictable.
- `UInt8` per cell (supports up to 256 domain values).

```
┌─────────────────────────────────────────────────────────┐
│ ColumnMajorArray                                        │
├─────────────────────────────────────────────────────────┤
│ columns: [[UInt8]]      // columns[param][row]          │
│ rowCount: Int                                           │
│ paramCount: Int                                         │
├─────────────────────────────────────────────────────────┤
│ value(row:param:) → UInt8                               │
│ addColumn([UInt8])           // horizontal growth        │
│ appendRow(UnsafeBufferPointer<UInt8>)  // vertical       │
│ sortedRows() → [[UInt8]]    // final shortlex output    │
└─────────────────────────────────────────────────────────┘
```

### Active-Frontier Coverage

At each IPOG step (extending with parameter p_{i+1}), coverage slices are allocated **only** for combinations involving p_{i+1}:

| Strength | Slices needed at step i | Combination size |
|---|---|---|
| t=2 | i (one per partner param) | C(i, 1) |
| t=3 | C(i, 2) = i(i−1)/2 | C(i, 2) |
| t=4 | C(i, 3) = i(i−1)(i−2)/6 | C(i, 3) |

Previous steps' slices are deallocated. This keeps peak memory proportional to C(k−1, t−1) × v^t **bits**, not C(k, t) × v^t.

## Strength-Specialised Hot Loops

The single most important optimisation: **separate implementations per strength** for horizontal growth. This eliminates generic tuple iteration, allows the compiler to fully inline the flatIndex calls, and enables SIMD auto-vectorisation of the inner counting loop.

### t=2 Horizontal Growth

For each existing row, evaluate each candidate value for p_new. Count how many partner parameters would yield a newly-covered pair.

```
for row in 0..<N:
    bestValue = 0
    bestCount = 0
    for v in 0..<v_new:                      // candidate values
        count = 0
        for p in 0..<i:                       // partner parameters
            existing = ca[p][row]
            idx = existing * stride_p + v      // flatIndex for t=2
            if !slice[p].isSet(idx):
                count += 1
        if count > bestCount:                  // strict > : smallest v wins tie
            bestCount = count
            bestValue = v
    ca.newColumn[row] = bestValue
    // mark covered
    for p in 0..<i:
        existing = ca[p][row]
        idx = existing * stride_p + bestValue
        slice[p].mark(idx)
```

**Inner loop cost**: one multiply, one add, one word load, one AND, one compare. Fully branchless except for the count increment.

### t=3 Horizontal Growth

Same structure, but the inner loop iterates over C(i, 2) parameter pairs:

```
for row in 0..<N:
    bestValue = 0
    bestCount = 0
    for v in 0..<v_new:
        count = 0
        for (p1, p2) in pairCombinations(0..<i):   // C(i,2) pairs
            v0 = ca[p1][row]
            v1 = ca[p2][row]
            idx = v0 * stride[0] + v1 * stride[1] + v
            if !slice[p1,p2].isSet(idx):
                count += 1
        if count > bestCount:
            bestCount = count
            bestValue = v
    ...
```

### t=4 Horizontal Growth

Inner loop iterates over C(i, 3) parameter triples. The flatIndex uses four multiplies.

### Combination Iteration

The set of parameter combinations at each step is fixed and known in advance. Precompute it as a flat array of tuples:

```
// For t=3, extending with parameter i:
// pairs = [(0,1), (0,2), ..., (0,i-1), (1,2), ..., (i-2,i-1)]
// These are computed once per IPOG step, not per row.
```

Store these as a contiguous buffer of `UInt16` pairs/triples so the inner loop accesses them sequentially (cache-friendly).

## Vertical Growth — Deterministic Strategy

After horizontal growth, some t-tuples may remain uncovered. The vertical growth phase adds new rows.

### Algorithm

```
while any slice has remaining > 0 AND rowCount < 2000:
    1. Find the first uncovered tuple across all slices
       (scanning slices in index order → deterministic)
    2. Create a new row:
       a. Fix positions dictated by the uncovered tuple
       b. Fill all free positions with 0 (shortlex bias / default)
       c. Greedily improve: for each free position (in parameter order),
          try all values (0..v-1), pick the one maximising additional
          coverage. Ties broken by smallest value.
    3. Append the row, mark all newly covered tuples
```

### Don't-Care Handling

Standard IPOG uses a don't-care sentinel that is resolved later. For fastest generation and shortlex bias, resolve immediately with value 0, then greedily overwrite. This avoids a separate resolution pass and naturally pushes rows toward the lexicographic minimum.

## Final Shortlex Sort

After all parameters are extended:

```
rows.sort(by: lexicographicCompare)
```

For N ≤ 2000 rows of width k ≤ ~30, this is O(N log N × k) comparisons — microseconds. Because smallest-value tiebreaking in both horizontal and vertical growth already biases the array toward sorted order, the sort is nearly a no-op for Swift's TimSort (O(N) on nearly-sorted input).

## Memory Budget

### Coverage Slices (Peak, at Final Step)

For the worst case at step k−1 (extending with the last parameter):

| t | k=10, v=4 | k=15, v=4 | k=20, v=6 |
|---|---|---|---|
| 2 | 9 slices × 2B = 18B | 14 slices × 2B = 28B | 19 slices × 4.5B = 85.5B |
| 3 | 36 slices × 8B = 288B | 91 slices × 8B = 728B | 171 slices × 27B = 4.6KB |
| 4 | 84 slices × 32B = 2.6KB | 364 slices × 32B = 11.4KB | 969 slices × 162B = 153KB |

Coverage memory is negligible for all practical parameters.

### Output Array

2000 rows × 20 columns × 1 byte = 40KB. Also negligible.

### Total Peak Memory

Under 1MB for any realistic parameter combination at t ≤ 4. The algorithm is completely memory-bound by the output array, not by coverage tracking.

## Implementation Checklist

### Phase 1: Core Data Structures

- [ ] `CoverageSlice` with UInt64 bit-vector storage
- [ ] Strength-specialised `flatIndex` overloads (t=2, t=3, t=4)
- [ ] `mark(_ idx:) -> Bool` and `isSet(_ idx:) -> Bool`
- [ ] `ColumnMajorArray` with column-append and row-append
- [ ] Combination precomputation (pairs for t=3, triples for t=4)

### Phase 2: IPOG Core

- [ ] Full-factorial initialisation for first t parameters
- [ ] Horizontal growth — three separate implementations for t=2,3,4
- [ ] Vertical growth with greedy don't-care resolution
- [ ] Row-count cap at 2000
- [ ] Active-frontier allocation/deallocation per step

### Phase 3: Output

- [ ] Lexicographic sort of final array (shortlex)
- [ ] Conversion to row-major output format

### Phase 4: Optimisation

- [ ] `@inline(__always)` on `flatIndex`, `mark`, `isSet`
- [ ] `UnsafeBufferPointer` / `UnsafeMutablePointer` for all hot-path storage
- [ ] Precomputed stride tables
- [ ] `&+` / `&*` wrapping arithmetic in hot loops (skip overflow checks)
- [ ] Profile-guided: verify horizontal growth dominates via Instruments

## Performance Expectations

Based on FIPOG benchmarks (Kleine & Simos 2018) and CAgen measurements (Wagner et al. 2024):

| Parameters | Expected generation time |
|---|---|
| t=2, k=10, v=4 | < 0.1ms |
| t=2, k=20, v=6 | < 1ms |
| t=3, k=15, v=4 | 1–5ms |
| t=3, k=20, v=6 | 5–20ms |
| t=4, k=15, v=4 | 10–50ms |
| t=4, k=20, v=4 | 50–200ms |

These are rough estimates scaled from FIPOG's published benchmarks. Actual Swift performance should be within 2× of equivalent Rust, given the use of unsafe pointers and inlining.

## References

1. Lei, Y., Tai, K.C. (1998). In-parameter-order: a test generation strategy for pairwise testing. _Proc. 3rd IEEE Int. High-Assurance Systems Engineering Symposium_, 254–261.
2. Lei, Y., Kacker, R., Kuhn, D.R., Okun, V., Lawrence, J. (2007). IPOG: a general strategy for t-way software testing. _Proc. 14th Annual IEEE ECBS_, 549–556.
3. Forbes, M., Lawrence, J., Lei, Y., Kacker, R.N., Kuhn, D.R. (2008). Refining the in-parameter-order strategy for constructing covering arrays. _J. Res. NIST_, 113(5), 287.
4. Kleine, K., Simos, D.E. (2018). An efficient design and implementation of the in-parameter-order algorithm. _Math. Comput. Sci._, 12(1), 51–67.
5. Bryce, R.C., Colbourn, C.J. (2009). A density-based greedy algorithm for higher strength covering arrays. _Softw. Test. Verif. Reliab._, 19(1), 37–53.
6. Colbourn, C.J. (2014). Conditional expectation algorithms for covering arrays. _J. Combin. Math. Combin. Comput._, 90, 97–115.
7. Kampel, L., Leithner, M., Simos, D.E. (2020). Sliced AETG: a memory-efficient variant of the AETG covering array generation algorithm. _Optim. Lett._, 14(6), 1543–1556.
8. Wagner, M., Kampel, L., Simos, D.E. (2021). Heuristically enhanced IPO algorithms for covering array generation. _Proc. IWOCA 2021_, LNCS 12757, 571–586.
9. Wagner, M., Colbourn, C.J., Simos, D.E. (2022). In-parameter-order strategies for covering perfect hash families. _Appl. Math. Comput._, 421, 126952.
10. Sarkar, K., Colbourn, C.J. (2019). Two-stage algorithms for covering array construction. _J. Combin. Des._, 27(8), 475–505.
11. Colbourn, C.J. (2024). Efficient greedy algorithms with accuracy guarantees for combinatorial restrictions. _SN Comput. Sci._, 5(1), 21.
12. Duan, F., Lei, Y., Yu, L., Kacker, R.N., Kuhn, D.R. (2015). Improving IPOG's vertical growth based on a graph colouring scheme. _Proc. ICSTW 2015_, 1–8.
13. Wagner, M., et al. (2024). State of the CArt: evaluating covering array generators at scale. _Int. J. Softw. Tools Technol. Transfer_.
