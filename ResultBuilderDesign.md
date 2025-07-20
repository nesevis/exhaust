# Result Builders for Ergonomic Generator Authoring

## Executive Summary

This document explores how Swift's Result Builders can be used to make generator authoring more ergonomic in the Exhaust library while simultaneously making "illegal states" around determinism and replayability unrepresentable at compile time.

## Current Architecture Analysis

### Core Components

The Exhaust library is built around a sophisticated three-phase architecture:

1. **ReflectiveGenerator<Input, Output>** - Type alias for `FreerMonad<ReflectiveOperation<Input>, Output>`
2. **FreerMonad<Operation, Value>** - Fundamental Free Monad pattern with `.pure` and `.impure` cases
3. **ReflectiveOperation<Input>** - Enum defining primitive operations (chooseBits, pick, sequence, etc.)

### Three-Phase Execution Model

**Generation (Forward Pass):**
- Uses `RandomNumberGenerator` for entropy
- Executes operations to produce random values
- Creates concrete instances from abstract generators

**Reflection (Backward Pass):**
- Takes concrete values and works backwards to find generation paths
- Returns `ChoiceTree` representing all possible ways the value could have been generated
- Validates that values match generator constraints

**Replay (Deterministic Forward Pass):**
- Uses `ChoiceTree` as a script to deterministically recreate values
- Consumes pre-recorded choices instead of generating random ones
- Must structurally match the original generator

## Current Pain Points & Illegal States

### 1. Type Safety Issues

**Problem:** Extensive use of `Any` type for operation erasure creates runtime failures
```swift
// Current approach - type erasure everywhere
enum ReflectiveOperation<Input> {
    case chooseBits(min: UInt64, max: UInt64)
    case pick(choices: [(weight: UInt64, label: UInt64, generator: ReflectiveGenerator<Any, Any>)])
    case sequence(length: ReflectiveGenerator<Any, UInt64>, gen: ReflectiveGenerator<Any, Any>)
    case lmap(transform: (Any) -> Any?, next: ReflectiveGenerator<Any, Any>)
}
```

**Illegal States:**
- Force unwrapping in continuations can cause crashes
- Type mismatches between reflection and replay phases
- `eraseInputType` function creates potential for type confusion

### 2. Non-Invertible Operations

**Problem:** Operations that transform values in ways that can't be inverted
```swift
// This cannot be reflected - information is lost
let problematicGen = String.arbitrary
    .proliferate(with: 1...5)
    .map { $0.joined() } // Non-invertible transformation
```

**Illegal States:**
- `.map` operations that lose information
- Opaque transformations that can't be reversed during reflection
- Current tests explicitly expect failure for these cases

### 3. Unicode/Character Handling Inconsistencies

**Problem:** Character generation and reflection show mismatches
```swift
// Test failures show strings missing characters during replay
// Suggests issues with Unicode normalization or scalar representation
```

**Illegal States:**
- Unicode normalization differences between generation and reflection
- Character vs Unicode.Scalar representation mismatches
- String length inconsistencies during replay

### 4. Lens/Transformation Type Safety

**Problem:** Complex type erasure in lens operations
```swift
// Current lens operations use partial functions
static func lens<Input, NewInput>(
    extract path: some PartialPath<NewInput, Input>, 
    _ next: ReflectiveGenerator<Any, Input>
) -> ReflectiveGenerator<Any, Input>
```

**Illegal States:**
- Partial functions that may fail during transformation
- Type erasure hiding incompatible transformations
- Input transformation functions that aren't properly invertible

### 5. Verbose Monadic Composition

**Problem:** Current composition relies on explicit monadic operations
```swift
// Deeply nested bind chains are hard to read and error-prone
let complexGen = String.arbitrary.bind { name in
    Int.arbitrary.bind { age in
        Bool.arbitrary.bind { isActive in
            Gen.just(Person(name: name, age: age, isActive: isActive))
        }
    }
}
```

## Result Builder Solution Design

### Core Result Builder

