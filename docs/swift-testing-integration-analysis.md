# Exhaust × Swift Testing: Integration Analysis

## Executive Summary

Exhaust is a good Swift Testing partner today. The `@Test` + `#exhaust(...)` composition is natural, failure reporting uses the right integration point (`reportIssue()`), and the settings DSL is stylistically consistent with Swift Testing conventions. The framework correctly positions itself as a complement to parameterized testing, not a replacement for it.

The sharpest issue is a semantic gap: `#expect` failures inside a property body are invisible to Exhaust's reduction loop. This document analyses all integration dimensions and goes deep on options for closing that gap.

---

## What's Working Well

### `reportIssue()` is the correct foundation

Swift Testing's `IssueReporting` module is the right integration seam. Exhaust already uses `reportIssue()`, which means failures surface as proper test issues with correct source location. `withKnownIssue {}` wrapping composes correctly for free — no special handling required.

### Macro-in-body composition is idiomatic

The `@Test` + `#exhaust(...)` inside the body pattern does not fight the framework. From a Swift Testing user's perspective, `#exhaust` reads as a macro that drives the property, which is accurate.

### Settings style matches Swift conventions

`.samplingBudget(100)`, `.replay(seed)`, `.reductionBudget(.fast)` read similarly to `Trait.timeLimit(.minutes(1))`. Variadic enum-case settings fit the Swift Testing aesthetic.

### Source location threading is correct

Both macros capture `fileID`, `filePath`, `line`, and `column` and forward them through. Failures point at the right line.

### `#require` propagates naturally

Because `#require` throws on failure, Exhaust's runner catches the thrown error and treats it as a property failure. This composes correctly without any special handling.

---

## Structural Mismatches

### `#exhaust` and `@Test(arguments:)` are philosophically incompatible

Swift Testing's parameterized testing expects a fixed, eager collection of arguments at test definition time. The framework filters, retries, and identifies individual cases by stable ID. Exhaust generates arguments adaptively at runtime based on coverage feedback. There is no way to express Exhaust's generation loop as a `@Test(arguments:)` collection. Exhaust is complementary to parameterized testing, not equivalent.

### The `Trait` extensibility point does not fit Exhaust's model

Swift Testing's `TestScoping` trait wraps test execution by calling a body closure it receives. Exhaust is the body — it needs to run the user's property many times, not wrap a single invocation. A trait-based integration (`@Test(.exhausting(gen, ...))`) would require injecting a generated value into the test function's parameter, which `TestScoping` has no mechanism for. The `@Test(arguments:)` code path has special macro-level handling that custom traits cannot hook into.

---

## Opportunities

### Issue kind richness

Exhaust currently calls `reportIssue()` with a rendered string, which surfaces as an `Issue.Kind.unconditional` issue. Swift Testing's richer `Issue.Kind.expectationFailed(_:Expectation)` path carries a structured `differenceDescription` and expression representation. Exhaust's failure messages are good prose, but they bypass this structured path. IDEs and test reporters that parse issue structure receive a plain string rather than a diff. Constructing an `Issue` via the `expectationFailed` path would improve integration with tooling built on top of Swift Testing.

### Attachment API for machine-readable output

Swift Testing has an `Attachment` type for saving test artifacts to test reports. Exhaust's LLM-optimized JSON failure format is currently emitted only as a log event. Recording it as a Swift Testing `Attachment` would make it accessible to CI tooling and test reporters without custom log parsing.

### Replay via parameterized tests

When Exhaust finds a counterexample it emits a `.replay(seed)` instruction. A natural composition that is not currently exploited:

```swift
@Test(arguments: [knownSeed1, knownSeed2])
func regressionSeeds(seed: UInt64) {
    #exhaust(gen, .replay(seed)) { value in
        // property body
    }
}
```

This lets Swift Testing identify each regression seed as an individually-filterable parameterized case. It requires no new Exhaust API — just documentation and convention.

### `#expect` inside property bodies — semantic gap and remediation options

This is the sharpest integration issue, covered in detail in the next section.

---

## The `#expect` Semantic Gap

### The problem

Exhaust detects property failure by catching thrown errors from the property closure. Swift Testing's `#expect` records an issue directly into the framework's task-local issue storage without throwing. The result:

```swift
#exhaust(#gen(.int(in: 0...100))) { n in
    #expect(n.isMultiple(of: 2))  // records an issue, but Exhaust sees the property as PASSING
}
```

Exhaust runs to completion and reports no counterexample. Swift Testing shows a failed expectation from one of the intermediate invocations — probably not the simplest one, and not attributed to the value that caused it. The user gets a confusing failure: an issue is reported but no counterexample is shown, and the issue's source location points into the loop rather than at a specific generated value.

The `#require` equivalent does not have this problem because it throws.

### Why this is not just a documentation issue

The problem is that `#expect` is the idiomatic assertion macro in Swift Testing. Users reach for it instinctively, especially when they are writing `@Test` functions first and adding `#exhaust` later. The mismatch is not obvious from reading the signatures, and the failure mode is silently incorrect (missing counterexample) rather than loudly wrong (compilation error or crash).

### Option A: Documentation only

Instruct users to always use `#require` inside `#exhaust` closures, and explain why.

**Pros:** Zero implementation cost. The guidance maps to how property-based testing works in other ecosystems — Python's Hypothesis uses `assert`, which throws `AssertionError`. `#require` is the direct equivalent.

