# Coverage-guided fuzzing

Give Exhaust a time budget and let it search for bugs by observing which branches your code takes.

> Experiment: `#explore(time:)` is experimental. Settings, report format, and search behavior may change in any release.

## Overview

`#exhaust` runs a property across boundary values and random samples, then stops. For most tests that's the right tradeoff: fast feedback, deterministic budget, done in well under a second. But the iteration budget is finite, and the values a generator usually produces may never reach some branches in your code.

`#explore(time:)` takes a wall-clock time budget instead. You compile the target under test with coverage instrumentation (see below), and Exhaust watches which branches each generated input reaches. Inputs that reach a branch nothing else has reached become the starting points for the next inputs. A thrown error or a failed `#expect` is a failure, and when Exhaust finds one it keeps going. When the budget runs out, it reports the distinct counterexamples it found, each reduced to a minimal form.

> Note: A run reports distinct reduced *counterexamples*, which is a lower bound on distinct faults rather than a count of them. Reduction keeps shrinking a failing input for as long as it keeps failing with the same symptom: the same thrown error type, or a `false` return. It does not check that the smaller input fails for the same reason. So a failure can reduce into the counterexample of a different bug with the same symptom, such as another `false` return or another case of the same error enum, and disappear from the report. Two bugs whose minimal forms differ are reported separately; a bug reachable only through inputs that reduce toward another bug may not appear at all.

```swift
@Test func parserHandlesAdversarialInput() async {
    await #explore(myInputGenerator, time: .seconds(20)) { input async in
        let result = try MyParser.parse(input)
        #expect(result.isWellFormed)
    }
}
```

The test reads like any other `#exhaust` test: a generator, a property, and `#expect` assertions. The differences are the `time:` parameter and the `async`/`await`.

The search holds one thread for the entire budget. Write the `async` form so that thread is not one of the cooperative pool's.

The recommended workflow is to run the test through the `explore` package command. It builds the selected root targets with instrumentation in a separate directory, then runs the selected tests. Manual instrumentation is also supported for tests that should run as part of the ordinary suite.

## Running a fuzzing campaign

Use Swift 6.4 or later and a version of Exhaust that provides the `explore` command. Add Exhaust as a direct dependency of the package you want to test; <doc:GettingStarted> covers adding the dependency. The command runs on macOS and Linux. Windows support is experimental pending native CI verification. The single-line commands below work in a Unix shell or PowerShell.

### 1. Add a fuzz test target

Keep campaign tests in a dedicated Swift test target so you can select them separately from your ordinary unit tests. For a library target named `MyLibrary`, add this entry to the `targets` array in `Package.swift`:

```swift
.testTarget(
    name: "MyLibraryFuzz",
    dependencies: [
        "MyLibrary",
        .product(name: "Exhaust", package: "exhaust"),
    ]
),
```

Leave the existing library and unit-test targets in place. You do not need to add a plugin declaration or coverage flags to any target. `explore` supplies instrumentation for the campaign through an ephemeral manifest overlay; it never edits your `Package.swift`. There is no setup command or hook to commit.

### 2. Write the property

Create `Tests/MyLibraryFuzz/IntegerCodecFuzzTests.swift`. This example assumes `MyLibrary` exposes `IntegerCodec.encode(_:)` and a throwing `IntegerCodec.decode(_:)`. Replace those calls with the API you want to exercise:

```swift
import Exhaust
import MyLibrary
import Testing

@Test func integerRoundTrip() async {
    await #explore(
        #gen(.int(in: -1_000_000...1_000_000)),
        time: .seconds(60),
        .replay(.numeric(1337))
    ) { value async in
        let encoded = IntegerCodec.encode(value)
        let decoded = try IntegerCodec.decode(encoded)
        #expect(decoded == value)
    }
}
```

The generator defines the inputs the search can explore; the property describes what must hold for every input. Here, encoding and decoding must recover the original integer. A thrown error or a failed `#expect` records a counterexample. The run reduces counterexamples and continues searching until its budget expires or it stops making progress. Add `.failFast` to stop after the first reduced failure.

