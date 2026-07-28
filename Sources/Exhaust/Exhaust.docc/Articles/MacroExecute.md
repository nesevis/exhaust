# \#execute

Run a state machine spec against a stateful system.

## Overview

`#execute` generates command sequences, runs them against the system under test, checks the spec's invariants wherever the state is settled, and reduces failures to a minimal sequence. Always awaited. `mode:` is required, and it selects whether the commands run one at a time, interleaved across tasks, or on real OS threads.

```swift
@Test func queueBehavesCorrectly() async {
    await #execute(QueueSpec.self, mode: .sequential, .commandLimit(15), .budget(.thorough))
}
```

| Parameter | Description |
|---|---|
| `specType` | The `@StateMachine` spec class to run. |
| `mode` | An ``ExecutionModel``: `.sequential`, `.tasks`, or `.threads`. |
| `settings` | Variadic ``StateMachineSettings`` values: command limit, budget, lanes, replay, timeout, suppression. |

Returns a ``StateMachineResult`` with the reduced command sequence and trace on failure, or `nil` if all sequences pass.

For the full guide, see <doc:StateMachineTesting>.

## Coverage-guided fuzzing with time:

Coverage-guided fuzzing over command sequences is spelled `#explore`, which takes a spec in place of the generator its value-searching form expects. Exhaust mutates sequences from a corpus toward novel SUT coverage until the time budget is consumed, cataloguing every distinct fault it discovers.

> Experiment: This mode is experimental. Settings, report format, and search behaviour may change in any release.

```swift
@Test func boundedQueueDeepFaults() async {
    await #explore(BoundedQueueSpec.self, mode: .sequential, time: .minutes(5))
}
```

| Parameter | Description |
|---|---|
| `specType` | The `@StateMachine` spec to run. |
| `mode` | A ``SearchableExecutionModel``: `.sequential` or `.tasks`. Coverage-guided search cannot use `.threads`. |
| `time` | Wall-clock ``TimeSpan`` for the run (for example `.minutes(5)`). |
| `settings` | Variadic ``FuzzSettings`` values: replay, suppression, log verbosity, `.commandLimit(n)`. |

Requires coverage instrumentation on the target under test. Returns a ``FuzzReport`` with the clustered fault inventory, attempt counts, throughput, and coverage summary.

For the full guide, see <doc:CoverageGuidedFuzzing>.
