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

## Searching under a time budget

`#execute` runs a fixed budget of sequences and stops at the first failure. To search command sequences under a wall-clock budget instead, cataloguing distinct counterexamples rather than stopping at one, pass the same spec to `#explore`:

```swift
@Test func boundedQueueDeepFaults() async {
    await #explore(BoundedQueueSpec.self, mode: .sequential, time: .minutes(5))
}
```

That mode is experimental, requires coverage instrumentation on the target under test, and returns a ``FuzzReport`` instead of a ``StateMachineResult``. See <doc:MacroExplore> for the parameters and <doc:CoverageGuidedFuzzing> for the full guide.
