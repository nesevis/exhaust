# Fibred Sequence Covering Array

The current boundary-domain covering array construction passes `sequenceLength`, `sequenceElement(0)`, and `sequenceElement(1)` to IPOG as three independent parameters. They are not independent. `sequenceElement(1)` only exists when `sequenceLength = 2`, and `sequenceElement(0)` only exists when `sequenceLength ≥ 1`. The three length values serve distinct purposes: 0 to verify empty-array handling, 1 to test single-element boundary values, 2 to test whether extreme values interact badly. This document describes why the current construction fails to deliver on the third purpose, and what the correct construction looks like.

---

## 1. The Problem in Concrete Terms

Consider `.int(in: 1...100).array(length: 0...5)`. The analysis extracts five boundary values for the element type — `{1, 2, 50, 99, 100}` — and three length values `{0, 1, 2}`, giving k=5 boundary values per element parameter.

**What IPOG does.** It runs over three parameters (length×3, elem0×5, elem1×5) at t=2. The seed phase enumerates all 15 `(length, elem0)` combinations. Horizontal growth assigns one `elem1` value to each seed row to maximise new tuple coverage. The five `length=0` rows receive the diagonal pairs `(elem0=i, elem1=i)`; the five `length=1` rows receive the off-diagonal pairs `(elem0=i, elem1=i+1 mod 5)`. All ten of these pairs are claimed covered, but both length values produce fewer array elements than required to exercise them — they are infeasible claims. The five `length=2` rows each pick up one genuinely new pair. Vertical growth then adds 11 rows for the remaining 20 uncovered `(elem0, elem1)` pairs. These rows have no length assignment and finalize with the default `length=0`. Total: **26 rows. Of these, only 5 rows have `length=2` and actually exercise an element-pair interaction.** The other 20 pairs are claimed covered but never tested.

The pattern holds for any k: horizontal growth covers k diagonal pairs via `length=0` rows and k off-diagonal pairs via `length=1` rows, and vertical growth adds k²−3k rows that all finalize to `length=0`. Total ≈ k² rows, of which k actually test element interactions at length=2.

---

## 2. The Fibred Structure

The dependency between `sequenceLength` and `sequenceElement` is an instance of the same Grothendieck fibration structure described in `bonsai-fibred-minimisation.md`. The **base** is the length value. The **fibre above a base point** is the set of element parameters accessible at that length:

- Fibre above `length=0`: empty — no element parameters exist.
- Fibre above `length=1`: parameters from element 0's subtree.
- Fibre above `length=2`: parameters from element 0's subtree and element 1's subtree.

A covering array row is a section of this fibration — a consistent assignment of values at every accessible parameter. For a section to be sound, the element values it specifies must live in the fibre above its length value. The current flat IPOG construction generates unsound sections because it treats a non-trivial fibration as a trivial product. The correct construction partitions rows by base point and covers each fibre independently.

---

## 3. The Fibred Construction

Build three sub-arrays, one per accessible length value, and concatenate them. Each sub-array uses the **same parameter list** as the original `BoundaryDomainProfile` — in the same tree-walk order — with one modification: the `sequenceLength` parameter's `values` array is replaced with a single-element array `[targetLength]`. No parameters are reordered or regrouped. The `substituteParameters` template walk expects parameters at `paramIndex` to match the tree node it is currently visiting; any reordering would misalign the cursor. `buildFibred` partitions rows, not parameters.

The sub-array profiles differ only in which element parameters exist. `substituteParameters` stops iterating the sequence's element subtrees at `min(newLength, elements.count)` — see Section 6. Parameters for element slots beyond `newLength` are absent from the sub-array's profile and are never consumed.

**Sub-array 1 — length=0** (omit if 0 ∉ lengthRange)

Profile: original parameters with `sequenceLength.values = [0]` and element 0 and element 1 parameters removed. IPOG runs over non-sequence parameters only (or a single row if none).

```
row: { nonSeq_idx=..., length_idx=0 }    →  generates []
```

**Sub-array 2 — length=1** (omit if 1 ∉ lengthRange)

Profile: original parameters with `sequenceLength.values = [1]` and element 1 parameters removed. Element 0 parameters remain. IPOG runs over non-sequence parameters × element 0 parameters.

```
rows: { nonSeq_idx=..., length_idx=0, elem0_idx=... }    →  generates [b]
```

