# Shrinking Strategy Analysis: Semantic vs SIMD Performance

## Problem Statement

The current shrinking implementation in Exhaust has a fundamental issue where signed integer shrinking produces counterintuitive results. The test `testWithASmallShrunkenNumber` demonstrates this:

- **Input**: `Int(33)` with property `thing % 2 == 0 && thing < 10 && thing > 0` (find small even positive numbers)
- **Expected**: Should shrink toward `1` (smallest failing value)
- **Actual**: Shrinks to `Int.min` (-9223372036854775808)

## Root Cause Analysis

### The XOR Sign Bit Normalization Problem

The issue stems from how signed integers are mapped to `UInt64` values for uniform shrinking:

```swift
extension Int: BitPatternConvertible {
    private static let signBitMask: UInt64 = 0x8000000000000000
    
    public var bitPattern64: UInt64 {
        return UInt64(bitPattern: Int64(self)) ^ Self.signBitMask
    }
    
    public init(bitPattern64: UInt64) {
        self = Int(Int64(bitPattern: bitPattern64 ^ Self.signBitMask))
    }
}
```

### Mapping Analysis

This XOR approach creates a problematic mapping:
- `Int(0)` → `UInt64(9223372036854775808)` (middle of UInt64 range)
- `Int(33)` → `UInt64(9223372036854775841)` (very large UInt64)
- `Int.min` → `UInt64(0)` (smallest UInt64)
- `Int.max` → `UInt64(18446744073709551615)` (largest UInt64)

### Shrinking Behavior

The `shrinkNumberAggressively` function operates on UInt64 values and naturally tries to minimize toward 0:

```
UInt64(9223372036854775841) // Int(33)
  ↓ (shrinking subtracts values)
UInt64(9223372036854775808) // Int(0)  
  ↓ (continues shrinking)
UInt64(0) // Int.min (-9223372036854775808)
```

The shrinker finds `Int.min` because `UInt64(0)` corresponds to the most negative integer, not the semantically minimal value of `0`.

## Investigation: Semantic vs SIMD Performance Tradeoffs

### SIMD Requirements and Benefits

The choice of UInt64 as the base type serves critical performance purposes:

1. **Uniformity**: All types use identical UInt64 arithmetic operations
2. **Vectorization**: SIMD instructions can process multiple shrink candidates simultaneously:
   ```swift
   let candidates = SIMD8<UInt64>(base, base, base, base, base, base, base, base)
   let shrinks = SIMD8<UInt64>(1, 2, 4, 8, 16, 32, 64, 128)
   let results = candidates - shrinks  // 8 subtractions in parallel
   ```
3. **Dense Memory Layout**: Cache-friendly arrays of UInt64 values
4. **Branchless Operations**: XOR conversion is fast and vectorizable

### Semantic Mapping Approaches

#### Approach 1: Interleaving for Signed Integers

**Concept**: Map semantically simpler values to smaller UInt64 values through interleaving:

```swift
extension Int: BitPatternConvertible {
    public var bitPattern64: UInt64 {
        // Even UInt64s for non-negative, odd for negative
        return self >= 0 ? UInt64(self) * 2 : UInt64(-self) * 2 - 1
    }
    
    public init(bitPattern64: UInt64) {
        self = (bitPattern64 % 2 == 0) ? Int(bitPattern64 / 2) : -Int((bitPattern64 + 1) / 2)
    }
}
```

**Mapping Results**:
- `Int(0)` → `UInt64(0)` ✅ (Perfect for shrinking!)
- `Int(1)` → `UInt64(2)`, `Int(-1)` → `UInt64(1)`
- `Int(2)` → `UInt64(4)`, `Int(-2)` → `UInt64(3)`
- `Int(33)` → `UInt64(66)`

**SIMD Compatibility**:
- ✅ **Branchless**: Uses conditional moves, fully vectorizable
- ✅ **Simple Operations**: Only multiply, negate, and basic arithmetic
- ✅ **Uniform**: Same formula for all integers

#### Approach 2: Complex Semantic Mapping for Floating Points

**Concept**: Create a hierarchy of floating point "simplicity":

```swift
extension Double: BitPatternConvertible {
    public var bitPattern64: UInt64 {
        // Tier 1: Fundamental values (0-15)
        switch self {
        case 0.0: return 0
        case 1.0: return 1
        case -1.0: return 2
        case 2.0: return 3
        case -2.0: return 4
        // ... more special cases
        default:
            return mapByMagnitudeAndComplexity(self, startingAt: 1024)
        }
    }
}
```