Use the `async` test and `await #explore` form with an explicitly `async` property closure so the search can use its own thread. A synchronous closure selects the synchronous overload even if you write `await` before the macro. Keep the property's work on that execution lane; <doc:#When-the-run-cannot-see-the-code> explains the restrictions on actor and detached-task work.

The optional `.replay(.numeric(1337))` fixes the seed. Change it in the test to try another seed; the command has no `--seed` option. A seed helps reproduce a search under the same build and budget, but debug and release builds can follow different paths through the search.

### 3. Run a campaign

From the package directory, run:

```sh
swift package explore --instrument MyLibrary --test-target MyLibraryFuzz --filter integerRoundTrip --time 60
```

This builds the package's tests in a separate build directory, instruments `MyLibrary` and `MyLibraryFuzz`, and runs the selected property. Exhaust and other dependency targets keep their own build settings. The command automatically links the coverage runtime and test-reporting support; the test target needs only the dependencies shown above.

The default build configuration is **release**. To run the same property in debug:

```sh
swift package explore --instrument MyLibrary --test-target MyLibraryFuzz --filter integerRoundTrip --configuration debug --time 60
```

Once the property works, give mutation more time with a fifteen-minute campaign:

```sh
swift package explore --instrument MyLibrary --test-target MyLibraryFuzz --filter integerRoundTrip --time 900
```

`--time` overrides the budget of **each** `#explore(time:)` invocation, including state machine specs. It is not a limit on compilation or the whole test suite. Omit it to use the budget written in each test. Swift Testing time limits still apply, so increase an explicit `@Test` time limit when running a longer campaign.

These options belong to `explore` and go after its name:

| Option | Meaning |
|--------|---------|
| `--instrument <target>` | Instrument a Swift target in the root package. Required; repeat it for additional targets the property exercises. |
| `--test-target <target>` | Select one Swift test target. It is also instrumented automatically. May be omitted when the package has exactly one Swift test target. |
| `--filter <regex>` | Select matching tests within that target. Omit it to run all tests in the target. No matches is an error. |
| `--time <seconds>` | Override each invocation's budget with a positive whole number of seconds. |
| `--configuration debug\|release` | Choose the campaign's build configuration. Defaults to `release`. |
| `--help` | Show command usage. |

SwiftPM options such as `--package-path` and `--scratch-path` go before `explore`. No `--allow-writing-to-package-directory` flag is needed. SwiftPM builds the package's test bundle, including other test targets, but `explore` runs only the tests selected above.

### 4. Inspect findings and rerun

The command prints its build, attachment, and crash-recovery directories under `.build/plugins`, which remains inside the usual ignored `.build` directory. A custom SwiftPM `--scratch-path` relocates that workspace. Each invocation gets a new attachment directory; reports remain available even when a test fails.

Read the reduced counterexamples in the test output and open `explore-time-summary.txt` in the printed attachment directory for coverage and throughput. Per-cluster attachments contain further diagnostic detail. <doc:#Reading-the-report> explains the report and reproduction settings. A property failure, build error, or test-process crash makes the command exit unsuccessfully, so the same invocation can be used in CI.

Rerun the command after fixing a bug. If the previous process crashed, the command uses its stable checkpoint directory to recover and continue the campaign. Set `EXHAUST_RESUME=0` in your shell's environment for a fresh run. To relocate checkpoints, set `EXHAUST_STATE_DIR`; a location outside the plugin work directory also needs SwiftPM's `--allow-writing-to-directory <path>` permission. A lock prevents overlapping commands from using the same instrumentation selection and configuration.

### Keep campaigns separate from ordinary tests

A dedicated test target is still discovered by an ordinary `swift test`. When no instrumented module is loaded, `#explore(time:)` emits a runtime warning and returns without invoking the property or consuming its time budget. The returned report has `.instrumentationMissing` termination and zero attempts. The test can stay in the ordinary suite; the warning makes clear that no fuzzing took place. Code outside the macro still runs, including assertions on its report.