```swift
@resultBuilder
struct GeneratorBuilder<Input> {
    // Basic building blocks
    static func buildBlock<T>(_ generator: ReflectiveGenerator<Input, T>) -> ReflectiveGenerator<Input, T> {
        generator
    }
    
    // Sequential composition (preserves determinism)
    static func buildBlock<T1, T2>(
        _ g1: ReflectiveGenerator<Input, T1>, 
        _ g2: ReflectiveGenerator<Input, T2>
    ) -> ReflectiveGenerator<Input, (T1, T2)> {
        g1.bind { v1 in
            g2.map { v2 in (v1, v2) }
        }
    }
    
    // Extend for 3, 4, 5... parameter tuples
    static func buildBlock<T1, T2, T3>(
        _ g1: ReflectiveGenerator<Input, T1>,
        _ g2: ReflectiveGenerator<Input, T2>,
        _ g3: ReflectiveGenerator<Input, T3>
    ) -> ReflectiveGenerator<Input, (T1, T2, T3)> {
        g1.bind { v1 in
            g2.bind { v2 in
                g3.map { v3 in (v1, v2, v3) }
            }
        }
    }
    
    // Conditional generation (type-safe branching)
    static func buildEither<T>(first: ReflectiveGenerator<Input, T>) -> ReflectiveGenerator<Input, T> { 
        first 
    }
    
    static func buildEither<T>(second: ReflectiveGenerator<Input, T>) -> ReflectiveGenerator<Input, T> { 
        second 
    }
    
    // Optional generation
    static func buildOptional<T>(_ generator: ReflectiveGenerator<Input, T>?) -> ReflectiveGenerator<Input, T?> {
        guard let generator = generator else {
            return Gen.just(nil)
        }
        return generator.map(Optional.some)
    }
    
    // Array generation with compile-time safety
    static func buildArray<T>(_ generators: [ReflectiveGenerator<Input, T>]) -> ReflectiveGenerator<Input, [T]> {
        generators.reduce(Gen.just([])) { acc, gen in
            acc.bind { array in
                gen.map { element in
                    array + [element]
                }
            }
        }
    }
    
    // Limited transformation - only for final conversion
    static func buildFinalResult<T, U>(_ generator: ReflectiveGenerator<Input, T>) -> ReflectiveGenerator<Input, U> 
    where T: TupleConvertible, T.Converted == U {
        generator.map(T.convert)
    }
}
```

### Type-Safe Transformation Protocol

```swift
// Ensures all transformations are invertible
protocol ReflectableTransform {
    associatedtype Input
    associatedtype Output
    
    func apply(_ input: Input) -> Output
    func reflect(_ output: Output) -> Input? // Must be invertible
}

// Compile-time enforcement of reflectable operations
extension ReflectiveGenerator {
    func safeMap<Transform: ReflectableTransform>(_ transform: Transform) -> ReflectiveGenerator<Input, Transform.Output>
    where Transform.Input == Output {
        // Implementation ensures reflection works by storing both forward and backward transforms
        .impure(.safeTransform(forward: transform.apply, backward: transform.reflect, next: self)) { result in
            .pure(result)
        }
    }
}

// Example safe transformations
struct StringToUppercase: ReflectableTransform {
    func apply(_ input: String) -> String {
        input.uppercased()
    }
    
    func reflect(_ output: String) -> String? {
        // This is problematic - uppercasing loses information!
        // The type system forces us to acknowledge this
        return nil // Cannot reliably invert
    }
}

struct AddConstant: ReflectableTransform {
    let constant: Int
    
    func apply(_ input: Int) -> Int {
        input + constant
    }
    
    func reflect(_ output: Int) -> Int? {
        output - constant // Perfectly invertible
    }
}
```

### Unicode-Safe Character Generation