**SIMD Impact Analysis**:
- ❌ **Switch Statements**: Not vectorizable
- ❌ **Complex Branching**: Breaks SIMD pipelines  
- ❌ **Lookup Tables**: Memory access patterns kill vectorization
- ❌ **Floating Point Operations**: `log2()`, `isPowerOf2()` not SIMD-friendly

#### Approach 3: Simple Magnitude-Based Floating Point Mapping

**Concept**: Keep SIMD-friendly approach but fix the `0.0` mapping:

```swift
extension Double: BitPatternConvertible {
    public var bitPattern64: UInt64 {
        let bits = self.bitPattern
        let sign_bit = bits >> 63
        let magnitude_bits = bits & 0x7FFFFFFFFFFFFFFF
        // Interleave: even UInt64s for positive, odd for negative
        return magnitude_bits * 2 + sign_bit
    }
}
```

**Results**:
- `0.0` → `UInt64(0)` ✅
- `1.0` → `UInt64(9194533649915854848)` (still very large)
- `-1.0` → `UInt64(9194533649915854849)`

**Analysis**: Even with this fix, floating point values like `1.0` still map to enormous UInt64 values due to IEEE 754 structure. The semantic benefit is minimal.

## Tradeoff Analysis

### Signed Integers: Strong Case for Semantic Mapping

**Benefits**:
- ✅ **Major Semantic Win**: Fixes the core shrinking problem where `Int(33)` shrinks to `Int.min`
- ✅ **Perfect SIMD Compatibility**: Branchless, vectorizable operations
- ✅ **Intuitive Results**: `Int(0)` becomes the natural shrinking target
- ✅ **Minimal Overhead**: 2-3 extra operations vs single XOR

**Costs**:
- ❌ **Slight Performance**: Additional multiply/divide operations
- ❌ **Range Reduction**: Only uses half the UInt64 space per sign (but this is rarely limiting)

### Floating Points: SIMD Performance Wins

**Semantic Mapping Challenges**:
- ❌ **Limited Benefit**: Even `0.0` → `UInt64(0)` doesn't help much when `1.0` maps to ~9e18
- ❌ **IEEE Complexity**: "Simple" floating point values are scattered across bit patterns
- ❌ **Test Failure Patterns**: Floating point bugs usually involve precision/edge cases, not "finding 0.0"
- ❌ **SIMD Destruction**: Complex semantic mapping breaks vectorization entirely

**Current XOR Benefits**:
- ✅ **Maximum SIMD Performance**: Single XOR, fully vectorizable
- ✅ **Full Range Usage**: Efficient utilization of UInt64 space
- ✅ **Magnitude Preservation**: IEEE structure maintains approximate ordering
- ✅ **Proven Approach**: Less complexity, fewer edge cases

## Recommendations

### Hybrid Strategy: Type-Specific Optimization

Apply semantic mapping where it provides clear wins, maintain SIMD performance where it matters most:

```swift
// Signed integers: Use semantic interleaving
extension Int: BitPatternConvertible {
    public var bitPattern64: UInt64 {
        return self >= 0 ? UInt64(self) * 2 : UInt64(-self) * 2 - 1
    }
    
    public init(bitPattern64: UInt64) {
        self = (bitPattern64 % 2 == 0) ? Int(bitPattern64 / 2) : -Int((bitPattern64 + 1) / 2)
    }
}

// Floating points: Keep XOR approach  
extension Double: BitPatternConvertible {
    private static let signBitMask: UInt64 = 0x8000000000000000
    
    public var bitPattern64: UInt64 {
        self.bitPattern ^ Self.signBitMask
    }
    
    public init(bitPattern64: UInt64) {
        let normalizedBitPattern = bitPattern64 ^ Self.signBitMask
        self = Double(bitPattern: normalizedBitPattern)
    }
}
```

### Implementation Impact

**Expected Improvements**:
- Fixed shrinking for signed integers (the main problem)
- Maintained SIMD performance for floating points
- Type-appropriate optimization strategies
- Preserved uniform UInt64 arithmetic in shrinking algorithms

