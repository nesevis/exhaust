# Swift Testing Integration Opportunities

Builds on `swift-testing-integration-analysis.md`, which identified the `#expect` semantic gap and documented what already works well. This document records concrete integration opportunities and design decisions from a review of the Swift Testing source (March 2026).

---

## 1. `#expect` and `#require` Support in `#exhaust`

The highest-value integration. Today `#exhaust` takes `(T) -> Bool`. Adding a `(T) throws -> Void` overload lets users write `#expect`/`#require` inside the property body, getting Swift Testing's expression expansion (operand capture, diff display, source locations) for free.

### Surface API

Two complementary approaches, both using the same runtime mechanism:

**Option B: Evolve `#exhaust`.** Add the `(T) throws -> Void` overload alongside the existing `(T) -> Bool`:

```swift
@Test func ageIsNonNegative() {
    #exhaust(personGen) { person in
        #expect(person.age >= 0)
        #expect(person.name.isEmpty == false)
    }
}
```

**Option C: Configuration trait.** A trait carries budget, regression seeds, and tags. `#exhaust` reads the configuration at runtime:

```swift
@Test(.exhaust(.expensive))
func ageIsNonNegative() {
    #exhaust(personGen) { person in
        #expect(person.age >= 0)
    }
}
```

Budget is a positional parameter (most commonly varied). Regressions are variadic:

```swift
@Test(.exhaust(.expensive, regressions: "3RT5GH8KM2", "9WXY1CV7"))
```

This keeps the common case terse and the complex case readable — the regressions don't push budget off-screen.

The trait composes with other Swift Testing traits (`.timeLimit`, `.bug(...)`, `.tags(...)`) and can automatically add a `.propertyTest` tag. It does not inject parameters or drive execution — `#exhaust` in the body does that.

**Trait → macro communication via `@TaskLocal`.** The trait conforms to `TestScoping` and sets configuration for the duration of the test body:

```swift
struct ExhaustTrait: TestTrait, TestScoping {
    let budget: ExhaustBudget
    let regressions: [String]

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let config = ExhaustTraitConfiguration(
            budget: budget,
            regressions: regressions
        )
        try await ExhaustTraitConfiguration.$current.withValue(config) {
            try await function()  // test body runs here
        }
    }
}
```

Inside the test body, `#exhaust` expands to `__ExhaustRuntime.__exhaustExpect(...)`, which reads the task-local and merges it with any inline settings (inline takes precedence):

```swift
public static func __exhaustExpect<Output>(...) -> Output? {
    var budget = ExhaustBudget.expedient
    var regressionSeeds: [String] = []

    // Read trait configuration
    if let traitConfig = ExhaustTraitConfiguration.current {
        budget = traitConfig.budget
        regressionSeeds = traitConfig.regressions
    }
    // Inline settings override
    for setting in settings { ... }

    // ... pipeline runs with merged configuration
}
```

`prepare(for:)` does not work here — it runs before the test but does not wrap execution, so a task-local set there would not persist into the test body. `provideScope` is the right hook because it wraps the test body, keeping the task-local alive for the entire execution. The task-local bridges from async (`provideScope`) to sync (`__exhaustExpect`) because task-locals are inherited by synchronous code running within the same task.

The trait intentionally ignores the `testCase` parameter. `provideScope` is called once per test case for parameterized tests (with `testCase` non-nil) and once with `testCase == nil` for suite-level scope. Since `#exhaust` drives its own iteration internally rather than using `@Test(arguments:)`, it always hits the single-case path. The `testCase` parameter is unused — nobody should try to vary Exhaust configuration per test case.

### Why not an `@ExhaustTest` attribute macro?

Ruled out. It would need to either generate `@Test` (cross-module attached macro expansion on generated declarations is not supported) or replicate `@Test`'s discovery/registration machinery (unstable `@_spi(ForToolsIntegrationOnly)` internals that change between compiler versions). Both paths subsume Swift Testing internals rather than composing with its public API.

### Why not `@Test(arguments:)`?

Swift Testing's parameterized testing expects a fixed, eager `Sequence` at test definition time with stable IDs for re-running individual cases. Exhaust generates arguments adaptively (coverage analysis determines the first batch, failure triggers reduction). There is no way to express this as a `Sequence`. A trait also cannot inject test function parameters — parameter injection is hardwired into `@Test`'s macro expansion.

### Runtime: `withKnownIssue` as the detection mechanism

