# Coverage-guided fuzzing

Give Exhaust a time budget and let it search for bugs by observing which branches your code takes.

> Experiment: `#explore(time:)` is experimental. Settings, report format, and search behaviour may change in any release. Every call site emits a build warning until the mode stabilises.

## Overview

`#exhaust` runs a property across boundary values and random samples, then stops. For most tests that's the right tradeoff: fast feedback, deterministic budget, done in well under a second. But the iteration budget is finite, and some branches in your code may never be reached by the generator's natural distribution.

`#explore(time:)` takes a wall-clock time budget instead. You compile the target under test with coverage instrumentation (see below), and Exhaust watches which branches each generated input reaches, using that feedback as a novelty signal to drive a search. When it finds a failure, it keeps going. When the budget runs out, it reports every distinct fault it found, each reduced to a minimal counterexample.

```swift
@Test func parserHandlesAdversarialInput() async {
    await #explore(myInputGenerator, time: .minutes(15)) { input in
        let result = try MyParser.parse(input)
        #expect(result.isWellFormed)
    }
}
```

The test reads like any other `#exhaust` test: a generator, a property, and `#expect` assertions. The differences are the `time:` parameter and the `async`/`await`. The search is single-threaded by design: one thread generates each input, runs the property, and reads back the coverage counters, so every measurement belongs to exactly one attempt (<doc:#Getting-a-clean-signal> covers what that buys and what it asks of you). That thread is occupied for the entire budget, whichever form you write. The async form moves the run onto a dedicated thread away from the cooperative pool.

> Important: Fuzz tests must run in isolation. The branch counters Exhaust reads are shared by the whole process, so any other test running in parallel executes instrumented code in the middle of an attempt and distorts the feedback signal the search depends on. Give fuzz tests their own test target and mark the suite `.serialized`; for the strongest signal, filter each test run down to a single fuzz test (`swift test --filter FuzzTests.fuzzMyLibrary`) so nothing else runs in the process at all. Isolation also keeps minute-scale time budgets out of your everyday `swift test` runs. <doc:#Getting-a-clean-signal> covers the full set of conditions.

## Setting up coverage instrumentation

Both macros require the target under test to be compiled with coverage instrumentation. Without it, the test fails immediately with a diagnostic showing the flags to add. No budget is consumed.

There are two ways to add the flags, depending on whether the target you want instrumented is one you control in your own `Package.swift`.

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

The flags go on the library target, not the test target. Exhaust tracks which branches are hit inside the instrumented code each time the property runs.

If you are testing a function that lives in the test target itself, put the flags on the test target instead.

### Whole-graph instrumentation via the CLI

When the target you want instrumented is a dependency you cannot add `swiftSettings` to, pass the flags at the command line instead:

```bash
swift test \
    -Xswiftc -sanitize=undefined \
    -Xswiftc -sanitize-coverage=edge,inline-8bit-counters,pc-table
```

This instruments every module in the build graph. Gate the fuzz suite on an environment variable so that the uninstrumented default `swift test` does not trip the missing-instrumentation diagnostic:

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
FUZZ=1 swift test \
    -Xswiftc -sanitize=undefined \
    -Xswiftc -sanitize-coverage=edge,inline-8bit-counters,pc-table \
    --filter FuzzTests
```

### Adding comparison-operand injection (optional)

> Experiment: Comparison-operand injection is experimental and may change or be removed in any release.

Some branches gate on a value the generator will almost never produce by chance: an equality against a wide constant (`token == 0x5F3759DF`), a parsed magic number, a specific string. Edge coverage gives the search nothing to climb there, because every wrong value takes the same branch. Adding `trace-cmp` to the coverage flags lets Exhaust read the operands of the code's own comparisons and work backward through the generator to the choices that would produce the wanted constant. On constructed wide-constant gates this has been the difference between never solving and solving in around a thousand attempts. It works for whole-value gates and for structs compared field by field.

It helps only where the wanted value is rare in its domain. A comparison on a small per-element domain — a byte, a printable character — sees no benefit, because ordinary generation already produces every value there; the payoff is on wide or parsed constants, not on the small enumerable ones typed generators manufacture by construction.

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
swift test \
    -Xswiftc -sanitize=undefined \
    -Xswiftc -sanitize-coverage=edge,inline-8bit-counters,pc-table,trace-cmp
```

Injection activates automatically when the flag is present. It steers only the generators Exhaust can run backward: the reflective generators `#gen` builds from initialisers and value-preserving transforms. A generator whose output comes from a forward-only `map` cannot be steered this way, and Exhaust ignores the harvested operand. Without the flag, or on a run that never reaches such a comparison, the search behaves as it does without it. In the throughput measurement, adding the flag cost under one percent on a generation-bound fixture.

## How a time-bounded run works

Exhaust runs the property in three phases:

1. **Screening.** The same known problematic-value combinations `#exhaust` uses: integer min/max/zero, IEEE 754 sentinels, Unicode edge cases, and so on. Screening has its own row budget (10,000 rows by default) and stops at the cap, at the end of the covering array, or when the wall-clock budget runs out, whichever comes first. Inputs that reach new branches are kept for the next phase.
2. **Sampling.** Random generation, as in `#exhaust`. Exhaust watches the rate of new branch discovery and moves on when it flatlines or 10% of the time budget has elapsed, whichever comes first.
3. **Mutation.** Exhaust takes inputs that reached interesting branches, modifies them, and checks whether the modified version reaches branches that nothing in the collection has reached before. When it does, the new input joins the collection and becomes a candidate for further modification. This continues until the budget runs out or new branches stop appearing.

Failures at any phase are reduced to minimal counterexamples and catalogued. The run does not stop at the first failure.

## Getting a clean signal

The search is driven by one signal: which branches each attempt reached. That signature decides what enters the corpus, what gets mutated next, and when the run stops. Three conditions, all under your control, determine how much of that signal is real.

### Nothing else in the process

The branch counters are shared by the whole process, and Exhaust measures one attempt at a time: it zeroes the counters, runs the property once, and reads back what was hit. Any other code executing in an instrumented module during that window is indistinguishable from the property's own behaviour.

What matters is that nothing else executes *during* the run. Each attempt re-zeroes the counters before it starts, so a test that ran to completion before the fuzz test cannot affect it — strictly serial execution is enough. `.serialized` alone does not provide that: it orders the tests within one suite, but separate suites still run concurrently with each other, so a fuzz target with a second suite (even a small helper suite) can cross-pollute. Either run the whole target with `swift test --no-parallel`, or filter each test run down to a single fuzz test. Filtering is the stronger form: serial scheduling guarantees ordering, not quiescence, so a test that leaks background work past its own completion (a detached task, an unawaited timer) can still fire mid-attempt — an empty process has nothing to leak.

Pollution is one-directional: a concurrent test can only add branches to an attempt's measurement, never remove them. The result is inputs admitted to the corpus for novelty they did not earn, a search that wanders, and a replay that cannot follow the original run.

### Instrument only the code under test

Everything an attempt executes inside an instrumented module counts toward its signature, and that includes generation: building the input runs inside the attempt's measurement window. Instrumenting modules beyond the code under test therefore adds edges that say nothing about the property. Those edges compete for corpus admissions (an input can look novel for reaching a new branch in a helper library) and inflate the instrumented-edge count in the report. Prefer the per-target flags over the whole-graph CLI flags, and put them on the narrowest set of targets that covers the code the property exercises.

### Replay under the conditions of the original run

The seed pins every decision the search makes: the screening rows, the random-sampling stream, and each mutation choice. Reduction runs inline on the search's own thread, so even the point where a failure's classification feeds back into the search is the same on every run. What the search observes between decisions is environmental: coverage comes from the process counters, and phase transitions are wall-clock cuts. A replay is a rerun of the same search from the same starting point. Give it the same build (recompiled code moves branches), the same isolation, and at least the original budget, and expect it to rediscover the same clusters rather than reproduce an attempt-for-attempt identical log.

One exception is deliberate: when the previous run crashed, the rerun resumes from the crash checkpoint instead of replaying, even when `.replay` is passed. A trapping input is the most valuable thing a fuzzing run can find, and reporting it beats a faithful rerun. Set `EXHAUST_RESUME=0` when reproduction matters more than the crash finding; the crash state is discarded.

## Fuzzing a state machine spec

The same coverage-guided search works over `@StateMachine` specs. Pass the spec in place of the generator and add the `mode:` its commands should run under. Exhaust then mutates command sequences where it would otherwise mutate values, deleting, duplicating, and replacing commands as it searches.

```swift
@Test func boundedQueueDeepFaults() async {
    await #explore(BoundedQueueSpec.self, mode: .sequential, time: .minutes(5))
}
```

The spec form skips the screening phase (boundary-value catalogues apply to values, not command vocabularies) and begins with random sampling. Commands whose preconditions fail at runtime are pruned from the stored sequence so that modifications don't keep resurrecting operations that have no effect in a given context.

Sequences carry up to 40 commands by default. Override with `.commandLimit(n)` when the default is too short to reach deep state, or to shorten sequences when each command is expensive.

### Execution model support

| Mode | Status |
|-------|--------|
| `mode: .sequential` | Supported, for both synchronous and async specs. `mode:` is required, so this is the mode to pass when you want one command at a time. |
| `mode: .tasks` | Supported for async specs. Requires macOS 15, iOS 18, tvOS 18, watchOS 11, or visionOS 2 on Apple platforms; no version requirement on Linux and Windows. The search mutates both commands and their lane assignments, and reduction minimises concurrency back toward one command at a time. `.parallelize(lanes:)` sets the lane count, defaulting to two. A spec with no async members runs one command at a time here. |
| `mode: .threads` | Unavailable, and a compile error rather than a run that says nothing: the `mode:` here takes a ``SearchableExecutionModel``, which has no `.threads` case. The search treats an attempt's coverage as determined by its command sequence, and thread-based scheduling makes it depend on an OS schedule the run can neither observe nor replay. The discussion below the table expands on this and names the alternatives. |

That exclusion is the clean-signal requirement applied from the inside. Every condition in <doc:#Getting-a-clean-signal> removes a hidden influence on what an attempt's coverage says about its input. Thread-based scheduling adds one to every attempt: the same command sequence takes different branches depending on how the OS interleaves the lanes, so the search cannot tell a sequence that reached new code from one that won an unusual schedule, and it spends the budget chasing the scheduler instead of your spec.

No isolation arrangement recovers the signal. The conditions in <doc:#Getting-a-clean-signal> are fixable because the interference comes from outside the run. Here the interference is the mode's purpose: `mode: .threads` exists so the OS is free to realise a different schedule for the same sequence on every attempt, which is the one freedom the coverage signal cannot absorb.

Concurrency testing under a time budget splits by what you are hunting. To search interleavings, use `mode: .tasks`: the lane assignment travels inside the generated input, so schedules are mutated, replayed, and reduced like any other part of the sequence. To find data races, run the same spec under `#execute` with `mode: .threads`, which judges runs through the spec's `@Equivalence` and relies on repetition rather than coverage, and is built for schedules it cannot replay.

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

**Clusters group failures by their reduced form.** Two failures that look different on the surface but reduce to the same minimal counterexample are one cluster. That is what the "reduced" number counts. The larger failure count beside it includes failures the backpressure gate declined to reduce, which are attributed to a cluster by matching error type, so read it as a rough weight rather than a membership count. When a property returns `false` instead of throwing, every failure in the run shares one symptom and the attribution carries no information at all.

**The overhead figure is about the property, not the pipeline.** 97% here means the property is cheap enough that generation, mutation, and coverage bookkeeping dominate, which is expected for a small parser fixture and is not actionable. It is worth attention when a property that does real work still reports a high fraction: then the pipeline is genuinely eating the budget.

**The edge count is the module, not the run.** The 1171 edges include everything in the instrumented module, most of which this property and generator can never reach. The reachable-edge estimate (Chao2, sharpened to iChao2 when the run's incidence counts allow it) is scoped to what this run can actually reach, which is a more honest denominator than module size.

Read it as a lower bound with a known lean rather than a measurement. The estimator assumes one sampling frame, and a run is a mixture of three phases with different distributions; the mutation phase also concentrates on regions that already paid off, which suppresses the singleton count the estimator reads. Both effects push the same way, toward reporting the search as more complete than it is. Treat a rising estimate as evidence, and a flat one as weak evidence.

**Late-discovered clusters are foregrounded.** A cluster found in the final quarter of the run with few instances is the strongest signal that extending the budget would find more.

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

The generator form takes ``PropertyFuzzSettings``. The spec form takes ``StateMachineFuzzSettings``, which adds the last two rows. Writing a spec-only setting on a generator does not compile.

| Setting | Effect |
|---------|--------|
| `.replay(seed)` | Replays a prior run's search from its seed. Pass the seed from a report's `Reproduce:` line. |
| `.suppress(.issueReporting)` | Silences test failures. Use when asserting on the returned ``FuzzReport`` directly. |
| `.suppress(.logs)` | Silences log output. |
| `.suppress(.attachments)` | Stops the run recording its per-cluster and summary attachments. Use when a test loops fuzz runs and the attachments would only accumulate noise in the result bundle. |
| `.suppress(.all)` | All of the above. |
| `.log(.info)` | Raises log verbosity (default is `.error`). |
| `.failFast` | Stops the run as soon as its first fault is classified, instead of spending the remaining budget cataloging every distinct fault. The failing input is still reduced first. Use where any failure fails the run, such as a merge gate. |
| `.commandLimit(n)` | Maximum commands per generated sequence. Default 40. Spec form only. |
| `.parallelize(lanes:)` | Lane count for `.tasks` specs. Default two. Spec form only. |

## Choosing a time budget

Short budgets (seconds to a minute) are useful during development: confirm the instrumentation works, see what screening and sampling find. These belong in your regular test suite alongside `#exhaust` tests.

Longer budgets (five to thirty minutes) give the mutation phase time to work. A fifteen-minute run on an M-series machine completes hundreds of thousands of attempts; each attempt that reaches a new branch becomes a candidate for further modification.

Overnight budgets (hours) suit nightly CI. The report's "estimated chance the next attempt covers a new edge" line is the one to steer by: when it drops below one in a million, the search has saturated and further time buys diminishing returns. That figure is a discovery-probability estimate denominated in edge incidences rather than attempts, and its consistency argument is the stronger of the two the report carries. The Chao2 reachable-edge line beside it is more sensitive to the search's own bias, so prefer the discovery-probability line when the two disagree.

## Early termination

If the mutation phase goes a sustained window without reaching any new branches, the run terminates early and returns the unused budget. The summary states how much time was returned and why.

A plateau does not mean the code is bug-free. Bugs on already-covered paths are still possible. The plateau means the search can no longer reach new branches from the inputs it has.

## Asserting on the report

When the run is expected to find faults and you want to assert on the outcome programmatically, suppress issue reporting and inspect the returned ``FuzzReport``:

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

A fuzzing run can find an input that traps: a `fatalError`, a failed precondition, an out-of-bounds subscript in the code under test. A trap kills the whole test process, and with it any report the run would have produced. To keep the discovery, Exhaust checkpoints its progress to disk during the run: the collection of interesting inputs, the fault clusters found so far, and a note of which candidate is currently being evaluated.

Rerun the test after a crash and Exhaust reports the trapping candidate as a finding (or its mutation parent, when the candidate itself was never stored), quarantines it so mutation does not immediately rediscover the trap, and spends the rest of the declared budget continuing the search from the restored collection rather than starting over.

Checkpoints live in the system temporary directory and are removed when a run completes normally, so there is nothing to add to `.gitignore`. Set `EXHAUST_STATE_DIR` to relocate them, for example on CI where each step gets a fresh temporary directory. Set `EXHAUST_RESUME=0` to ignore a crashed predecessor's state and start fresh.

If the instrumented code changed between the crash and the rerun, the saved inputs' coverage records may no longer match the new binary. Exhaust detects this and re-measures the restored inputs against the rebuilt code before resuming.

Checkpoints are keyed by test file and line, not by process, so two processes fuzzing the same test at the same time (a local run alongside a CI runner on a shared temporary directory, or two concurrent `swift test` invocations) overwrite each other's checkpoints and can misread each other's crash state as their own. Point each process at its own `EXHAUST_STATE_DIR` when runs of the same test can overlap.

## Topics

### Settings and Results

- ``PropertyFuzzSettings``
- ``StateMachineFuzzSettings``
- ``FuzzReport``
- ``TimeSpan``
