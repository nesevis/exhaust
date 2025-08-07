# Recursive Property Testing Architecture for Exhaust

## Overview

This document outlines a fundamental architectural insight: the structural properties of ChoiceTrees are themselves **properties being tested** at a meta-level. This creates a recursive, fractal structure where property-based testing appears at every abstraction level, enabling a unified framework for domain testing, shrinking optimization, and classifier validation.

## Core Insight: The Property Symmetry

Property-based testing traditionally operates on domain objects:
```swift
let domainProperty: (String) -> Bool = { $0.count < 100 }
let testResult = domainProperty(generatedString) // true/false
```

But structural properties of ChoiceTrees follow the exact same pattern:
```swift
let structuralProperty: (ChoiceTree) -> Bool = { $0.sequenceLength < 100 }
let shrinkingSuccess = structuralProperty(choiceTree) // true/false
```

Both are **predicate functions over data structures**, just operating at different abstraction levels. This symmetry reveals that ChoiceTree analysis is itself a form of property-based testing.

## Recursive Property Testing Levels

The system exhibits a natural recursive structure:

```swift
// Level 1: Domain Properties - Test the generated value
property1: (T) -> Bool

// Level 2: Structural Properties - Test the ChoiceTree that generated the value
property2: (ChoiceTree) -> Bool  

// Level 3: Feature Properties - Test the features extracted from the ChoiceTree
property3: (StructuralFeatures) -> Bool

// Level 4: Classifier Properties - Test the classifier's prediction about the features
property4: (ClassifierPrediction) -> Bool

// Level 5: Meta Properties - Test the entire system's behavior
property5: (TestingSystem) -> Bool
```

Each level is **property-based testing the level below**, creating a fractal architecture where the same conceptual framework applies recursively.

## Unified Property Framework

### Common Interface

All levels can use the same conceptual interface:

```swift
protocol PropertyTestable {
    associatedtype PropertyInput
    static var arbitrary: ReflectiveGenerator<Any, PropertyInput> { get }
}

struct UnifiedPropertyFramework {
    func test<T: PropertyTestable>(
        property: (T.PropertyInput) -> Bool,
        using generator: ReflectiveGenerator<Any, T.PropertyInput>
    ) -> TestResult
}
```

### Multi-Level Implementation

```swift
// Level 1: Domain Level
extension String: PropertyTestable {
    static var arbitrary = String.arbitrary  // generates Strings
}

// Level 2: Meta Level  
extension ChoiceTree: PropertyTestable {
    static var arbitrary = ChoiceTreeGenerator.arbitrary  // generates ChoiceTrees
}

// Level 3: Feature Level
extension StructuralFeatures: PropertyTestable {
    static var arbitrary = StructuralFeaturesGenerator.arbitrary  // generates features
}

// Level 4: Classifier Level
extension ClassifierPrediction: PropertyTestable {
    static var arbitrary = ClassifierPredictionGenerator.arbitrary  // generates predictions
}
```

### Usage Examples

```swift
let framework = UnifiedPropertyFramework()

// Domain testing
framework.test(
    property: { $0.count < 100 }, 
    using: String.arbitrary
)

// Structural testing  
framework.test(
    property: { $0.sequenceLength < 100 }, 
    using: ChoiceTree.arbitrary
)

// Meta testing
framework.test(
    property: { $0.accuracy > 0.8 }, 
    using: ClassifierPrediction.arbitrary
)
```

## Property Composition Across Levels

Properties can be composed both horizontally (within a level) and vertically (across levels).

### Horizontal Composition

```swift
// Domain property composition
let complexDomainProperty = { string in
    string.count < 100 && 
    !string.contains("@") && 
    string.isAlphanumeric
}

// Structural property composition  
let complexStructuralProperty = { tree in
    tree.sequenceLength < 100 && 
    tree.choiceCount > 5 && 
    tree.maxDepth < 10
}
```

### Vertical Composition