The key insight from reading the Swift Testing source. `withKnownIssue(isIntermittent: true)` detects `#expect` failures per invocation without macro rewriting and without importing Swift Testing internals.

**How it works.** `withKnownIssue` installs a `KnownIssueScope` via `@TaskLocal`. When `#expect` fails, `Issue.record()` checks `KnownIssueScope.current` and, if a matcher is installed, marks the issue as "known" (suppressed). The `isIntermittent: true` flag prevents a "known issue not recorded" warning when the property passes.

**Per-invocation detection:**

```swift
// During coverage/sampling/reduction:
var didFail = false
withKnownIssue(isIntermittent: true) {
    try property(generatedValue)
} matching: { _ in
    didFail = true
    return true  // suppress this issue
}
// didFail tells us whether this value is a counterexample
```

**All failure modes are handled:**

| Source | Detection path |
|--------|---------------|
| `#expect` fails | `Issue.record()` → `KnownIssueScope` matcher fires → `didFail = true` |
| `#require` fails | Issue recorded + `ExpectationFailedError` thrown → matcher fires, error caught by `withKnownIssue` |
| Arbitrary thrown error | `withKnownIssue`'s `do/catch` → `_matchError` → matcher fires |
| `(T) -> Bool` returns `false` (wrapped) | Wrapper calls `reportIssue()` → `Issue.record()` → matcher fires |
| Property passes | No issues, no throws. `isIntermittent: true` suppresses the "known issue not recorded" warning |

**Handles helper functions.** Unlike the `#expect` → `#require` macro rewrite (Option B from the prior analysis), `withKnownIssue` intercepts all issues recorded within its dynamic scope — including `#expect` calls inside helper functions called from the property body.

**Works from Exhaust's synchronous pipeline.** `KnownIssueScope.current` is `@TaskLocal`. `__exhaust` runs synchronously inside the `@Test` function's task. `reportIssue()` already works from inside `__exhaust` (proving the task context is preserved), so `withKnownIssue` will too.

**Overhead.** Each `withKnownIssue` call installs and removes a `@TaskLocal` value — negligible compared to the property evaluation itself.

### Transparent reporting

After reduction, the property is re-run one final time with the reduced counterexample, *without* `withKnownIssue`. The `#expect` failures record naturally with the reduced values. The user sees standard Swift Testing assertion failures and does not need to know that reduction happened:

```swift
#exhaust(personGen) { person in            // ← "Reproduce: .replay("a7Kx9mPq2Lb")"
    #expect(person.age >= 0)               // ← "Expectation failed: (person.age → -5) >= 0"
    #expect(person.name.isEmpty == false)   // ← "Expectation failed: (person.name.isEmpty → true) == false"
}
```

The only Exhaust artifact is the replay seed. The counterexample dump, reduction diff, and invocation count are available behind a verbose setting for debugging reduction itself. They are not shown by default.

The `(T) -> Bool` path keeps the current full Exhaust failure report (counterexample dump, diff, seed) because it has no per-assertion detail to fall back on.

### Coexistence of `Bool` and `Void` signatures

Both signatures coexist permanently:

- `(T) -> Bool`: Concise for simple predicates. Framework-agnostic — works identically under Swift Testing, XCTest, or standalone. No `import Testing` needed.
- `(T) throws -> Void`: Richer assertions with `#expect`/`#require`. Swift Testing specific. Requires `import Testing` for `withKnownIssue`.

The `Bool` path can be wrapped into `Void` for a unified pipeline implementation:

```swift
let voidProperty: (Output) throws -> Void = { value in
    if boolProperty(value) == false {
        reportIssue("Property returned false")
    }
}
```

This works because `reportIssue` → `Issue.record()` → `KnownIssueScope.current` — the same interception chain that catches `#expect`.

### XCTest and framework-agnostic concerns

The `withKnownIssue` mechanism is Swift Testing specific. `XCTAssert*` functions bypass Swift Testing's issue recording and cannot be intercepted. XCTest users should use the `(T) -> Bool` signature, `XCTUnwrap` (which throws), or write throwing assertion wrappers. The prior analysis document covers this in detail.

The `#expect` → `#require` macro rewrite (Option B from the prior analysis) is a belt-and-suspenders fallback for direct `#expect` calls in the closure literal. It does not handle `XCTAssert*` calls (plain function expressions, not macros).

### Async properties