**Test Case Verification**:
The failing `testWithASmallShrunkenNumber` would now behave correctly:
- `Int(33)` → `UInt64(66)`
- Shrinking: `66 → 64 → 62 → ... → 4 → 2 → 0`
- Back to Int: `33 → 32 → 31 → ... → 2 → 1 → 0`
- Property `thing % 2 == 0 && thing < 10 && thing > 0` would find `1` as the minimal failing case

## Key Insights

1. **SIMD Uniformity**: The requirement for uniformity is at the UInt64 arithmetic level, not the conversion level. Different types can use different conversion strategies.

2. **Cost-Benefit Analysis**: Semantic improvements must be weighed against SIMD performance. For signed integers, the semantic gain is enormous with minimal SIMD cost. For floating points, the semantic gain is minimal with huge SIMD costs.

3. **Problem Domains**: Signed integer shrinking failures often involve finding boundary values (0, 1, -1), where semantic mapping helps enormously. Floating point failures often involve precision or special values, where bit-pattern shrinking is more appropriate.

4. **Pragmatic Approach**: Perfect semantic mapping for all types is not necessary. Fixing the most problematic cases (signed integers) while preserving performance for others is the optimal strategy.

## Conclusion

The hybrid approach provides the best balance:
- **Semantic mapping for signed integers**: Fixes the core shrinking problem with minimal performance impact
- **XOR mapping for floating points**: Preserves maximum SIMD performance where semantic gains are limited
- **Maintained system uniformity**: All types still produce UInt64 values for identical shrinking algorithms
- **Type-specific optimization**: Each type gets the conversion strategy that maximizes its benefit/cost ratio

This addresses the original shrinking problem while preserving the SIMD performance benefits that motivated the UInt64-based approach.

## Advanced Framework: Semantic Complexity Protocol

### Evolution Beyond BitPatternConvertible

The hybrid approach reveals a deeper architectural opportunity: **semantic complexity scoring**. Instead of forcing all types through bit pattern conversions, we can design a unified system where each type maps values to "complexity scores" - UInt64 values representing how semantically simple a value is.

### Core Architecture: SemanticComplexity Protocol

```swift
protocol SemanticComplexity {
    var complexityScore: UInt64 { get }
    init(complexityScore: UInt64)
}
```

This protocol enables **type-specific semantic optimization** while maintaining **uniform shrinking algorithms**:

```swift
// Shrinking operates uniformly on complexity scores
func shrinkComplexity<T: SemanticComplexity>(_ value: T) -> [T] {
    let score = value.complexityScore
    let shrunkScores = shrinkUInt64Aggressively(score)  // Same SIMD algorithm
    return shrunkScores.compactMap { T(complexityScore: $0) }
}
```

### Type-Category-Specific Implementations

#### Unsigned Integers: Zero-Cost Semantic Mapping
```swift
extension UInt64: SemanticComplexity {
    var complexityScore: UInt64 { self }  // Magnitude equals complexity
    init(complexityScore: UInt64) { self = complexityScore }
}
```

#### Signed Integers: Interleaved Semantic Mapping
```swift
extension Int: SemanticComplexity {
    var complexityScore: UInt64 {
        // Even scores for non-negative, odd for negative
        self >= 0 ? UInt64(self) * 2 : UInt64(-self) * 2 - 1
    }
    
    init(complexityScore: UInt64) {
        self = (complexityScore % 2 == 0) 
            ? Int(complexityScore / 2) 
            : -Int((complexityScore + 1) / 2)
    }
}
```

**Semantic Results**:
- `Int(0)` → complexity `0` (simplest value)
- `Int(1)` → complexity `2`, `Int(-1)` → complexity `1` 
- `Int(33)` → complexity `66`
- Natural shrinking: `33 → 32 → 31 → ... → 1 → 0`

#### Floating Point: SIMD-Optimized Bit Pattern Mapping
```swift
extension Double: SemanticComplexity {
    private static let signBitMask: UInt64 = 0x8000000000000000
    
    var complexityScore: UInt64 {
        self.bitPattern ^ Self.signBitMask  // Preserve SIMD performance
    }
    
    init(complexityScore: UInt64) {
        let normalizedBitPattern = complexityScore ^ Self.signBitMask
        self = Double(bitPattern: normalizedBitPattern)
    }
}
```

