# Transform Reification — Next Steps

## Completed Work

### Phase 1: Transform Reification

PR `feature/reflective-op-transform` reifies forward-only `map` and `bind` as a visible `ReflectiveOperation.transform(kind:inner:)` case. Previously these operations were invisible — buried in the FreerMonad continuation chain.

1. **New operation**: `case transform(kind: TransformKind, inner: ReflectiveGenerator<Any>)` in `ReflectiveOperation`. `TransformKind` carries the forward function plus captured `inputType`/`outputType` strings for diagnostics.

2. **Critical invariant**: `mapped(forward:backward:)` uses `_map` (invisible continuation) — it must NOT reify, because the `contramap` already handles the backward path. Only the user-facing `.map()` and `.bind()` reify.

3. **~16 interpreter switch sites** updated: generation, replay, reflection, materialisation, adaptation, coverage analysis helpers, debug description.

4. **Replay scoping for bind**: VACTI produces `.group([innerTree, boundTree])` for bind. Both `replayWithChoices` and `replayRecursive` now scope inner and bound to their respective subtrees, preventing the zip lane-splitting heuristic from cross-contaminating them.

5. **`#examine` diagnostics**: `ValidationFailure.forwardOnlyTransform` reports the transform type and an actionable message. Detection halts further reflection attempts but continues generation and determinism checks — forward-only transforms only block reflection (shrinking), not the rest of `#examine`'s value.

6. **`_validate` round-trip flow**: When reflection returns nil, the VACTI-generated tree is used as fallback for replay, and the determinism check always runs regardless of reflection outcome.

### Phase 2: Bidirectional Bind (`bound`)

Added `bound(forward:backward:)` — the bind-level analogue of `mapped(forward:backward:)`. Implements the `comap` annotation at bind sites from partial monadic profunctors (Xia et al., "Composing Bidirectional Programs Monadically", ESOP 2019).

1. **`TransformKind.bind` gains optional `backward`**: Forward-only `.bind()` passes `backward: nil`; `bound(forward:backward:)` passes the user's extraction function. No new `ReflectiveOperation` cases — the existing `.transform(.bind)` carries both.

2. **`_bound` / `bound` split**: Internal `_bound` (no `@Sendable`) in `ReflectiveGenerator+InternalCombinators.swift`; public `bound` (with `@Sendable`) delegates to it. Mirrors the `_mapped` / `mapped` pattern.

3. **`PartialPath` overload**: `bound(forward:, backward: some PartialPath<NewValue, Value>)` wraps the path extraction in a closure and delegates to `_bound`.

4. **Reflection**: `backward(finalOutput)` extracts the inner value; `forward(innerValue)` reconstructs the bound generator; both are reflected independently; paths are combined as `.group(innerPath + boundPath)`.

5. **Debug description**: Distinguishes `bind↔` (bidirectional) from `bind→` (forward-only).

### Files changed (both phases)