```swift
struct SafeUnicodeCharacter {
    let scalar: Unicode.Scalar
    
    static var generator: ReflectiveGenerator<Any, SafeUnicodeCharacter> {
        Gen.choose(in: 0...0x10FFFF)
            .compactMap { value in
                Unicode.Scalar(value).map(SafeUnicodeCharacter.init)
            }
    }
}

extension String {
    @GeneratorBuilder<Any>
    static var safeArbitrary: ReflectiveGenerator<Any, String> {
        let lengthGen = Gen.choose(in: 0...20)
        return SafeArray.build(count: lengthGen) {
            SafeUnicodeCharacter.generator
                .map(\.scalar)
                .map(Character.init)
        }
        .map { characters in
            String(characters)
        }
    }
}
```

### Deterministic Collection Generation

```swift
struct SafeArray<Element> {
    @GeneratorBuilder<Any>
    static func build<LengthInput>(
        count: ReflectiveGenerator<LengthInput, UInt64>,
        @GeneratorBuilder<Any> element: () -> ReflectiveGenerator<Any, Element>
    ) -> ReflectiveGenerator<Any, [Element]> {
        Gen.arrayOf(element(), count)
    }
    
    // Convenience for fixed ranges
    @GeneratorBuilder<Any>
    static func build(
        count: ClosedRange<Int>,
        @GeneratorBuilder<Any> element: () -> ReflectiveGenerator<Any, Element>
    ) -> ReflectiveGenerator<Any, [Element]> {
        let lengthGen = Gen.choose(in: UInt64(count.lowerBound)...UInt64(count.upperBound))
        return Gen.arrayOf(element(), lengthGen)
    }
}
```

### Tuple Conversion Protocol

```swift
// Allows clean conversion from tuples to custom types
protocol TupleConvertible {
    associatedtype Converted
    static func convert(_ tuple: Self) -> Converted
}

extension (String, Int, Bool): TupleConvertible {
    static func convert(_ tuple: (String, Int, Bool)) -> Person {
        Person(name: tuple.0, age: tuple.1, isActive: tuple.2)
    }
}
```

### Generator Building Protocol

```swift
protocol GeneratorBuildable {
    associatedtype GeneratorInput = Any
    
    @GeneratorBuilder<GeneratorInput>
    static func build(@GeneratorBuilder<GeneratorInput> _ content: () -> ReflectiveGenerator<GeneratorInput, Self>) -> ReflectiveGenerator<GeneratorInput, Self>
}

extension GeneratorBuildable {
    @GeneratorBuilder<GeneratorInput>
    static func build(@GeneratorBuilder<GeneratorInput> _ content: () -> ReflectiveGenerator<GeneratorInput, Self>) -> ReflectiveGenerator<GeneratorInput, Self> {
        content()
    }
}

// Types can opt-in to builder syntax
extension Person: GeneratorBuildable {}
```

## Usage Examples

### Before: Current Verbose Approach

```swift
// Deeply nested, error-prone
let personGen = String.arbitrary.bind { name in
    Gen.choose(in: 18...100, input: Any.self).bind { age in
        Bool.arbitrary.map { isActive in
            Person(name: name, age: age, isActive: isActive)
        }
    }
}

// Array generation is clunky
let peopleGen = Gen.arrayOf(personGen, Gen.choose(in: 1...10, input: Any.self))

// Conditional generation is verbose
let maybePersonGen = Bool.arbitrary.bind { shouldGenerate in
    if shouldGenerate {
        return personGen.map(Optional.some)
    } else {
        return Gen.just(nil)
    }
}
```

### After: Result Builder Approach

```swift
// Clean, declarative syntax
let personGen = Person.build {
    String.safeArbitrary                    // name
    Gen.choose(in: 18...100)               // age
    Bool.arbitrary                         // isActive
}

// Array generation is natural
let peopleGen = SafeArray.build(count: 1...10) {
    personGen
}

// Conditional generation reads naturally
@GeneratorBuilder<Any>
let maybePersonGen: ReflectiveGenerator<Any, Person?> {
    if Bool.arbitrary.generate() {
        personGen
    } else {
        nil
    }
}
```

### Complex Nested Structure

