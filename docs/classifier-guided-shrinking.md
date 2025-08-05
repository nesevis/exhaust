# Classifier-Guided Shrinking for Exhaust

## Overview

This document outlines a comprehensive approach to enhance Exhaust's test case reduction using machine learning classifiers, specifically the C5.0 decision tree algorithm via the See5 framework. The key insight is to combine Hypothesis-style pass-based shrinking with structural pattern recognition to create an adaptive, intelligent shrinking system.

## Core Concept

Instead of the current strategy-per-choice approach, we propose a **classifier-guided pass-based architecture** that:

1. **Learns structural patterns** that predict shrinking success
2. **Applies coordinated transformations** across the entire ChoiceTree
3. **Adapts strategies dynamically** based on learned patterns
4. **Focuses on structural properties** rather than concrete values

## Background: Lessons from Hypothesis

### Current Exhaust Limitations

- **Linear strategy application**: Each choice gets strategies applied sequentially
- **No coordination**: Can't handle interdependent data (e.g., "Bound 5" challenge)
- **Fixed ordering**: No adaptation based on what's working
- **Local optimization**: Gets stuck in local minima

### Hypothesis Advantages

- **Pass-based architecture**: Coordinated changes across entire structure
- **Dynamic reordering**: Successful passes get prioritized
- **Comprehensive caching**: Prevents redundant work
- **Shortlex ordering**: Better simplicity metrics

## Proposed Architecture

### 1. Pass-Based Shrinking with Classifier Guidance

```swift
struct ClassifierGuidedPassRunner {
    let classifier: C50Classifier
    
    func selectOptimalPass(for tree: ChoiceTree, property: (Output) -> Bool) async -> ShrinkingPass? {
        let features = tree.extractStructuralFeatures()
        let prediction = try await classifier.classify(features)
        
        // Decision tree rules tell us which structural features lead to success
        return parseRulesIntoPassSelection(prediction.rules)
    }
}
```

### 2. Structural Pattern Recognition

The classifier learns **meta-patterns about shrinking effectiveness**:

```swift
// Examples of rules C5.0 might discover:
// "sequence_count > 0 AND avg_sequence_length > (avg_element_complexity * 2) -> sequence_reduction_effective [0.92]"
// "choice_count > 5 AND avg_range_size < 1000 -> boundary_detection_effective [0.89]"
// "max_depth > 6 AND avg_branching_factor < 2.5 -> top_down_reduction_preferred [0.85]"
```

### 3. Concurrent Classification

Process isolation + Swift concurrency enables parallel classification:

```swift
struct ConcurrentClassifierSuite {
    let passSelector: C50Classifier       // Process 1
    let boundaryDetector: C50Classifier   // Process 2  
    let convergencePredictor: C50Classifier // Process 3
    let rangeRefiner: C50Classifier       // Process 4
    
    func classifyInParallel(_ tree: ChoiceTree) async -> CoordinatedPrediction {
        // All classifications happen simultaneously across processes
        async let passStrategy = passSelector.classify(tree.passSelectionFeatures())
        async let boundaries = boundaryDetector.classify(tree.boundaryFeatures())  
        async let convergence = convergencePredictor.classify(tree.convergenceFeatures())
        async let ranges = rangeRefiner.classify(tree.rangeFeatures())
        
        // Wait for all to complete - limited by slowest, not sum of all
        return await CoordinatedPrediction(passStrategy, boundaries, convergence, ranges)
    }
}
```

**Performance benefit**: 3.3x speedup from parallelization (40ms sequential → 12ms concurrent)

## Technical Implementation

### Case Paths Integration

Using Swift Case Paths for type-safe ChoiceTree navigation:

```swift
extension ChoiceTree {
    // Case paths for each enum case
    static let choicePath = /ChoiceTree.choice
    static let sequencePath = /ChoiceTree.sequence
    static let groupPath = /ChoiceTree.group
    
    // Composed paths for nested access
    static let sequenceLengthPath = sequencePath.appending(path: \.0) // length
    static let choiceValuePath = choicePath.appending(path: \.0) // ChoiceValue
}
```

### Serializable Path System