Compiler `-warnings-as-errors` does not promote this runtime warning to a test failure. To omit campaign tests and their warnings from the ordinary suite entirely, filter out the target:

```sh
swift test --skip MyLibraryFuzz
```

Use `swift package explore` for the campaign target. To include short fuzz properties in ordinary test runs instead, configure the manual instrumentation described below.

### Instrumentation scope and current limits

The command enables edge coverage, comparison tracing, and assertions for the selected targets in both debug and release. It instruments the calling test target too, so you do not need to add `@inline(never)` merely to keep calls from disappearing into an uninstrumented test module. Dependency code inlined or specialized into a selected module can still contribute coverage: selection is by compiled module, not by the original source of every function.

The overlay preserves relative dependency paths and the manifest's `#filePath`. This first version requires a top-level variable named `package` and a single `Package.swift`; version-specific manifests such as `Package@swift-6.4.swift` are rejected. You can select root Swift library, executable, and test targets. Dependency targets, C-family targets, macro targets, and binary targets cannot be selected. The command leaves Exhaust's coverage runtime uninstrumented.

## Setting up coverage instrumentation manually

`#explore(time:)` requires the code under test to be compiled with coverage instrumentation. When no instrumented module is loaded, it emits a runtime warning showing how to enable instrumentation and returns without invoking the property. No budget is consumed. An instrumented build whose property records no coverage still fails, because its campaign cannot observe the code under test.

The fuzz test lives in an ordinary test target and runs whenever the suite runs. Add the flags to the library under test, gated on the debug configuration the suite builds in. The flags are `unsafeFlags`, which SwiftPM accepts only in a root package, so they belong in the manifest of the package you are testing:

```swift
// Package.swift
.target(
    name: "MyLibrary",
    swiftSettings: [
        .unsafeFlags(
            ["-sanitize=fuzzer-no-link",
             "-sanitize-coverage=edge,trace-pc-guard,pc-table"],
            .when(configuration: .debug)
        ),
    ]
)
```

`-sanitize=fuzzer-no-link` enables fuzzing instrumentation without linking libFuzzer's runtime or entry point. Exhaust supplies the coverage callbacks and search loop. This flag works on both macOS and Linux; it does not enable AddressSanitizer or UndefinedBehaviorSanitizer.

`trace-pc-guard` records each run's coverage through a context bound to the run's own thread, so other tests running in the same process, and other `#explore(time:)` runs, do not disturb it. The suite needs no `.serialized` trait, no `--no-parallel`, and no filtering. Keep the budget short (a few seconds) so the suite stays fast; the search returns unused budget when it stops finding new branches.

If the function under test lives in the test target itself, put the flags on the test target instead.

When the run cannot see the code it is testing, it says so: a run that records no coverage at all fails with a diagnostic naming the causes, and a run whose property does some of its work on another executor reports how many edge hits it missed. <doc:#When-the-run-cannot-see-the-code> explains both messages.

## How a time-bounded run works

Exhaust runs the property in three phases:

1. **Screening.** The boundary catalogue `#exhaust` tries first (integer min/max/zero, IEEE 754 sentinels, Unicode edge cases), combined by the covering array sampler. Screening stops at its own row cap, the end of the covering array, or the time budget, whichever comes first. Inputs that reach new branches are kept.
2. **Sampling.** Random generation, as in `#exhaust`, until new branches stop appearing or 10% of the budget has elapsed.
3. **Mutation.** Exhaust modifies inputs that reached interesting branches (the corpus). A modified input that reaches a branch nothing in the corpus has reached joins the corpus and is modified in turn. A fraction of attempts is spent on fresh generation rather than mutation, and that fraction grows while the corpus stops admitting new inputs and falls back once discoveries resume, so the search keeps probing beyond the corpus's neighbourhood for the whole run. This continues until the budget runs out or new branches stop appearing.

Failures at any phase are reduced to minimal counterexamples and catalogued. The run does not stop at the first failure.

