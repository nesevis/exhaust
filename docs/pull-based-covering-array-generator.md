# Pull-Based Covering Array Generator — Implementation Specification

> **Status: Implemented.** `PullBasedCoveringArrayGenerator` in `Sources/ExhaustCore/Analysis/PullBasedCoveringArray.swift` is the active covering array generator for both finite and boundary domain coverage. `CoverageRunner` pulls rows via `next()` and tests each against the property, stopping on first failure. The `FibreCoveringEncoder` in the BonsaiReducer also uses this generator for downstream fibre search.

## 1. Purpose

A pull-based (lazy) covering array generator for use in a property-based testing framework. Each call to `next()` returns a single row (test case) that greedily maximises new t-tuple coverage. The caller pulls rows until a property test fails, then stops. The generator never builds the full covering array — it emits only as many rows as needed to find a failure.

This design is motivated by the observation that in PBT, the covering array is not the deliverable — the _failure_ is. Most bugs triggered by a t-way interaction will be found within the first O(vᵗ · t · log k) rows, far fewer than the complete array.

## 2. Design Constraints

| Constraint | Value |
|---|---|
| Strength (t) | 2, 3, or 4 |
| Max rows (N) | 2000 (hard cap) |
| Determinism | Fully deterministic — no randomisation |
| Output order | Rows emitted in greedy order; shortlex achieved via smallest-value tiebreaking |
| Interface | Pull-based iterator: `next() → Row?` |
| Per-row latency | Predictable, no amortisation, no upfront cost beyond O(C(k,t)) slice allocation |

## 3. Theoretical Foundation

### 3.1 Coverage Decay Guarantee

From Bryce & Colbourn (2007/2009): if R tuples remain uncovered before generating a row, the greedy row covers at least R / vᵗ of them. The remaining uncovered count after row n is bounded by:

```
R(n) ≤ T · (1 − 1/vᵗ)ⁿ
```

where T = C(k, t) · vᵗ is the total number of t-tuples.

Concrete example — t=2, k=10, v=3:

```
T = C(10,2) · 9 = 405
After 20 rows:  R ≤ 405 · (8/9)²⁰ ≈ 39   (~90% covered)
After 40 rows:  R ≤ 405 · (8/9)⁴⁰ ≈ 4    (~99% covered)
After 60 rows:  R ≤ 405 · (8/9)⁶⁰ ≈ 0.4  (~100% covered)
```

For a bug triggered by any specific pairwise interaction, the expected number of rows before detection is O(vᵗ · log(C(k,t))).

### 3.2 Algorithm Class

One-row-at-a-time greedy with left-to-right column fill. Each column position is filled by choosing the value that maximises the number of t-tuples that become _fully determined and newly covered_ at that position. This is a deterministic variant of the density/conditional-expectation approach.

The algorithm does not use conditional expectation of future coverage from unfilled columns — it counts only fully-determined tuples. This is slightly weaker theoretically (no formal guarantee of meeting the probabilistic bound) but simpler and faster per cell, and produces competitive results in practice.

## 4. Data Structures

### 4.1 CoverageSlice

Each `CoverageSlice` tracks coverage for one specific combination of t parameter indices. It uses a flat bit vector indexed by a packed integer representation of the value-tuple.

#### Fields

| Field | Type | Description |
|---|---|---|
| `paramIndices` | `[UInt16]` | The t parameter indices this slice tracks. Length = t. Sorted ascending. |
| `domainSizes` | `[Int]` | Domain size for each parameter in this slice. Parallel to `paramIndices`. |
| `strides` | `[UInt32]` | Precomputed stride multipliers for row-major index packing. Length = t. |
| `bits` | `UnsafeMutablePointer<UInt64>` | The bit vector. One bit per possible value-tuple. |
| `wordCount` | `Int` | Number of UInt64 words in `bits`. |
| `totalTuples` | `Int` | Total number of value-tuples = ∏ domainSizes. Immutable after init. |
| `remaining` | `Int` | Number of currently uncovered tuples. Decremented on each `mark`. |

#### Stride Computation

