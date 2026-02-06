# Collect/Classification Implementation for Exhaust

## Overview

This document outlines the implementation of `collect` functionality for Exhaust, enabling statistical analysis of test data distribution. The feature allows developers to categorize generated values and receive reports on how frequently different types of test cases are generated.

## Motivation

Property-based testing frameworks like QuickCheck and Hypothesis provide `collect` and `classify` functions to help developers:

1. **Debug generator bias** - "Am I actually generating edge cases?"
2. **Verify test coverage** - "Are my tests exercising the scenarios I care about?"  
3. **Tune generators** - "Should I adjust weights/probabilities?"

Example usage:
```swift
let classifiedInts = Gen.collect(
    Gen.choose(in: 0...100),
    ({ $0 < 10 }, "single digit"),
    ({ $0 % 2 == 0 }, "even"), 
    ({ $0 > 90 }, "large")
)
```

After running tests, developers would see distribution reports like:
```
Classification Statistics:
42% single digit
51% even  
8% large
15% single digit AND even
3% even AND large
0% single digit AND large
```

## Architecture

### 1. New ReflectiveOperation Case

Add a new case to `ReflectiveOperation` that signals classification intent to the interpreter:

```swift
case collect(
    gen: ReflectiveGenerator<Any>, 
    classifiers: [(predicate: (Any) -> Bool, label: String)]
)
```

This follows the same pattern as `.filter` - it wraps a generator with metadata that the interpreter uses for special behavior.

### 2. Static Method on Gen

Provide a clean API as a static method on `Gen`:

```swift
extension Gen {
    static func collect<T>(
        _ generator: ReflectiveGenerator<T>,
        _ classifiers: ((T) -> Bool, String)...
    ) -> ReflectiveGenerator<T> {
        .impure(
            operation: .collect(
                gen: generator.erase(),
                classifiers: classifiers.map { (predicate, label) in
                    ({ predicate($0 as! T) }, label)
                }
            ),
            continuation: { .pure($0 as! T) }
        )
    }
}
```

### 3. Context-Based Statistics Collection

Extend `GenerationContext` to track classification data:

```swift
class GenerationContext {
    // Existing properties...
    
    // Classification tracking
    private var classifications: [String: Set<Int>] = [:]
    private var currentRun: Int = 0
    private let maxRuns: Int
    
    func recordClassification(_ label: String) {
        classifications[label, default: []].insert(currentRun)
    }
    
    func nextRun() {
        currentRun += 1
        if currentRun >= maxRuns {
            reportClassificationStatistics()
        }
    }
    
    private func reportClassificationStatistics() {
        guard !classifications.isEmpty else { return }
        
        print("Classification Statistics:")
        
        // Single label percentages
        for (label, indices) in classifications.sorted(by: { $0.key < $1.key }) {
            let percentage = (indices.count * 100) / maxRuns
            print("\(percentage)% \(label)")
        }
        
        // Intersection analysis
        let labels = Array(classifications.keys)
        for i in 0..<labels.count {
            for j in (i+1)..<labels.count {
                let label1 = labels[i]
                let label2 = labels[j]
                let intersection = classifications[label1]!.intersection(classifications[label2]!)
                if !intersection.isEmpty {
                    let percentage = (intersection.count * 100) / maxRuns
                    print("\(percentage)% \(label1) AND \(label2)")
                }
            }
        }
        
        // Could extend to higher-order intersections if needed
    }
}
```

### 4. Interpreter Implementation

Update `ValueAndChoiceTreeGenerator` to handle the `.collect` operation:

```swift
extension ValueAndChoiceTreeGenerator {
    private func interpret(operation: ReflectiveOperation.collect(let gen, let classifiers)) -> Any {
        // Generate the value normally
        let value = interpret(generator: gen)
        
        // Test against all classifiers
        for (predicate, label) in classifiers {
            if predicate(value) {
                context.recordClassification(label)
            }
        }
        
        return value
    }
}
```