## Reading the report

When a run discovers faults, the terminal shows a summary. This is real output from a run against an instrumented parser fixture, seed 1, with an eight-second budget:

```
#explore(time:) found at least 4 distinct failures in 4.2s (189233 inputs tried).

1. WindowError, first seen at 0.0s
   Message(mode: .heartbeat, flags: 0, checksum: 0, region: 6, payload: [])
   likely in Parser.decode, decodeHeartbeat, validateWindow (Parser.swift)

2. IntegrityError, first seen at 0.0s
   Message(mode: .data, flags: 3, checksum: 0, region: 5, payload: [0, 0])
   likely in integrityCheck (Parser.swift:121)

3. ChecksumError, first seen at 0.1s
   Message(mode: .handshake, flags: 0, checksum: 65535, region: 0, payload: [])
   likely in Parser.decode (Parser.swift), checkChecksum (Parser.swift), ChecksumError.init (Parser.swift:9)

4. IntegrityError, first seen at 0.2s
   Message(mode: .control, flags: 12, checksum: 0, region: 2, payload: [241])
   likely in integrityCheck (Parser.swift:121)

Stopped 3.8s early: the search had stopped reaching new code, so a longer run is unlikely to find more.
Reproduce: .replay(1)
Coverage, throughput, and full suspect lists are in the explore-time-summary.txt attachment.
```

**Each numbered entry is one distinct failure.** Failures whose inputs reduce to the same minimal counterexample are counted once, so the count is a floor: two different bugs whose inputs happen to reduce to the same form appear as one entry. Entries 2 and 4 above throw the same error from the same line and are still listed separately, because their reduced inputs differ. Throw distinct errors when you want distinct entries; a property that returns `false` gives every failure the same name.

**`first seen at` is when the search first hit that failure.** An entry found late in the run, marked `late`, is the strongest sign that a longer run would find more.

**`likely in` names where to look.** When one function's branches separate this failure's inputs from passing ones and resolve to a line, that function is named alone. When no suspect resolves to a line, the top three are listed in rank order, outermost first, because without a line the ranking cannot tell an entry point from the branch beneath it. The attachment carries the ranked list for every entry.

**The line before `Reproduce` answers "should I run longer?".** A run that stopped early had stopped reaching new branches. A run that used its whole budget says how long before the end it last reached new code: if that was recent, give it more time.

**The seed is for replay.** Pass it as `.replay(1)` to rerun from the same starting point. Isolation matters doubly for replay: a replay that sees different coverage takes a different path.

**The attachments hold the numbers.** `explore-time-summary.txt` carries the search's own figures for the same run: attempts per second, the share of each attempt spent outside your property, how many of the module's instrumented branches the run reached, the estimated number it could reach, and each entry's membership and discovery phase. `explore-time-cluster-N.txt` has entry N's full ranked list of suspect branches. Find them in Xcode's result bundle or wherever your runner collects attachments. Two of those figures need a caveat. The branch count is the module's, most of which this property can never reach, so a low fraction is expected. The reachable estimate is a statistical lower bound that only prints once the run has seen enough repeat coverage; on short runs it usually does not.

For the spec form the report has the same structure, but each entry's reduced counterexample is a command sequence:

```
1. BoundedQueueError, first seen at 0.3s
   [.enqueue(value: 0), .clear, .enqueue(value: 0), .clear]
   likely in BoundedQueue.clear (BoundedQueue.swift:123)
```

## Inputs the property cannot judge

A property with a precondition should throw `PropertySkip` (or `XCTSkip`) for an input that does not meet it, the same way it would under `#exhaust`. Under `#explore(time:)` a skipped input is a *discard*: not a failure, not a pass, and not thrown away either. Its coverage is recorded, and when it reached a branch nothing else has, it stays in the corpus as a mutation parent at a third of the weight of a valid input. On a property whose precondition random generation rarely satisfies, this is how the search finds valid inputs at all: a near miss is mutated toward one, where fresh generation would keep missing. The summary reports the share of inputs the property skipped.