```
strides[t-1] = 1
strides[i]   = strides[i+1] × domainSizes[i+1]    for i = t-2 down to 0
```

#### Flat Index Computation

For a value-tuple (v₀, v₁, ..., v_{t-1}):

```
flatIndex = Σᵢ vᵢ × strides[i]
```

Provide separate overloads for t=2, t=3, t=4 — all marked `@inline(__always)` with wrapping arithmetic (`&*`, `&+`).

```swift
// t=2
@inline(__always)
func flatIndex(_ v0: UInt8, _ v1: UInt8) -> Int {
    Int(v0) &* Int(strides[0]) &+ Int(v1)
}

// t=3
@inline(__always)
func flatIndex(_ v0: UInt8, _ v1: UInt8, _ v2: UInt8) -> Int {
    Int(v0) &* Int(strides[0]) &+ Int(v1) &* Int(strides[1]) &+ Int(v2)
}

// t=4
@inline(__always)
func flatIndex(_ v0: UInt8, _ v1: UInt8, _ v2: UInt8, _ v3: UInt8) -> Int {
    Int(v0) &* Int(strides[0]) &+ Int(v1) &* Int(strides[1])
        &+ Int(v2) &* Int(strides[2]) &+ Int(v3)
}
```

#### Bit Operations

```swift
/// Set bit at index. Returns true if the bit was previously unset (newly covered).
@inline(__always)
mutating func mark(_ idx: Int) -> Bool {
    let (word, bit) = idx.quotientAndRemainder(dividingBy: 64)
    let mask: UInt64 = 1 &<< bit
    if bits[word] & mask == 0 {
        bits[word] |= mask
        remaining &-= 1
        return true
    }
    return false
}

/// Test bit at index.
@inline(__always)
func isSet(_ idx: Int) -> Bool {
    let (word, bit) = idx.quotientAndRemainder(dividingBy: 64)
    return bits[word] & (1 &<< bit) != 0
}
```

#### Memory

```
bytes per slice = ⌈(∏ domainSizes) / 64⌉ × 8
```

| v | t=2 | t=3 | t=4 |
|---|---|---|---|
| 2 | 1 byte | 1 byte | 2 bytes |
| 3 | 2 bytes | 4 bytes | 8 bytes |
| 4 | 2 bytes | 8 bytes | 32 bytes |
| 5 | 4 bytes | 16 bytes | 80 bytes |
| 6 | 8 bytes | 32 bytes | 168 bytes |

#### Lifecycle

Slices are allocated during generator initialisation and deallocated when the generator is dropped. No allocation occurs during `next()`.

### 4.2 SlicesByCompletingColumn

A precomputed lookup table: for each column index c, which slice indices have c as their rightmost (highest-index) participating parameter?

| Type | `[[Int]]` of length k |
|---|---|

#### Construction

For each slice i with `paramIndices` = [p₀, p₁, ..., p_{t-1}] (sorted ascending):

```
rightmost = paramIndices[t - 1]
slicesByCompletingColumn[rightmost].append(i)
```

#### Purpose

During left-to-right row fill, when filling column c, only the slices in `slicesByCompletingColumn[c]` can have tuples that become fully determined. All other slices either:

- Have all parameters to the left of c (already evaluated at an earlier column), or
- Have at least one parameter to the right of c (not yet determined).

This avoids evaluating irrelevant slices and is the primary efficiency gain of left-to-right fill.

#### Work Distribution

For strength t and column c, the number of completing slices at column c is C(c, t−1):

**t=2:**

```
col 0:  0 slices
col 1:  1 slice   — pair (0, 1)
col 2:  2 slices  — pairs (0,2), (1,2)
col 3:  3 slices  — pairs (0,3), (1,3), (2,3)
...
col c:  c slices
```

**t=3:**

```
col 0:  0 slices
col 1:  0 slices
col 2:  1 slice   — triple (0, 1, 2)
col 3:  3 slices  — triples (0,1,3), (0,2,3), (1,2,3)
...
col c:  C(c, 2) slices
```

**t=4:**

```
col c:  C(c, 3) slices
```

