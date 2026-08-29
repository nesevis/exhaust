# Coverage-guided fuzzing

Give Exhaust a time budget and let it search for bugs by observing which branches your code takes.

> Experiment: `#explore(time:)` is experimental. Settings, report format, and search behaviour may change in any release. Every call site emits a build warning until the mode stabilises.

## Overview

`#exhaust` runs a property across boundary values and random samples, then stops. For most tests that's the right tradeoff: fast feedback, deterministic budget, done in well under a second. But the iteration budget is finite, and the values a generator usually produces may never reach some branches in your code.

`#explore(time:)` takes a wall-clock time budget instead. You compile the target under test with coverage instrumentation (see below), and Exhaust watches which branches each generated input reaches. Inputs that reach a branch nothing else has reached become the starting points for the next inputs. A thrown error or a failed `#expect` is a failure, and when Exhaust finds one it keeps going. When the budget runs out, it reports every distinct fault it found, each reduced to a minimal counterexample.

```swift
@Test func parserHandlesAdversarialInput() async {
    await #explore(myInputGenerator, time: .minutes(15)) { input in
        let result = try MyParser.parse(input)
        #expect(result.isWellFormed)
    }
}
```

The test reads like any other `#exhaust` test: a generator, a property, and `#expect` assertions. The differences are the `time:` parameter and the `async`/`await`.

The search holds one thread for the entire budget. Write the `async` form so that thread is not one of the cooperative pool's.

> Important: Fuzz tests must run in isolation. Give them their own test target, mark the suite `.serialized`, and for the strongest signal filter each run down to one fuzz test (`swift test --filter FuzzTests.fuzzMyLibrary`). This also keeps minute-scale budgets out of everyday `swift test` runs. <doc:#Getting-a-clean-signal> explains why.

## What the search can and cannot see

Coverage is recorded against the lane the run owns. Work that executes on an executor the run did not bind is invisible to the search, and the two instrumentation modes differ in exactly this respect.

`inline-8bit-counters` writes to a process-global table, so it records work wherever it runs. The cost is that the table is shared: two coverage-guided runs in one process clear each other's counters, which is why a counter build needs `swift test --no-parallel`.

`trace-pc-guard` records through a context bound to the running lane. That is what lets separate runs share a process, and it is also the limitation: a `@MainActor` function, an actor with a custom executor, or work inside a detached task runs somewhere else, and its branches are not recorded.

Measured on the same five-branch function reached four ways:

| the property's work runs | counters | guards |
|---|---|---|
| directly, on the run's lane | recorded | recorded |
| inside a default actor | recorded | recorded |
| inside a `@MainActor` function | recorded | **not recorded** |
| inside a detached task | recorded | **partly recorded** |

A default actor is fine because it has no executor of its own and adopts the calling task's, which is the run's lane.

Two shapes are prevented at compile time rather than left to fail quietly. A property closure cannot be marked `@MainActor`, because the parameter is nonisolated. A `@Command` cannot be marked `@MainActor`, because synthesised command dispatch is nonisolated. So this is reached by a nonisolated property that `await`s main-actor work, not by annotating the test.

When a run records nothing at all, it stops early and says so rather than spending the budget, and names the counter flags as the way to record the work it could not see. Partial loss has no such signal: a property that does some work on the lane and some on the main actor reports plausible coverage while a region of the code is never searched. If the system under test is main-actor isolated, prefer counter-based instrumentation and give the run the process to itself.

## Setting up coverage instrumentation

`#explore(time:)` requires the target under test to be compiled with coverage instrumentation. Without it, the test fails immediately with a diagnostic showing the flags to add. No budget is consumed.

Add the flags in your manifest when you control the target, or on the command line when you don't.

### Per-target instrumentation (the common case)

When the library under test is a target in your own manifest, add the flags to its `swiftSettings`:

```swift
// Package.swift
.target(
    name: "MyLibrary",
    swiftSettings: [
        .unsafeFlags(
            ["-sanitize=undefined",
             "-sanitize-coverage=edge,inline-8bit-counters,pc-table"],
            .when(configuration: .debug)
        ),
    ]
)
```

The flags go on the library target, not the test target: Exhaust tracks branches inside the instrumented code.

If you are testing a function that lives in the test target itself, put the flags on the test target instead.

### Whole-graph instrumentation via the CLI

When the target you want instrumented is a dependency you cannot add `swiftSettings` to, pass the flags at the command line instead:

```bash
swift test --no-parallel \
    -Xswiftc -sanitize=undefined \
    -Xswiftc -sanitize-coverage=edge,inline-8bit-counters,pc-table
```

