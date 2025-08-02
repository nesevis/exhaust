# Exhaust Framework Public API Design Document

**Version:** 1.0  
**Date:** August 2025  
**Authors:** Framework Design Team

## Executive Summary

This document proposes a comprehensive redesign of Exhaust's public API to address fundamental usability and type safety concerns. The current API exposes complex internal generics and doesn't clearly communicate when operations break reflection capabilities. 

The proposed design introduces capability-aware wrapper types that hide implementation complexity while providing compile-time guarantees about generator behavior, inspired by the successful patterns used in Apple's Combine and SwiftUI frameworks.

## Current State Analysis

### Problems with Current API

1. **Complex Generic Exposure**
   ```swift
   // Current: Exposes internal complexity
   ReflectiveGenerator<Input, Output>
   FreerMonad<ReflectiveOperation<Input>, Output>
   ```

2. **Silent Capability Loss**
   ```swift
   // Breaks reflection silently
   let gen = Gen.zip(String.arbitrary, Int.arbitrary).map(Person.init)
   // gen can no longer be reflected, but type system doesn't indicate this
   ```

3. **Poor Discoverability**
   - No clear distinction between reflective and non-reflective operations
   - Generic constraints make API exploration difficult
   - Internal implementation details leak through

4. **Runtime Failures**
   ```swift
   // Compiles but fails at runtime during property testing
   let brokenGen = someGenerator.map(irreversibleTransform)
   PropertyTest.check(property, using: brokenGen) // Runtime error
   ```

## Proposed Design

### Core Architecture

#### Public Types

```swift
/// A generator that can produce values but may not support reflection
public struct Generator<Output> {
    internal let _implementation: AnyGenerator<Output>
    internal let _capability: GeneratorCapability
}

/// A generator that guarantees reflection support for property testing
public struct ReflectiveGenerator<Output> {
    internal let _implementation: AnyGenerator<Output>
    // Capability is always .reflective
}

/// Internal capability tracking
internal enum GeneratorCapability {
    case reflective
    case generateOnly
}
```

#### Type-Erased Implementation

```swift
/// Internal type-erased generator implementation
internal struct AnyGenerator<Output> {
    private let _generate: (inout GeneratorIterator) -> Output?
    private let _reflect: ((Output) -> Recipe?)?
    private let _shrink: ((Output, Recipe) -> [Output])?
    private let _metadata: GeneratorMetadata
    
    init<Input>(_ generator: FreerMonad<ReflectiveOperation<Input>, Output>) {
        // Type erasure implementation
    }
}

internal struct GeneratorMetadata {
    let supportsReflection: Bool
    let optimizations: Set<OptimizationHint>
    let debugDescription: String
}
```

### Public API Design

#### Factory Methods

```swift
public struct Gen {
    // Core generators - always reflective
    public static func constant<T>(_ value: T) -> ReflectiveGenerator<T>
    public static func choose<T: Numeric>(in range: ClosedRange<T>) -> ReflectiveGenerator<T>
    public static func element<T>(of collection: [T]) -> ReflectiveGenerator<T>
    public static func optional<T>(_ generator: ReflectiveGenerator<T>) -> ReflectiveGenerator<T?>
    
    // Composite generators
    public static func array<T>(
        of generator: ReflectiveGenerator<T>,
        count: ClosedRange<Int> = 0...10
    ) -> ReflectiveGenerator<[T]>
    
    public static func set<T: Hashable>(
        of generator: ReflectiveGenerator<T>,
        count: ClosedRange<Int> = 0...10
    ) -> ReflectiveGenerator<Set<T>>
    
    // Combination generators
    public static func zip<A, B>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>
    ) -> ReflectiveGenerator<(A, B)>
    
    public static func zip<A, B, C>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>
    ) -> ReflectiveGenerator<(A, B, C)>
    
    // One-way combination (loses reflection)
    public static func combineLatest<A, B>(
        _ a: Generator<A>,
        _ b: Generator<B>
    ) -> Generator<(A, B)>
}
```

#### Capability-Aware Transformations

