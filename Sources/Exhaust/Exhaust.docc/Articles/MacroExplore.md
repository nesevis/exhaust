# \#explore

Test a property with per-direction coverage guarantees.

## Overview

`#explore` steers sampling toward named regions of the output space using Choice Gradient Sampling. Each direction is a predicate the test must reach; unreachable directions are reported rather than silently skipped.

```swift
#explore(orderGen,
    directions: [
        ("has refund",       { $0.hasRefund }),
        ("refund + partial", { $0.hasRefund && $0.fulfilment == .partial }),
    ]
) { order in
    #expect(order.balance.isValid)
}
```

| Parameter | Description |
|---|---|
| `gen` | The generator to draw inputs from. |
| `directions` | Named predicates over the output, each describing a region to cover. |
| `settings` | Variadic ``ExploreSettings`` values: budget, replay, parallelism, suppression. |
| `property` | Closure checked against each generated value. Async closures supported with `await`. |

Returns an ``ExploreReport`` with per-direction coverage and the counterexample if any.

For the full guide, see <doc:DirectedExploration>.