This instruments every module in the build graph. `--no-parallel` keeps other suites out of the coverage counters mid-run (<doc:#Getting-a-clean-signal> explains why `.serialized` alone is not enough). Gate the fuzz suite on an environment variable so an uninstrumented `swift test` skips it instead of tripping the missing-instrumentation diagnostic:

```swift
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FUZZ"] == "1"))
struct FuzzTests {
    @Test func fuzzMyLibrary() async {
        await #explore(gen, time: .minutes(5)) { value in
            try myProperty(value)
        }
    }
}
```

Then invoke with:

```bash
FUZZ=1 swift test --no-parallel \
    -Xswiftc -sanitize=undefined \
    -Xswiftc -sanitize-coverage=edge,inline-8bit-counters,pc-table \
    --filter FuzzTests
```

### Adding comparison tracing (optional)

> Experiment: Comparison tracing is experimental and may change or be removed in any release.

Some branches depend on a value the generator will almost never produce by chance: an equality against a wide constant (`token == 0x5F3759DF`), a parsed magic number, a specific string. Every wrong value takes the same branch, so coverage cannot tell the search it is getting closer. With `trace-cmp` in the coverage flags, Exhaust reads the operands of the code's own comparisons and works backward through the generator to the choices that produce the wanted constant (input-to-state solving, as in AFL++'s RedQueen). It works for whole values and for structs compared field by field.

It helps only where the wanted value is rare. A byte or a printable character sees no benefit, because ordinary generation already produces every value there.

Append `trace-cmp` to the coverage list, in the per-target flags:

```swift
.unsafeFlags(
    ["-sanitize=undefined",
     "-sanitize-coverage=edge,inline-8bit-counters,pc-table,trace-cmp"],
    .when(configuration: .debug)
)
```

or on the command line:

```bash
swift test --no-parallel \
    -Xswiftc -sanitize=undefined \
    -Xswiftc -sanitize-coverage=edge,inline-8bit-counters,pc-table,trace-cmp
```

Solving needs a reflective generator, one Exhaust can run backward from a value to the choices that produced it. `#examine` reports whether a generator is reflective. A forward-only `map` breaks the chain, and Exhaust then ignores the operand. The flag itself costs almost nothing in throughput.

## How a time-bounded run works

Exhaust runs the property in three phases:

1. **Screening.** The boundary catalogue `#exhaust` tries first (integer min/max/zero, IEEE 754 sentinels, Unicode edge cases), combined by the covering-array sampler. Screening stops at its own row cap, the end of the covering array, or the time budget, whichever comes first. Inputs that reach new branches are kept.
2. **Sampling.** Random generation, as in `#exhaust`, until new branches stop appearing or 10% of the budget has elapsed.
3. **Mutation.** Exhaust modifies inputs that reached interesting branches (the corpus). A modified input that reaches a branch nothing in the corpus has reached joins the corpus and is modified in turn. This continues until the budget runs out or new branches stop appearing.

Failures at any phase are reduced to minimal counterexamples and catalogued. The run does not stop at the first failure.

## Getting a clean signal

The search is driven by one signal: the set of branches each attempt reached (its coverage signature). It decides what enters the corpus, what gets mutated next, and when the run stops. Three conditions, all yours to control, decide how much of that signal is real.

### Nothing else in the process

The branch counters are shared by the whole process, and Exhaust measures one attempt at a time: it zeroes the counters, runs the property once, and reads back what was hit. Any other code executing in an instrumented module during that window is indistinguishable from the property's own behaviour.

Only code running *during* an attempt matters. Each attempt re-zeroes the counters, so a test that finished earlier cannot affect it. `.serialized` alone does not give you that: it orders tests within one suite, but other suites still run concurrently and can cross-pollute.

Either run the whole target with `swift test --no-parallel`, or filter each run down to a single fuzz test. Filtering is stronger: a finished test can still have background work running (a detached task, an unawaited timer), and an empty process has nothing to leak.

Pollution only adds branches, never removes them. The result is inputs admitted for novelty they did not earn, a search that wanders, and a replay that cannot follow the original run.

### Instrument only the code under test

Everything an attempt executes inside an instrumented module counts, including generating the input. Instrumenting modules beyond the code under test adds branches (the report counts them as edges) that say nothing about the property, and an input can look novel for reaching one in a helper library. Prefer the per-target flags, on the narrowest set of targets that covers the code the property exercises.

### Replay under the conditions of the original run

The seed pins every decision the search makes: the screening rows, the sampling stream, and each mutation choice. What the search observes between decisions is environmental: coverage comes from the process counters, and phase transitions are wall-clock cuts. Give a replay the same build (recompiled code moves branches), the same isolation, and at least the original budget, and expect it to rediscover the same clusters rather than an attempt-for-attempt identical log.

One exception: after a crash, the rerun resumes from the crash checkpoint even when `.replay` is passed, because a trapping input is worth more than a faithful rerun. Set `EXHAUST_RESUME=0` when reproduction matters more. The crash state is then discarded.

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