```swift
struct Company {
    let name: String
    let employees: [Person]
    let founded: Int
    let isPublic: Bool
}

// Before: Deeply nested nightmare
let companyGen = String.arbitrary.bind { name in
    Gen.arrayOf(personGen, Gen.choose(in: 1...1000, input: Any.self)).bind { employees in
        Gen.choose(in: 1800...2024, input: Any.self).bind { founded in
            Bool.arbitrary.map { isPublic in
                Company(name: name, employees: employees, founded: founded, isPublic: isPublic)
            }
        }
    }
}

// After: Clear structure
extension Company: GeneratorBuildable {}
extension (String, [Person], Int, Bool): TupleConvertible {
    static func convert(_ tuple: (String, [Person], Int, Bool)) -> Company {
        Company(name: tuple.0, employees: tuple.1, founded: tuple.2, isPublic: tuple.3)
    }
}

let companyGen = Company.build {
    String.safeArbitrary
    SafeArray.build(count: 1...1000) { personGen }
    Gen.choose(in: 1800...2024)
    Bool.arbitrary
}
```

## Benefits of Result Builder Approach

### 1. Compile-Time Safety
- **Type System Enforcement**: Illegal transformations won't compile
- **No More Type Erasure**: Generic constraints maintain type information
- **Invertibility Guarantees**: Only reflectable operations are allowed

### 2. Readability and Maintainability
- **Declarative Syntax**: What you want, not how to get it
- **Natural Composition**: Sequential generators read top-to-bottom
- **Reduced Nesting**: Flat structure instead of nested bind chains

### 3. Determinism Guarantees
- **Reflectable by Design**: All operations must provide inverse functions
- **Unicode Consistency**: Explicit scalar handling prevents normalization issues
- **Array Length Constraints**: Deterministic relationship between count and elements

### 4. Developer Experience
- **Better Error Messages**: Compile-time errors instead of runtime failures
- **IDE Support**: Auto-completion and type inference work naturally
- **Refactoring Safety**: Type system catches breaking changes

## Implementation Strategy

### Phase 1: Core Result Builder
1. Implement basic `GeneratorBuilder` with tuple support
2. Add `TupleConvertible` protocol for clean type conversion
3. Create `GeneratorBuildable` protocol for opt-in syntax

### Phase 2: Type Safety Improvements
1. Implement `ReflectableTransform` protocol
2. Replace `Any` erasure with generic constraints where possible
3. Add compile-time checks for invertible operations

### Phase 3: Unicode and Collection Safety
1. Create `SafeUnicodeCharacter` wrapper
2. Implement `SafeArray` builder with deterministic length
3. Fix Character/String reflection consistency

### Phase 4: Migration and Testing
1. Provide migration guides from current syntax
2. Add comprehensive property tests for generation-reflection-replay cycles
3. Performance benchmarking to ensure no regressions

## Potential Challenges

### 1. Type System Limitations
Swift's type system might not be expressive enough for all the generic constraints we need.

**Mitigation**: Start with simpler cases and gradually expand. Use protocols judiciously.

### 2. Performance Impact
Result Builders and additional type safety might introduce overhead.

**Mitigation**: Benchmark early and often. The Free Monad structure should minimize runtime cost.

### 3. Migration Complexity
Existing generators would need to be rewritten or wrapped.

**Mitigation**: Provide automatic migration tools and maintain backward compatibility during transition.

### 4. Learning Curve
Result Builders are a more advanced Swift feature.

**Mitigation**: Comprehensive documentation and examples. The declarative syntax should actually be easier for most developers.

## Conclusion

Result Builders offer a compelling path to make generator authoring more ergonomic while simultaneously eliminating entire classes of runtime errors through compile-time enforcement. The key insight is that most "illegal states" in the current system stem from type erasure and non-invertible operations - both of which can be caught at compile time with the right abstractions.

The proposed design maintains the sophisticated three-phase execution model that makes Exhaust powerful while providing a much more pleasant authoring experience. By making illegal states unrepresentable, we shift debugging from runtime to compile time, where it belongs.