Returning `true` for an input that does not meet the precondition hides it from the search and counts it as a pass; throw instead.

## Settings

Pass settings as variadic arguments after the time budget:

```swift
await #explore(myInputGenerator, time: .minutes(15), .replay(20260710), .log(.info)) { input in
    let result = try MyParser.parse(input)
    #expect(result.isWellFormed)
}
```

The generator form takes ``PropertyFuzzSettings``. The spec form takes ``StateMachineFuzzSettings``, which adds the two spec-only rows. Writing a spec-only setting on a generator does not compile.

| Setting | Effect |
|---------|--------|
| `.replay(seed)` | Replays a prior run's search from its seed. Pass the seed from a report's `Reproduce:` line. |
| `.suppress(.issueReporting)` | Silences test failures. Use when asserting on the returned ``FuzzReport`` directly. |
| `.suppress(.logs)` | Silences log output. |
| `.suppress(.attachments)` | Stops the run recording its per-cluster and summary attachments. Use when a test loops fuzz runs and the attachments would only accumulate noise in the result bundle. |
| `.suppress(.all)` | All of the above. |
| `.log(.info)` | Raises log verbosity (default is `.error`). |
| `.failFast` | Stops the run at its first fault, after reducing it, instead of cataloguing further distinct counterexamples. Use where any failure fails the run, such as a merge gate. |
| `.skipScreening` | Starts the search at random sampling, skipping the boundary catalogue. Use for a property whose precondition discards nearly every boundary row, or to compare runs from identical starting conditions. The spec form always skips screening, so there it changes nothing. |
| `.commandLimit(n)` | Maximum commands per generated sequence. Default 40. Spec form only. |
| `.parallelize(lanes:)` | Lane count for `.tasks` specs. Default two. Spec form only. |

## Choosing a time budget

Short budgets (seconds to a minute) confirm the instrumentation works and show what screening and sampling find. They are the right size for a fuzz test that lives in the wider suite, where a short budget makes it cheap to run routinely.

Longer budgets (five to thirty minutes) give mutation time to work. A fifteen-minute run on an M-series machine makes hundreds of thousands of attempts.

Overnight budgets (hours) suit nightly CI. Treat the budget as a maximum: the run returns whatever it does not need. The line before `Reproduce` in the summary answers "would a longer run find more?". A run that stopped early had stopped reaching new branches and new faults well before it ended. A run that used the whole budget and was still reaching new code near the end is the one to give more time. The reachability estimate in the summary attachment describes the same thing statistically and is unreliable on short runs, so do not steer by it alone.

## Early termination

If the mutation phase goes a sustained window without reaching a new branch or classifying a new fault, the run stops early and returns the unused budget. The window is at least thirty seconds and grows with the budget, so a long run waits longer after its last discovery before giving up. The summary states how much time was returned and why.

A plateau does not mean the code is bug-free. Bugs on already-covered paths are still possible. The plateau means the search can no longer reach new branches from the inputs it has.

## Asserting on the report

To assert on the outcome programmatically, suppress issue reporting and inspect the returned ``FuzzReport``:

```swift
@Test func parserHasNoUnhandledFailures() async {
    let report = await #explore(
        myInputGenerator,
        time: .minutes(5),
        .suppress(.issueReporting)
    ) { input in
        let result = try MyParser.parse(input)
        #expect(result.isWellFormed)
    }
    #expect(report.clusters.isEmpty)
}
```

## Fuzzing a state machine spec

The same coverage-guided search works over `@StateMachine` specs. Pass the spec in place of the generator and add the `mode:` its commands should run under. Exhaust then mutates command sequences where it would otherwise mutate values, deleting, duplicating, and replacing commands as it searches.

```swift
@Test func boundedQueueDeepFaults() async {
    await #explore(BoundedQueueSpec.self, mode: .sequential, time: .minutes(5))
}
```