#### Characters: ASCII-Biased Semantic Complexity
```swift
extension Character: SemanticComplexity {
    var complexityScore: UInt64 {
        guard let scalar = self.unicodeScalars.first else { return UInt64.max }
        let value = scalar.value
        
        // Branchless calculation for SIMD compatibility
        let isASCII = value < 128 ? 0 : 10000
        let spaceBonus = value == 32 ? value : 0  // Make space complexity 0
        
        return UInt64(value - spaceBonus + isASCII)
    }
    
    init(complexityScore: UInt64) {
        // Map complexity back to Unicode scalar
        let adjustedValue: UInt32
        if complexityScore >= 10128 {
            adjustedValue = UInt32(complexityScore - 10000)
        } else if complexityScore == 0 {
            adjustedValue = 32  // Space character
        } else {
            adjustedValue = UInt32(complexityScore)
        }
        
        guard let scalar = UnicodeScalar(adjustedValue) else {
            self = " "  // Fallback to space
            return
        }
        self = Character(scalar)
    }
}
```

**Character Shrinking Semantics**:
- `' '` (space) → complexity `0` (most common/simple)
- `'0'` → complexity `48` (simple digit)
- `'a'` → complexity `97` (common letter)
- `'🚀'` → complexity `10000+` (Unicode/complex)

Random Unicode characters shrink toward printable ASCII, eventually reaching space.

### Architectural Benefits

#### 1. Semantic Separation
**Complexity mapping happens once per value**, then uniform UInt64 minimization takes over. This cleanly separates:
- Type-specific semantic concerns (what values are "simple")
- Universal shrinking algorithms (minimize UInt64 complexity scores)

#### 2. SIMD Performance Preservation
```swift
// Same vectorized algorithm for all types
let candidates = SIMD8<UInt64>(scores...)
let shrinks = SIMD8<UInt64>(1, 2, 4, 8, 16, 32, 64, 128)
let results = candidates - shrinks  // 8 subtractions in parallel
```

#### 3. Type-Appropriate Optimization
Each type gets the complexity mapping strategy that maximizes its semantic benefit/SIMD cost ratio:
- **Signed integers**: Major semantic fix with minimal SIMD impact
- **Floating points**: Maximum SIMD performance where semantic gains are limited
- **Characters**: Cultural simplicity bias with branchless calculation
- **Unsigned integers**: Zero-cost identity mapping

#### 4. Extensibility
New types can implement `SemanticComplexity` with domain-specific complexity definitions:
```swift
extension URL: SemanticComplexity {
    var complexityScore: UInt64 {
        // Shorter URLs are simpler
        // localhost/file URLs are simpler than remote URLs
        // Common schemes (http/https) are simpler
        // etc.
    }
}
```

### Implementation Strategy

**Phase 1**: Introduce `SemanticComplexity` protocol alongside existing `BitPatternConvertible`
**Phase 2**: Migrate core types (Int, UInt64, Double, Character) to use semantic complexity
**Phase 3**: Update shrinking algorithms to operate on complexity scores
**Phase 4**: Deprecate `BitPatternConvertible` in favor of the more semantic approach

### Expected Impact

**Test Case Resolution**:
The failing `testWithASmallShrunkenNumber` would now behave correctly:
- `Int(33)` → complexity `66`
- Shrinking: `66 → 64 → 62 → ... → 4 → 2 → 0`
- Back to Int: `33 → 32 → 31 → ... → 2 → 1 → 0`
- Property `thing % 2 == 0 && thing < 10 && thing > 0` finds `1` as the minimal failing case

**Performance Characteristics**:
- Signed integer conversion: ~2x slower than XOR, but enormous semantic benefit
- Floating point conversion: Identical performance to current XOR approach
- Character conversion: Minimal overhead with significant semantic improvement
- Unsigned integer conversion: Zero overhead (identity mapping)

**Developer Experience**:
- Intuitive shrinking behavior across all types
- Predictable complexity ordering within each type
- Type-specific semantic optimizations
- Maintained SIMD performance where it matters most

### Key Innovation

The **semantic complexity framework** resolves the false dichotomy between "uniform bit patterns" and "semantic shrinking". By moving uniformity to the algorithmic level (UInt64 complexity scores) rather than the representation level (bit patterns), we achieve:

1. **Semantic correctness** for types where it provides major benefits (signed integers, characters)
2. **SIMD performance** for types where semantic mapping is expensive or unnecessary (floating points)
3. **Uniform algorithms** that work identically across all types
4. **Type-specific optimization** strategies based on cost-benefit analysis

This approach transforms shrinking from a bit-manipulation technique into a **semantic complexity minimization system** while preserving all the performance benefits that motivated the original UInt64-based design.