| File | Change |
|------|--------|
| `ReflectiveOperation.swift` | Added `.transform` case + `TransformKind` enum; optional `backward` on `.bind` |
| `ReflectiveGenerator+Combinators.swift` | `map()` / `bind()` reify; `mapped` uses `_map`; `bound(forward:backward:)` + `PartialPath` overload |
| `ReflectiveGenerator+InternalCombinators.swift` | `_bound(forward:backward:)` — internal version without `@Sendable` |
| `ReflectiveGenerator+Strings.swift` | Internal `.map` → `._map` |
| `MirrorCombinators.swift` | Internal `.map` → `._map` (except `_macroMapScalar` fallback — intentionally forward-only) |
| `ValueInterpreter.swift` | `.transform` case: interpret inner, apply forward |
| `ValueAndChoiceTreeInterpreter.swift` | `.transform` case: bind produces `.group([innerTree, boundTree])` |
| `OnlineCGSInterpreter.swift` | `.transform` case with CGS parameter threading |
| `LightweightSampler.swift` | `.transform` case inline |
| `Reflect.swift` | Bidirectional bind reflection; throws `.forwardOnlyMap` / `.forwardOnlyBind` |
| `Replay.swift` (×2 paths) | Scoped bind replay: inner gets first subtree, bound gets second |
| `Materialize.swift` (×2 paths) | Interpret inner, apply forward |
| `PrefixMaterializer.swift` | Interpret inner, apply forward; bind dual tree shape |
| `ChoiceGradientTuner.swift` (×2) | Recurse into inner generator |
| `GeneratorTuning.swift` (×4) | Recurse into inner generator |
| `CoveringArrayReplay.swift` | `buildSubTree`: recurse into inner |
| `BoundaryCoveringArrayReplay.swift` | `buildSubTree`: recurse into inner |
| `SequenceCoveringArray.swift` | `isParameterFree`: recurse into inner |
| `ReflectiveGenerator+CustomDebugStringConvertible.swift` | `bind↔` / `bind→` format |
| `ReflectiveGenerator+Validation.swift` | `forwardOnlyTransform` failure case; `forwardOnlyDetected` flag |
| `CompositionTests.swift` | `BoundTests` suite (4 tests); fixed `mapped(forward:backward:)` test |
| `UUIDGeneratorTests.swift` | `withKnownIssue` for forward-only bind `#examine` |

---

## Architectural Boundary: What `bound` Does Not Solve

### The `getSize()._bind` pattern is fundamentally non-invertible

The most common internal bind pattern is `getSize()._bind { size in ... }`, used by:

- `Gen.arrayOf` default length: `Gen.getSize()._bind { Gen.chooseDerived(in: ($0 / 10) ... $0) }`
- `Gen.sized`: `getSize()._bind { size in arrayOf(elementGenerator, chooseDerived(in: finalRange)) }`
- `Gen.slice(of:)`: `getSize()._bind { size in ... }`
- `Gen.choose(in:, scaling:)`: `Gen.getSize()._bind { size in chooseDerived(in: scaledRange(...)) }`

These cannot use `_bound` because the backward `(Output) -> UInt64` must recover the size from the generated value, which is lossy. For `chooseDerived(in: (size / 10) ... size)`, a length of 5 could have come from any size in 5...50. For `scaledRange`, the mapping is even more lossy — many sizes produce the same effective range.

The framework was designed to handle this at the **operation level**: `.sequence` derives length directly from the target array during reflection; `.chooseBits` with `isRangeExplicit: false` uses the value's `BitPatternConvertible` range. They sidestep the size → bind → value chain entirely, making `getSize` reflection a non-issue for the operations that use it.

### Instance-level `element()` remains infeasible

An instance method `ReflectiveGenerator<[T]>.element() -> ReflectiveGenerator<T>` would require:

```swift
self.bound(
    forward: { collection in Gen.element(from: collection) },
    backward: { element in [element] }  // reconstruct collection from one element??
)
```

The backward is a projection (N → 1) — genuine information loss. The static `Gen.element(from:)` works because the collection is a **constant** known at construction time, so `contramap` only needs to find the element's index. An instance version would need to recover the collection from a single element, which is impossible.

---

## Opportunity 1: Partial Reflection for Invertible Maps

### Problem

Today, `.map(f)` blocks reflection entirely. But many maps are trivially invertible — the user just didn't write `mapped(forward:backward:)`. Common patterns:

- Numeric conversions: `{ Double($0) }`, `{ Int($0) }`, `{ UInt32($0) }`
- Identity-like: `{ $0 }`, `{ String($0) }`
- Self-inverse: `{ $0.reversed() }`, `{ -$0 }`
- Arithmetic: `{ $0 * 2 }` ↔ `{ $0 / 2 }`

The `_macroMapScalar` overloads already handle numeric conversions at compile time via protocol-constrained overload resolution:

```swift
// BinaryInteger → BinaryInteger: backward = { Input($0) }
static func _macroMapScalar<Input: BinaryInteger, Output: BinaryInteger>(...)

// BinaryFloatingPoint → BinaryFloatingPoint: backward = { Input($0) }
static func _macroMapScalar<Input: BinaryFloatingPoint, Output: BinaryFloatingPoint>(...)

// Fallback: forward-only .map()
static func _macroMapScalar<Input, Output>(...)
```

