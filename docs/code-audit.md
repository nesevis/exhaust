# Exhaust Framework — Code & Architecture Audit

## Executive Summary

Exhaust is a well-architected property-based testing framework built on a genuinely novel foundation: a freer monad that reifies generators as inspectable data, enabling bidirectional (forward generation + backward reflection) and deterministic replay from a single generator definition. The core abstraction is sound and the documentation of complex algorithms is excellent.

**The highest-impact issues are:**

1. **ExhaustCore is exposed as a product despite being intended as internal** — `Package.swift` lists `ExhaustCore` as a `.library` product (line 37-40). When published, consumers can `import ExhaustCore` and depend on 230+ public declarations that are implementation details. Remove the product before publishing.

2. **`element()` silently breaks the bidirectional contract** — The only public combinator that uses reflection-incompatible `bind`. Shrinking won't work through it, with no compiler warning or runtime indication.

3. **Interpreter code duplication is a maintenance liability** — ~15 switch statements over `ReflectiveOperation`'s 13 cases across 11 files. Adding a new operation case requires coordinated changes in all of them, with no compiler-enforced completeness across files.

4. **Force unwraps at type-erasure boundaries** — Several `as!` casts and `!` unwraps have acknowledged FIXMEs. While architecturally motivated, these are crash risks in a published library.

5. **Exploration infrastructure is fully public despite being "beginning phases"** — `ExploreRunner`, `HillClimber`, `DefaultSeedPool`, `NoveltyTracker`, `PowerSchedule`, `LogarithmicSchedule`, `SeedPool` protocol, `ExploreResult`, `HillClimbResult`, `Seed`, `SearchDirective` are all public API that will be hard to evolve.

---

## 1. Public API & Module Boundaries

### What's good
- Clean two-module split: `ExhaustCore` (engine) -> `Exhaust` (consumer-facing wrapper + macros)
- `Reexports.swift` curates the public surface via typealiases
- Macros (`#gen`, `#exhaust`, `#explore`, `#extract`) provide the primary entry points
- `Gen` namespace is correctly positioned as internal plumbing (called by `Exhaust` module, not by consumers)
- `ReflectiveGenerator` static methods + instance combinators provide a fluent, chainable API

### Issues

**1.1 ExhaustCore is listed as a product in Package.swift**

`Package.swift` lines 37-40 define `ExhaustCore` as a `.library` product. This means published consumers can `import ExhaustCore` directly and depend on all 230+ public declarations — types like `ChoiceTree`, `ChoiceSequence`, `ReducerCache`, `FitnessAccumulator`, `GenerationContext`, `Xoshiro256`, etc. Since ExhaustCore is intended to be strictly internal (currently a product only for test coverage inspection), this product must be removed before publishing.

**Recommendation:** Remove the `ExhaustCore` product from `Package.swift` before publishing. If test coverage inspection needs it temporarily, gate it behind an environment variable like the existing `EXHAUST_RELEASE` pattern.

**1.2 `Gen` is public but should be hidden from consumers**

`Gen` is declared `public enum Gen {}` in ExhaustCore with all its static methods public. While intended as internal plumbing that `ReflectiveGenerator` extensions call into, it's currently visible to consumers (via ExhaustCore's public surface). Once ExhaustCore is no longer a product, `Gen` won't be directly importable — but it will still appear in autocompletion and documentation if the `Exhaust` module re-exports it transitively. Verify that removing the ExhaustCore product fully hides `Gen` from consumer autocomplete.

**1.3 `ShrinkBudget` typealias is misleading**

`public typealias ShrinkBudget = Interpreters.ShrinkConfiguration` — the name suggests a numeric budget, but it's actually an enum with two cases (`.fast`, `.slow`). The underlying type name `ShrinkConfiguration` is better.

---

## 2. Architecture & Separation of Concerns

### What's good
- FreerMonad cleanly separates effect description from interpretation
- ReflectiveOperation's 13 cases are well-motivated and documented with forward/backward/replay semantics
- Shared infrastructure exists: `InterpreterWrapperHandlers`, `PickBranchResolution`, `SequenceExecutionKernel`
- Non-copyable `ValueInterpreter` prevents accidental state duplication

### Issues

**2.1 GenerationContext carries too many concerns**

`GenerationContext` (used by ValueInterpreter, ValueAndChoiceTreeInterpreter, OnlineCGSInterpreter) bundles 15+ mutable fields spanning:
- PRNG state (`prng`, `baseSeed`)
- Iteration control (`runs`, `maxRuns`, `isFixed`)
- Size scaling (`size`, `sizeOverride`)
- Deduplication (`uniqueSeenKeys`, `uniqueSeenSequences`)
- Classification (`classificationCounts`)
- CGS state (`filterWeights`, `cgsWeights`)
- Tree construction (`materializePicks`)