Total work per row = Σ_{c=0}^{k-1} C(c, t−1) · v_c = C(k, t) · v (for uniform alphabet). This is the same as evaluating all slices once per candidate value, but the left-to-right structure means early columns do less work, and the greedy signal concentrates where it matters most.

### 4.3 ParameterOrdering

Parameters are reordered so that columns with the smallest domains come first. This is a free optimisation: early columns (small domain) have few completing slices and few candidate values, so they resolve quickly. Later columns (larger domain) have the most completing slices and thus the richest greedy signal.

| Field | Type | Description |
|---|---|---|
| `reorderedDomainSizes` | `[Int]` | Domain sizes in the new order. |
| `forwardPermutation` | `[Int]` | Maps original parameter index → reordered index. |
| `inversePermutation` | `[Int]` | Maps reordered index → original parameter index. |

#### Construction

```swift
let indexed = domainSizes.enumerated()
    .sorted(by: { $0.element < $1.element })
forwardPermutation = indexed.map(\.offset)
// inversePermutation[forwardPermutation[i]] = i for all i
```

#### Row Restoration

When emitting a row to the caller, un-permute it back to the original parameter order:

```swift
func restore(_ row: ContiguousArray<UInt8>) -> ContiguousArray<UInt8> {
    var out = ContiguousArray<UInt8>(repeating: 0, count: row.count)
    for i in 0..<row.count {
        out[forwardPermutation[i]] = row[i]
    }
    return out
}
```

This step is O(k) and negligible.

### 4.4 Row Buffer

A single `ContiguousArray<UInt8>` of length k, reused across `next()` calls. No allocation during row generation.

## 5. Algorithm

### 5.1 Initialisation

```
INPUT:  domainSizes: [Int], strength: Int
OUTPUT: fully initialised generator ready for next() calls

1.  Validate: strength ∈ {2, 3, 4}, domainSizes.count ≥ strength

2.  Compute parameter ordering:
    ordering = ParameterOrdering(domainSizes)
    reorderedDomains = ordering.reorderedDomainSizes

3.  Enumerate all C(k, t) parameter combinations (in reordered index space):
    combos = combinations(of: 0..<k, choose: t)

4.  Allocate one CoverageSlice per combination:
    for each combo [p₀, p₁, ..., p_{t-1}]:
        dims = [reorderedDomains[p₀], ..., reorderedDomains[p_{t-1}]]
        slice = CoverageSlice(domainSizes: dims)

5.  Build slicesByCompletingColumn:
    for each (sliceIndex, combo) in combos.enumerated():
        rightmost = combo.last!
        slicesByCompletingColumn[rightmost].append(sliceIndex)

6.  Compute totalRemaining = Σ slice.totalTuples

7.  Allocate rowBuffer of length k, zeroed.
```

### 5.2 Row Generation — `next()`

```
OUTPUT: one row (ContiguousArray<UInt8>) or nil if fully covered

1.  If totalRemaining == 0, return nil.

2.  LEFT-TO-RIGHT FILL:
    for col in 0..<k:
        relevantSlices = slicesByCompletingColumn[col]

        if relevantSlices is empty:
            rowBuffer[col] = 0      // no coverage signal; shortlex default
            continue

        bestValue = 0
        bestGain  = 0

        for v in 0 ..< UInt8(reorderedDomains[col]):
            rowBuffer[col] = v
            gain = 0

            for sliceIdx in relevantSlices:
                // Extract the values from rowBuffer at positions
                // corresponding to this slice's parameter indices.
                // All these positions are ≤ col, so they are already filled.
                flatIdx = computeFlatIndex(sliceIdx, rowBuffer)
                if NOT slices[sliceIdx].isSet(flatIdx):
                    gain += 1

            if gain > bestGain:     // strict >  : smallest value wins ties
                bestGain  = gain
                bestValue = v

        rowBuffer[col] = bestValue

3.  MARK COVERED TUPLES:
    for col in 0..<k:
        for sliceIdx in slicesByCompletingColumn[col]:
            flatIdx = computeFlatIndex(sliceIdx, rowBuffer)
            if slices[sliceIdx].mark(flatIdx):
                totalRemaining -= 1

4.  RESTORE PARAMETER ORDER:
    output = ordering.restore(rowBuffer)

5.  Return output.
```