```swift
extension ReflectiveGenerator {
    /// Bidirectional mapping that preserves reflection capability
    public func map<NewOutput>(
        forward: @escaping (Output) -> NewOutput,
        backward: @escaping (NewOutput) -> Output
    ) -> ReflectiveGenerator<NewOutput>
    
    /// Explicit one-way mapping that loses reflection
    public func mapOneWay<NewOutput>(
        _ transform: @escaping (Output) -> NewOutput
    ) -> Generator<NewOutput>
    
    /// Filtering with bidirectional support
    public func filter(
        _ predicate: @escaping (Output) -> Bool,
        inverse: @escaping (Output) -> [Output]
    ) -> ReflectiveGenerator<Output>
    
    /// Simple filtering (loses reflection)
    public func filterOneWay(
        _ predicate: @escaping (Output) -> Bool
    ) -> Generator<Output>
}

extension Generator {
    /// One-way mapping (already non-reflective)
    public func map<NewOutput>(
        _ transform: @escaping (Output) -> NewOutput
    ) -> Generator<NewOutput>
    
    /// Filtering
    public func filter(
        _ predicate: @escaping (Output) -> Bool
    ) -> Generator<Output>
    
    /// Attempt to convert to reflective (may return nil)
    public func asReflective() -> ReflectiveGenerator<Output>?
}
```

#### Protocol-Based Arbitrary Generation

```swift
/// Types that can be generated with reflection support
public protocol ArbitraryReflective {
    static var arbitrary: ReflectiveGenerator<Self> { get }
}

/// Types that can be generated (may not support reflection)
public protocol ArbitraryGenerate {
    static var arbitrary: Generator<Self> { get }
}

// Standard library conformances
extension String: ArbitraryReflective {
    public static var arbitrary: ReflectiveGenerator<String> {
        Gen.array(of: Character.arbitrary)
            .map(
                forward: String.init,
                backward: Array.init
            )
    }
}

extension Int: ArbitraryReflective {
    public static var arbitrary: ReflectiveGenerator<Int> {
        Gen.choose(in: Int.min...Int.max)
    }
}
```

### Builder Pattern Support

```swift
@resultBuilder
public struct GeneratorBuilder {
    public static func buildBlock<T>(
        _ generator: ReflectiveGenerator<T>
    ) -> ReflectiveGenerator<T> {
        generator
    }
    
    public static func buildBlock<A, B>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>
    ) -> ReflectiveGenerator<(A, B)> {
        Gen.zip(a, b)
    }
    
    public static func buildBlock<A, B, C>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>
    ) -> ReflectiveGenerator<(A, B, C)> {
        Gen.zip(a, b, c)
    }
    
    // Additional overloads for more parameters
}

// Usage example
public func person(
    @GeneratorBuilder builder: () -> ReflectiveGenerator<(String, Int, String)>
) -> ReflectiveGenerator<Person> {
    builder().map(
        forward: Person.init,
        backward: { p in (p.name, p.age, p.email) }
    )
}

let personGen = person {
    String.arbitrary
    Int.arbitrary
    String.arbitrary
}
```

### Property Testing Integration

```swift
public struct PropertyTest {
    /// Full property testing with reflection and shrinking
    public static func check<T>(
        _ property: @escaping (T) -> Bool,
        using generator: ReflectiveGenerator<T>,
        iterations: Int = 100
    ) -> TestResult
    
    /// Property testing without shrinking
    public static func checkWithoutShrinking<T>(
        _ property: @escaping (T) -> Bool,
        using generator: Generator<T>,
        iterations: Int = 100
    ) -> TestResult
    
    /// Generate values for manual testing
    public static func generate<T>(
        _ generator: Generator<T>,
        count: Int = 10
    ) -> [T]
}

public struct TestResult {
    public let success: Bool
    public let iterations: Int
    public let counterexample: Any?
    public let shrinkingSteps: Int
}
```

## Implementation Strategy

### Phase 1: Internal Refactoring (Weeks 1-4)

1. **Create Type-Erased Infrastructure**
   - Implement `AnyGenerator<Output>`
   - Add capability tracking
   - Maintain full backward compatibility

2. **Internal API Migration**
   - Wrap existing generators in new types
   - Add capability inference
   - Create conversion utilities

3. **Testing Infrastructure**
   - Ensure all existing tests pass
   - Add capability tracking tests
   - Performance benchmarking

### Phase 2: Public API Introduction (Weeks 5-8)

1. **New Public Types**
   - Release `Generator<Output>` and `ReflectiveGenerator<Output>`
   - Provide migration utilities
   - Add comprehensive documentation

2. **Deprecation Warnings**
   - Mark old API as deprecated
   - Provide clear migration paths
   - Add compiler warnings with suggestions

3. **Standard Library Conformances**
   - Implement `ArbitraryReflective` for basic types
   - Provide extension points for user types
   - Create migration guide for existing conformances

