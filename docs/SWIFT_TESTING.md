# Swift Testing integration

Exhaust integrates with Swift Testing through traits, assertion interception, and issue reporting. This page covers how to configure property tests at the suite and test level, how `#expect` and `#require` behave inside property closures, and how failures surface in the test runner.

## Traits

Swift Testing traits are the declarative way to configure property tests. Exhaust provides two: a test trait for per-test configuration and a suite trait for suite-wide defaults.

### Test trait

The `.exhaust(...)` test trait sets budget and regression seeds for a single test function:

```swift
@Test(.exhaust(.budget(.thorough)))
func ageIsNonNegative() {
    #exhaust(personGen) { person in
        #expect(person.age >= 0)
    }
}

@Test(.exhaust(.budget(.thorough), .regressions("3RT5GH8KM2", "9WXY1CV7")))
func ageIsNonNegative() {
    #exhaust(personGen) { person in
        #expect(person.age >= 0)
    }
}
```

The trait composes with other Swift Testing traits — `.timeLimit`, `.bug(...)`, `.tags(...)` — as you'd expect.

Two options are available:

| Option | Effect |
|---|---|
| `.budget(.thorough)` | Sets the coverage and sampling budget for all `#exhaust` calls in the test. |
| `.regressions("seed1", "seed2")` | Registers seeds to replay before the normal pipeline. |

#### Budget precedence

An inline `.budget(...)` setting on the `#exhaust` call itself always takes precedence over the trait. This means you can set a suite-wide default and override it for individual calls that need a different budget:

```swift
@Test(.exhaust(.budget(.thorough)))
func myProperty() {
    // This call uses .quick, not .thorough — inline wins.
    #exhaust(gen, .budget(.quick)) { value in
        #expect(value.isValid)
    }

    // This call inherits .thorough from the trait.
    #exhaust(gen) { value in
        #expect(value.isConsistent)
    }
}
```

#### Regression seeds

Regression seeds are Crockford Base32 encoded strings from a previous failure report. When a test has regression seeds, Exhaust replays each one before the normal coverage and sampling pipeline. If a seed still fails, the test reports the failure immediately with the replayed counterexample. If a seed now passes — because the bug was fixed — it sits inert as a silent guard until the property fails on that seed again.

This means regression seeds are safe to leave in place permanently. They cost one property invocation per seed when the bug is fixed, and they catch regressions the moment the bug reappears. Think of them as pinned counterexamples that run before the random search begins.

```swift
@Test(.exhaust(.regressions("3RT5GH8KM2")))
func dedupePreservesDistinctElements() {
    #exhaust(gen) { xs in
        #expect(Set(myDedupe(xs)) == Set(xs))
    }
}
```

Regression seeds are per-test concerns. They belong on `@Test`, not `@Suite`.

### Suite trait

The suite trait sets a default budget for every property test in the suite:

```swift
@Suite(.exhaust(.thorough))
struct MyPropertyTests {
    @Test func sortPreservesLength() {
        #exhaust(gen) { xs in
            #expect(mySort(xs).count == xs.count)
        }
    }

    @Test(.exhaust(.budget(.quick)))
    func cheapCheck() {
        // Overrides the suite default to .quick.
        #exhaust(gen) { value in
            #expect(value >= 0)
        }
    }
}
```

The suite trait is recursive — it propagates to nested suites. A test-level `.exhaust(...)` trait overrides the suite default for that test. An inline `.budget(...)` on the `#exhaust` call overrides both.

The full precedence order, from highest to lowest:

1. Inline `.budget(...)` on the `#exhaust` call.
2. `.exhaust(.budget(...))` on the `@Test`.
3. `.exhaust(.thorough)` on the `@Suite`.
4. The default (`.standard`).

The suite trait only accepts a budget. Regression seeds are per-test and are not accepted at the suite level.

### Tags

Exhaust defines a `Tag.propertyTest` tag you can use to filter property tests in the test runner:

```swift
@Test(.tags(.propertyTest))
func sortPreservesLength() {
    #exhaust(gen) { xs in
        #expect(mySort(xs).count == xs.count)
    }
}
```

This is useful for selecting or excluding property tests in CI. For example, `swift test --filter .propertyTest` runs only tagged tests, and `swift test --skip .propertyTest` excludes them.

## `#expect` and `#require` inside property closures