### 5.3 Flat Index Dispatch

The `computeFlatIndex` call must resolve the slice's parameter indices into values from the row buffer, then call the appropriate strength-specialised `flatIndex` overload.

```
func computeFlatIndex(sliceIdx: Int, row: ContiguousArray<UInt8>) -> Int {
    let params = sliceParamIndices[sliceIdx]
    switch strength {
    case 2:
        return slices[sliceIdx].flatIndex(
            row[Int(params[0])],
            row[Int(params[1])]
        )
    case 3:
        return slices[sliceIdx].flatIndex(
            row[Int(params[0])],
            row[Int(params[1])],
            row[Int(params[2])]
        )
    case 4:
        return slices[sliceIdx].flatIndex(
            row[Int(params[0])],
            row[Int(params[1])],
            row[Int(params[2])],
            row[Int(params[3])]
        )
    }
}
```

For maximum performance, the switch on `strength` should be hoisted out of the inner loop. This can be achieved by making the generator generic over strength (compile-time specialisation), or by having three separate `next()` implementations dispatched once at init time.

### 5.4 Compile-Time Strength Specialisation

The switch on `strength` inside the inner loop is a performance hazard — it prevents vectorisation and adds a branch per slice evaluation. Two approaches to eliminate it:

**Option A: Generic over strength.**

```swift
struct CoveringArrayGenerator<Strength: CoveringStrength>: IteratorProtocol {
    // Strength.value is a compile-time constant
    // All flatIndex calls resolve to the correct overload at compile time
}

protocol CoveringStrength {
    static var value: Int { get }
}
enum Pairwise: CoveringStrength { static let value = 2 }
enum ThreeWay: CoveringStrength { static let value = 3 }
enum FourWay: CoveringStrength  { static let value = 4 }
```

**Option B: Three concrete types behind a protocol.**

```swift
protocol CoveringArrayGenerating: IteratorProtocol where Element == ContiguousArray<UInt8> {}

struct PairwiseCoveringArrayGenerator: CoveringArrayGenerating { ... }
struct ThreeWayCoveringArrayGenerator: CoveringArrayGenerating { ... }
struct FourWayCoveringArrayGenerator: CoveringArrayGenerating { ... }
```

Option A is preferred — it avoids code triplication while still giving the compiler full static dispatch. The `Strength` generic parameter is erased at the public API boundary.

## 6. Worked Example

Parameters: A (domain 2), B (domain 3), C (domain 2), D (domain 3). Strength t=2.

### 6.1 Parameter Reordering

Sort by domain size (ascending): A(2), C(2), B(3), D(3).

```
Reordered indices:   0=A, 1=C, 2=B, 3=D
Reordered domains:   [2, 2, 3, 3]
Forward permutation: [0, 2, 1, 3]   (original A→0, B→2, C→1, D→3)
Inverse permutation: [0, 2, 1, 3]   (reordered 0→A, 1→C, 2→B, 3→D)
```

### 6.2 Slice Enumeration

C(4, 2) = 6 pairwise slices (in reordered index space):

| Slice | Params (reordered) | Domain sizes | Total tuples | Strides |
|---|---|---|---|---|
| 0 | (0, 1) | [2, 2] | 4 | [2, 1] |
| 1 | (0, 2) | [2, 3] | 6 | [3, 1] |
| 2 | (0, 3) | [2, 3] | 6 | [3, 1] |
| 3 | (1, 2) | [2, 3] | 6 | [3, 1] |
| 4 | (1, 3) | [2, 3] | 6 | [3, 1] |
| 5 | (2, 3) | [3, 3] | 9 | [3, 1] |

Total tuples: 4 + 6 + 6 + 6 + 6 + 9 = 37.

### 6.3 SlicesByCompletingColumn