### Phase 3: Optimization and Cleanup (Weeks 9-12)

1. **Performance Optimization**
   - Optimize type-erased implementations
   - Add specialized fast paths for common cases
   - Implement lazy evaluation where possible

2. **API Refinement**
   - Gather user feedback
   - Refine method signatures
   - Add convenience methods

3. **Legacy Removal**
   - Remove deprecated APIs
   - Clean up internal implementation
   - Finalize documentation

## Benefits Analysis

### Type Safety

**Before:**
```swift
let gen = someGenerator.map(irreversibleFunction)
PropertyTest.check(property, using: gen) // ❌ Runtime error
```

**After:**
```swift
let gen = someGenerator.mapOneWay(irreversibleFunction) // Generator<T>
PropertyTest.check(property, using: gen) // ❌ Compile error - clear expectation
```

### Discoverability

**Before:**
```swift
// Unclear what methods are available or safe to use
someGenerator. // Shows complex generic methods
```

**After:**
```swift
// Clear capability-based method availability
let reflectiveGen = String.arbitrary
reflectiveGen. // Shows: map(forward:backward:), mapOneWay(_:), filter, etc.

let oneWayGen = reflectiveGen.mapOneWay(String.init)
oneWayGen. // Shows: map(_:), filter(_:), but no bidirectional methods
```

### User Experience

**Before:**
```swift
// Complex, error-prone
Person.arbitrary = Gen.zip(String.arbitrary, Int.arbitrary, String.arbitrary)
    .mapped(
        forward: Person.init,
        backward: { p in (p.name, p.age, p.email) }
    )
```

**After:**
```swift
// Clean, discoverable
Person.arbitrary = Gen.zip(String.arbitrary, Int.arbitrary, String.arbitrary)
    .map(
        forward: Person.init,
        backward: { p in (p.name, p.age, p.email) }
    )

// Or with builder pattern
Person.arbitrary = person {
    String.arbitrary
    Int.arbitrary
    String.arbitrary
}
```

## Risk Assessment

### Technical Risks

1. **Type Erasure Performance**
   - **Risk:** Performance overhead from type erasure
   - **Mitigation:** Benchmark critical paths, optimize hot paths, provide escape hatches

2. **Swift Type System Limitations**
   - **Risk:** Complex generic constraints may not work as expected
   - **Mitigation:** Prototype key scenarios, have fallback designs

3. **Migration Complexity**
   - **Risk:** Breaking changes may be difficult for users
   - **Mitigation:** Comprehensive migration guide, automated migration tools

### User Experience Risks

1. **Learning Curve**
   - **Risk:** New API concepts may confuse existing users
   - **Mitigation:** Clear documentation, examples, migration guide

2. **API Complexity**
   - **Risk:** Two generator types may be confusing
   - **Mitigation:** Clear naming, good defaults, comprehensive examples

## Success Metrics

### Quantitative Metrics

1. **Compile-Time Safety**
   - 90% reduction in reflection-related runtime errors
   - Type errors caught at compile time instead of runtime

2. **API Usability**
   - 50% reduction in lines of code for common generator definitions
   - Improved auto-completion and discoverability metrics

3. **Performance**
   - No more than 5% performance regression
   - Faster compilation times due to reduced generic complexity

### Qualitative Metrics

1. **Developer Experience**
   - Positive feedback on API clarity
   - Reduced confusion about capability limitations
   - Easier onboarding for new users

2. **Maintainability**
   - Cleaner internal architecture
   - Easier to add new combinators
   - Better separation of concerns

## Conclusion

The proposed API redesign addresses fundamental usability and type safety issues in the current Exhaust framework. By introducing capability-aware wrapper types and following established patterns from Apple's frameworks, we can provide a clean, discoverable, and type-safe API while maintaining full backward compatibility during migration.

The design clearly communicates generator capabilities at the type level, prevents common runtime errors through compile-time checks, and provides a modern Swift API that follows current best practices. The phased implementation approach minimizes risk while allowing for thorough testing and user feedback.

## Next Steps

1. **Technical Review** - Review with engineering team for technical feasibility
2. **Prototype Development** - Build small prototype to validate key concepts
3. **User Research** - Gather feedback from current framework users
4. **Implementation Planning** - Detailed breakdown of implementation phases
5. **Documentation Planning** - Plan comprehensive documentation and migration guides

---

**Appendix A: Code Examples**  
**Appendix B: Migration Guide**  
**Appendix C: Performance Benchmarks**  
**Appendix D: Alternative Designs Considered**