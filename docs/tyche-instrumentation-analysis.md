# OpenPBTStats / Tyche Instrumentation Analysis

## What is OpenPBTStats?

A JSON Lines format (one JSON object per line) where each line describes one generated test example. Required fields: `line_type`, `run_start`, `property`, `status` ("passed"/"failed"/"discarded"), `representation`. Optional: `features` (numerical/categorical for distribution charts), `coverage`, `timing`.

Tyche (a React webapp / VSCode extension) consumes this `.jsonl` file and renders: sample breakdowns (unique/duplicate/invalid), feature distribution charts, code coverage plots, timing breakdowns, and drill-down example views.

## Execution Paths to Instrument

Exhaust has **three execution paths** that generate per-example data. All three need instrumentation points.

### Path 1: Random Sampling — `__exhaust()` main loop

**File**: `Sources/Exhaust/Macros/MacroSupport.swift`, lines 229–314

```
while let (next, tree) = try generator.next() {     // ← generation
    iterations += 1
    let passed = property(next)                       // ← evaluation
    if passed == false { ... reduction ... }
}
```

**Data available per iteration:**
| Field | Source | Cost |
|-------|--------|------|
| `status` | `property(next)` return value | Free (already computed) |
| `representation` | `customDump(next)` | Moderate — must serialize the value. Already used in PropertyTestFailure.swift |
| `features` (auto) | Walk `tree: ChoiceTree` — see Feature Extraction below | Cheap (O(tree nodes), typically 5–30) |
| `features` (classify) | `GenerationContext.classifications` inside `ValueAndChoiceTreeInterpreter` | Needs accessor — not currently exposed from `.next()` |
| `timing.generate` | Wrap `generator.next()` in `ContinuousClock` | Trivial |
| `timing.execute` | Wrap `property(next)` in `ContinuousClock` | Trivial |
| `property` name | Not currently passed to `__exhaust()` — needs new parameter or settings case |
| `run_start` | `Date().timeIntervalSince1970` before loop | Trivial |

**Instrumentation point**: After `let passed = property(next)` on line 231, before the failure handling block. This is where all data is simultaneously available: the value, the tree, and the pass/fail status.

### Path 2: Coverage Phase — `CoverageRunner.run()`

**File**: `Sources/Exhaust/Macros/CoverageRunner.swift`

Per-example data is **not exposed** — the runner returns an aggregate result enum (`.failure`, `.exhaustive`, `.partial`, `.notApplicable`). Individual `property(value)` calls happen inside `runFinite`/`runBoundary` private methods.

**Data available per iteration:**
| Field | Source | Notes |
|-------|--------|-------|
| `status` | `property(value)` return | Available inside runFinite/runBoundary |
| `representation` | `customDump(value)` | Value is available |
| `tree` | Built by `CoveringArrayReplay.buildTree()` / `BoundaryCoveringArrayReplay.buildTree()` | Available, but coverage trees lack unselected branches (noted in comment on line 92–93 of MacroSupport.swift) |
| `features` | Walk the tree | Tree shape is simpler (no materialized picks) but TypeTag/sequence/branch info is present |

**Instrumentation point**: Add an `onExample` callback parameter to `run()`, threaded through to `runFinite`/`runBoundary`. Called after each `property(value)` evaluation. The closure would be provided by `__exhaust()`.

### Path 3: Exploration — `ExploreRunner.run()`

**File**: `Sources/ExhaustCore/Exploration/ExploreRunner.swift`

Two sub-phases: initial generation (fresh random values) and hill-climbing (mutated seeds). Per-example data stays internal to the runner.

**Instrumentation point**: Add `onExample` closure to `ExploreRunner.init()`, called per-example during both initial generation and hill-climbing. Wired by `__explore()` in MacroSupport.swift.

### Path 4: Contract SCA Phase — `ContractRunner`

**File**: `Sources/Exhaust/Contract/ContractRunner.swift`

Has its own SCA coverage phase before delegating to `__exhaust()` for random sampling. The random phase gets instrumentation for free via Path 1.

**Instrumentation point**: Same `onExample` callback pattern as CoverageRunner for the SCA-specific loop.

## Feature Extraction from ChoiceTree

This is the key advantage over Hypothesis. The ChoiceTree captures every generation decision as inspectable data. A tree walk can auto-derive features without user annotation.

**Existing infrastructure**: `ChoiceTreeWalker` in `Sources/ExhaustCore/Extensions/ChoiceTree+Walk.swift` — depth-first iterator yielding `(Fingerprint, ChoiceTree)` pairs.

**Extractable features by node type:**