But these only work when the `#gen` macro is used. Direct `.map()` calls have no backward function.

### Design: Runtime Heuristic Inversion

At the `.transform(.map)` case in `Reflect.swift`, attempt inversion before throwing:

```swift
case let .transform(kind, inner):
    switch kind {
    case let .map(forward, inputType, outputType):
        // 1. Try heuristic inversion
        if let inverter = HeuristicInverter.inverter(
            inputType: inputType, outputType: outputType
        ) {
            let inverted = try inverter(finalOutput)
            // Validate: forward(inverted) should ≈ finalOutput
            let roundTripped = try forward(inverted)
            if areEquivalent(roundTripped, finalOutput) {
                // Success — reflect through inner with inverted value
                return try reflectRecursive(inner, onFinalOutput: inverted)
            }
        }
        // 2. Fallback: throw with diagnostic
        throw ReflectionError.forwardOnlyMap(inputType: inputType, outputType: outputType)
    case let .bind(forward, backward, inputType, outputType):
        // ... existing bidirectional/forward-only handling ...
    }
```

#### `HeuristicInverter`

```swift
enum HeuristicInverter {
    /// Returns an inversion function if we can heuristically invert based on type names.
    static func inverter(inputType: String, outputType: String) -> ((Any) throws -> Any)? {
        // Same type → identity
        if inputType == outputType { return { $0 } }

        // Both integer types → init conversion
        if isIntegerType(inputType), isIntegerType(outputType) {
            return numericInverter(from: outputType, to: inputType)
        }

        // Both floating-point types → init conversion
        if isFloatType(inputType), isFloatType(outputType) {
            return numericInverter(from: outputType, to: inputType)
        }

        return nil
    }
}
```

#### Validation is essential

The round-trip check (`forward(inverted) ≈ finalOutput`) guards against lossy conversions. For example, `Double(Int.max)` loses precision — the inverted `Int(thatDouble)` won't match the original. The reflector should reject lossy inversions and fall through to the error.

#### Scope

- **Map only**, not bind. Bind inversion requires inverting the generator-producing function, which is fundamentally harder.
- **Type-name matching** for known numeric types. No runtime protocol conformance checks needed — the type names are already captured.
- **Validation-gated**: every heuristic inversion is verified via round-trip. False positives are impossible.

### Impact

- Users who write `#gen(.int(in: 0...100)).map { Double($0) }` get automatic reflectivity — no need to rewrite as `mapped(forward:backward:)`.
- `#examine` reports pass instead of failure for trivially invertible maps.
- Shrinking works through invertible maps — the reducer can reflect counterexamples back to their choice sequences.

---

## Opportunity 2: Bind-Aware Shrinking

### Problem

The reducer operates on `ChoiceSequence` — the flattened representation of the `ChoiceTree`. It has 14 shrink passes that operate on positional spans. None of them understand bind dependencies.

When a generator uses `.bind` or `.bound`, the bound subtree's choices depend on the inner value. Changing inner choices without regenerating the bound subtree produces invalid combinations. Today, the reducer discovers this empirically: it mutates, replays, and rejects failures. This wastes shrink budget on doomed attempts.

With `bound(forward:backward:)` now available, users can write dependent generators that are fully reflectable — but the reducer still treats their choice sequences as flat, independent entries. The backward function is used during reflection to extract the initial choice recipe, but the reducer's shrink passes don't know that mutating inner choices invalidates bound choices.

### Current Architecture

VACTI produces `.group([innerTree, boundTree])` for bind — indistinguishable from any other nested group (e.g. a zip with two components):

```
ChoiceTree:
  group                          ← could be bind or zip or anything
  ├── group (inner)
  │   ├── choice (inner₁)
  │   └── choice (inner₂)
  └── group (bound)
      ├── choice (bound₁)
      └── choice (bound₂)
```