**Sub-array 3 — length=2** (omit if lengthRange.upperBound < 2 or elem1 not extracted)

Profile: original parameters with `sequenceLength.values = [2]`. All element parameters remain. IPOG runs over non-sequence parameters × element 0 parameters × element 1 parameters at t=2.

When each element contributes exactly one boundary parameter, this is exhaustive over (elem0, elem1): k² rows. When `walkElementTree` extracts multiple parameters per element (for example, a `chooseBits` and a `pick` grouped inside an element), IPOG at t=2 over those parameters is not exhaustive but still provides pairwise coverage of all accessible element parameters at length=2.

```
rows: { nonSeq_idx=..., length_idx=0, elem0_idx=..., elem1_idx=... }    →  generates [b_i, b_j]
```

**Why the single-value length parameter is kept in the profile.** `substituteParameters` consumes the length parameter at `paramIndex` when it reaches the `.sequence` node in the template tree. If the length parameter were absent from the profile, `paramIndex` would not advance and the next parameter consumed would be misaligned with the node the walk visits next. The IPOG cost of a domain-1 parameter is nil — it multiplies the seed size by 1.

**Scope.** This construction handles profiles with exactly one `sequenceLength` parameter. If `walkTree` encounters two independent `.sequence` siblings (for example, a tuple of two arrays), the profile contains two `sequenceLength` parameters. The fibred construction is not defined for this case; the profile falls back to the existing flat IPOG path. The generalisation would require a Cartesian product of sub-arrays — one per combination of `(length₁, length₂)` — which is out of scope here.

Non-sequence parameters appear in all three sub-array profiles in their original tree-walk positions. Every `(nonSeqParam=v, elem_j=b)` pair is tested at the correct length. The cost is that non-sequence parameter interactions are exercised separately at each length value rather than once; see Section 4.

---

## 4. Row Counts: Pure-Sequence Generators

The table applies to generators whose only parameters are `sequenceLength` and `sequenceElement`. k is the number of boundary values per element, assuming each element contributes a single parameter.

| Element type                  | k   | Sub-arrays (0 + 1 + 2)  | Total | Current IPOG | Δ    | Pairs tested at length=2    |
|-------------------------------|-----|--------------------------|-------|--------------|------|-----------------------------|
| Integer, positive range       | 5   | 1 + 5 + 25               | 31    | ~26          | +5   | All 25 of 25                |
| Integer, range contains zero  | 6   | 1 + 6 + 36               | 43    | ~36          | +7   | All 36 of 36                |
| Full-range Double             | 11  | 1 + 11 + 121             | 133   | ~121         | +12  | All 121 of 121              |
| Date, no DST in range         | ~8  | 1 + 8 + 64               | 73    | ~64          | +9   | All 64 of 64                |
| Date, 1–2 DST transitions     | ~15 | 1 + 15 + 225             | 241   | ~225         | +16  | All 225 of 225              |
| Date, many DST transitions    | ~25 | 1 + 25 + 625             | 651   | ~625         | +26  | All 625 of 625              |

The delta is always k+1. The current construction already costs approximately k² rows; the fibred construction costs k²+k+1.

**Budget ceiling for pure-sequence generators.** With a 2000-row budget the construction fits up to k≈43. Date generators rarely exceed ~30 boundary values.

**Mixed generators (non-sequence parameters alongside the array).** With m non-sequence parameters, each sub-array runs IPOG at t=2 over its accessible element parameters plus all m non-sequence parameters. Sub-array 3 is IPOG over (element 0 params + element 1 params + non-sequence params) at t=2, which may be substantially larger than k². The budget ceiling above does not apply; budget fitness must be checked against the actual IPOG output for each sub-array.

**Corner cases.**

- `lengthRange` excludes 0: sub-array 1 omitted. Total = k + k².
- `lengthRange` excludes 0 and 1: total = k² rows only.
- Max length is 1 (no elem1 extracted): sub-array 3 omitted. Total = 1 + k rows.
- Two independent sequences: falls back to flat IPOG (see Section 3, Scope).

---

## 5. Soundness Guarantees

**Claim.** Every row in the fibred covering array generates a value for which all parameter values in that row are exercised by the generator. No coverage claim is made for a parameter combination that is structurally inaccessible at the specified length.