```
col 0:  []                 (no slice has rightmost param = 0)
col 1:  [0]                (slice 0: params (0,1))
col 2:  [1, 3]             (slice 1: params (0,2), slice 3: params (1,2))
col 3:  [2, 4, 5]          (slice 2: params (0,3), slice 4: params (1,3), slice 5: params (2,3))
```

### 6.4 Generating Row 0

**Col 0**: No completing slices. Set rowBuffer[0] = 0.

**Col 1**: Completing slices: [0] (pair (0,1)).

- v=0: tuple (0,0) → flatIndex = 0×2 + 0 = 0. Uncovered. gain=1.
- v=1: tuple (0,1) → flatIndex = 0×2 + 1 = 1. Uncovered. gain=1.
- Tie → pick v=0 (smallest). rowBuffer[1] = 0.

**Col 2**: Completing slices: [1, 3] (pairs (0,2) and (1,2)).

- v=0: slice 1 tuple (0,0) idx=0 uncovered; slice 3 tuple (0,0) idx=0 uncovered. gain=2.
- v=1: slice 1 tuple (0,1) idx=1 uncovered; slice 3 tuple (0,1) idx=1 uncovered. gain=2.
- v=2: slice 1 tuple (0,2) idx=2 uncovered; slice 3 tuple (0,2) idx=2 uncovered. gain=2.
- Tie → pick v=0. rowBuffer[2] = 0.

**Col 3**: Completing slices: [2, 4, 5] (pairs (0,3), (1,3), (2,3)).

- v=0: slice 2 (0,0) uncov; slice 4 (0,0) uncov; slice 5 (0,0) uncov. gain=3.
- v=1: all uncov. gain=3.
- v=2: all uncov. gain=3.
- Tie → pick v=0. rowBuffer[3] = 0.

**Row 0 (reordered)**: [0, 0, 0, 0]

**Mark covered**: 6 tuples marked. totalRemaining = 37 − 6 = 31.

**Restore to original order**: A=0, B=0, C=0, D=0 → [0, 0, 0, 0].

### 6.5 Generating Row 1

**Col 0**: No completing slices. rowBuffer[0] = 0.

**Col 1**: Slice 0 (pair (0,1)).

- v=0: tuple (0,0) → already covered. gain=0.
- v=1: tuple (0,1) → uncovered. gain=1.
- Pick v=1. rowBuffer[1] = 1.

**Col 2**: Slices [1, 3].

- v=0: slice 1 (0,0) covered (from row 0); slice 3 (1,0) uncovered. gain=1.
- v=1: slice 1 (0,1) uncovered; slice 3 (1,1) uncovered. gain=2.
- v=2: slice 1 (0,2) uncovered; slice 3 (1,2) uncovered. gain=2.
- Tie at v=1, v=2 → pick v=1. rowBuffer[2] = 1.

**Col 3**: Slices [2, 4, 5].

- v=0: slice 2 (0,0) covered; slice 4 (1,0) uncov; slice 5 (1,0) uncov. gain=2.
- v=1: slice 2 (0,1) uncov; slice 4 (1,1) uncov; slice 5 (1,1) uncov. gain=3.
- v=2: slice 2 (0,2) uncov; slice 4 (1,2) uncov; slice 5 (1,2) uncov. gain=3.
- Tie at v=1, v=2 → pick v=1. rowBuffer[3] = 1.

**Row 1 (reordered)**: [0, 1, 1, 1]

**Mark covered**: 6 tuples marked. totalRemaining = 31 − 6 = 25.

**Restore**: A=0, B=1, C=1, D=1 → [0, 1, 1, 1].

## 7. Memory Budget

### 7.1 Coverage Slices

Total slice memory = Σ over all C(k,t) slices of ⌈(∏ domainSizes) / 64⌉ × 8 bytes.

For uniform alphabet v:

```
Total = C(k, t) × ⌈vᵗ / 64⌉ × 8 bytes
```

