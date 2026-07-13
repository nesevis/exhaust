# \#execute

Run a state machine spec against a stateful system.

## Overview

`#execute` generates command sequences, runs them against the system under test, checks invariants (or an oracle) after each step, and reduces failures to a minimal sequence. Always awaited.

```swift
@Test func queueBehavesCorrectly() async {
    await #execute(QueueSpec.self, .commandLimit(15), .budget(.thorough))
}
```

| Parameter | Description |
|---|---|
| `specType` | The `@StateMachine` spec class or actor to run. |
| `settings` | Variadic ``StateMachineSettings`` values: command limit, budget, lanes, replay, timeout, suppression. |

Returns a ``StateMachineResult`` with the reduced command sequence and trace on failure, or `nil` if all sequences pass.

For the full guide, see <doc:StateMachineTesting>.

## Coverage-guided fuzzing with time:

`#execute` also supports a `time:` mode that runs coverage-guided fuzzing over command sequences. Exhaust mutates sequences from a corpus toward novel SUT coverage until the time budget is consumed, cataloguing every distinct fault it discovers.

> Experiment: This mode is experimental. Settings, report format, and search behaviour may change in any release.

```swift
@Test func boundedQueueDeepFaults() async {
    await #execute(BoundedQueueSpec.self, time: .minutes(5))
}
```

| Parameter | Description |
|---|---|
| `specType` | The `@StateMachine` spec to run. `.sequential` and `.tasks` specs are supported. |
| `time` | Wall-clock ``TimeBudget`` for the run (for example `.minutes(5)`). |
| `settings` | Variadic ``FuzzSettings`` values: replay, suppression, log verbosity, `.commandLimit(n)`. |

Requires coverage instrumentation on the target under test. Returns a ``FuzzReport`` with the clustered fault inventory, attempt counts, throughput, and coverage summary.

For the full guide, see <doc:CoverageGuidedFuzzing>.
