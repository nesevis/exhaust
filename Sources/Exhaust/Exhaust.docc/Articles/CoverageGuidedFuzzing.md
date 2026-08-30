# Coverage-guided fuzzing

Give Exhaust a time budget and let it search for bugs by observing which branches your code takes.

> Experiment: `#explore(time:)` is experimental. Settings, report format, and search behaviour may change in any release. Every call site emits a build warning until the mode stabilises.

## Overview

`#exhaust` runs a property across boundary values and random samples, then stops. For most tests that's the right tradeoff: fast feedback, deterministic budget, done in well under a second. But the iteration budget is finite, and the values a generator usually produces may never reach some branches in your code.

`#explore(time:)` takes a wall-clock time budget instead. You compile the target under test with coverage instrumentation (see below), and Exhaust watches which branches each generated input reaches. Inputs that reach a branch nothing else has reached become the starting points for the next inputs. A thrown error or a failed `#expect` is a failure, and when Exhaust finds one it keeps going. When the budget runs out, it reports the distinct counterexamples it found, each reduced to a minimal form.

> Note: A run reports distinct reduced *counterexamples*, which is a lower bound on distinct faults rather than a count of them. Reduction keeps shrinking a failing input for as long as it keeps failing, and it does not require the smaller input to fail for the same reason. So a failure can reduce into a different bug's counterexample and disappear from the report. Two bugs whose minimal forms differ are reported separately; a bug reachable only through inputs that reduce toward another bug may not appear at all.

```swift
@Test func parserHandlesAdversarialInput() async {
    await #explore(myInputGenerator, time: .seconds(20)) { input in
        let result = try MyParser.parse(input)
        #expect(result.isWellFormed)
    }
}
```

The test reads like any other `#exhaust` test: a generator, a property, and `#expect` assertions. The differences are the `time:` parameter and the `async`/`await`.

The search holds one thread for the entire budget. Write the `async` form so that thread is not one of the cooperative pool's.

Two ways to run it are covered here. The setup below puts a fuzz test in your ordinary suite with a budget of seconds; <doc:#Running-in-a-dedicated-target> covers a fuzz-only target with a release build and a long budget.

## Setting up coverage instrumentation

`#explore(time:)` requires the code under test to be compiled with coverage instrumentation. Without it, the test fails immediately with a diagnostic showing the flags to add. No budget is consumed.

The fuzz test lives in an ordinary test target and runs whenever the suite runs. Add the flags to the library under test, gated on the debug configuration the suite builds in. The flags are `unsafeFlags`, which SwiftPM accepts only in a root package, so they belong in the manifest of the package you are testing:

```swift
// Package.swift
.target(
    name: "MyLibrary",
    swiftSettings: [
        .unsafeFlags(
            ["-sanitize=undefined",
             "-sanitize-coverage=edge,trace-pc-guard,pc-table"],
            .when(configuration: .debug)
        ),
    ]
)
```

`trace-pc-guard` records each run's coverage through a context bound to the run's own thread, so other tests running in the same process, and other `#explore(time:)` runs, do not disturb it. The suite needs no `.serialized` trait, no `--no-parallel`, and no filtering. Keep the budget short (a few seconds) so the suite stays fast; the search returns unused budget when it stops finding new branches.

If the function under test lives in the test target itself, put the flags on the test target instead.

When the run cannot see the code it is testing, it says so: a run that records no coverage at all fails with a diagnostic naming the causes, and a run whose property does some of its work on another executor reports how many edge hits it missed. <doc:#When-the-run-cannot-see-the-code> explains both messages.

## How a time-bounded run works

Exhaust runs the property in three phases:

1. **Screening.** The boundary catalogue `#exhaust` tries first (integer min/max/zero, IEEE 754 sentinels, Unicode edge cases), combined by the covering-array sampler. Screening stops at its own row cap, the end of the covering array, or the time budget, whichever comes first. Inputs that reach new branches are kept.
2. **Sampling.** Random generation, as in `#exhaust`, until new branches stop appearing or 10% of the budget has elapsed.
3. **Mutation.** Exhaust modifies inputs that reached interesting branches (the corpus). A modified input that reaches a branch nothing in the corpus has reached joins the corpus and is modified in turn. This continues until the budget runs out or new branches stop appearing.

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

A fuzz-only test target, built in release configuration and run by itself with a long budget. Release runs several times more attempts per second than debug on the same property, which is the point of a dedicated run. Three things change relative to the suite recipe:

1. **The flags apply in release and on both the library and the test target.** In an optimised build the compiler inlines small functions from the library into the module that calls them. An inlined copy is compiled as part of the calling module, so if only the library carries the flags, those copies have no instrumentation and the branches they contain are never recorded. Instrumenting the test target as well closes that gap.
2. **`-assert-config Debug` keeps `assert` and `assertionFailure` active.** Release compiles them out; without this flag any oracle your code expresses through `assert` disappears from the fuzz run. `precondition` and `fatalError` are unaffected.
3. **Build and run with `-c release`.**

```swift
// Package.swift
let fuzzFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-sanitize=undefined",
        "-sanitize-coverage=edge,trace-pc-guard,pc-table",
        "-assert-config", "Debug",
    ]),
]

.target(name: "MyLibrary", swiftSettings: fuzzFlags),
.testTarget(name: "MyLibraryFuzz", dependencies: ["MyLibrary"], swiftSettings: fuzzFlags),
```

```bash
swift test -c release --filter MyLibraryFuzz
```

The flags are not gated on a configuration here because the dedicated target is only ever built for fuzzing. If the same library also serves the suite recipe, keep the debug-gated flags there too; the two do not conflict.

### When the code under test is a dependency you cannot edit

Pass the flags on the command line instead. This instruments every module in the build graph, Exhaust included, which costs roughly 8–30 µs per attempt on top of the property (more for complex generators) and makes the report's edge count describe the whole graph rather than your code:

```bash
swift test -c release \
    -Xswiftc -sanitize=undefined \
    -Xswiftc -sanitize-coverage=edge,trace-pc-guard,pc-table \
    -Xswiftc -assert-config -Xswiftc Debug \
    --filter MyLibraryFuzz
```

Use `trace-pc-guard` here; a whole-graph build with `inline-8bit-counters` spends most of each attempt clearing and rescanning a table of every module's counters and is not a usable configuration.

### Adding comparison tracing (optional)

> Experiment: Comparison tracing is experimental and may change or be removed in any release.

Some branches depend on a value the generator will almost never produce by chance: an equality against a wide constant (`token == 0x5F3759DF`), a parsed magic number, a specific string. Every wrong value takes the same branch, so coverage cannot tell the search it is getting closer. With `trace-cmp` in the coverage flags, Exhaust reads the operands of the code's own comparisons and works backward through the generator to the choices that produce the wanted constant (input-to-state solving, as in AFL++'s RedQueen). It works for whole values and for structs compared field by field.

It helps only where the wanted value is rare. A byte or a printable character sees no benefit, because ordinary generation already produces every value there.

Append `trace-cmp` to the coverage list, in the per-target flags:

```swift
.unsafeFlags(
    ["-sanitize=undefined",
     "-sanitize-coverage=edge,trace-pc-guard,pc-table,trace-cmp"],
    .when(configuration: .debug)
)
```

or on the command line:

```bash
swift test \
    -Xswiftc -sanitize=undefined \
    -Xswiftc -sanitize-coverage=edge,trace-pc-guard,pc-table,trace-cmp
```

Solving needs a reflective generator, one Exhaust can run backward from a value to the choices that produced it. `#examine` reports whether a generator is reflective. A forward-only `map` breaks the chain, and Exhaust then ignores the operand. The flag itself costs almost nothing in throughput.

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

`inline-8bit-counters`, added to the flag list beside `trace-pc-guard` or in its place, writes to a process-global table instead of a per-run context. When both recorders are compiled in, Exhaust uses the counters. It records work wherever it runs, including on executors the run did not bind (a `@MainActor` function, an actor with a custom executor, a detached task), which `trace-pc-guard` cannot see. The cost is that the table is shared by the whole process: two coverage-guided runs in one process clear each other's counters, and any other test executing instrumented code during an attempt pollutes the signal. A counter build therefore needs the process to itself: `swift test --no-parallel`, or a filter down to one fuzz test. Reach for counters only when the system under test does its work off the run's lane, as the table above shows.

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

Checkpoints live in the system temporary directory and are removed when a run completes normally, so there is nothing to add to `.gitignore`. Set `EXHAUST_STATE_DIR` to relocate them, for example on CI where each step gets a fresh temporary directory. Set `EXHAUST_RESUME=0` to ignore a crashed predecessor's state and start fresh.

If the instrumented code changed between crash and rerun, Exhaust re-measures the restored inputs against the rebuilt code before resuming.

Checkpoints are keyed by test file and line, not by process. Two processes fuzzing the same test at once (a local run beside a CI runner on a shared temporary directory, or two concurrent `swift test` invocations) overwrite each other's checkpoints and can misread each other's crash state. Give each its own `EXHAUST_STATE_DIR`.

## Topics

### Settings and Results

- ``PropertyFuzzSettings``
- ``StateMachineFuzzSettings``
- ``FuzzReport``
- ``TimeSpan``