The spec form skips screening, since the boundary catalogue describes values and a command sequence has none, and begins with random sampling. Exhaust prunes commands whose preconditions fail from the stored sequence, so mutation does not keep resurrecting operations that do nothing.

Sequences carry up to 40 commands by default. Override with `.commandLimit(n)` when the default is too short to reach deep state, or to shorten sequences when each command is expensive.

### Execution model support

| Mode | Status |
|-------|--------|
| `mode: .sequential` | Supported, for both synchronous and async specs. `mode:` is required. Pass `.sequential` to run one command at a time. |
| `mode: .tasks` | Supported for async specs. Requires macOS 15, iOS 18, tvOS 18, watchOS 11, or visionOS 2; no version requirement on Linux and Windows. The search mutates commands and their lane assignments, and reduction minimises concurrency back toward one command at a time. `.parallelize(lanes:)` sets the lane count (default two). |
| `mode: .threads` | Not available; it does not compile. Coverage under thread scheduling depends on an OS schedule the run cannot replay. See below for alternatives. |

Under `.threads` the same command sequence takes different branches depending on how the OS interleaves the lanes, so coverage stops describing the input and the search chases the scheduler. To search interleavings, use `mode: .tasks`, where the lane assignment is part of the generated input and is mutated, replayed, and reduced with it. To find data races, run the spec under `#execute` with `mode: .threads`, which relies on repetition rather than coverage.

## Running in a dedicated target

The campaign workflow above uses a dedicated test target and instruments both the library and its calling test module. It keeps assertions active in release builds and leaves ordinary builds unchanged.

For a **manual** release build, apply the coverage flags and `-assert-config Debug` to both modules, and gate them on an explicit fuzzing opt-in. A separate test target alone does not prevent flags on a shared library from affecting ordinary builds.

### When the fuzz target and the code under test share a build

When configuring instrumentation manually, instrumenting only the library can lose coverage under release optimization if its code is inlined into an uninstrumented caller. The `explore` command instruments the test target too to cover this case. The compiler inlines small public functions from the instrumented library into the uninstrumented caller, and each inlined copy is compiled under the caller's flags: no guards, no comparison callbacks. The functions still compute correctly; they just vanish from the coverage signal. If everything the property touches is inlined away, the run fails with the no-coverage diagnostic. If only some helpers are, nothing fails: the search runs on a partial signal and comparison tracing sees none of the swallowed comparisons, with no indication anything is missing. Only a prebuilt binary dependency is out of the optimiser's reach.

If you deliberately leave the caller uninstrumented, marking the library's public entry points `@inline(never)` keeps those calls in the instrumented module. This is an option for a manual configuration, not a requirement for the command workflow. A cheap way to verify is a canary property: an equality check against a wide constant inside the instrumented module, run under `trace-cmp` for a few seconds. Solved almost immediately means edges and comparison operands are flowing end to end; unsolved means the boundary is being inlined away.

### When the code under test is a dependency you cannot edit

Pass the flags on the command line instead. This instruments every module in the build graph, Exhaust included, which costs roughly 8–30 µs per attempt on top of the property (more for complex generators) and makes the report's edge count describe the whole graph rather than your code:

```bash
swift test -c release \
    -Xswiftc -sanitize=fuzzer-no-link \
    -Xswiftc -sanitize-coverage=edge,trace-pc-guard,pc-table \
    -Xswiftc -assert-config -Xswiftc Debug \
    --filter MyLibraryFuzz
```

Use `trace-pc-guard` here; a whole-graph build with `inline-8bit-counters` spends most of each attempt clearing and rescanning a table of every module's counters and is not a usable configuration.

### Adding comparison tracing (optional)

> Experiment: Comparison tracing is experimental and may change or be removed in any release.