## Reading the report

When a run discovers faults, the terminal shows a summary. This is real output from a run against an instrumented parser fixture:

```
#explore(time:) cataloged 3 fault clusters in 4978 attempts (35650 evaluated/s; 97% Exhaust testing overhead).
Coverage: 103 of 1171 instrumented edges hit; 1068 never hit (module-wide count,
  includes code the property never calls).
Estimated chance the next attempt covers a new edge: about 1 in 2489.
At least 104 edges look reachable for this generator and property.
At least 1 of those remains uncovered (scoped to this run's search space, not the module).
Stopped 0.3s early: no coverage-novel corpus admission in the plateau window;
  the unused budget was returned.

Cluster 1 WindowError
  7 reduced, 216 more attributed by symptom, found via sampling
  Counterexample: Message(mode: .heartbeat, flags: 0, checksum: 0, region: 6, payload: [])
  suspects:
    - Parser.decode (Parser.swift)
    - decodeHeartbeat (Parser.swift)
    - validateWindow (Parser.swift)

Cluster 2 IntegrityError
  6 reduced, 148 more attributed by symptom (1 normalized in), found via sampling
  Counterexample: Message(mode: .data, flags: 3, checksum: 0, region: 5, payload: [0, 0])
  suspects:
    - integrityCheck (Parser.swift:121)
    - Parser.decode (Parser.swift)
    - decodeData (Parser.swift)

Cluster 3 ChecksumError
  8 reduced, 446 more attributed by symptom, found via mutation
  Counterexample: Message(mode: .handshake, flags: 0, checksum: 65535, region: 0, payload: [])
  suspects:
    - Parser.decode (Parser.swift)
    - checkChecksum (Parser.swift)
    - ChecksumError.init (Parser.swift:9)

Full per-cluster detail is in the explore-time-cluster attachments.
Reproduce: .replay(1)
```

**Clusters group failures by their reduced form.** Failures that reduce to the same minimal counterexample are one cluster. That is the "reduced" count. The larger count beside it adds failures the run chose not to reduce (reduction per cluster is capped), attributed by matching error type, so read it as a rough weight. When a property returns `false` instead of throwing, every failure shares one symptom and the attribution carries no information. Throw distinct errors when you want distinct clusters.

**The attachments hold the full detail.** Each cluster's complete ranked suspect list is a test attachment named `explore-time-cluster-N.txt`, in Xcode's result bundle or wherever your runner collects attachments.

**A high overhead figure usually means the property is cheap.** 97% here says generation, mutation, and coverage bookkeeping dominate because the parser fixture costs almost nothing. It deserves attention only when a property that does real work still reports a high fraction.

**The edge count is the module, not the run.** The 1171 edges include everything in the instrumented module, most of which this property can never reach. The reachable-edge estimate is scoped to what this run can reach. It is a lower bound with a known bias toward completeness, so treat a rising estimate as evidence and a flat one as weak evidence.

**Late-discovered clusters come first.** A cluster found late with few instances is listed first and marked `discovered late at`. It is the strongest signal that extending the budget would find more.

**The seed is for replay.** Pass it as `.replay(1)` to rerun from the same starting point. Isolation matters doubly for replay: a replay that sees different coverage takes a different path.

For the spec form the report has the same structure, but each cluster's reduced counterexample is a command sequence:

```
Cluster 1 BoundedQueueError
  25 reduced, 11003 more attributed by symptom, found via sampling
  Counterexample: [.enqueue(value: 0), .clear, .enqueue(value: 0), .clear]
  suspect:
    - BoundedQueue.clear (BoundedQueue.swift:123)
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
| `.failFast` | Stops the run at its first fault, after reducing it, instead of cataloguing every distinct fault. Use where any failure fails the run, such as a merge gate. |
| `.commandLimit(n)` | Maximum commands per generated sequence. Default 40. Spec form only. |
| `.parallelize(lanes:)` | Lane count for `.tasks` specs. Default two. Spec form only. |

## Choosing a time budget

Short budgets (seconds to a minute) confirm the instrumentation works and show what screening and sampling find. Keep them in the fuzz target. A short budget makes it cheap to run routinely.

Longer budgets (five to thirty minutes) give mutation time to work. A fifteen-minute run on an M-series machine makes hundreds of thousands of attempts.

Overnight budgets (hours) suit nightly CI. Steer by the "estimated chance the next attempt covers a new edge" line: below one in a million, the search has saturated. When it disagrees with the reachable-edge line, trust it. The other is more sensitive to the search's own bias.

## Early termination

If the mutation phase goes a sustained window without reaching any new branches, the run terminates early and returns the unused budget. The summary states how much time was returned and why.

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