| Node | Feature Type | Example Key | Example Value |
|------|-------------|-------------|---------------|
| `.choice(value, metadata)` | Numeric | `"int_0"`, `"double_1"` | Semantic value from `ChoiceValue` + `TypeTag` |
| `.sequence(length, elements, _)` | Numeric | `"seq_0_length"` | `length` as Double |
| `.branch(siteID, _, id, branchIDs, _)` | Categorical | `"pick_<siteID>"` | Branch id as String |
| `.just(description)` | Skip | — | Deterministic, no variance |
| `.getSize(value)` | Possibly numeric | `"size"` | The size parameter value |
| `.resize(newSize, _)` | Skip | — | Structural, not data-bearing |
| `.group([children])` | Skip | — | Just grouping |
| `.selected(child)` | Skip | — | Wrapper for reflection |

**TypeTag → semantic value reconstruction**: `TypeTag.makeConvertible(bitPattern64:)` in `Sources/ExhaustCore/Core/Types/TypeTag.swift` converts raw `UInt64` bit patterns back to typed values (`Int`, `Double`, `Float`, `Date` step index, etc.). This means features carry actual semantic values, not raw bits.

**Date features**: `TypeTag.date(lowerSeconds:, intervalSeconds:, timeZoneID:)` encodes enough info to reconstruct the actual `Date` value as a feature — potentially more useful than a raw step index.

## Discard Tracking

Discards happen inside generators via `filter` and `unique` combinators, before values reach the property. These are handled by CGS (Choice Gradient Sampling) which tunes generation to avoid filtered-out values.

Existing mechanisms that could report discards:
- `filter`/`unique` operations in the Freer monad track rejection counts internally
- `GenerationContext` could be extended to accumulate discard counts per-run
- The `sparse_validity_condition` and `uniqueness_budget_exhausted` log events already detect excessive discards

For OpenPBTStats, discards would need a per-example `"discarded"` status line. Since discarded values don't reach the property loop, they'd need to be emitted from within the generation interpreter — a deeper instrumentation point than the other paths.

## Classify Integration

`Gen.classify()` (in `Sources/ExhaustCore/Core/Combinators/Gen+Classify.swift`) wraps a generator with labeled predicates. Classifications are tracked in `GenerationContext.classifications: [UInt64: [String: Set<UInt64>]]` (fingerprint → label → set of run indices).

**Current gap**: `ValueAndChoiceTreeInterpreter.next()` returns `(Output, ChoiceTree)` — classifications stay internal. To expose them, add an accessor like `currentClassifications: [String: Bool]` that checks which labels matched the most recent run index.

These would become categorical features: `"classify_small": true`, `"classify_even": false`.

## Representation Strategy

`customDump(value, to: &string)` (from the CustomDump package, already a dependency) is the single representation mechanism. It's used in `PropertyTestFailure.swift` for counterexample display.

**Cost concern**: For large/deep values, `customDump` can be expensive. Options:
- Truncate to N characters (Tyche's example view handles truncated strings)
- Make representation opt-out via a setting
- Lazy evaluation — only compute when observer is active

## Logging Infrastructure Gap

`ExhaustLog` (`Sources/ExhaustCore/Logging/ExhaustLog.swift`) is **output-only** — it renders to `OSLog` with no observer/callback/sink mechanism. There's no way to programmatically intercept log events.

An observer protocol would be a new abstraction, separate from ExhaustLog. It lives at the `__exhaust()` call-site level (not deep in interpreters), receiving structured data rather than rendered strings.

## Summary: Instrumentation Surface Area

| Component | File | What to Add | Invasiveness |
|-----------|------|-------------|-------------|
| Random loop | `MacroSupport.swift:229-314` | Observer calls after property eval | Low — 10 lines |
| CoverageRunner | `CoverageRunner.swift` | `onExample` callback param | Low — threading a closure |
| ExploreRunner | `ExploreRunner.swift` | `onExample` callback param | Low — threading a closure |
| ContractRunner SCA | `ContractRunner.swift` | `onExample` callback param | Low — threading a closure |
| Feature extraction | New file | `ChoiceTree` walker → `[String: FeatureValue]` | None — additive |
| Classify exposure | `ValueAndChoiceTreeInterpreter` | Accessor for current classifications | Low — property accessor |
| Discard counting | `ValueInterpreter` / CGS internals | Accumulate filter/unique rejections | Medium — deeper in interpreter stack |
| Settings | `ExhaustSettings.swift` | New `.openPBTStats` case | Low — enum case |
| Property name | Macro expansion | Derive from `@Test` function context | Low — macro change |

**Total: ~6 files modified, 1–2 new files, no architectural changes.**