Some branches depend on a value the generator will almost never produce by chance: an equality against a wide constant (`token == 0x5F3759DF`), a parsed magic number, a specific string. Every wrong value takes the same branch, so coverage cannot tell the search it is getting closer. With `trace-cmp` in the coverage flags, Exhaust reads the operands of the code's own comparisons and feeds them back into the search in two ways. Where a stored input contains an integer choice whose type and declared range can hold the operand, Exhaust writes the operand into that choice directly and tries the result — or into several matching choices at once, for a precondition that needs many positions to agree before it is satisfied. Where the generator is reflective, Exhaust also works backward through the generator to the choices that produce the wanted value, which covers whole values, strings, and structs compared field by field.

It helps where the wanted value is rare — a byte or a printable character sees no benefit on its own, because ordinary generation already produces every value there — and where several generated values must agree at once, which random draws rarely deliver even over a small domain.

`explore` enables comparison tracing automatically. For manual instrumentation, append `trace-cmp` to the coverage list in the per-target flags:

```swift
.unsafeFlags(
    ["-sanitize=fuzzer-no-link",
     "-sanitize-coverage=edge,trace-pc-guard,pc-table,trace-cmp"],
    .when(configuration: .debug)
)
```

or on the command line:

```bash
swift test \
    -Xswiftc -sanitize=fuzzer-no-link \
    -Xswiftc -sanitize-coverage=edge,trace-pc-guard,pc-table,trace-cmp
```

Backward solving needs a reflective generator, one Exhaust can run backward from a value to the choices that produced it; `#examine` reports whether a generator is reflective. A forward-only `map` breaks the chain, and direct substitution then carries the operands alone, reaching integer choices only. The flag itself costs almost nothing in throughput.

## When the run cannot see the code

Two runtime messages cover this, so a run that is blind does not pass quietly.

- **No coverage at all.** The run fails with a diagnostic. In a release build the usual cause is the compiler inlining the code under test into a module that has no coverage flags; the fix is to instrument the calling module too, as the dedicated-target recipe does. Otherwise the property's work ran on an executor the run did not bind.
- **Some coverage missed.** The summary reports "N edge hits fired off the run's lane and were not searched". Either the property handed work to another executor, or another test exercised the same instrumented code at the same time; the count cannot tell which, so read it against what the suite was doing.

Behind both: `trace-pc-guard` records through a context bound to the running lane. That is what lets separate runs share a process, and it is also the limitation: a `@MainActor` function, an actor with a custom executor, or work inside a detached task runs somewhere else, and its branches are not recorded. Measured on the same five-branch function reached four ways:

| the property's work runs | counters | guards |
|---|---|---|
| directly, on the run's lane | recorded | recorded |
| inside a default actor | recorded | recorded |
| inside a `@MainActor` function | recorded | **not recorded** |
| inside a detached task | recorded | **partly recorded** |

A default actor is fine because it has no executor of its own and adopts the calling task's, which is the run's lane.

Two shapes are prevented at compile time rather than left to fail quietly. A property closure cannot be marked `@MainActor`, because the parameter is nonisolated. A `@Command` cannot be marked `@MainActor`, because synthesised command dispatch is nonisolated. So this is reached by a nonisolated property that `await`s main-actor work, not by annotating the test.

### Counter-based instrumentation

`inline-8bit-counters`, used **in place of** `trace-pc-guard`, writes to a process-global table instead of a per-run context. A build carrying both is refused with a configuration error: the two recorders number their edges independently, so a run reads one of them, and nothing in the build says which. Check every target in the dependency graph, since flags on a library and different flags on the test target put both into one process. It records work wherever it runs, including on executors the run did not bind (a `@MainActor` function, an actor with a custom executor, a detached task), which `trace-pc-guard` cannot see. The cost is that the table is shared by the whole process: two coverage-guided runs in one process clear each other's counters, and any other test executing instrumented code during an attempt pollutes the signal. A counter build therefore needs the process to itself: `swift test --no-parallel`, or a filter down to one fuzz test. Reach for counters only when the system under test does its work off the run's lane, as the table above shows.

## Getting a clean signal

The search is driven by one signal: the set of branches each attempt reached (its coverage signature). It decides what enters the corpus, what gets mutated next, and when the run stops. Three conditions, all yours to control, decide how much of that signal is real.