| Params (k) | v | t=2 | t=3 | t=4 |
|---|---|---|---|---|
| 10 | 3 | 45 × 2B = 90B | 120 × 4B = 480B | 210 × 8B = 1.6KB |
| 10 | 4 | 45 × 2B = 90B | 120 × 8B = 960B | 210 × 32B = 6.6KB |
| 15 | 4 | 105 × 2B = 210B | 455 × 8B = 3.6KB | 1365 × 32B = 42.7KB |
| 20 | 4 | 190 × 2B = 380B | 1140 × 8B = 8.9KB | 4845 × 32B = 151KB |
| 20 | 6 | 190 × 8B = 1.5KB | 1140 × 32B = 35.6KB | 4845 × 168B = 795KB |

Coverage memory is under 1MB for all practical parameter combinations.

### 7.2 Auxiliary Structures

- `slicesByCompletingColumn`: k arrays of Int indices. ~C(k,t) × 8 bytes total.
- `sliceParamIndices`: C(k,t) arrays of t × UInt16. ~C(k,t) × 2t bytes.
- `rowBuffer`: k bytes.
- `ParameterOrdering`: 3 × k × 8 bytes.

All negligible.

### 7.3 Total Peak Memory

Under 1MB for any realistic combination with t ≤ 4, k ≤ 20, v ≤ 6.

## 8. Performance Characteristics

### 8.1 Per-Row Cost

For uniform alphabet v, the work per `next()` call is:

```
Σ_{c=0}^{k-1} C(c, t-1) × v_c   evaluations of flatIndex + isSet
```

For uniform v, this simplifies to C(k, t) × v evaluations per row.

Each evaluation is:

- t multiply-adds (flatIndex computation)
- 1 word load + 1 AND + 1 compare (isSet)

For t=2, k=15, v=4: C(15,2) × 4 = 420 evaluations per row. At ~2ns per evaluation (assuming L1 cache hits), that is approximately 0.84μs per row.

For t=3, k=15, v=4: C(15,3) × 4 = 1820 evaluations per row ≈ 3.6μs per row.

For t=4, k=15, v=4: C(15,4) × 4 = 5460 evaluations per row ≈ 11μs per row.

### 8.2 Expected Rows to Failure

If a bug is triggered by a specific t-way interaction, the expected number of rows before it is covered follows from the coverage decay bound:

```
Expected rows ≈ vᵗ × ln(C(k,t) × vᵗ)
```

| k | v | t=2 | t=3 | t=4 |
|---|---|---|---|---|
| 10 | 3 | ~54 | ~240 | ~750 |
| 10 | 4 | ~90 | ~500 | ~2000 |
| 15 | 3 | ~58 | ~270 | ~900 |
| 15 | 4 | ~95 | ~560 | ~2200 |

These are upper bounds. In practice, greedy covering is substantially better than the worst-case bound, and most bugs involve common interactions that appear in the first few dozen rows.

### 8.3 Time to First Failure

Combining per-row cost with expected rows:

| Scenario | Per-row | Expected rows | Time to failure |
|---|---|---|---|
| t=2, k=15, v=4 | 0.84μs | ~95 | ~80μs |
| t=3, k=15, v=4 | 3.6μs | ~560 | ~2ms |
| t=4, k=15, v=4 | 11μs | ~2200 | ~24ms |

This is the generation time only, excluding the property test execution cost. In most PBT scenarios, the property test itself dominates.

## 9. Termination Conditions

The generator returns `nil` (signalling completion) when:

1. `totalRemaining == 0` — all t-tuples are covered. The full covering array has been emitted.
2. The caller stops calling `next()` — normal early termination on property failure.

The caller should also enforce the 2000-row hard cap externally:

```swift
var count = 0
while count < 2000, let row = generator.next() {
    count += 1
    if !property(decode(row)) {
        return .failure(row)
    }
}
```

## 10. Integration Points

### 10.1 ChoiceSequence Mapping

Each row from `next()` is a `ContiguousArray<UInt8>` of length k, where `row[i]` is the value index (0-based) for original parameter i (after restoration from reordered space). The caller maps these to actual typed values:

```swift
// Example: parameter 0 is an enum with cases [.a, .b, .c]
let paramValue = MyEnum.allCases[Int(row[0])]
```

### 10.2 Domain Size Extraction

