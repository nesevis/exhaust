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
