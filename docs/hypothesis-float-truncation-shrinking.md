# Float Truncation Shrinking in Hypothesis

## Overview

When Hypothesis shrinks a failing test case containing floating-point numbers, it needs a way to systematically find "simpler" float values that still reproduce the failure. The **truncation shrinking** technique provides an efficient approach to this problem.

## The Problem with Floating-Point Shrinking

IEEE-754 doubles have 52 bits of mantissa (significand) precision. Naively trying to shrink a float by decrementing its value bit-by-bit would require up to 2^52 iterations—completely impractical.

Additionally, IEEE-754 bit ordering doesn't correspond to intuitive "simplicity." For example, simply decrementing the integer representation doesn't reliably produce "simpler" floats.

## The Truncation Approach

The insight behind truncation shrinking is that we can reduce float precision by scaling, truncating to an integer, then scaling back:

```python
for p in range(10):
    scaled = self.current * 2**p
    for truncate in [math.floor, math.ceil]:
        self.consider(truncate(scaled) / 2**p)
```

### How It Works

For a float `f`, scaling by `2^p` effectively shifts the binary point left by `p` bits:

| p | Operation | Effect |
|---|-----------|--------|
| 0 | `f × 1` | Original value (full precision) |
| 1 | `f × 2` | Binary point shifted left 1 bit |
| 2 | `f × 4` | Binary point shifted left 2 bits |
| ... | ... | ... |
| 9 | `f × 512` | Binary point shifted left 9 bits |

After scaling, we truncate (either floor or ceil) to an integer, then divide back by `2^p`.

### Example Walkthrough

Using `f = 3.14159`:

| p | Scale | Calculation | floor() Result | Precision Lost |
|---|-------|-------------|----------------|----------------|
| 0 | ×1 | 3.14159 × 1 | 3.0 | Full → Integer |
| 1 | ×2 | 3.14159 × 2 = 6.28318 | 3.0 | Full → Integer |
| 2 | ×4 | 3.14159 × 4 = 12.5664 | 3.0 | Full → Integer |
| 3 | ×8 | 3.14159 × 8 = 25.1327 | 3.125 | 3 bits |
| 4 | ×16 | 3.14159 × 16 = 50.2655 | 3.125 | 4 bits |
| 5 | ×32 | 3.14159 × 32 = 100.531 | 3.125 | 5 bits |
| 6 | ×64 | 3.14159 × 64 = 201.062 | 3.140625 | 6 bits |
| 7 | ×128 | 3.14159 × 128 = 402.124 | 3.140625 | 7 bits |
| 8 | ×256 | 3.14159 × 256 = 804.248 | 3.140625 | 8 bits |
| 9 | ×512 | 3.14159 × 512 = 1608.5 | 3.140625 | 9 bits |

Using `ceil()` instead of `floor()` at each step produces slightly different values:

| p | ceil() Result (p=0-4) |
|---|----------------------|
| 0 | 4.0 |
| 1 | 4.0 |
| 2 | 4.0 |
| 3 | 3.25 |
| 4 | 3.25 |

## Why This Works Well

### 1. Order from Coarse to Fine

The shrinker tries `p = 0, 1, 2, ...` in order, meaning it finds the **coarsest** (simplest) precision that still fails the test. This aligns with the shortlex principle: simpler values first.

### 2. Naturally Finds Integer Boundaries

At `p = 0`, truncation always produces an integer. Since integers are intuitively "simpler" than floats, this is the first thing the shrinker tries.

### 3. Binary-Aligned Precision Reduction

Scaling by powers of 2 means we're removing high bits of the mantissa first—the most significant reductions in complexity. This mirrors how floating-point arithmetic naturally loses precision.

### 4. Exhaustive Within Each Precision Level

By trying both `floor()` and `ceil()`, we explore both directions at each precision level, ensuring we don't miss a valid shrink.

## The Range Limit: Why 10?

The current implementation uses `range(10)`, meaning `p = 0` through `p = 9`. This is a practical tradeoff:

- **Lower values** (0-2): Most dramatic simplification, often hitting integers
- **Medium values** (3-6): Good balance of simplicity vs. finding the failure
- **Higher values** (7-9): Very close to original, rarely needed but cheap to try

Going beyond 10 would add significant compute with diminishing returns—the test case usually fails at lower precision levels if it will at all.

## Integration with Other Shrinking Techniques

Truncation is just one step in the float shrinker's algorithm. The full flow:

1. **Short circuit**: Try special values (`max`, `inf`, `nan`) first
2. **Truncation**: Try the `p = 0...9` truncations
3. **Integer conversion**: If the float is now integral, delegate to `Integer` shrinker
4. **Fraction minimization**: Use `as_integer_ratio()` to reduce the fractional part

This combination ensures comprehensive shrinking while remaining performant.

## Swift Implementation

```swift
/// Try truncation shrinks at various precision levels
/// - Parameter current: The current float value being shrunk
/// - Returns: Whether any truncation was accepted
func tryTruncationShrinks(_ current: Double) -> Bool {
    // Try p = 0 through 9 (scale by 2^p)
    for p in 0..<10 {
        let scaled = current * pow(2.0, Double(p))
        
        // Try both floor and ceil
        if let shrunk = tryShrink(scaled, direction: .floor, p: p) {
            return shrunk
        }
        if let shrunk = tryShrink(scaled, direction: .ceil, p: p) {
            return shrunk
        }
    }
    return false
}

func tryShrink(_ scaled: Double, direction: TruncateDirection, p: Int) -> Bool? {
    let truncated: Double
    switch direction {
    case .floor:
        truncated = floor(scaled)
    case .ceil:
        truncated = ceil(scaled)
    }
    
    let result = truncated / pow(2.0, Double(p))
    
    // Test if this simpler value still fails the predicate
    if predicate(result) {
        current = result
        return true
    }
    return nil
}
```

## Summary

| Aspect | Description |
|--------|-------------|
| **Technique** | Scale → Truncate → Unscale |
| **Scale factors** | Powers of 2: 2^0 through 2^9 |
| **Truncation** | Both floor and ceil at each level |
| **Order** | Coarse (low p) to fine (high p) |
| **Benefit** | Binary-aligned precision reduction |
| **Limit** | 10 levels (practical tradeoff) |

This approach elegantly transforms the intractable problem of shrinking 52-bit mantissas into just 20 targeted attempts that systematically explore simpler representations.
