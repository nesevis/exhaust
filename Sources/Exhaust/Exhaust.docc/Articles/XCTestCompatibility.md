# XCTest compatibility

Exhaust works under XCTest. All macros expand to the same runtime functions regardless of test framework. Exhaust detects which framework is active at runtime via `TestContext.current` from the IssueReporting library and routes output accordingly.

This page covers what works, what doesn't, and what behaves differently from Swift Testing.

## What works

### Boolean and throwing property closures

Under XCTest, property closures must either return `Bool` or throw an error to signal failure. These are the only two ways for Exhaust to detect that an input is a counterexample. (Under Swift Testing, `#expect` and `#require` provide a third option, but those are not available under XCTest.)

Both shapes work identically to their Swift Testing equivalents:

```swift
final class SortTests: XCTestCase {
    func testSortPreservesLength() {
        #exhaust(.int().array(length: 0...100)) { array in
            mySort(array) == array.sorted()
        }
    }

    func testParserDoesntCrash() {
        #exhaust(.string()) { input in
            do {
                _ = try parse(input)
            } catch is ParseError {
                // expected
            } catch {
                throw error
            }
        }
    }
}
```

Async variants of both shapes are also supported:

```swift
func testAsyncPropertyWorks() async {
    await #exhaust(.int(in: 0...100)) { value in
        try await someAsyncCheck(value)
    }
}
```

All closure shapes go through the same screening, sampling, and reduction pipeline as with Swift Testing.

### Issue reporting

When a property fails, Exhaust calls `reportIssue()` from the IssueReporting library. Under XCTest, this bridges to `XCTFail` with the rendered failure summary (counterexample, invocation count, replay seed) at the `#exhaust` call site. The failure appears in Xcode's test navigator the same way any `XCTFail` would.

`.suppress(.issueReporting)` prevents the `XCTFail` call, letting you assert on the return value with `XCTAssert` instead:

```swift
func testMinimalCounterexample() {
    let result = #exhaust(
        #gen(.int(in: 0...100)),
        .suppress(.issueReporting)
    ) { value in
        value < 50
    }
    XCTAssertEqual(result, 50)
}
```

### XCTSkip

Throwing `XCTSkip` inside a property closure skips that input: it counts as neither pass nor failure, and the pipeline continues sampling. Skips are tallied in the run's `ExhaustReport`; a run that skips nearly every invocation reports a warning, and a run whose every invocation was skipped fails, because it asserted nothing. `PropertySkip` behaves identically and works under both frameworks.

### OpenPBTStats attachments

When `.collectOpenPBTStats` is enabled, Exhaust records the data as an `XCTAttachment`. The attachment appears in Xcode's test report alongside any other test attachments.

### State machine tests

`await #execute(Spec.self)` works under XCTest (in an `async` test method) with the same command generation, invariant checking, and reduction pipeline. Failures are reported via `XCTFail`.

## What doesn't work

### XCTAssert inside property closures

`XCTAssertEqual`, `XCTAssertTrue`, `XCTAssertNil`, and the rest of the `XCTAssert` family are not intercepted by Exhaust. They record XCTest failures directly, bypassing the detection mechanism that makes `#expect` work cleanly inside `#exhaust`.

Using `XCTAssert` inside a property closure has two problems. First, Exhaust cannot detect the assertion failure as a property violation, so it won't trigger reduction. The pipeline sees the closure as passing even when `XCTAssertEqual` has recorded a failure. Second, if the `XCTAssert` happens to be in a throwing context and the assertion records a failure, that failure appears in the test log on every invocation during sampling, not just once with the reduced counterexample.

Exhaust emits a compile-time warning when it detects `XCTAssert` or `XCTFail` calls in a property closure. Use boolean return values or thrown errors instead:

```swift
// Don't do this.
func testBroken() {
    #exhaust(.int(in: 0...100)) { value in
        XCTAssertTrue(value >= 0)  // Exhaust can't see this failure
    }
}

// Do this.
func testWorks() {
    #exhaust(.int(in: 0...100)) { value in
        value >= 0
    }
}
```

### XCTUnwrap inside property closures

`XCTUnwrap` works in the sense that its thrown error is caught and treated as a counterexample. But when unwrapping fails, `XCTUnwrap` records an XCTest failure via `XCTFail` before throwing, and that recording is expensive. A single `XCTFail` call costs several hundred milliseconds of XCTest framework overhead. During reduction, the property closure may be invoked hundreds of times with the failing input, and each invocation pays that cost. Exhaust emits a compile-time warning when it detects `XCTUnwrap` in a property closure. Prefer a guard with a thrown error:

```swift
// Slow.
func testUnwrap() {
    #exhaust(.int(in: 0...100).optional()) { value in
        let unwrapped = try XCTUnwrap(value)
        return unwrapped > 0
    }
}

// Fast.
func testUnwrap() {
    #exhaust(.int(in: 0...100).optional()) { value in
        guard let unwrapped = value else { throw UnwrapError() }
        return unwrapped > 0
    }
}
```

### #expect and #require inside closures

The `#expect`/`#require` interception that works under Swift Testing is not available under XCTest. Without it, a void-returning closure has no way to signal failure to Exhaust. The macro detects this and emits an error: "Closure has no failure mechanism; return a Bool or throw an error to signal failure."

This applies equally to sync and async closures.

## Differences from Swift Testing

| Feature | Swift Testing | XCTest |
|---|---|---|
| `#expect` / `#require` inside closures | Intercepted, suppressed during reduction, re-run once with reduced value | Not available; use Bool or throwing closures |
| Issue reporting | `Issue.record` at call site + `#expect` at assertion line | `XCTFail` at call site only |
| Traits (`.exhaust(.budget(...))`) | Supported on `@Test` and `@Suite` | Not available; use inline `.budget(...)` settings |
| Regression seeds | Via `.exhaust(.regressions(...))` trait | Not available via traits; use `.replay(...)` inline |
| Async closures | Bool, throwing, and `#expect` closures all supported | Bool and throwing closures supported; `#expect`/`#require` not available |
| Tags (`.propertyTest`) | Available for test plan filtering | Not applicable |
| OpenPBTStats | `Attachment.record` | `XCTAttachment` via `XCTContext.runActivity` |