`ChoiceSequence.flatten` produces:

```
( ( V V ) ( V V ) )             ← no way to distinguish bind from group
```

The reducer doesn't know where the dependency boundary is. A pass like `reduceValues` might binary-search `inner₂` while leaving `bound₁` unchanged — but `bound₁`'s valid range depends on the value of `inner₂`.

### Design: Structural Bind Markers

#### ChoiceTree: New `bind` Case

Add a dedicated case to `ChoiceTree` with named children:

```swift
public enum ChoiceTree: Hashable, Equatable, Sendable {
    // ... existing cases ...

    /// A bind node capturing the dependency between an inner generator and a
    /// bound generator whose structure depends on the inner value.
    indirect case bind(inner: ChoiceTree, bound: ChoiceTree)
}
```

VACTI's `.transform(.bind)` handler produces `.bind(inner:bound:)` instead of `.group([innerTree, boundTree])`. The two subtrees are named, making the dependency explicit in the tree structure.

**Debug description:**

```
└── bind
    ├── inner
    │   └── choice(signed: 3) 1...10
    └── bound
        └── sequence(length: 3) 0...5
```

**Switch-site updates** (~12 sites): `map(_:)`, `contains(_:)`, `containsPicks`, `pickComplexity`, `debugDescription`, `elementDescription`, `unwrapped`, `relaxingNonExplicitSequenceLengthRanges`. In most cases `bind` behaves like a two-child `group` — recurse into both `inner` and `bound`.

**Map (`.transform(.map)`)** does not need a ChoiceTree case. Map is transparent — the inner generator's choices appear directly in the tree with no structural change.

#### ChoiceSequenceValue: New `bind` Marker

Add a balanced open/close marker, parallel to `.group(Bool)` and `.sequence(Bool, ...)`:

```swift
public enum ChoiceSequenceValue: Hashable, Equatable, Sendable {
    // ... existing cases ...

    /// Bind scope markers (true = open, false = close).
    /// The first child group is the inner subtree; the second is the bound subtree.
    case bind(Bool)
}
```

**`shortString`:** `{` (open) / `}` (close) — the only standard bracket pair not already taken (`()` for group, `[]` for sequence).

**Flatten** emits `.bind(true)`, inner subtree, bound subtree, `.bind(false)`:

```
{ ( V V ) ( V V ) }             ← bind scope wraps two child groups
```

**Depth-tracking** treats `.bind(true/false)` like `.group(true/false)` for nesting purposes. Existing code that counts balanced brackets (e.g. `countTopLevelElements`, `extractContainerSpans`) adds `.bind` alongside `.group` in open/close handling.

**`extractContainerSpans()`** emits a new `ChoiceSpan.Kind.bind` for bind-scoped spans, allowing reducer passes to identify and special-case them.

#### Reducer: Phased Integration

**Phase 1: Annotation only.** Add the ChoiceTree case, ChoiceSequenceValue marker, and flatten logic. All existing reducer passes treat `.bind` like `.group` — no behavioral change, but the structural information is preserved.

**Phase 2: Bind-aware tandem reduction** (new pass). Analogous to `reduceValuesInTandem`, but bind-dependency aware. When the reducer mutates entries in a bind's inner span, the bound span's entries become stale — they encode choices that were valid for the *original* inner value but are likely invalid for the mutated one. Full materialization then fails, and the mutation is rejected. The budget is wasted.

A bind-aware tandem pass would mutate inner entries and re-derive the bound entries in lockstep:

1. Identify bind spans via `extractContainerSpans()` with `Kind.bind`
2. When reducing values in the inner child span, replace the bound child span with fresh entries (using `PrefixMaterializer` — replay the mutated prefix, then extend for the bound portion)
3. Materialize and test the combined sequence as usual

This turns doomed mutations into productive exploration of the bound generator's space under the new inner value.

**Phase 3: Pass-level awareness.** Modify existing span-based passes to account for bind dependencies:

1. **`reduceValues`**: When reducing a value in the inner span, also replace the bound span with fresh entries before materialization.
2. **`deleteContainerSpans`**: When deleting the inner span, also delete the bound span. A bind without its inner value is meaningless.
3. **`simplifyValuesToSemanticSimplest`**: When zeroing inner values, replace the bound span with fresh entries.
4. **`deleteSequenceElements`**: If a sequence element contains a bind, delete inner + bound together.

### Impact

- Fewer wasted shrink budget cycles on doomed bind mutations
- Faster convergence to minimal counterexamples for bind-heavy generators
- Especially valuable for `Gen.recursive` (which unfolds via bind) and `@Contract` testing (which chains commands via bind)
- With `bound` now available, users can write shrinkable dependent generators — bind-aware shrinking makes this shrinking maximally efficient

### Complexity

This is a significant change to the reducer's architecture. The current span-based design is elegant precisely because it's structure-agnostic. Adding bind awareness requires:

- New ChoiceTree case with ~12 switch-site updates (mechanical, same cascade as `.transform`)
- New ChoiceSequenceValue marker with flatten + depth-tracking updates
- Preserving structural metadata through flattening
- Teaching each pass about dependent spans (Phase 3)
- Careful handling of nested binds (bind within bind)
- Regression testing against the full shrinking challenge suite

Phasing mitigates the risk: Phase 1 is purely additive (no behavioral change), Phase 2 adds a single new pass, and Phase 3 modifies existing passes only after the infrastructure is proven.

---

## Opportunity 3: Coverage Analysis Through Transforms

### Problem

`ChoiceTreeAnalysis` walks the ChoiceTree to extract parameters for covering array construction. Map transforms are invisible in the tree — the inner generator's choices appear directly. But with the new `ChoiceTree.bind(inner:bound:)` case (from Opportunity 2), bind nodes are now structurally visible in the tree, and `walkTree` must handle them.

However, the `.transform` operation at the *generator* level IS already visible when walkers inspect the generator structure directly (e.g., `isParameterFree` in `SequenceCoveringArray.swift`, `buildSubTree` in `CoveringArrayReplay.swift`).

### Current State

- `ChoiceTreeAnalysis.walkTree` sees the ChoiceTree, not the generator. Map transforms are transparent — the inner generator's choices appear directly in the tree.
- `isParameterFree(gen)` recurses into `.transform`'s inner generator — already handles this correctly.
- `buildSubTree(for: gen)` recurses into `.transform`'s inner — already handles this correctly.

### What Changes With `ChoiceTree.bind`

Once `ChoiceTree.bind(inner:bound:)` exists, `walkTree` will encounter bind nodes. The coverage walker needs to decide how to treat them:

- **Option A: Treat as group.** Walk both `inner` and `bound` subtrees, extracting parameters from each. This is the simplest approach and matches how the current `.group` handling works. However, it ignores the dependency — parameters in `bound` are not independent of parameters in `inner`, so covering array construction may generate invalid combinations.

- **Option B: Treat bound subtree as opaque.** Extract parameters only from `inner`; treat `bound` as a single opaque unit (like `isOpaque: true` on group). This avoids invalid cross-product combinations but sacrifices coverage of the bound subtree's parameters.

- **Option C: Dependency-aware parameter extraction.** Extract parameters from both subtrees but annotate that bound parameters depend on inner parameters. This would require extending the covering array model to express dependencies — a significant change.

**Recommendation:** Option B (treat bound as opaque). The bound subtree's parameters are meaningless without the correct inner value, so extracting them into the covering array produces invalid combinations that materialization must reject. More importantly, this massively reduces the parameter count for bound generators — the inner subtree might have 1-2 parameters, but the bound subtree can fan out into many (e.g. a length-dependent array with N element parameters). Treating bound as opaque collapses all of that into a single unit, keeping the covering array's parameter count proportional to what the user actually controls. The bound subtree gets exercised naturally through random generation.

### Additional Enhancement

The `inputType`/`outputType` strings on `TransformKind` could enrich coverage reports:

```
Coverage Profile:
  Parameter 1: chooseBits(Int: 0...100)  →  transform(map: Int → String)
  Parameter 2: chooseBits(UInt64: 0...255)
```

This helps users understand which parameters are being covered and how they relate to the final output type.

---

## Opportunity 4: Macro Synthesis of Backward for Bind

### Problem

The `#gen` macro already synthesizes backward functions for `map` via `_macroMapScalar` overloads. No equivalent exists for `bind`. Users must always write `bound(forward:backward:)` manually, even when the backward is structurally obvious.

### Common Patterns Where Backward is Derivable

```swift
// Pattern 1: Dependent length — backward is .count
#gen(.int(in: 1...10)).bound(
    forward: { n in Gen.arrayOf(.bool(), exactly: UInt64(n)) },
    backward: { arr in arr.count }
)

// Pattern 2: Dependent range — backward is identity
#gen(.int(in: 1...100)).bound(
    forward: { max in #gen(.int(in: 0...max)) },
    backward: { $0 }  // the inner value IS the bound output (same type)
)

// Pattern 3: Dependent construction — backward is a stored property
#gen(.int(in: 1...5)).bound(
    forward: { n in Gen.just(String(repeating: "x", count: n)) },
    backward: { str in str.count }
)
```

### Design Considerations

Unlike map inversion (which can be heuristic because the round-trip is verifiable), bind backward synthesis is harder:

- The forward closure returns a **generator**, not a value — we can't probe it at compile time
- The backward must extract `A` from `B` where `B` is the output of an arbitrary generator parameterised by `A`
- No general compile-time strategy exists; would need pattern-matching on the closure body's AST

A more pragmatic approach: provide **convenience overloads** for the common structural patterns rather than general synthesis:

```swift
// When B: Collection and A is derivable from count
func bound<B: Collection>(
    forward: @escaping (Value) throws -> ReflectiveGenerator<B>,
    backwardCount: @escaping (Int) -> Value
) -> ReflectiveGenerator<B>

// When A == B (dependent constraint on same type)
func bound(
    forward: @escaping (Value) throws -> ReflectiveGenerator<Value>,
    backward: @escaping (Value) -> Value = { $0 }
) -> ReflectiveGenerator<Value>  // only when Value == NewValue
```

### Assessment

Low priority. The manual `bound(forward:backward:)` API is clear and the backward is always a single expression. Convenience overloads add API surface for marginal ergonomic gain. Revisit if user feedback shows `bound` adoption is hampered by backward-writing friction.

---

## Priority Assessment

Opportunities 2 and 3 share a prerequisite: `ChoiceTree.bind(inner:bound:)` and `ChoiceSequenceValue.bind(Bool)`. Phase 1 of Opportunity 2 (annotation only) is also the foundation for Opportunity 3. Both represent genuine structural advances — they make dependency information that was previously invisible available to the reducer and coverage analysis.

| Opportunity | Impact | Complexity | Recommendation |
|-------------|--------|------------|----------------|
| Bind-aware shrinking (Opp 2) | High — stops wasting shrink budget on doomed mutations; enables efficient shrinking through dependent generators | Medium (Phase 1) / High (Phase 2-3) — Phase 1 is additive (~12 switch sites + flatten); later phases touch reducer core | **Do first** — Phase 1 unlocks Opportunity 3 |
| Coverage analysis with bind nodes (Opp 3) | High — collapses bound subtree parameters, keeping covering arrays tractable for dependent generators | Low — once Phase 1 of Opp 2 lands, treat `.bind` as opaque in `walkTree` | **Do alongside Opp 2 Phase 1** |
| Partial reflection for invertible maps (Opp 1) | Medium — convenience for users who forget `mapped(forward:backward:)` | Low — isolated to `Reflect.swift`, validation-gated | Do after Opp 2/3 |
| Macro synthesis of backward for bind (Opp 4) | Low — manual API is clear enough | Medium — AST pattern matching or multiple overloads | **Revisit based on user feedback** |