Using Swift Testing assertions directly inside `#exhaust` is the recommended way to write property tests. It keeps assertions consistent with the rest of your test suite:

```swift
#exhaust(gen) { value in
    let result = try process(value)
    #expect(result.count > 0)
    #expect(result.isValid)
}
```

This works, but the mechanism behind it is unusual enough to be worth understanding.

### The problem

`#expect` normally records a Swift Testing issue the moment it fails. Inside `#exhaust`, the property closure runs hundreds of times during coverage and sampling, then potentially thousands more during reduction. Recording an issue is expensive — Swift Testing captures source locations, formats diagnostic messages, and synchronizes with the test runner on every call. If `#expect` recorded an issue on every invocation, a single failing property would both flood the test log with duplicate failures and slow the pipeline to a crawl. The purpose of `#exhaust` is to find the minimal counterexample, not to report every failing input along the way.

### The solution: dual closures

The `#exhaust` macro solves this by expanding a single closure into two:

**The detection closure** is a rewritten copy where every `#expect(condition)` becomes `try __ExhaustRuntime.__detectRequire(condition)`, and every `try #require(optional)` becomes `try __ExhaustRuntime.__detectRequire(optional)`. These replacement functions throw a plain `Error` on failure instead of recording a Swift Testing issue. The pipeline uses this closure for coverage, sampling, and reduction — hundreds or thousands of invocations with no test output.

**The property closure** is the original, with `#expect` and `#require` calls preserved as-is but with explicit source locations injected. Exhaust runs this closure exactly once, on the final reduced counterexample, outside the issue suppression scope. This single invocation produces the failure message you see in the test runner — with the minimal counterexample, at the correct source location.

The dual-closure design means:

- During coverage, sampling, and reduction: failures are detected silently via try/catch. No issues are recorded, no console noise.
- After reduction: `#expect` runs once with the reduced value and records a single, clean failure pointing at your assertion line.

### Source locations

In a macro expansion, `#_sourceLocation` resolves to the `#exhaust` call site, not the line where you wrote `#expect`. Without correction, every assertion failure would point at the `#exhaust` line rather than the failing `#expect`. Exhaust fixes this by rewriting `#expect` and `#require` calls in the property closure to include explicit `sourceLocation:` parameters derived from the original source positions. The detection closure doesn't need this — it never records issues.

### What this means in practice

You don't need to think about any of this when writing tests. Write `#expect` and `#require` exactly as you would in a regular Swift Testing test. Two things are worth knowing:

**Assertion failures mean "property failure."** An `#expect` that fails inside `#exhaust` doesn't just record an issue — it signals that the current input is a counterexample. The pipeline treats any `#expect` failure, `#require` failure, or thrown error as a property violation and proceeds to reduction.

**The failure you see is always the reduced one.** The test runner shows a single `#expect` failure at the assertion line, with the minimal counterexample as the value. The hundreds of intermediate failures during reduction never appear.

### Closure shape detection

The macro inspects the trailing closure to decide which runtime path to use:

- **Single-expression closures returning Bool** use the predicate path — the closure is called directly and its return value signals pass/fail.
- **Multi-statement closures, or closures containing `#expect`/`#require`/`throw`** use the void assertion path — the dual-closure mechanism described above.

A closure that returns Bool but also contains `#expect` uses the void path. The presence of assertion macros always wins. A closure with no failure mechanism (no `#expect`, no `throw`, no `try`) produces a compile-time diagnostic warning that the closure can never fail.

## Issue reporting

When a property fails, Exhaust reports three things to the test runner:

1. **A rendered failure summary** via `reportIssue()`, containing the counterexample, property invocation count, and replay seed. This appears at the `#exhaust` call site.
2. **The `#expect` failure itself**, from the final re-run of the property closure with the reduced counterexample. This appears at the `#expect` line.
3. **A console line** with the replay seed in a greppable format: `exhaust:<function>:replay:<seed>`.

For predicate-style closures (returning Bool), only the rendered failure summary and replay seed appear — there is no `#expect` to re-run.

### Suppressing issue reporting

When you want to assert on the return value directly — testing that a property fails in a particular way, or that reduction produces a specific counterexample — use `.suppress(.issueReporting)`:

```swift
let result = #exhaust(gen, .suppress(.issueReporting)) { value in
    #expect(value < 50)
}
#expect(result == 50, "Minimal counterexample should be 50")
```

