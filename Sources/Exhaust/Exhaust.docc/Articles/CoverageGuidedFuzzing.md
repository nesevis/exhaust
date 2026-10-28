# Coverage-guided fuzzing

Give Exhaust a time budget and let it search for bugs by observing which branches your code takes.

> Experiment: `#explore(time:)` is experimental. Settings, report format, and search behaviour may change in any release.

## Overview

`#exhaust` runs a property across boundary values and random samples, then stops. For most tests that's the right tradeoff: fast feedback, deterministic budget, done in well under a second. But the iteration budget is finite, and the values a generator usually produces may never reach some branches in your code.

`#explore(time:)` takes a wall-clock time budget instead. You compile the code under test with coverage instrumentation, and Exhaust watches which branches each generated input reaches. The report calls these branches *edges*. Inputs that reach a branch nothing else has reached join a pool of starting points (the *corpus*), and Exhaust builds later inputs by changing them.

A thrown error or a failed `#expect` is a failure. Exhaust reduces each failure to a minimal counterexample and keeps searching. When the budget runs out, it reports the distinct counterexamples it found.

```swift
@Test func parserHandlesAdversarialInput() async {
    await #explore(myInputGenerator, time: .seconds(20)) { input in
        let result = try MyParser.parse(input)
        #expect(result.isWellFormed)
    }
}
```

The test reads like any other `#exhaust` test: a generator, a property, and `#expect` assertions. The differences are the `time:` parameter and the `await`. Exhaust runs the search on its own thread for the whole budget, so every call is `async`. The test waits on that thread without holding one of its own.

Run campaigns with the `explore` package command. It builds the selected targets with instrumentation in a separate directory, then runs the selected tests in parallel, each campaign recording its own coverage. Manual instrumentation exists for the cases the command does not cover: short fuzz properties inside the ordinary suite, dependencies you cannot select, and executables.

## How a time-bounded run works

Exhaust runs the property in three phases:

1. **Screening.** The boundary catalogue `#exhaust` tries first (integer min/max/zero, IEEE 754 sentinels, Unicode edge cases), combined by the covering-array sampler. Screening stops at its own row cap, the end of the covering array, or the time budget, whichever comes first. Inputs that reach new branches join the corpus.
2. **Sampling.** Random generation, as in `#exhaust`, until a long stretch of samples adds nothing to the corpus or 10% of the budget has elapsed.
3. **Mutation.** Exhaust changes inputs from the corpus. A changed input that reaches a branch nothing in the corpus has reached joins the corpus and is changed in turn. Some attempts go to fresh generation instead. That share grows while the corpus stops admitting new inputs and falls back once discoveries resume, so the search keeps probing beyond the corpus's neighbourhood for the whole run.