The generator requires `domainSizes: [Int]` — the number of distinct values for each parameter. These must be extracted from the generator/enum definitions at the call site:

- Boolean parameters: domain size 2
- Enum parameters: domain size = `CaseIterable.allCases.count`
- Integer ranges: discretised to domain size = range count
- Filtered/constrained parameters: domain size = number of valid values after filtering

### 10.3 Strength Selection

Typical defaults:

- t=2 (pairwise) for most testing scenarios. Covers all two-way interactions.
- t=3 for safety-critical or high-interaction systems.
- t=4 rarely needed; use only when lower strengths miss known interaction faults.

The framework should default to t=2 and allow override via API.

## 11. Implementation Checklist

### Phase 1: Core Types

- [ ] `CoverageSlice` struct with UnsafeMutablePointer<UInt64> storage
- [ ] `flatIndex` overloads for t=2, t=3, t=4
- [ ] `mark(_ idx:) -> Bool`
- [ ] `isSet(_ idx:) -> Bool`
- [ ] `deinit` / deallocation for the bit vector
- [ ] `ParameterOrdering` struct with forward/inverse permutations and `restore`

### Phase 2: Generator Initialisation

- [ ] Combination enumeration (all C(k,t) subsets of 0..<k)
- [ ] Slice allocation from combinations + reordered domain sizes
- [ ] `slicesByCompletingColumn` construction
- [ ] `sliceParamIndices` storage
- [ ] `totalRemaining` computation

### Phase 3: Row Generation

- [ ] Left-to-right column fill with greedy value selection
- [ ] Strength-specialised `computeFlatIndex` dispatch (hoist switch out of inner loop)
- [ ] Smallest-value tiebreaking (strict `>` comparison)
- [ ] Coverage marking pass after row completion
- [ ] Row restoration to original parameter order

### Phase 4: Compile-Time Specialisation

- [ ] Generic `CoveringArrayGenerator<Strength>` with `CoveringStrength` protocol
- [ ] Or: three concrete types behind a common protocol
- [ ] Ensure inner loops contain no dynamic dispatch or strength branching

### Phase 5: Testing

- [ ] Verify full coverage: run generator to exhaustion, confirm all t-tuples covered
- [ ] Verify determinism: same inputs always produce same output sequence
- [ ] Verify parameter restoration: output rows are in original parameter order
- [ ] Coverage decay: confirm coverage percentage at row n matches theoretical bound
- [ ] Memory: confirm no allocations during `next()` (use Instruments Allocations)
- [ ] Performance: benchmark per-row latency for representative parameter sets

### Phase 6: Optimisation

- [ ] `@inline(__always)` on flatIndex, mark, isSet, computeFlatIndex
- [ ] `ContiguousArray` for all hot-path arrays
- [ ] Wrapping arithmetic (`&+`, `&*`, `&-`) in all index computations
- [ ] Profile with Instruments: confirm inner loop of horizontal fill dominates
- [ ] Consider SIMD popcount for bulk `remaining` recomputation (optional)

## 12. References

1. Bryce, R.C., Colbourn, C.J. (2007). The density algorithm for pairwise interaction testing. _Softw. Test. Verif. Reliab._, 17(3), 159–182.
2. Bryce, R.C., Colbourn, C.J. (2009). A density-based greedy algorithm for higher strength covering arrays. _Softw. Test. Verif. Reliab._, 19(1), 37–53.
3. Kleine, K., Simos, D.E. (2018). An efficient design and implementation of the in-parameter-order algorithm. _Math. Comput. Sci._, 12(1), 51–67.
4. Colbourn, C.J. (2014). Conditional expectation algorithms for covering arrays. _J. Combin. Math. Combin. Comput._, 90, 97–115.
5. Lei, Y., Kacker, R., Kuhn, D.R., Okun, V., Lawrence, J. (2007). IPOG: a general strategy for t-way software testing. _Proc. 14th Annual IEEE ECBS_, 549–556.
6. Colbourn, C.J. (2024). Efficient greedy algorithms with accuracy guarantees for combinatorial restrictions. _SN Comput. Sci._, 5(1), 21.