The document assumes synchronous property bodies, and the existing `#exhaust` pipeline is synchronous. Real-world Swift Testing code increasingly uses async test functions. An async `#exhaust` overload would allow `await` inside the property body:

```swift
#exhaust(personGen) { person in
    let result = await service.validate(person)
    #expect(result.isValid)
}
```

The `withKnownIssue` mechanism does not foreclose this — `KnownIssueScope` is `@TaskLocal`, so it works in async contexts. Swift Testing provides both sync and async overloads of `withKnownIssue`. The detection mechanism, transparent reporting, and regression seed design all carry over unchanged.

The pipeline itself would need an async variant. Contract testing already supports async functions via `AsyncContractSpec` and `__runContractAsync`, so there is precedent in the codebase. The `#exhaust` async overload would follow the same pattern — async property closure, async pipeline execution, same `withKnownIssue` detection.

**Cancellation as a design advantage.** If an async property body respects `Task.checkCancellation()` or uses cancellation-aware APIs, the pipeline can abandon a slow evaluation mid-flight (for example, a timeout during reduction). The sync pipeline has no equivalent — it must wait for each evaluation to complete. This is a meaningful advantage for the async path, especially for property bodies that call network services or other latency-sensitive APIs.

Implementation is deferred, but the design accommodates it.

### Open question

The `withKnownIssue` path requires `import Testing`. Should it be behind `#if canImport(Testing)`, or should the `(T) throws -> Void` overload live in a separate module (`ExhaustTesting`)?

---

## 2. Regression Seeds

### Problem

Pinning a counterexample as a regression test requires a separate function with manually maintained seeds. A persistent database (Hypothesis style) avoids the duplication but produces file artifacts that need git management — merge conflicts on a seed database are annoying.

### Design: inline seeds with Crockford Base32 encoding

Regression seeds live directly in the `#exhaust` call:

```swift
#exhaust(personGen, .regressions("3RT5GH8KM2", "9WXY1CV7")) { person in
    #expect(person.age >= 0)
}
```

Or via the trait:

```swift
@Test(.exhaust(.expensive, regressions: "3RT5GH8KM2", "9WXY1CV7"))
func ageIsNonNegative() {
    #exhaust(personGen) { person in
        #expect(person.age >= 0)
    }
}
```

**Execution.** Regression seeds are replayed deterministically before the normal pipeline runs. If a regression seed now passes, the runtime emits a warning: "Regression seed `3RT5GH8KM2` now passes — consider removing it."

**Crockford Base32 encoding.** Alphabet: `0123456789ABCDEFGHJKMNPQRSTVWXYZ` — excludes `I`, `L`, `O`, `U` to avoid visual ambiguity with `1`, `1`, `0`, and `V`. A `UInt64` encodes to at most 13 characters. Key properties:

- **Case-insensitive.** Output is uppercase; input accepts both cases. No bugs from a user typing `3rt5gh8km2` instead of `3RT5GH8KM2`.
- **No visual ambiguity.** `I`/`1`, `L`/`1`, `O`/`0` confusion eliminated. Safe to read from screenshots, logs, or Slack messages.
- **No padding.** Leading zeros omitted, so small seeds are short.

Failure output uses Crockford Base32:

```
Reproduce: .replay("3RT5GH8KM2")
```

**`.replay` accepts Crockford Base32:**

```swift
#exhaust(gen, .replay("3RT5GH8KM2")) { ... }
```

The existing `.replay(UInt64)` overload stays for programmatic use. The decoder also accepts base62 input for forward compatibility — if a user pastes a base62 string from an older Exhaust version, it decodes correctly.

### What regression seeds do NOT replace

Seeds replay a specific PRNG path. They are not stable across generator changes. For regression tests that must survive generator evolution, write a direct unit test with a hardcoded value.

### Decisions

- **"Now passes" warning.** Recorded as a Swift Testing issue (via `Issue.record` with warning severity), not a log message. A log message vanishes in CI noise. An issue shows up in Xcode's test navigator and in structured test output — where a developer triaging a green CI run would actually notice it.
- **API surface.** `.regressions(...)` accepts `String` only (Crockford Base32, with base62 fallback decoding). `.replay` accepts both `String` and `UInt64`. Nobody hardcodes a raw integer literal as a regression seed — keep that surface minimal.

### Open question

Should regression seeds trigger the full reduction pipeline on failure, or just report as-is? Full reduction is expensive but may produce a simpler counterexample than the original seed. On the other hand, the user already saw the reduced counterexample when they first pinned the seed.