Each input Exhaust runs the property on is an *attempt*. Failures in any phase are reduced and catalogued, and the run carries on. By default a run spends its whole budget. `.failFast` stops it at the first failure, and `.stopWhenSaturated` stops it once the search has stopped reaching new code (see <doc:#Stopping-early>).

## Running a fuzzing campaign

Use Swift 6.4 or later and a version of Exhaust that provides the `explore` command. Add Exhaust as a direct dependency of the package you want to test. <doc:GettingStarted> covers adding the dependency. The command runs on macOS and Linux. Windows support is experimental pending native CI verification: on Windows the command runs campaigns in debug only and leaves the test target uninstrumented (see <doc:#Instrumentation-scope-and-current-limits>). The single-line commands below work in a Unix shell or PowerShell.

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

Leave the existing library and unit-test targets in place. You do not need to add a plugin declaration or coverage flags to any target. `explore` supplies instrumentation through a temporary manifest overlay and never edits your `Package.swift`. There is no setup command or hook to commit.

### 2. Write the property

Create `Tests/MyLibraryFuzz/MessageDecodingFuzzTests.swift`. This example assumes `MyLibrary` has a `Message` type with a generator for it (<doc:BuildingGenerators>) and a throwing `Parser.decode(_:)`. Replace those with the API you want to exercise:

```swift
import Exhaust
import MyLibrary
import Testing

@Test func decoderAcceptsEveryMessage() async {
    await #explore(messageGenerator, time: .seconds(60), .replay(1)) { message in
        let decoded = try Parser.decode(message)
        #expect(decoded.byteCount == message.payload.count)
    }
}
```

The generator defines the inputs the search can explore. The property describes what must hold for every input: here, decoding any message succeeds and accounts for its whole payload. A decoder like this is where coverage guidance pays off. Each message mode leads into its own validation code, and a bug three checks deep is rarely reached by values drawn at random.

Call `#explore` with `await` from an `async` test. The property closure can be synchronous or `async`. Exhaust calls a synchronous closure directly on the search's thread. It awaits an `async` closure once per input, which costs throughput, so add `async` only when the property needs to `await` something. Keep the property's work on the search's thread. <doc:#When-the-run-cannot-see-the-code> explains the restrictions on actor and detached-task work.

The optional `.replay(1)` fixes the seed. Change it in the test to try another seed, because the command has no `--seed` option. A seed helps reproduce a search under the same build and budget, but debug and release builds can follow different paths through the search.

### 3. Run a campaign

From the package directory, run:

```sh
swift package explore --instrument MyLibrary --test-target MyLibraryFuzz --filter decoderAcceptsEveryMessage --time 60
```

This builds the package's tests in a separate build directory, instruments `MyLibrary` and `MyLibraryFuzz`, and runs the selected property. Exhaust and other dependency targets keep their own build settings. The command links the coverage runtime and test-reporting support itself, so the test target needs only the dependencies shown above.

The default build configuration is **release**, except on Windows, where campaigns run in debug only. To run the same property in debug, add `--configuration debug`. Once the property works, give mutation more time with a fifteen-minute campaign by passing `--time 900`.

`--time` overrides the budget of **each** `#explore(time:)` invocation, including state machine specs. It does not limit compilation or the whole test suite. Omit it to use the budget written in each test. Swift Testing time limits still apply, so increase an explicit `@Test` time limit when running a longer campaign.

These options belong to `explore` and go after its name:

| Option | Meaning |
|--------|---------|
| `--instrument <target>` | Instrument a Swift target in the root package. Required. Repeat it for additional targets the property exercises. |
| `--test-target <target>` | Select one Swift test target. It is also instrumented automatically, except on Windows. May be omitted when the package has exactly one Swift test target. |
| `--filter <regex>` | Select matching tests within that target. Omit it to run all tests in the target. No matches is an error. |
| `--time <seconds>` | Override each invocation's budget with a positive whole number of seconds. |
| `--xunit` | Also write SwiftPM native xUnit XML for CI test-result import. Off by default. |
| `--output <path>` | Set the report and recovery root. Relative paths resolve from the package root. Overrides `EXHAUST_STATE_DIR`. |
| `--configuration debug\|release` | Choose the campaign's build configuration. Defaults to `release`. Windows supports `debug` only, and defaults to it. |
| `--no-parallel` | Run tests serially and use `inline-8bit-counters` to record coverage across thread, task, and executor hops. The default runs tests in parallel with `trace-pc-guard`. |
| `--help` | Show command usage. |

SwiftPM options such as `--package-path` and `--scratch-path` go before `explore`. After `explore`, the command rejects them as unknown options. No `--allow-writing-to-package-directory` flag is needed. SwiftPM builds the package's whole test bundle, including other test targets, but `explore` runs only the selected tests.

### 4. Inspect findings and rerun

The command prints its build, attachment, and crash-recovery directories under `.build/plugins`, inside the usual ignored `.build` directory. A custom SwiftPM `--scratch-path` moves that workspace. Each invocation gets a new attachment directory, and reports remain available even when a test fails.

Read the reduced counterexamples in the test output, then open the summary attachment in the printed attachment directory for coverage and throughput. <doc:#Reading-the-report> explains both. A property failure, build error, or test-process crash makes the command exit unsuccessfully, so the same invocation works in CI. Each run also writes a machine-readable `report.json` and a live `events.jsonl` stream, described in <doc:ExploreCommandReference>.

Rerun the command after fixing a bug. If the previous test process crashed, the rerun recovers the campaign from its checkpoint (see <doc:#Crash-recovery>). To keep reports and checkpoints somewhere else, such as a CI cache, pass `--output <path>` after `explore`. A location outside the plugin work directory also needs SwiftPM's `--allow-writing-to-directory <path>` permission before `explore`:

```sh
swift package --allow-writing-to-directory /tmp/my-library-campaigns explore \
  --instrument MyLibrary --test-target MyLibraryFuzz \
  --output /tmp/my-library-campaigns --time 60
```

### Running several campaigns at once

Campaigns run in parallel by default, each with its own coverage. Exhaust bounds how much of its own work runs at once (`EXHAUST_LANE_LIMIT`, default 32). That limit does not cover threads created by the system under test.

A parameterised test runs one campaign per argument. Give each case a distinct explicit seed so the cases keep separate recovery state:

```swift
@Test(arguments: [UInt64(1), 2, 3, 4, 5])
func integerCampaign(seed: UInt64) async {
    await #explore(
        .int(),
        time: .seconds(60),
        .replay(.numeric(seed))
    ) { value in
        decode(encode(value)) == value
    }
}
```

Swift Testing can run all five cases concurrently. Each case is an independent search with its own seed, budget, corpus, checkpoint, and report, and the cases do not share findings. `--time` overrides each case's budget separately. With enough cores, the five 60-second searches overlap in roughly one minute of elapsed search time. With `--no-parallel` they run one after another. <doc:ExploreCommandReference> covers how their attachments and recovery stores are named.

### Work that crosses threads or tasks

If the property or system under test moves instrumented work to another thread or to an executor outside Exhaust's own, such as `@MainActor`, a custom actor executor, a dispatch queue, or a detached task, run the campaign with `--no-parallel`:

```sh
swift package explore --instrument MyLibrary --test-target MyLibraryFuzz --no-parallel --time 60
```

This switches the build to `inline-8bit-counters`, which records branches on every thread, and runs tests one at a time so campaigns cannot clear each other's counters. Ordinary async work that stays on Exhaust's executor can use the default mode.

Each property invocation must await or otherwise join all the work it starts before returning. Awaiting `#explore` does not join an unstructured task the property abandons, and background work leaking into a later attempt contaminates that attempt's coverage even in serial mode.

Counters clear and scan the whole instrumented table on every attempt, whereas the default mode tracks only the branches actually hit. Switching modes can change throughput and search results, so reproduce a finding with its original mode and configuration.

### Keep campaigns separate from ordinary tests

An ordinary `swift test` still discovers the dedicated test target. When no instrumented module is loaded, `#explore(time:)` emits a runtime warning and returns without invoking the property or consuming its budget. The returned report has `.instrumentationMissing` termination and zero attempts. Code outside the macro still runs, including assertions on its report.

Compiler `-warnings-as-errors` does not promote this runtime warning to a test failure. To leave campaign tests and their warnings out of the ordinary suite entirely, filter out the target:

```sh
swift test --skip MyLibraryFuzz
```

To include short fuzz properties in ordinary test runs instead, configure the manual instrumentation described in <doc:#Setting-up-coverage-instrumentation-manually>.

### Instrumentation scope and current limits

The command enables edge coverage, comparison tracing, and assertions for the selected targets in both debug and release. It instruments the calling test target too, so calls into the library cannot be inlined into an uninstrumented test module and disappear from coverage. Dependency code inlined or specialised into a selected module still contributes coverage, because selection works by compiled module rather than by where each function's source lives.

On Windows the command does not instrument the test target. SwiftPM builds a separate runner for each test target there, and that runner cannot link the coverage runtime. Code that lives only in the test target, including the property closure itself, records no coverage, and the inlining protection described above does not apply. A property whose attempts never reach an instrumented target stops after a fixed number of attempts with a "recorded no coverage at all" error, even when it resumed a crashed run and reported that run's trap. Keep the logic a property checks in the library under test, and have every attempt call into it.

Windows campaigns also run in debug only. SwiftPM's release test runners on Windows do not load test targets that contain only Swift Testing tests, so a release campaign would find no tests.

The overlay preserves relative dependency paths and the manifest's `#filePath`. This first version requires a top-level variable named `package` and a single `Package.swift`. Version-specific manifests such as `Package@swift-6.4.swift` are rejected. You can select root Swift library, executable, and test targets. Dependency targets, C-family targets, macro targets, and binary targets cannot be selected. The command leaves Exhaust's coverage runtime uninstrumented.

## Reading the report

When a run finds failures, the terminal shows a summary. This is real output from a run of the step 2 property against an instrumented message parser with planted bugs, seed 1, and an eight-second budget:

```
#explore(time:) found at least 4 distinct failures in 8.0s (227900 inputs tried).

1. WindowError, first seen at 0.0s
   Message(mode: .heartbeat, flags: 0, checksum: 0, region: 6, payload: [])
   likely in static Parser.decode(_:), static Parser.decodeHeartbeat(_:), static Parser.validateWindow(_:) (Parser.swift)

2. IntegrityError, first seen at 0.0s
   Message(mode: .data, flags: 3, checksum: 0, region: 5, payload: [0, 0])
   likely in static Parser.integrityCheck(mode:) (Parser.swift:121)

3. ChecksumError, first seen at 0.1s
   Message(mode: .handshake, flags: 0, checksum: 65535, region: 0, payload: [])
   likely in static Parser.decode(_:), static Parser.checkChecksum(_:) (Parser.swift)

4. IntegrityError, first seen at 0.4s
   Message(mode: .control, flags: 12, checksum: 0, region: 2, payload: [241])
   likely in static Parser.integrityCheck(mode:) (Parser.swift:121)

Used the whole budget; the last new code was reached 7.6s before the end, so a longer run is unlikely to find more.
Reproduce: .replay(1)
Coverage, throughput, and full suspect lists are in this campaign's summary attachment (named with the test and seed).
```

**Each numbered entry is one distinct reduced counterexample.** Entries 2 and 4 throw the same error from the same line and are still listed separately, because their reduced inputs differ. The count is a lower bound on distinct bugs. Reduction keeps a smaller input as long as it fails with the same symptom (the same thrown error type, or a `false` return), without checking that it fails for the same reason. So one bug's failures can reduce into another bug's counterexample and vanish from the report. Throw distinct errors when you want distinct entries. A property that returns `false` gives every failure the same symptom.

**`first seen at` is when the search first hit that failure.** An entry found late in the run is marked `late`, and that is the strongest sign a longer run would find more.

**`likely in` names where to look.** When one function's branches separate this failure's inputs from passing ones and resolve to a line, that function is named alone. Otherwise up to three suspects are listed in rank order, outermost first, because without a line the ranking cannot tell an entry point from the branch beneath it. The cluster attachment carries the full ranked list for every entry.

**The line before `Reproduce` answers "should I run longer?".** Exhaust bases the verdict on its estimate of the chance that the next input reaches new code. The line also says how long ago the last discovery was, because that is easy to picture, but the estimate decides the verdict. When the estimate says more is reachable, the line reads "Used the whole budget and was still reaching new code … a longer run may find more." A run that `.stopWhenSaturated` ended early states how much budget it returned.

**The seed is for replay.** Pass it as `.replay(1)` to rerun from the same starting point. A replay that sees different coverage takes a different path, so replay under the conditions in <doc:#Getting-a-clean-signal>.

**The attachment line appears only when attachments were recorded.** It is omitted under `.suppress(.attachments)`, when the run made no attempt, and outside a test.

**The attachments hold the numbers.** The summary attachment carries the search's own figures for the same run: attempts per second, the share of each attempt spent outside your property, how many of the module's instrumented branches the run reached, the estimated number it could reach, and each entry's membership and discovery phase. One cluster attachment per entry has its full ranked list of suspect branches. Find them in Xcode's result bundle, the `explore` command's attachment directory, or wherever your runner collects attachments. Their names start `explore-time-<test>-seed-<seed>`, followed by a campaign ID under the `explore` command, and end in `-summary.txt` or `-cluster-N.txt`.

Two of the summary's figures need a caveat. The branch count is the whole module's, most of which this property can never reach, so a low fraction is expected. The reachable estimate is a statistical lower bound that only prints once the run has seen enough repeat coverage, and short runs usually don't get there.

For the spec form the report has the same structure, but each entry's reduced counterexample is a command sequence:

```
1. BoundedQueueError, first seen at 0.3s
   [.enqueue(value: 0), .clear, .enqueue(value: 0), .clear]
   likely in BoundedQueue.clear (BoundedQueue.swift:123)
```

## Inputs the property cannot judge

A property with a precondition should throw `PropertySkip` (or `XCTSkip`) for an input that does not meet it, the same way it would under `#exhaust`. Under `#explore(time:)` a skipped input is a *discard*: neither a failure nor a pass. Exhaust still records its coverage, and when it reached a branch nothing else has, it stays in the corpus as a mutation parent at a third of the weight of a valid input.

On a property whose precondition random generation rarely satisfies, this is how the search finds valid inputs at all. A near miss is mutated toward a valid input, where fresh generation would keep missing. The summary reports the share of inputs the property skipped.

Returning `true` for an input that does not meet the precondition hides it from the search and counts it as a pass. Throw instead.

A run must judge at least one input. If the property discards every input it receives, or every evaluation stalls without a verdict, the run reports a pointless-run error and ``FuzzReport/outcome`` is ``FuzzReport/Outcome/error``, even though the inventory is empty.

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
| `.failFast` | Stops the run at its first failure, after reducing it, instead of cataloguing further distinct counterexamples. Use where any failure fails the run, such as a merge gate. |
| `.skipScreening` | Starts the search at random sampling, skipping the boundary catalogue. Use for a property whose precondition discards nearly every boundary row, or to compare runs from identical starting conditions. The spec form always skips screening, so there it changes nothing. |
| `.stopWhenSaturated` | Ends the run once the search has stopped reaching new code, returning the unused budget. Off by default. See <doc:#Stopping-early>. |
| `.commandLimit(n)` | Maximum commands per generated sequence. Default 40. Spec form only. |
| `.parallelize(lanes:)` | Lane count for `.tasks` specs. Default two. Spec form only. |

## Choosing a time budget

Short budgets (seconds to a minute) confirm the instrumentation works and show what screening and sampling find. They suit a fuzz test that lives in the wider suite, where a short budget keeps it cheap to run routinely.

Longer budgets (five to thirty minutes) give mutation time to work. A fifteen-minute run on an M-series machine makes hundreds of thousands of attempts.

Overnight budgets (hours) suit nightly CI. The line before `Reproduce` in the summary tells you whether a longer run is likely to find more. To have a long run hand back time it cannot use, add `.stopWhenSaturated`.

## Stopping early

A run spends its whole budget unless `.failFast` stops it at the first failure or `.stopWhenSaturated` is set.

With `.stopWhenSaturated`, Exhaust uses the run's own coverage to estimate the chance that the next attempt reaches a branch nothing has reached yet. Once that chance falls below 1 in 10,000, the run stops and returns the rest of its budget. The first check waits until the run has made hundreds of thousands of attempts, because a smaller sample says too little. The summary states how much time was returned.

The setting is off by default because a plateau in coverage does not mean the code is bug-free. A failure on an already-covered path stays reachable long after the last new branch. On one workload with a hard-to-satisfy precondition, about a fifth of all detections arrived after coverage stopped growing. Use it where the budget is long, the machine is shared, and returning unspent time is worth more than the tail of the search.

One case stops early without the setting. When the generator's whole domain is small enough to enumerate and mutation has nothing left to vary, the run ends and returns the rest of its budget.

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
    #expect(report.outcome == .passed)
}
```

Assert on ``FuzzReport/outcome`` rather than an empty ``FuzzReport/clusters`` list. A run without instrumentation, with a rejected setting, or whose property judged no input also has no clusters, and only ``FuzzReport/Outcome/passed`` means the search ran and the property held for every input it judged. Assert on ``FuzzReport/clusters`` when a run is expected to find specific failures.

## Setting up coverage instrumentation manually

`#explore(time:)` requires the code under test to be compiled with coverage instrumentation. When no instrumented module is loaded, it emits a runtime warning showing how to enable instrumentation and returns without invoking the property or consuming the budget. An instrumented build whose property records no coverage still fails, because its campaign cannot observe the code under test.

### Fuzzing in the ordinary suite

With manual flags, the fuzz test lives in an ordinary test target and runs whenever the suite runs. Add the flags to the library under test, gated on the debug configuration the suite builds in. The flags are `unsafeFlags`, which SwiftPM accepts only in a root package, so they belong in the manifest of the package you are testing:

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

`-sanitize=fuzzer-no-link` enables fuzzing instrumentation without linking libFuzzer's runtime or entry point. Exhaust supplies the coverage callbacks and search loop. The flag works on both macOS and Linux, and it does not enable AddressSanitizer or UndefinedBehaviorSanitizer.

`trace-pc-guard` records each run's coverage through a context bound to the run's own thread, so other tests running in the same process, including other `#explore(time:)` runs, do not disturb it. The suite needs no `.serialized` trait, no `--no-parallel`, and no filtering. Keep the budget short (a few seconds) so the suite stays fast.

If the function under test lives in the test target itself, put the flags on the test target instead.

### Release builds

In a release build, instrumenting only the library can lose coverage. The compiler inlines small public functions from the instrumented library into the uninstrumented caller, and each inlined copy is compiled under the caller's flags: no guards and no comparison callbacks. The functions still compute correctly, but they vanish from the coverage signal. If everything the property touches is inlined away, the run fails with the no-coverage diagnostic. If only some helpers are, nothing fails. The search runs on a partial signal and comparison tracing misses the swallowed comparisons, with no sign anything is missing. Only a prebuilt binary dependency is out of the optimiser's reach.

For a manual release build, apply the coverage flags and `-assert-config Debug` to both the library and the calling test target, and gate them on an explicit fuzzing opt-in. A separate test target alone does not keep flags on a shared library out of ordinary builds. This is the configuration the `explore` command sets up for you.

If you deliberately leave the caller uninstrumented, marking the library's public entry points `@inline(never)` keeps those calls in the instrumented module.

### When the code under test is a dependency you cannot edit

Pass the flags on the command line instead. This instruments every module in the build graph, Exhaust included, which costs roughly 8–30 µs per attempt on top of the property (more for complex generators) and makes the report's edge count describe the whole graph rather than your code:

```bash
swift test -c release \
    -Xswiftc -sanitize=fuzzer-no-link \
    -Xswiftc -sanitize-coverage=edge,trace-pc-guard,pc-table \
    -Xswiftc -assert-config -Xswiftc Debug \
    --filter MyLibraryFuzz
```

Use `trace-pc-guard` here. A whole-graph build with `inline-8bit-counters` spends most of each attempt clearing and rescanning a table of every module's counters, which makes it unusable.

### Adding comparison tracing (optional)

> Experiment: Comparison tracing is experimental and may change or be removed in any release.

Some branches depend on a value the generator will almost never produce by chance: an equality against a wide constant (`token == 0x5F3759DF`), a parsed magic number, a specific string. Every wrong value takes the same branch, so coverage cannot tell the search it is getting closer. With `trace-cmp` in the coverage flags, Exhaust reads the operands of the code's own comparisons and feeds them back into the search in two ways:

- **Direct substitution.** Where a stored input contains an integer choice whose type and declared range can hold the operand, Exhaust writes the operand into that choice and tries the result. It can also write into several matching choices at once, for a precondition that needs many positions to agree.
- **Backward solving.** Where the generator is reflective, Exhaust works backward through the generator to the choices that produce the wanted value. This covers whole values, strings, and structs compared field by field.

It helps where the wanted value is rare, and where several generated values must agree at once, which random draws rarely deliver even over a small domain. A byte or a printable character sees no benefit on its own, because ordinary generation already produces every value there.

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

Backward solving needs a reflective generator, one Exhaust can run backward from a value to the choices that produced it. `#examine` reports whether a generator is reflective. A forward-only `map` breaks the chain, and direct substitution then carries the operands alone, reaching integer choices only. The flag itself costs almost nothing in throughput.

### When the run cannot see the code

Two runtime messages cover this, so a run that cannot see the code does not pass quietly.

- **No coverage at all.** The run fails with a diagnostic. In a release build the usual cause is the inlining described under <doc:#Release-builds>. Otherwise the property's work ran on an executor the run did not bind.
- **Some coverage missed.** The summary reports "N edge hits fired off the run's lane and were not searched". Either the property handed work to another executor, or another test exercised the same instrumented code at the same time. The count cannot tell which, so read it against what the suite was doing.

Behind both, `trace-pc-guard` records through a context bound to the running lane, the executor Exhaust runs the property on. That is what lets separate runs share a process, and it is also the limitation. A `@MainActor` function, an actor with a custom executor, or work inside a detached task runs somewhere else, and its branches are not recorded. Measured on the same five-branch function reached four ways:

| the property's work runs | counters | guards |
|---|---|---|
| directly, on the run's lane | recorded | recorded |
| inside a default actor | recorded | recorded |
| inside a `@MainActor` function | recorded | **not recorded** |
| inside a detached task | recorded | **partly recorded** |

A default actor is fine because it has no executor of its own and adopts the calling task's, which is the run's lane.

The compiler rules out the two obvious ways to put a property's work on the main actor. A property closure cannot be marked `@MainActor`, because the parameter is nonisolated. A `@Command` cannot be marked `@MainActor`, because synthesised command dispatch is nonisolated. The unrecorded case arises only when a nonisolated property `await`s main-actor work.

### Counter-based instrumentation

`inline-8bit-counters`, used **in place of** `trace-pc-guard`, writes to a process-global table instead of a per-run context. It records work wherever it runs, including on executors the run did not bind.

The cost is that the whole process shares the table. Two coverage-guided runs in one process clear each other's counters, and any other test executing instrumented code during an attempt pollutes the signal. A counter build therefore needs the process to itself: `swift test --no-parallel`, or a filter down to one fuzz test. `swift package explore --no-parallel` selects counters and serial execution together. With manual instrumentation, replace the guard flags with counter flags and run `swift test --no-parallel`.

A build carrying both recorders is refused with a configuration error. The two number their edges independently, so a run reads only one of them, and nothing in the build says which. Check every target in the dependency graph, since flags on a library and different flags on the test target put both into one process.

### Getting a clean signal

The search is driven by one signal: the set of branches each attempt reached. It decides what enters the corpus, what gets mutated next, and what the stopping verdict says. Three conditions, all yours to control, decide how much of that signal is real.

#### Nothing else in the process (counter builds only)

A `trace-pc-guard` build records through a per-run context, so other tests in the process cannot reach it and this condition does not apply.

With counters, Exhaust measures one attempt at a time: it zeroes the counters, runs the property once, and reads back what was hit. Any other code executing in an instrumented module during that window is indistinguishable from the property's own behaviour. Only code running *during* an attempt matters, because each attempt re-zeroes the counters.

`.serialized` alone does not give you that. It orders tests within one suite, but other suites still run concurrently. Either run the whole target with `swift test --no-parallel`, or filter each run down to a single fuzz test. Filtering is stronger: a finished test can still have background work running (a detached task, an unawaited timer), and an empty process has nothing to leak.

Pollution only adds branches, never removes them. The result is inputs admitted for novelty they did not earn, a search that wanders, and a replay that cannot follow the original run.

#### Instrument only the code under test

Exhaust records coverage while the property runs and nowhere else, so generating the input costs nothing in signal. Everything the property executes inside an instrumented module counts. Instrumenting modules beyond the code under test adds branches that say nothing about the property, and an input can look novel for reaching one in a helper library. Prefer the per-target flags on the narrowest set of targets that covers the code the property exercises. In a release build that set includes the calling module, for the reason given under <doc:#Release-builds>.

#### Replay under the conditions of the original run

The seed pins every decision the search makes: the screening rows, the sampling stream, and each mutation choice. What the search observes between decisions depends on the environment. Coverage comes from the instrumented code as it actually ran, and phase transitions are wall-clock cuts. Give a replay the same build (recompiled code moves branches), the same isolation, and at least the original budget. Expect it to rediscover the same counterexamples rather than repeat the original log attempt for attempt.

One exception: after a crash, a rerun recovers the crashed campaign even when `.replay` is passed (see <doc:#Crash-recovery>).

## Crash recovery

A fuzzing run can find an input that traps: a `fatalError`, a failed precondition, an out-of-bounds subscript. A trap kills the test process and any report with it, so Exhaust checkpoints its progress to disk during the run: the corpus, the counterexamples found so far, and which input is being evaluated.

Rerun the test and Exhaust reports the trapping input, quarantines that region so mutation does not immediately rediscover it, and continues the search from the restored corpus for the rest of the budget. Recovery takes precedence over `.replay`, because a trapping input is worth more than a faithful rerun. If the instrumented code changed between crash and rerun, Exhaust re-measures the restored inputs against the rebuilt code before resuming.

For runs of ten minutes or longer, the checkpoint stores the trapping input itself. Shorter runs store only its hash and the input it was mutated from, and the rerun reports that parent instead. A short run is cheap to reproduce by running it again, and a long campaign is not. Storing the input costs about 8% of throughput on a fast property, so a run just over ten minutes searches slightly slower than one just under.

Checkpoints are removed when a run completes normally. Where they live depends on the workflow:

- **`explore` command:** the printed crash-recovery directory in the build workspace, or `<path>/state/` when you pass `--output <path>`.
- **Manual instrumentation and executables:** `EXHAUST_STATE_DIR`, or the system temporary directory when that is unset. Set it on CI, where each step may get a fresh temporary directory.

Set `EXHAUST_RESUME=0` to ignore a crashed predecessor's state and start fresh. Exhaust still writes checkpoints for the new run.

A rerun recovers a campaign only when it has the same identity: the enclosing Swift Testing test, the macro's source location, and the explicit seed. Keep the original seed (or leave it unset if the original run did), since changing or adding a seed selects a different checkpoint. Two runs with the same identity cannot run at once, and the second fails with a configuration error. That is why parameterised campaigns at one call site need distinct explicit seeds. <doc:ExploreCommandReference> describes the store layout and locking in detail.

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
| `mode: .tasks` | Supported for async specs. Requires macOS 15, iOS 18, tvOS 18, watchOS 11, or visionOS 2. No version requirement on Linux and Windows. The search mutates commands and their lane assignments, and reduction minimises concurrency back toward one command at a time. `.parallelize(lanes:)` sets the lane count (default two). |
| `mode: .threads` | Not available. It does not compile. |

Under `.threads` the same command sequence takes different branches depending on how the OS interleaves the lanes, so coverage stops describing the input and the search chases the scheduler. To search interleavings, use `mode: .tasks`, where the lane assignment is part of the generated input and is mutated, replayed, and reduced with it. To find data races, run the spec under `#execute` with `mode: .threads`, which relies on repetition rather than coverage.

## Running outside a test

An executable that depends on Exhaust can also await `#explore(time:)`, for example a long-running fuzzing job on a build machine. The `explore` command drives campaigns only through `swift test`, so add the coverage flags to the executable target yourself, as described in <doc:#Setting-up-coverage-instrumentation-manually>.

Without a running test, Exhaust has nowhere to record its findings. Failures, configuration errors, and the missing-instrumentation warning all go to IssueReporting's default reporter. On Apple platforms that reporter writes them to the system log as runtime issues: Xcode shows them while it is debugging the process, but a terminal shows nothing, and the process still exits successfully. On other platforms the reporter prints them to standard error.

Read the returned ``FuzzReport`` instead, and set the exit status from it:

```swift
import Exhaust
import Foundation

let report = await #explore(myInputGenerator, time: .minutes(30)) { input in
    try MyParser.parse(input).isWellFormed
}
print(report.renderedSummary())
guard report.outcome == .passed else {
    print(report.renderedAttachmentSummary())
    exit(EXIT_FAILURE)
}
```

Check ``FuzzReport/outcome`` here too, for the reasons given under <doc:#Asserting-on-the-report>. Outside a test, these runs end with no clusters but not with a pass:

- A run without instrumentation is ``FuzzReport/Outcome/skipped``.
- A run with an invalid setting, unreachable coverage, a failed generator, work that escaped the property, or a property that judged no input is ``FuzzReport/Outcome/error``.
- A run that continued a crashed predecessor is ``FuzzReport/Outcome/failed``, because the predecessor's trap is a finding.

A few other things change without a test:

- **No attachments.** Exhaust records the summary and cluster text only through a test framework. `renderedAttachmentSummary()` returns the same text.
- **No test identity.** Checkpoints use `standalone` in place of the test name. Two unseeded campaigns at the same call site therefore share one checkpoint identity, and the second fails with a configuration error while the first holds it. Give each a distinct explicit seed.
- **No JSON report.** `report.json` and `events.jsonl` come from the `explore` command.

Crash recovery works as it does in a test.

## Topics

### Settings and Results

- ``PropertyFuzzSettings``
- ``StateMachineFuzzSettings``
- ``FuzzReport``
- ``TimeSpan``

### Command Reference

- <doc:ExploreCommandReference>
