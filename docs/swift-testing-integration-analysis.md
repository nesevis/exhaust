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

When `#exhaust` receives its trailing closure, `#expect` calls inside it have not yet been expanded — they appear as `MacroExpansionExprSyntax` nodes with `macroName.text == "expect"`. The `#exhaust` macro can walk the closure body, find those nodes, rename them to `"require"`, and wrap them with `try`. The rewritten `#require` calls then expand normally in the second macro expansion pass. All `#expect` overloads have direct `#require` equivalents with matching signatures, so the rewrite is structurally clean:

```
#expect(condition)              → try #require(condition)
#expect(throws: E.self) { }     → try #require(throws: E.self) { }
#expect(throws: Never.self) { } → try #require(throws: Never.self) { }
```

**The semantic is correct, not a surprise.** In every property-based testing framework, a failed assertion means "stop this invocation and try to shrink." That is exactly `#require` semantics. `#expect` (record but continue) has no useful meaning inside a property body — reaching the second `#expect` with a value that already violated the first produces noise, not signal. Documenting that `#expect` inside `#exhaust` behaves like `#require` is accurate and defensible.

**The real limitation** is that the rewrite only covers direct call sites in the closure literal. Calls to helper functions are not visible to the macro:

```swift
func checkInvariant(_ n: Int) {
    #expect(n > 0)  // not rewritten — invisible to #exhaust's expansion
}

#exhaust(#gen(.int(in: 1...100))) { n in
    #expect(n > 0)       // rewritten: try #require(n > 0) ✓
    checkInvariant(n)    // #expect inside is untouched ✗
}
```

Helper functions called from property bodies should use `#require` directly. This needs to be documented clearly.

**Pros:** Transparent for the common case. No new public API. The rewrite is the correct PBT semantic. Source locations are preserved because the arguments are passed through unchanged.

**Cons:** Indirect `#expect` calls through helper functions are silently not rewritten, leaving the gap in place for that pattern. The behavior difference between direct and indirect calls is non-obvious.

**Verdict:** Viable and worth implementing for the direct-call case. The limitation on indirect calls is real but acceptable — it reduces the footgun surface area significantly without claiming to eliminate it entirely. Should be paired with documentation that `#require` is the correct choice in helper functions called from property bodies.

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

1. **Immediately:** Add documentation to `#exhaust` and `#explore` stating that `#require` is the correct assertion macro in helper functions called from property bodies.
2. **Short term:** Implement the Option B rewrite in `#exhaust` and `#explore` macro expansion — walk the closure literal, find `MacroExpansionExprSyntax` nodes with `macroName == "expect"`, rewrite to `try #require(...)`. This closes the gap for the common case with no new public API.
3. **If Option E is still desired:** `#check` remains a coherent addition for users who want an explicit, indirect-call-safe assertion macro. It is not required to solve the core problem but would complete the API surface.

---

## XCTest Compatibility

Exhaust can be used in XCTest-based projects. Most of the integration works without changes, but three areas need attention.

### Failure reporting — already handled

The `IssueReporting` package routes `reportIssue()` to `XCTFail()` when running under XCTest and to `Issue.record()` when running under Swift Testing. Exhaust's failure reporting works correctly in both contexts with no changes required.

### `XCTAssert*` in property bodies — the same gap, no macro fix available

`XCTAssertEqual(a, b)` has the same "records but does not throw" problem as `#expect` under Swift Testing. Unlike `#expect`, there is no macro rewrite available: `XCTAssert*` functions are plain call expressions, not macro invocations, so the `#exhaust` macro cannot distinguish them syntactically from any other function call in the closure body. The fix cannot be applied automatically.

XCTest users writing property bodies must use assertion forms that throw on failure:

- `XCTUnwrap` — throws on `nil`, works correctly with Exhaust
- A custom throwing assertion wrapper, for example:

```swift
func assertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) throws {
    if a != b {
        XCTFail("\(a) != \(b)", file: file, line: line)
        throw PropertyCheckFailure()
    }
}
```

This should be documented alongside the `#require` guidance for Swift Testing users.

### `XCTSkip` must propagate, not be caught as a counterexample

If a property body throws `XCTSkip`, Exhaust's runner sees it as a thrown error and will treat the invocation as a property failure — potentially reporting it as a counterexample and attempting to shrink it. This is incorrect. A skip is control flow, not a falsified property.

Swift Testing already handles this pattern: `withErrorRecording` checks `SkipInfo(error) != nil` and suppresses the error before it is recorded as an issue. Exhaust needs the equivalent check in its property invocation catch clause:

```swift
} catch let error where isSkipError(error) {
    throw error  // propagate rather than treat as failure
}
```

Where `isSkipError` detects both Swift Testing skips (`SkipInfo`) and `XCTSkip`. Because `XCTSkip` is an `NSError` subclass and XCTest may not be available at compile time, the check uses `NSClassFromString("XCTSkip")` to avoid a hard import dependency:

```swift
func isSkipError(_ error: any Error) -> Bool {
    if let cls = NSClassFromString("XCTSkip") {
        return (error as AnyObject).isKind(of: cls)
    }
    return false
}
```

This is the only item in this section that requires implementation work.

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