With suppression enabled, the pipeline skips the final re-run and the `reportIssue` call. The counterexample is returned silently for the caller to inspect. `.suppress(.logs)` silences console output. `.suppress(.all)` does both.

## Async properties

Async closures work the same way, with `await` on the `#exhaust` call:

```swift
@Test func asyncPropertyWorks() async {
    await #exhaust(gen) { value in
        let result = try await value.validate()
        #expect(result.isValid)
    }
}
```

The async property is bridged to a synchronous form and dispatched onto a GCD thread where the synchronous pipeline runs. After reduction, the async property closure is re-run in the original async context so `#expect` records correctly.

One implementation detail worth mentioning: on the GCD thread, `Test.current` is `nil`, which causes the test context to misdetect as XCTest. Exhaust works around this by using `withKnownIssue` directly on the async path rather than the `withExpectedIssue` helper that auto-detects the framework. You shouldn't encounter this, but if you see XCTest-style output from an async property test, this is the mechanism involved.

## XCTest compatibility

Exhaust detects the test framework at runtime via `TestContext.current`. The macros (`#exhaust`, `#explore`, `#examine`, `#example`) work under both Swift Testing and XCTest. Under XCTest, `XCTAssert`-style assertions are not intercepted the way `#expect` and `#require` are — use predicate closures (returning Bool) or thrown errors for XCTest property tests.

OpenPBTStats attachments are recorded via `Attachment` under Swift Testing and `XCTAttachment` under XCTest. The test framework detection handles this automatically.

## CI budget override via environment variable

> [!Note]
> This feature is not yet implemented. This section describes the intended design.

When property tests run in CI, it's useful to control the budget globally — running `.quick` on every PR build for speed, `.thorough` on nightly builds for confidence, without changing any test code. An environment variable provides this control.

### Design

The environment variable `EXHAUST_BUDGET` sets a floor-or-ceiling budget for the entire test process:

```bash
# Fast CI: cap all property tests to .quick
EXHAUST_BUDGET=quick swift test

# Nightly: raise everything to .thorough
EXHAUST_BUDGET=thorough swift test
```

Accepted values: `quick`, `standard`, `thorough`, `extensive`.

### Precedence

The environment variable interacts with the existing precedence chain. The question is where it should sit. Two reasonable positions:

**Option A: lowest precedence (default override).** The environment variable replaces the `.standard` default but is overridden by suite traits, test traits, and inline settings. A test that explicitly asks for `.extensive` keeps its budget even when CI sets `EXHAUST_BUDGET=quick`.

```
inline > test trait > suite trait > env variable > default (.standard)
```

This is the conservative choice. It respects every explicit budget declaration in the code and only affects tests that rely on the default. A test author who wrote `.extensive` had a reason, and the CI operator shouldn't silently downgrade it.

**Option B: highest precedence (global override).** The environment variable overrides everything, including inline settings. A CI pipeline that sets `EXHAUST_BUDGET=quick` forces every property test to run at `.quick` regardless of what the code says.

```
env variable > inline > test trait > suite trait > default (.standard)
```

This is the blunt instrument. It's useful when the goal is wall-clock time control: "this pipeline must finish in under 10 minutes, whatever the tests say." The downside is that a test carefully configured with `.extensive` because its generator needs the budget to find rare bugs will silently run at `.quick`, and the CI operator may not realise the coverage loss.

### Recommendation

Option A — lowest precedence — is the safer default. A test author's explicit budget choice carries more information than a blanket CI setting, and overriding it silently undermines the point of setting it. If CI needs wall-clock control, `swift test --filter` or `.tags(.propertyTest)` combined with separate CI jobs (one fast, one thorough) achieves the same thing without losing per-test budget intent.

If the use case for Option B is strong enough, a second variable `EXHAUST_BUDGET_FORCE=quick` could provide the override-everything behaviour as an opt-in escalation.

### Reading the variable

The variable is read once at process start via `ProcessInfo.processInfo.environment["EXHAUST_BUDGET"]` and cached in a `@TaskLocal` or global constant. The lookup happens in `__exhaustBody` alongside the existing trait configuration check, at the lowest precedence position (before the `.standard` fallback).

An unrecognised value (a typo, an empty string) is ignored with a logged warning rather than crashing the test process.