**Cons:** The failure mode remains silently incorrect for users who miss the guidance. The behavior violates the principle of least surprise: the same `#expect(x)` call behaves differently depending on whether it is inside a property test or a regular test.

**Verdict:** Necessary regardless of whether other options are pursued, but not sufficient on its own.

### Option B: Rewrite `#expect` to `#require` in macro expansion

The `#exhaust` macro could perform AST rewriting on the property closure, replacing `#expect(...)` call sites with `#require(...)`.

**Pros:** Transparent to the user. Existing code that uses `#expect` inside `#exhaust` would work correctly without changes.

**Cons:** This is fragile. The `#exhaust` macro would need to walk the AST of the closure and identify `#expect` call expressions, which requires parsing macro invocations inside a macro's expansion context. It would miss `#expect` calls in functions called from the property body (only direct calls in the closure literal are rewritable). It would also be a semantic surprise in the opposite direction: the user wrote `#expect` and the framework silently changed the semantics to `#require`. The approach is too clever.

**Verdict:** Not recommended.

### Option C: Intercept via Swift Testing internals

Swift Testing's issue recording path is: `Issue.record()` → check `KnownIssueScope.current` (a `@TaskLocal`) → `Event.post(.issueRecorded(self))` → routed to `Configuration.current`'s event handler. `KnownIssueScope` is the task-local that `withKnownIssue` installs to suppress or annotate issues before they are posted. It is `internal` to Swift Testing.

The public `IssueHandlingTrait` (available as `Trait.compactMapIssues` and `Trait.filterIssues`, available since Swift 6.2) intercepts issues by replacing `Configuration.current` with a modified copy for the duration of the test body, using `Configuration.withCurrent(_:perform:)`. That function is also `internal`. Even if `IssueHandlingTrait` could be adapted to Exhaust's needs, it operates at the test annotation level — it cannot be scoped per property invocation from inside the running test body.

Both interception mechanisms — `KnownIssueScope` and `Configuration.withCurrent` — are therefore unavailable to Exhaust. There is no public API surface in Swift Testing that allows per-invocation issue interception from within a running test body.

**Verdict:** Not viable without forking or depending on Swift Testing internals.

### Option D: Wrap each invocation with a nested `Runner`

Swift Testing's `Runner` accepts a `Configuration` with `eventHandlers: [Event.Handler]`. An event handler receives `.issueRecorded` events. If Exhaust ran each property invocation inside a fresh nested `Runner`, it could intercept issue events and convert them into thrown errors.

The problem is that running a nested `Runner` for each of potentially thousands of property invocations would carry enormous overhead. `Runner` is designed for test discovery and full test execution, not as a per-invocation wrapper. The concurrency model would also be difficult to reconcile — the property closure is already running inside a test's task context.

**Verdict:** Architecturally wrong tool. Overhead is prohibitive.

### Option E: Exhaust-provided `#check` macro

Exhaust provides a `#check(condition)` macro that both records a Swift Testing issue (matching `#expect`'s behavior) and throws a `CheckFailure` error that Exhaust's runner catches. Inside a property body:

```swift
#exhaust(#gen(.int(in: 0...100))) { n in
    try #check(n.isMultiple(of: 2))  // records an issue AND signals failure to Exhaust
}
```

Outside a property body, `#check` degrades gracefully to `#expect` semantics (records an issue, does not throw, since `try` on a non-throwing call is a no-op in Swift).

**Pros:** Clean semantics. No AST rewriting. No Swift Testing internals. The `try` at the call site makes the throwing behavior explicit and communicates the different semantics. Composable with `#require` — users can use `#check` for soft assertions (Exhaust sees the failure, records it, continues trying to shrink) and `#require` for hard preconditions (stop this invocation immediately).

**Cons:** Adds a new macro to the public API surface. Users need to learn `#check` as a distinct concept from `#expect`. The `try` is slightly awkward since `#expect` never requires it.

**Verdict:** The most implementable option with correct semantics. The tradeoff between API surface and correctness is worth it if the semantic distinction between `#check` (soft, recorded, Exhaust-visible) and `#require` (hard, throws immediately) proves useful as a design primitive.

### Recommended path

1. **Immediately:** Add documentation to `#exhaust` and `#explore` stating that `#require` is the correct assertion macro inside property closures, with an explanation of why `#expect` does not trigger reduction.
2. **Longer term:** Implement `#check` (Option E) as an Exhaust-provided macro with explicit `try`. The two-macro split (`#check` for Exhaust-visible assertions, `#require` for hard preconditions) is a coherent API design that mirrors the existing soft/hard distinction in Swift Testing itself.

---

## Style Parity Summary

| Dimension | Swift Testing | Exhaust | Verdict |
|-----------|---------------|---------|---------|
| Macro naming | `#expect`, `#require` | `#exhaust`, `#explore`, `#gen` | Consistent — `#` freestanding, lowercase |
| Configuration style | `Trait.timeLimit(.minutes(1))` | `.samplingBudget(100)`, `.replay(seed)` | Consistent — enum cases, labeled arguments |
| Argument labels | `displayName:`, `arguments:` | generator positional first, settings variadic | Minor gap — settings have no label |
| Source location | `sourceLocation: SourceLocation = #_sourceLocation` | Captured implicitly by macro | Equivalent outcome, different surface |
| Failure recording | `Issue.record()` / `reportIssue()` | `reportIssue()` | Correct integration point |
| Async support | Full async/await | Full async/await in property closures | Aligned |
| `Sendable` discipline | Required everywhere | Generators are `Sendable` | Aligned |