### Nothing else in the process (counter builds only)

This condition applies to `inline-8bit-counters` builds. A `trace-pc-guard` build records through a per-run context, so other tests in the process cannot reach it and this section does not apply.

The branch counters are shared by the whole process, and Exhaust measures one attempt at a time: it zeroes the counters, runs the property once, and reads back what was hit. Any other code executing in an instrumented module during that window is indistinguishable from the property's own behaviour.

Only code running *during* an attempt matters. Each attempt re-zeroes the counters, so a test that finished earlier cannot affect it. `.serialized` alone does not give you that: it orders tests within one suite, but other suites still run concurrently and can cross-pollute.

Either run the whole target with `swift test --no-parallel`, or filter each run down to a single fuzz test. Filtering is stronger: a finished test can still have background work running (a detached task, an unawaited timer), and an empty process has nothing to leak.

Pollution only adds branches, never removes them. The result is inputs admitted for novelty they did not earn, a search that wanders, and a replay that cannot follow the original run.

### Instrument only the code under test

Coverage is recorded while the property runs and nowhere else, so generating the input costs nothing in signal. Everything the property itself executes inside an instrumented module counts. Instrumenting modules beyond the code under test adds branches (the report counts them as edges) that say nothing about the property, and an input can look novel for reaching one in a helper library. Prefer the per-target flags, on the narrowest set of targets that covers the code the property exercises. In a release build that set includes the module calling the code under test, for the inlining reason given under <doc:#Running-in-a-dedicated-target>.

### Replay under the conditions of the original run

The seed pins every decision the search makes: the screening rows, the sampling stream, and each mutation choice. What the search observes between decisions is environmental: coverage comes from the process counters, and phase transitions are wall-clock cuts. Give a replay the same build (recompiled code moves branches), the same isolation, and at least the original budget, and expect it to rediscover the same clusters rather than an attempt-for-attempt identical log.

One exception: after a crash, the rerun resumes from the crash checkpoint even when `.replay` is passed, because a trapping input is worth more than a faithful rerun. Set `EXHAUST_RESUME=0` when reproduction matters more. The crash state is then discarded.

## Crash recovery

A fuzzing run can find an input that traps: a `fatalError`, a failed precondition, an out-of-bounds subscript. A trap kills the test process and any report with it, so Exhaust checkpoints its progress to disk during the run: the corpus, the clusters found so far, and which input is being evaluated.

Rerun the test and Exhaust reports the trapping input (or the input it was mutated from, when the trapping input was never stored), quarantines that region so mutation does not immediately rediscover it, and continues the search from the restored corpus for the rest of the budget.

Whether the checkpoint stores the trapping candidate itself, or only identifies it by hash and names the input it was mutated from, follows the budget. Runs of ten minutes or longer store it; shorter runs do not, because a short run is cheap to reproduce by running it again and a long campaign is not. Storing the candidate writes it on every property invocation, which cost about 8% of candidate throughput on a search evaluating tens of thousands of inputs a second, so throughput steps down at that boundary.

With `explore`, checkpoints live in the printed crash-recovery directory under its build workspace. With manual instrumentation, they default to the system temporary directory. They are removed when a run completes normally. Set `EXHAUST_STATE_DIR` to relocate them, for example on CI where each step gets a fresh temporary directory. Set `EXHAUST_RESUME=0` to ignore a crashed predecessor's state and start fresh.

If the instrumented code changed between crash and rerun, Exhaust re-measures the restored inputs against the rebuilt code before resuming.

Checkpoints are keyed by test file and line, not by process. Two processes fuzzing the same test at once (a local run beside a CI runner on a shared temporary directory, or two concurrent `swift test` invocations) overwrite each other's checkpoints and can misread each other's crash state. Give each its own `EXHAUST_STATE_DIR`.

## Topics

### Settings and Results

- ``PropertyFuzzSettings``
- ``StateMachineFuzzSettings``
- ``FuzzReport``
- ``TimeSpan``