This makes it hard to reason about which fields matter for which interpreter. A `ValueInterpreter` doesn't need `materializePicks`; an `OnlineCGSInterpreter` doesn't need `classificationCounts`.

**Recommendation:** Consider grouping fields into nested structs (`PRNGState`, `SizingState`, `DeduplicationState`, etc.) even if they remain on the same type. This documents which concerns travel together.

**2.2 Interpreter duplication is architectural but costly**

The following files all contain independent switch statements dispatching on `ReflectiveOperation`:

| File | Lines | Purpose |
|------|-------|---------|
| `ValueInterpreter.swift` | ~400 | Forward generation |
| `ValueAndChoiceTreeInterpreter.swift` | ~600 | Forward + tree capture |
| `OnlineCGSInterpreter.swift` | ~870 | CGS-guided generation |
| `LightweightSampler.swift` | ~135 | Sampling helper |
| `Reflect.swift` | ~340 | Backward pass |
| `Replay.swift` | ~300+ | Tree-based replay |
| `Materialize.swift` | ~1020 | Sequence-based replay |
| `ChoiceGradientTuner.swift` | ~500+ | Offline CGS tuning |
| `PrefixMaterializer.swift` | ~300+ | Prefix replay |
| `GeneratorTuning.swift` | ~1470 | Weight computation |

Adding a new `ReflectiveOperation` case requires updating **~15 switch sites** across these files. There's no compile-time mechanism to ensure all sites are updated simultaneously — each switch is independently exhaustive within its own file, but nothing links them.

**Recommendation:** This is the hardest problem to solve without sacrificing performance. A protocol-based visitor pattern would add vtable overhead on hot paths. At minimum, consider a `CHANGELOG.md` entry or `ReflectiveOperation.allCases`-style audit helper that CI can verify. Alternatively, a single "interpreter sites" file that lists all locations could serve as a manual checklist.

**2.3 Materialize vs Replay: two replay systems**

`Replay.swift` operates on `ChoiceTree` (hierarchical). `Materialize.swift` operates on `ChoiceSequence` (flattened). Both deterministically recreate values from recorded choices, but with different assumptions about structure. There's no shared interface or documented guidance on when to use which.

**Recommendation:** Document the split clearly. If they're meant for different use cases (shrinking vs. exploration), name them to reflect that.

---

## 3. Coding Conventions & Quality

### What's good
- Consistent use of `ContiguousArray` for performance-critical paths
- `@inline(__always)` on hot interpreter handlers
- `reserveCapacity` used consistently before append loops
- Descriptive type parameter names (`FinalOutput`, `Element`, not `T`)
- `let .case(a, b, c)` pattern matching used correctly throughout

### Issues

**3.1 Force unwraps and force casts**

| Location | Issue |
|----------|-------|
| `ReflectiveGenerator+Combinators.swift:43` | `backward.extract(from: newOutput)!` |
| `ReflectiveGenerator+Combinators.swift:68` | Same pattern with FIXME comment |
| `ReflectiveGenerator+Combinators.swift:91` | `$0 as! NewOutput` |
| `ReflectiveGenerator+Combinators.swift:132` | `result as! Value` in `asOptional()` |
| `ReflectiveGenerator+Combinators.swift:159-160` | `$0 as! Value` in classify |
| `CharacterSet+Ranges.swift:53` | `Unicode.Scalar(scalarValue)!` — could crash on invalid scalars |
| `ReflectiveGenerator+Strings.swift:14-15` | `unicodeScalars.min()!` and `.max()!` |
| `Materialize.swift:1019` | `Int(exactly: unpacked.id)!` |
| `GenerateMacro.swift:120, 137` | Dictionary lookups with `!` |

The `as!` casts at monadic boundaries are architecturally justified (the interpreter controls both erasure and recovery), but a published library should handle these defensively. A type mismatch would produce an opaque crash rather than a meaningful error.

**Recommendation:** For the `as!` casts in interpreter internals: these are acceptable if you're confident in the type flow. For the `!` unwraps on `extract`, `Unicode.Scalar`, and dictionary lookups: convert to `guard let` with descriptive `fatalError` messages or proper error propagation.

**3.2 Unresolved FIXMEs**

- `ReflectiveGenerator+Combinators.swift:67` — "Should we be force unwrapping here? What if it's optional?" — This is a correctness question, not just style.
- ~~`ReflectiveGenerator+Collections.swift:124, 133` — "This is not reflective" on `element()` — The method uses `bind` which breaks the reflection path. This is a **functional gap** — `element()` won't shrink properly.~~ **RESOLVED:** Replaced instance `element()` with static `element(from:)` that delegates to `Gen.element(from:)`. Fully reflective.
- `GenerationContext.swift:73` — "FIXME: Xoshiro features this" — Minor.
- `ReflectiveGenerator+Combinators.swift:128` — "Can we verify this closure is executed from a `pick`?" — Indicates a correctness assumption that's unverified.