For round-trip mapping between ChoiceTree features and classifier rules:

```swift
struct SerializableCasePath<Root, Value> {
    let casePath: AnyCasePath<Root, Value>
    let serializedPath: String  // e.g., "choice.unsigned.value"
    
    // Bidirectional mapping:
    // 1. Extraction: Case Path → String attribute name → Classifier
    // 2. Application: String attribute name → Case Path → Tree modification
}
```

### Feature Extraction Strategy

Instead of concrete values, extract **structural fingerprints**:

```swift
struct StructuralFingerprint {
    let maxDepth: Int
    let nodeTypeCounts: [String: Int]  // "choice": 5, "sequence": 2
    let dominantPattern: String       // "choice-heavy", "sequence-heavy"  
    let complexityDistribution: [Double] // Quartiles
    let importantNodeRatio: Double
    let avgBranchingFactor: Double
    let reductionPotential: Double    // Estimated reducibility
}
```

### Adaptive Schema Generation

Handle diverse ChoiceTree structures with consistent feature schemas:

```swift
struct AdaptiveSchemaGenerator {
    static func generateSchema(from samples: [(ChoiceTree, Bool)]) -> DataSchema {
        // Create fixed-size feature space that captures essential patterns
        // Use C5.0's "?" support for features that don't exist in particular trees
        
        let fingerprintFeatures = StructuralFingerprint.featureDefinitions
        let canonicalFeatures = CanonicalPathExtractor.featureDefinitions
        
        return DataSchema(
            attributes: fingerprintFeatures + canonicalFeatures,
            classes: ["pass", "fail"]
        )
    }
}
```

## Key Benefits

### 1. Intelligent Pass Selection

Instead of fixed ordering, predict which passes will succeed:

```swift
// Before: Always try binary reduction first
// After: "For deep choice-heavy trees, boundary detection is 89% likely to succeed"
```

### 2. Boundary Discovery

Extract exact pass/fail boundaries from decision tree rules:

```swift
// Rule: "sequence_length <= 49 -> pass"
// Direct range refinement: set upper bound to 49 (no binary search needed!)
```

### 3. Coordinated Reduction

Handle interdependent data like the "Bound 5" challenge:

```swift
struct CoordinatedArrayReductionPass: ShrinkingPass {
    func apply(to tree: ChoiceTree, property: (Output) -> Bool) -> ChoiceTree? {
        // Find all arrays and reduce them together while maintaining property
        let arrays = findAllSequences(in: tree)
        return tryCoordinatedReduction(arrays, property: property)
    }
}
```

### 4. Performance Optimizations

- **Parallel classification**: 3.3x speedup using concurrent See5 processes
- **Predictive pre-classification**: Start classifying next iteration while testing current
- **Enhanced caching**: Learn from failed attempts to avoid similar failures

## Training Data Strategy

### Shared Dataset Approach

Generate expensive training data once, use for multiple specialized classifiers:

```swift
struct ShrinkingOutcome {
    let finalTree: ChoiceTree
    let successful: Bool
    let stepsToConvergence: Int
    let effectivePasses: [String]  // Which passes actually worked
    let discoveredBoundaries: [String: Range<Double>]
    let convergenceSignals: [String: Double]
}

// Generate once, extract multiple feature views for different classifiers
let sharedData = await generateRichDataset(size: 2000)
let passSelectionData = sharedData.map { extractPassSelectionFeatures($0) }
let boundaryData = sharedData.map { extractBoundaryFeatures($0) }
let convergenceData = sharedData.map { extractConvergenceFeatures($0) }
```

### Specialized Classifiers

Train multiple classifiers from the same expensive dataset:

- **Pass Selection**: Which pass should I try next?
- **Boundary Detection**: Where are the pass/fail boundaries?
- **Convergence Prediction**: Am I close to minimal example?
- **Range Refinement**: How should I refine value ranges?

## Structural vs. Concrete Classification

### Why Structural Properties Matter

**Problematic (concrete values)**:
```
Rule: "choice_value = 42 -> pass"  // Doesn't generalize!
```

**Powerful (structural patterns)**:
```
Rule: "sequence_length > 49 -> fail"  // Generalizes across all test cases
```