---

## 3. Future Considerations

### Attachments

**Status: nice-to-have.** The transparent reporting model already handles user-facing output. The strongest case is ExhaustReport as CI metrics — machine-readable stats that teams could trend across builds. Revisit when there is demand.

### Custom tags

Exhaust could provide `Tag.propertyTest` and `Tag.contractTest` for filtering property tests in the IDE or CI. The Option C trait could auto-tag. Low complexity, low urgency — useful when teams need to run property tests on a separate schedule from unit tests.

### `withKnownIssue` composition

Already works today — wrapping `#exhaust` in `withKnownIssue { }` marks failures as known. The Option C trait could read `.bug(...)` traits and adjust behavior (smaller budget for known-failing tests). Additive.

### Issue annotation

The `(T) -> Bool` path's `reportIssue()` message could be structured with machine-parseable markers. Lower priority now that the `Void` path delegates to `#expect` for assertion detail.

### Conditional budget

`.adaptive` budget that picks `.exorbitant` on CI and `.expedient` locally. Achievable today with `ProcessInfo.processInfo.environment["CI"]`. A built-in setting would save boilerplate.

---

## 4. Agent-Consumable Output

The transparent reporting model is optimized for humans — `#expect` operand values plus a replay seed. Agents have different needs.

### What agents need

**The full counterexample.** `Expectation failed: (person.age → -5) >= 0` tells the agent that `age` is `-5` but not what `person.name` is or any other field. If the fix depends on the relationship between fields (age computed from birthDate, name validated against a locale), the agent can't reason about it from the operand values alone. Humans mentally reconstruct the object; agents need it spelled out.

**A machine-extractable replay tag.** The human-facing `Reproduce: .replay("3RT5GH8KM2")` is embedded in prose. An agent grepping test output needs a fixed-format line it can reliably parse.

**Connection between failures and the generated value.** Multiple `#expect` failures from the same counterexample appear as independent issues in Swift Testing output. An agent needs to know they all stem from the same generated input.

### What agents don't need

**Reduction diffs.** The "before/after simplification" story helps humans understand what Exhaust did. Agents just need the final reduced value.

### Design

**Structured replay tag.** On failure, Exhaust emits a fixed-format line to the log:

```
exhaust:ageIsNonNegative:replay:3RT5GH8KM2
```

Format: `exhaust:<testName>:replay:<seed>`. No prose, no quoting, one per line. An agent can grep for `^exhaust:.*:replay:` to extract all failing seeds and their associated tests. The test name comes from `#function` at the `#exhaust` call site.

**Full counterexample in agent mode.** When `ExhaustLog.Format` is `.llmOptimized`, Exhaust emits an additional `reportIssue()` at the `#exhaust` call site with the full counterexample dump — the double-reporting rejected for humans but valuable for agents. This gives the agent the complete generated object alongside the per-assertion `#expect` failures.

**The existing `PropertyTestFailure.renderLLMOptimized()` path.** Already emits structured JSON with the counterexample dump as an `ExhaustLog` event. The structured replay tag complements this by providing a lightweight, greppable format that doesn't depend on JSON parsing.

### No changes to the transparent mode

The human-facing output is unchanged. The structured replay tag and full counterexample dump are additive — they appear in log output alongside the `#expect` failures, not instead of them. In `.human` format mode, only the replay tag is added (one line). In `.llmOptimized` mode, both the tag and the full counterexample are emitted.

---

## Summary

| Opportunity | Impact | Complexity | Status |
|-----------|--------|------------|--------|
| `#expect`/`#require` support via `withKnownIssue` | High | Moderate | Design complete, ready to implement |
| Configuration trait (Option C) | High | Low | Design complete, ready to implement |
| Regression seeds with Crockford Base32 | High | Moderate | Design complete, open question on reduction behavior |
| Agent-consumable output (replay tag, full counterexample) | Medium | Low | Design complete |
| `#expect` → `#require` macro rewrite | Medium | Low | Belt-and-suspenders for `withKnownIssue` |
| Attachments | Low | Low | Nice-to-have, revisit on demand |
| Custom tags | Low | Trivial | Nice-to-have |
| `withKnownIssue` composition | Low | Low | Already works; trait integration is additive |
| Issue annotation | Low | Low | Lower priority with transparent reporting |
| Conditional budget | Low | Trivial | Nice-to-have |