**Argument.** Sub-array 1 rows produce empty arrays; no element parameters appear in their profiles. Sub-array 2 rows produce single-element arrays; only element 0 parameters appear and are generated. Sub-array 3 rows produce two-element arrays; element 0 and element 1 parameters both appear and are generated. In every case the profile's parameter count matches exactly the parameters consumed by the template walk, because each sub-array profile removes element parameters beyond `newLength`.

**Coverage strength.** Sub-array 3 provides pairwise coverage of all element parameters and non-sequence parameters within the length=2 fibre. This is not the same guarantee as flat IPOG strength=2 (every 2-tuple across all parameters including length). Within each fibre every required pair is covered; cross-fibre pairs are not claimed. The `CoverageKind.fibredBoundaryValue` case carries this distinction for log events and result reporting.

**What this does not cover.** Generators with sequence parameters inside a bind's bound subtree are excluded from analysis by `walkTreeValidateOnly`. Generators with multiple independent sequence parameters fall back to flat IPOG. Both limitations are unchanged.

---

## 6. Implementation

### `BoundaryDomainProfile` — new computed property

Add `hasMultipleSequenceLengths: Bool` (counts `.sequenceLength` parameters; true if two or more exist). Used by `bestFitting` to gate the fallback.

### `BoundaryCoveringArrayReplay.swift` — sequence case

**This fix is only safe in the context of fibred sub-array profiles.** `bestFitting` dispatches any profile containing sequence parameters to the fibred construction, so no flat-IPOG profile with sequence parameters reaches `substituteParameters`. The fix is not a general-purpose compatibility shim.

Change the element iteration loop to stop at `newLength`:

```swift
case let .sequence(_, elements, metadata):
    guard paramIndex < profile.parameters.count else { return nil }
    let lengthParam = profile.parameters[paramIndex]
    let lengthValueIndex = row.values[paramIndex]
    paramIndex += 1
    guard Int(lengthValueIndex) < lengthParam.values.count else { return nil }
    let newLength = lengthParam.values[Int(lengthValueIndex)]

    var newElements: [ChoiceTree] = []
    for (i, element) in elements.enumerated() {
        guard UInt64(i) < newLength else { break }
        guard let newElement = substituteParameters(
            in: element, row: row, profile: profile, paramIndex: &paramIndex
        ) else { return nil }
        newElements.append(newElement)
    }
    return .sequence(length: newLength, elements: newElements, metadata)
```

Also remove the `.sequenceLength` and `.sequenceElement` branches from `buildTreeFlat` (lines 131–143). With fibred construction active and `originalTree` always present, those branches are unreachable.

### `CoveringArray.swift` — fibred construction

```swift
static func buildFibred(
    profile: BoundaryDomainProfile,
    sequenceLengthIndex: Int,      // index of the sequenceLength param in profile.parameters
    elem0Range: Range<Int>,        // indices of element 0's params in profile.parameters
    elem1Range: Range<Int>,        // indices of element 1's params (empty range if absent)
    originalTree: ChoiceTree?
) -> [(rows: [CoveringArrayRow], profile: BoundaryDomainProfile)]
```

**Determining `elem0Range` and `elem1Range`.** `buildFibred` does not use `BoundaryParameterKind` to group element parameters — `.finiteChooseBits` and `.pick` produced inside an element subtree carry no element index, only `.sequenceElement(elementIndex:...)` does. Instead, `buildFibred` determines element slot boundaries by counting parameters per element slot using the originalTree. A helper walks each element node from the template sequence tree (using the same dispatch logic as `walkElementTree`) and returns the parameter count for that subtree. Given counts `count₀` and `count₁`:

```
sequenceLengthIndex: L
elem0Range: (L+1) ..< (L+1+count₀)
elem1Range: (L+1+count₀) ..< (L+1+count₀+count₁)
```

Non-sequence parameters occupy all other indices in the profile. Their positions are unchanged across all three sub-array profiles.

**Building each sub-array profile.** The sub-array profile is the same `parameters` array, with two mutations applied to a copy:
1. Replace `parameters[L].values` with `[targetLength]`.
2. Remove the parameters in the element ranges that are inaccessible at `targetLength` (empty ranges for length=0, remove `elem1Range` for length=1, remove neither for length=2).

Because parameters are removed from the end of the sequence group (element 1 first, then element 0 for length=0), the indices of non-sequence parameters that follow the sequence in tree-walk order shift downward. The template walk handles this correctly because it indexes into the profile sequentially via `paramIndex`, not by absolute parameter index.

**Integration in `bestFitting`.**