---

## 4. Algorithmic Observations

**~~4.1 Zobrist hash computation~~** **NOT AN ISSUE.**

All call sites already follow the optimal pattern: compute `zobristHash` once into a local variable, then use `zobristHashUpdating` for O(1) incremental updates during probing. Full recomputation only happens after the underlying sequence changes. No caching needed.

**4.3 PrefixMaterializer sequence element counting is O(n)**

During hill climbing, `PrefixMaterializer` counts top-level sequence elements by scanning between markers. This is called per-mutation. Pre-computing boundary indices would make this O(1).

**Recommendation:** Cache sequence boundary positions in the `PrefixCursor` after first scan.

---

## 5. Gaps & Missing Functionality

**~~5.1 No `Sendable` conformance on generators~~** **RESOLVED.**

`FreerMonad` is now `@unchecked Sendable`. Safety is guaranteed by two mechanisms: (1) all internal closures in the generator chain are framework-controlled and pure, (2) all user-injected closures (`property`, `scorer`, `predicate`, `forward`/`backward`, etc.) are marked `@Sendable` at the public API boundary. This enables sharing generators across concurrent test methods.

**5.2 `optional()` weight ratio is hardcoded**

`optional()` uses a fixed 1:5 weight ratio (nil vs some). There's no way for users to customize this ratio.

**Recommendation:** Add an overload: `func optional(nilWeight: Int = 1, someWeight: Int = 5)`.

**~~5.3 No `flatMap`/`bind` exposed on `ReflectiveGenerator`~~** **RESOLVED.**

`map` and `bind` are now re-exported on `ReflectiveGenerator` in the `Exhaust` module with `@Sendable` closure constraints. The underlying `FreerMonad` methods are renamed to `_map`/`_bind` to avoid shadowing. `bind` includes a docstring warning that it breaks the reflection path.

**~~5.4 `bool()` generates via `choose(from: [true, false])` instead of `chooseBits`~~** **RESOLVED.**

---

## 6. Exploration Infrastructure (Lower Priority)

Since this is acknowledged as "beginning phases," brief notes:

- All exploration types (`ExploreRunner`, `HillClimber`, `DefaultSeedPool`, `NoveltyTracker`, `Seed`, `SearchDirective`, `PowerSchedule`, `LogarithmicSchedule`, `SeedPool` protocol, `ExploreResult`, `HillClimbResult`) are fully public
- Publishing these now locks you into the API. Consider making them `@_spi(ExhaustExploration)` or internal until the design stabilizes
- `DefaultSeedPool` is a `class` (reference type) while everything else is value types — this asymmetry may be intentional for shared mutation but should be documented

---

## Prioritized Recommendations

### Critical (before publishing)
1. **Remove ExhaustCore product from Package.swift** — Prevents consumers from importing internal machinery directly
2. ~~**Fix the `element()` reflectivity gap**~~ **RESOLVED** — Replaced with static `element(from:)` that delegates to reflective `Gen.element(from:)`
3. **Resolve the FIXME at `Combinators.swift:67`** — "Should we be force unwrapping here? What if it's optional?" is a potential correctness bug in `mapped(forward:backward:)` with PartialPath
4. **Verify `Gen` is hidden after ExhaustCore removal** — Ensure `Gen` doesn't leak into consumer autocomplete/documentation

### High Impact
5. **Convert force unwraps to guarded failures** with meaningful error messages (especially `CharacterSet+Ranges.swift:53`, `ReflectiveGenerator+Strings.swift:14-15`, `Materialize.swift:1019`)
6. **Gate exploration API** behind `@_spi(ExhaustExploration)` until the design stabilizes
7. **Resolve the `asOptional()` TODO** at `Combinators.swift:128` — "Can we verify this closure is executed from a `pick`?" indicates an unverified safety assumption

### Medium Impact
8. **Decompose GenerationContext** into concern-grouped sub-structs (PRNG, sizing, dedup, classification, CGS)
9. **Add customizable `optional()` weight ratio** — `func optional(nilWeight: Int = 1, someWeight: Int = 5)`
10. ~~**Expose `bind` on ReflectiveGenerator**~~ **RESOLVED** — `map` and `bind` re-exported with `@Sendable` constraints; docstring warns about reflection breakage
11. ~~**Use `chooseBits` for `bool()`**~~ **RESOLVED**

### Low Impact / Long-term
12. **Cache PrefixMaterializer sequence boundary positions** for O(1) lookups during hill climbing — profile first to confirm this is a bottleneck
13. ~~**Consider Zobrist hash caching**~~ **NOT AN ISSUE** — all call sites already use incremental updates correctly
14. **Document Materialize vs Replay split** — when to use tree-based vs sequence-based replay
15. **Add a ReflectiveOperation audit mechanism** for the ~15 switch sites (checklist, CI verification, or marker comments)