## Implementation Details

### Statistical Tracking Approach

The implementation uses **index-based tracking** rather than storing actual values:

- **Why indices?** Avoids `Equatable` constraint on generated types while enabling intersection analysis
- **Memory efficient**: Only stores integers, not the generated values themselves  
- **Set operations**: Easy to compute intersections using `Set<Int>.intersection()`

### Applicative Behavior

Each generated value is tested against **all** predicates simultaneously, enabling:
- Multiple labels per value (e.g., a value can be both "even" and "single digit")
- Intersection analysis (e.g., "how many values were both even AND single digit?")
- Complete statistical picture of generated data

### Lifecycle Management  

Classification statistics are scoped to individual property tests:
1. Each property gets its own `GenerationContext` 
2. Context accumulates classification data during test execution
3. When `maxRuns` is reached, statistics are automatically reported
4. No global state or manual lifecycle management needed

## Usage Examples

### Basic Classification
```swift
let generator = Gen.collect(
    Gen.choose(in: 0...100),
    ({ $0 < 10 }, "single digit"),
    ({ $0 % 2 == 0 }, "even")
)
```

### Complex Data Analysis
```swift
let treeGenerator = Gen.collect(
    BinaryTree.arbitrary,
    ({ $0.height > 5 }, "deep tree"),
    ({ $0.isBalanced }, "balanced"),
    ({ $0.nodeCount > 20 }, "large tree")
)
```

### String Generation Analysis  
```swift
let stringGenerator = Gen.collect(
    Gen.string(of: Gen.alphanumeric, Gen.choose(in: 0...50)),
    ({ $0.isEmpty }, "empty"),
    ({ $0.count < 5 }, "short"),
    ({ $0.allSatisfy { $0.isLetter } }, "letters only"),
    ({ $0.contains { $0.isNumber } }, "contains digits")
)
```

## Future Extensions

### Higher-Order Intersections
Currently supports pairwise intersections. Could extend to triple, quadruple, etc.:
```swift
// "single digit AND even AND prime": 2% 
```

### Conditional Classification
```swift
// Only classify even numbers by magnitude
Gen.collect(
    Gen.choose(in: 0...100),
    ({ $0 % 2 == 0 && $0 < 10 }, "small even"),
    ({ $0 % 2 == 0 && $0 > 90 }, "large even")
)
```

### Custom Reporting Formats
- JSON output for programmatic analysis
- Histogram visualization
- Integration with external analytics tools

## Testing the Implementation

### Unit Tests
- Test that classifiers are applied correctly to generated values
- Verify intersection calculations are accurate  
- Ensure statistics are properly scoped to individual test runs

### Integration Tests  
- Test with various generator types (primitives, collections, custom types)
- Verify reporting triggers correctly at `maxRuns`
- Test multiple classification operations in the same property

### Performance Tests
- Measure overhead of classification tracking
- Ensure acceptable performance impact on test execution time
- Validate memory usage for large test runs

## Implementation Checklist

- [ ] Add `.collect` case to `ReflectiveOperation` enum
- [ ] Add documentation to the new operation case  
- [ ] Implement `Gen.collect` static method
- [ ] Extend `GenerationContext` with classification tracking
- [ ] Update `ValueAndChoiceTreeGenerator` to handle `.collect` operations
- [ ] Implement statistical reporting in `GenerationContext`
- [ ] Add unit tests for classification logic
- [ ] Add integration tests with various generator types
- [ ] Add performance benchmarks
- [ ] Update documentation with usage examples

## Notes

- Classification is **analysis-only** - it doesn't affect value generation, reflection, or replay behavior
- The feature is **opt-in** - only generators wrapped with `Gen.collect` perform classification
- Statistics are **automatically reported** when tests complete - no manual trigger needed
- The implementation **requires no changes** to existing generator definitions or test code