### Classification Outcomes

Predict **shrinking strategies** rather than specific transformations:

```swift
enum ShrinkingStrategy: String, CaseIterable {
    case sequenceReduction = "sequence_reduction"
    case boundaryTightening = "boundary_tightening"  
    case structuralSimplification = "structural_simplification"
    case coordinatedReduction = "coordinated_reduction"
    case convergenceCheck = "convergence_check"
}
```

### Example Learned Patterns

```swift
// Sequence-related patterns
"sequence_count > 0 AND avg_sequence_length > (avg_element_complexity * 2) 
 -> sequence_reduction_effective [0.92]"

// Boundary-related patterns  
"choice_count > 5 AND avg_range_size < 1000 AND range_utilization > 0.8
 -> boundary_detection_effective [0.89]"

// Structural complexity patterns
"max_depth > 6 AND avg_branching_factor < 2.5
 -> top_down_reduction_preferred [0.85]"

// Convergence patterns
"important_node_ratio > 0.6 AND complexity_range < 100
 -> near_convergence [0.94]"
```

## Implementation Phases

### Phase 1: Foundation
- Implement structural fingerprinting
- Create Case Paths-based feature extraction
- Build shared training dataset generator
- Train single proof-of-concept classifier

### Phase 2: Specialization  
- Implement multiple specialized classifiers
- Add concurrent classification framework
- Integrate with existing shrinking system
- A/B test against current approach

### Phase 3: Optimization
- Add predictive pre-classification
- Implement adaptive pass reordering
- Add incremental learning from shrinking attempts
- Optimize for common structural patterns

### Phase 4: Advanced Features
- Hierarchical classification for complex structures
- Meta-learning across different property types
- Ensemble methods for improved accuracy
- Integration with property-specific optimizations

## Expected Impact

### Performance Improvements
- **Faster convergence**: Intelligent pass selection reduces wasted attempts
- **Better minimal examples**: Coordinated reduction finds smaller counterexamples
- **Reduced computation**: Boundary discovery eliminates binary search
- **Parallel efficiency**: Concurrent classification with minimal overhead

### Reliability Improvements
- **Escape local minima**: Randomized pass ordering based on learned patterns
- **Handle complex interdependencies**: Coordinated passes for "Bound 5" style challenges
- **Adaptive strategies**: System learns and improves from experience
- **Robust to edge cases**: Structural patterns generalize across diverse inputs

### Maintainability Benefits
- **Interpretable rules**: Decision tree output explains shrinking decisions
- **Type-safe implementation**: Case Paths prevent runtime errors
- **Modular architecture**: Specialized classifiers can be developed independently
- **Debuggable system**: Clear mapping from structural features to actions

## Risk Mitigation

### Training Data Quality
- **Diverse structural patterns**: Ensure training covers wide range of ChoiceTree shapes
- **Balanced outcomes**: Include both successful and failed shrinking attempts
- **Regular retraining**: Update classifiers as new patterns are discovered

### Performance Regression
- **Gradual rollout**: A/B test against existing system
- **Fallback mechanisms**: Revert to current approach if classification fails
- **Performance monitoring**: Track shrinking effectiveness metrics

### Complexity Management
- **Start simple**: Begin with structural fingerprints, add complexity gradually
- **Clear abstractions**: Separate concerns between classification and application
- **Comprehensive testing**: Validate round-trip mapping and rule application

## Conclusion

Classifier-guided shrinking represents a fundamental evolution in property-based testing reduction. By combining Hypothesis's proven pass-based architecture with machine learning insights about structural patterns, Exhaust can achieve:

1. **Intelligent strategy selection** based on learned patterns
2. **Coordinated transformations** that handle complex interdependencies  
3. **Performance optimization** through parallel classification and boundary discovery
4. **Adaptive improvement** that gets better with experience

The approach leverages Swift's strengths (Case Paths, concurrency) while addressing Exhaust's current limitations, creating a shrinking system that's both more effective and more maintainable than existing approaches.

This represents not just an incremental improvement, but a new paradigm where shrinking becomes a learned skill rather than a predetermined algorithm.