```swift
// Cross-level property relationships
let correlationProperty = { (domain: String, tree: ChoiceTree) in
    // Domain properties should correlate with structural properties
    (domain.count < 100) == (tree.sequenceLength < 100)
}
```

## Classifier as Structural Property Tester

The classifier becomes a **property-based testing system for ChoiceTrees**:

```swift
struct StructuralPropertyTester {
    let classifier: C50Classifier
    
    // This is essentially: (ChoiceTree) -> Bool
    func testStructuralProperty(_ tree: ChoiceTree) -> ShrinkingPrediction {
        let features = tree.extractFeatures()
        return classifier.predict(features) // "will shrinking succeed?"
    }
    
    // Validate classifier using property-based testing
    func validateClassifier() {
        @Property func classifierAccuracy(tree: ChoiceTree) {
            let prediction = testStructuralProperty(tree)
            let actual = performActualShrinking(tree)
            expect(prediction.confidence).to.correlateWith(actual.success)
        }
    }
}
```

## Meta-Property Generation

We can generate **properties about properties**:

```swift
// Generate random structural properties to test
let arbitraryStructuralProperty: ReflectiveGenerator<Any, (ChoiceTree) -> Bool> = 
    Gen.pick(choices: [
        (1, Gen.just({ $0.sequenceLength < 50 })),
        (1, Gen.just({ $0.choiceCount > 3 })),
        (1, Gen.just({ $0.maxDepth < 8 })),
        (1, Gen.just({ $0.importantNodeRatio > 0.5 }))
    ])

// Test our classifier against these generated properties
@Property func classifierGeneralizability(
    tree: ChoiceTree,
    structuralProperty: (ChoiceTree) -> Bool  // Generated property!
) {
    let prediction = classifier.predict(tree)
    let actual = structuralProperty(tree)
    expect(prediction.confidence).to.correlateWith(actual)
}
```

## Self-Validating Architecture

This recursive structure enables **self-validation** where each level tests the levels above and below:

```swift
struct SelfValidatingTestingSystem {
    
    // Level 1: Validate domain generators
    func validateDomainGenerators<T>(_ generator: ReflectiveGenerator<Any, T>) {
        @Property func generatorProducesValidValues(value: T) {
            expect(value).to.beValid()  // Domain-specific validation
        }
    }
    
    // Level 2: Validate ChoiceTree generation from domain values
    func validateChoiceTreeGeneration<T>(_ generator: ReflectiveGenerator<Any, T>) {
        @Property func reflectionRoundTrip(value: T) {
            let tree = try! Interpreters.reflect(generator, with: value)
            let reconstructed = try! Interpreters.replay(generator, using: tree)
            expect(reconstructed).to.equal(value)
        }
    }
    
    // Level 3: Validate structural feature extraction
    func validateFeatureExtraction() {
        @Property func featureConsistency(tree: ChoiceTree) {
            let features1 = tree.extractFeatures()
            let features2 = tree.extractFeatures()
            expect(features1).to.equal(features2)  // Deterministic
        }
    }
    
    // Level 4: Validate classifier predictions
    func validateClassifier() {
        @Property func classifierConsistency(features: StructuralFeatures) {
            let prediction1 = classifier.predict(features)
            let prediction2 = classifier.predict(features)
            expect(prediction1).to.equal(prediction2)  // Deterministic
        }
    }
    
    // Level 5: Validate entire system behavior
    func validateSystemBehavior() {
        @Property func shrinkingImprovement(
            originalTree: ChoiceTree,
            property: (Any) -> Bool
        ) {
            let shrunkTree = shrinkWithClassifier(originalTree, property: property)
            expect(shrunkTree.shortlexLength).to.beLessThanOrEqual(originalTree.shortlexLength)
        }
    }
}
```

## Fractal Testing Architecture

The architecture exhibits **fractal properties** where similar patterns emerge at every scale:

### Micro Level (Single Property Test)
```swift
// Generate value -> Test property -> Record outcome
let value = Interpreters.generate(generator)
let passes = property(value)
// Result: Bool
```

### Macro Level (Shrinking Session)
```swift
// Generate ChoiceTree -> Test structural property -> Record outcome
let tree = Interpreters.reflect(generator, with: value)
let willShrink = structuralProperty(tree)
// Result: ShrinkingPrediction
```

### Meta Level (Classifier Training)
```swift
// Generate features -> Test classification property -> Record outcome
let features = tree.extractFeatures()
let isAccurate = classificationProperty(features)
// Result: ClassifierMetrics
```

## Implementation Strategy

### Phase 1: Foundation
1. **Implement PropertyTestable protocol** for all major types
2. **Create UnifiedPropertyFramework** with consistent interface
3. **Build ChoiceTree.arbitrary generator** for meta-level testing
4. **Validate framework with simple cross-level tests**

### Phase 2: Multi-Level Integration  
1. **Implement structural property generators** for common patterns
2. **Create cross-level correlation tests** to validate relationships
3. **Build classifier validation using property-based testing**
4. **Add self-validation tests for entire system**

### Phase 3: Advanced Features
1. **Implement meta-property generation** for classifier testing
2. **Add fractal testing patterns** for complex scenarios
3. **Create property composition combinators** for building complex tests
4. **Integrate with existing shrinking system**

### Phase 4: Optimization
1. **Add parallel property testing** across levels
2. **Implement incremental validation** as system evolves
3. **Create property-guided optimization** for performance tuning
4. **Build monitoring system** using property-based health checks

## Benefits of Recursive Architecture

### Conceptual Benefits
- **Unified Framework**: Same concepts apply at all abstraction levels
- **Natural Composition**: Properties compose both horizontally and vertically
- **Self-Validation**: System can test and improve itself recursively
- **Fractal Consistency**: Similar patterns emerge at every scale

### Practical Benefits
- **Comprehensive Testing**: Every level is validated by property-based testing
- **Robust Optimization**: Classifier improvements are validated by properties
- **Predictable Behavior**: Recursive structure makes system behavior more understandable
- **Extensible Design**: New levels can be added following the same patterns

### Performance Benefits
- **Parallel Validation**: Properties at different levels can be tested concurrently
- **Incremental Improvement**: System optimizes itself through property feedback
- **Efficient Debugging**: Property violations pinpoint exact failure levels
- **Adaptive Optimization**: Properties guide system tuning automatically

## Risk Mitigation

### Complexity Management
- **Start Simple**: Begin with two-level implementation (domain + structural)
- **Clear Abstractions**: PropertyTestable protocol provides consistent interface
- **Incremental Adoption**: Can be added to existing system gradually

### Performance Overhead
- **Lazy Validation**: Properties only tested when needed
- **Cached Results**: Property test results cached to avoid redundant computation
- **Selective Testing**: Focus on critical properties based on importance

### Correctness Validation
- **Cross-Level Verification**: Each level validates the others
- **Property Composition**: Complex behaviors built from verified simple properties
- **Continuous Testing**: Properties run continuously to catch regressions

## Conclusion

The recursive property testing architecture represents a fundamental shift from viewing shrinking as a separate concern to recognizing it as **property-based testing at a meta-level**. This unified perspective enables:

1. **Conceptual Clarity**: Same framework applies across all abstraction levels
2. **Self-Improving System**: Each level optimizes the levels above and below
3. **Robust Validation**: Properties ensure correctness at every scale
4. **Natural Extension**: New capabilities follow established patterns

By recognizing that ChoiceTree structural properties are themselves properties to be tested, we create a system that is not only more powerful but also more principled and easier to reason about. The fractal nature of this architecture means that improvements at any level benefit the entire system, creating a virtuous cycle of continuous improvement.

This approach transforms Exhaust from a property-based testing library into a **recursive property-based testing system** that can test, validate, and optimize itself using the same fundamental principles it applies to user code.