```swift
if let lengthIdx = profile.parameters.indices.first(where: {
       if case .sequenceLength = profile.parameters[$0].kind { return true }
       return false
   }),
   !profile.hasMultipleSequenceLengths
{
    let (count0, count1) = countElementParams(in: originalTree, from: lengthIdx)
    let subArrays = buildFibred(
        profile: profile,
        sequenceLengthIndex: lengthIdx,
        elem0Range: (lengthIdx+1) ..< (lengthIdx+1+count0),
        elem1Range: (lengthIdx+1+count0) ..< (lengthIdx+1+count0+count1),
        originalTree: profile.originalTree
    )
    ...
}
```

### `CoverageRunner.swift` — replay and reporting

```swift
for subArray in covering.subArrays {
    for (rowIndex, row) in subArray.rows.enumerated() {
        guard let tree = BoundaryCoveringArrayReplay.buildTree(
            row: row, profile: subArray.profile
        ) else { continue }
        // ... rest unchanged
    }
}
```

Add `.fibredBoundaryValue` to `CoverageKind`. The integer `strength` in `.partial` and `.failure` results is reported as 2 when sub-array 3 is present; `.fibredBoundaryValue` carries the distinction for any consumer that needs to know it means "pairwise within each fibre" rather than "pairwise across all parameters."

---

## 7. Files Modified

| File | Change |
|---|---|
| `Sources/ExhaustCore/Analysis/BoundaryDomainAnalysis.swift` | Add `hasMultipleSequenceLengths` computed property to `BoundaryDomainProfile` |
| `Sources/ExhaustCore/Analysis/BoundaryCoveringArrayReplay.swift` | Fix sequence case in `substituteParameters` to stop at `newLength`; delete `.sequenceLength`/`.sequenceElement` branches from `buildTreeFlat` |
| `Sources/ExhaustCore/Analysis/CoveringArray.swift` | Add `buildFibred(...)` and `countElementParams(in:from:)`; update `bestFitting(budget:boundaryProfile:)` to dispatch to fibred path |
| `Sources/Exhaust/Macros/CoverageRunner.swift` | Update `runBoundary` to iterate `[(rows, profile)]`; add `.fibredBoundaryValue` to `CoverageKind` |

---

## 8. Verification

**Template substitution stop.** Construct a fibred sub-array 1 profile (length=0, no element parameters) with an `originalTree` that has two element nodes. Call `BoundaryCoveringArrayReplay.buildTree` with a single-value row. Assert the result is `.sequence(length: 0, elements: [])` and `paramIndex` equals `profile.parameters.count` on return.

**Row count: pure-sequence generators.**
- `#gen(.int(in: 1...100).array(length: 0...5))` → 1 + 5 + 25 = 31 rows; no row with `length=0` has element parameter values.
- `#gen(.int(in: -50...50).array(length: 0...5))` → k=6 → 1 + 6 + 36 = 43 rows.
- `#gen(.double.array(length: 1...5))` → no length=0 sub-array → 11 + 121 = 132 rows.

**Pairwise pair coverage.** For a k=5 generator: extract all rows with `length=2`; assert the set of `(elem0_valueIndex, elem1_valueIndex)` pairs equals {0..4}×{0..4}.

**Mixed generator: non-sequence params present in all sub-arrays.** For `#gen(Gen.zip(.double, .int(in: 1...10).array(length: 0...3)))`: assert the `Double` boundary values appear in sub-arrays for all three length values, and that no row with `length=0` carries element parameter values.

**Integration: property failing only on element interaction.**
```swift
#exhaust { (arr: [Int]) in
    arr.count < 2 || !(arr[0] == 100 && arr[1] == 1)
}
```
The fibred array must find `[100, 1]` during the coverage phase. Current flat IPOG finds this pair in a `length=2` row only by chance.

**Multiple-sequence fallback.** A tuple generator `(Int, [Int], [String])` has two array parameters and produces a profile with two `sequenceLength` parameters. Assert `hasMultipleSequenceLengths` is true and `bestFitting` uses the flat IPOG path.

**Parameter ordering: mixed generator with sequence first.** For `.sequence(...), .choice(intParam)` (sequence precedes non-sequence in tree), assert the sub-array 2 profile has the non-sequence parameter at the correct index (after the sequence group), and that replaying a row for that profile produces the correct int value — confirming that `paramIndex` alignment is preserved across the split.
