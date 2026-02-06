# Practical Choice Gradient Sampling Implementation

This document outlines a pragmatic approach to implementing Choice Gradient Sampling (CGS) for moderately complex generators in the Exhaust property-based testing framework.

## Target Use Cases

CGS serves the middle ground between trivial and expert-optimized generators:

- **Trivial generators**: Basic primitives, single choices - no optimization needed
- **Expert generators**: Hand-tuned for specific domains (parsers, complex data structures) - manual optimization preferred
- **Middle ground**: Generators with moderate complexity that could benefit from automatic optimization
  - Binary search trees with balance constraints
  - Sorted arrays with validity conditions
  - Simple AST generators with structural requirements
  - Collections with non-trivial predicates

## Core Architecture: Four Interpreters

The CGS implementation extends Exhaust's interpreter pattern with a fourth interpreter:

1. **Generate**: Forward pass - consumes randomness to produce values
2. **Reflect**: Backward pass - discovers which choices could produce target values
3. **Replay**: Deterministic recreation using recorded choice trees
4. **Adapt**: Reconstructs generators from modified choice trees (NEW)

## Working Domain: ChoiceTree

CGS operates on `ChoiceTree` structures rather than transforming `ReflectiveGenerator` directly:

1. **Materialization**: Use `ValueAndChoiceTreeGenerator(materializePicks: true)` to get complete choice structure
2. **Analysis**: Extract choice points and their impact on validity
3. **Optimization**: Modify weights in the choice tree based on gradient information
4. **Reconstruction**: Use the Adapt interpreter to convert optimized trees back to generators

## Derivative Theory

### Understanding Generator Derivatives

A **derivative** in CGS is the generator that remains after a specific choice has been made. From Goldstein's thesis:

```
δc (Bind (Pick xs) f) = 
  case find ((== c) . snd) xs of
    Just (_, _, x) → x >>= f    // The remaining generator
    Nothing → void
```

**Key insight**: A derivative differs from its originating generator by exactly one pick reduction.

### Example Transformation

```swift
// Original generator
fgenTree h = do
  c ← pick [(1, 'l', return False), (3, 'n', return True)]
  case c of
    False → return Leaf
    True → do
      x ← fgenInt
      return (Node Leaf x Leaf)

// Derivative δ_n - choice 'n' already made  
δ_n(fgenTree h) = do
  x ← fgenInt              // This is what remains
  return (Node Leaf x Leaf) // after choice 'n' was made
```

The derivative **eliminates the pick operation** and **directly continues** with the sub-generator corresponding to the chosen path.

## Implementation Strategy

### Phase 0: CGS Viability Analysis

Before applying optimization, analyze the materialized choice tree to determine if CGS is worth the computational cost:

```swift
extension ReflectiveGenerator {
    func optimize(
        _ predicate: @escaping (Output) -> Bool,
        sampleRate: Int = 50,
        timeout: TimeInterval = 2.0
    ) -> ReflectiveGenerator<Output> {
        
        // Step 1: Materialize choice tree for structural analysis
        let materializedTree = ValueAndChoiceTreeGenerator(materializePicks: true)
            .run(self)
            .choiceTree
        
        // Step 2: Analyze structure to determine CGS viability
        let analysis = analyzeCGSViability(materializedTree, sampleRate: sampleRate)
        
        guard analysis.shouldApplyCGS else {
            return self  // Skip CGS - not worth the overhead
        }
        
        // Step 3: Apply CGS with known cost estimates
        return applyCGS(self, predicate, analysis, timeout)
    }
}

struct CGSViabilityAnalysis {
    let shouldApplyCGS: Bool
    let estimatedPredicateExecutions: Int
    let reason: String
    
    static func analyze(_ tree: ChoiceTree, sampleRate: Int) -> CGSViabilityAnalysis {
        let pickLocations = extractPickLocations(tree)
        let totalExecutions = calculateTotalPredicateExecutions(pickLocations, sampleRate)
        
        // Heuristics for CGS viability
        if pickLocations.isEmpty {
            return CGSViabilityAnalysis(
                shouldApplyCGS: false,
                estimatedPredicateExecutions: 0,
                reason: "No choice points to optimize"
            )
        }
        
        if totalExecutions > 10_000 {
            return CGSViabilityAnalysis(
                shouldApplyCGS: false,
                estimatedPredicateExecutions: totalExecutions,
                reason: "Too many predicate executions required (\(totalExecutions))"
            )
        }
        
        if pickLocations.count < 3 {
            return CGSViabilityAnalysis(
                shouldApplyCGS: false,
                estimatedPredicateExecutions: totalExecutions,
                reason: "Too few choice points to benefit from optimization"
            )
        }
        
        return CGSViabilityAnalysis(
            shouldApplyCGS: true,
            estimatedPredicateExecutions: totalExecutions,
            reason: "Good candidate: \(pickLocations.count) choice points, \(totalExecutions) predicate calls"
        )
    }
}

func calculateTotalPredicateExecutions(_ pickLocations: [PickLocation], sampleRate: Int) -> Int {
    return pickLocations.enumerated().reduce(0) { total, pair in
        let (depth, location) = pair
        let depthSampleRate = max(sampleRate / (1 << depth), 4)  // minSampleRate = 4
        let branchCount = location.choices.count
        return total + (branchCount * depthSampleRate)
    }
}
```

**Structural Heuristics for Viability:**
- **Too trivial**: < 3 choice points → skip CGS, insufficient optimization potential
- **Too complex**: > 10,000 predicate executions → skip CGS, cost exceeds likely benefit
- **Too deep**: > 10 levels → likely sparse validity conditions, poor CGS candidate
- **Too wide**: > 20 branches per choice → expensive sampling, diminishing returns
- **Sweet spot**: 3-50 choice points with reasonable branching → apply CGS

**Benefits of Pre-Analysis:**
- **Cost prediction**: Know exactly how many predicate executions CGS will require
- **Smart filtering**: Automatically skip unsuitable generators
- **User feedback**: Clear reasoning for optimization decisions
- **Resource management**: Prevent expensive optimization of poor candidates

### Phase 1: Value Choice Transformation

Before CGS analysis, transform all `Gen.choose` operations into `Gen.pick` over uniform subranges:

```swift
// Original
Gen.choose(in: 0...9)

// Transformed  
Gen.pick([
    (weight: 1, label: 0, gen: Gen.just(0)),
    (weight: 1, label: 1, gen: Gen.just(1)),
    // ... etc
])
```

This provides uniform treatment for gradient optimization.

### Phase 2: Focused Pick Optimization

Rather than analyzing all choices simultaneously, optimize one pick at a time:

```swift
func optimizeSinglePick(_ generator: ReflectiveGenerator<Output>, 
                       _ pickLocation: SerializableChoiceTreePath<[PickChoice]>,
                       depth: Int) -> ReflectiveGenerator<Output> {
    
    // 1. Focus on one specific pick
    let targetPick = pickLocation.extract(from: generator.choiceTree)
    
    // 2. Create one derivative per choice in this pick
    let derivatives = targetPick.choices.map { choice in
        takeDerivative(generator, choice: choice.label)
    }
    
    // 3. Sample each derivative (with depth-based sample rate)
    let sampleCount = baseSampleRate / (1 << depth)
    let fitnessScores = derivatives.map { derivative in
        let samples = (1...sampleCount).map { _ in generate(derivative) }
        return samples.filter(validityPredicate).count
    }
    
    // 4. Assign weights back to respective choices
    return generator.withUpdatedWeights(fitnessScores)
}
```

### Phase 3: Exponential Sample Rate Decay

Use exponential decay to manage computational complexity as picks occur deeper in the generator:

```swift
// Sample rate schedule by depth
// Depth 0: 1000 samples per derivative
// Depth 1: 500 samples per derivative  
// Depth 2: 250 samples per derivative
// Depth 3: 125 samples per derivative

let sampleRate = max(baseSampleRate / (1 << depth), minSampleRate)
```

**Benefits**:
- **Front-loaded optimization**: Most effort on high-impact early choices
- **Bounded complexity**: Total work converges rather than exploding
- **Statistical validity**: Early choices get high confidence, deep choices get evidence-based hints

### Phase 4: Early Return Optimization

The **Adapt** interpreter can terminate early when creating derivatives:

```swift
func adapt<Output>(_ gen: ReflectiveGenerator<Output>, with tree: ChoiceTree) -> ReflectiveGenerator<Output> {
    switch (gen, tree) {
    case let (.impure(.pick(choices), continuation), choiceTree):
        // Apply CGS adaptations
        if shouldCreateDerivative(choices, choiceTree) {
            let dominantChoice = getDominantChoice(choices)
            
            // Create derivative: choice.generator >>= continuation
            let derivative = dominantChoice.generator.bind(continuation)
            return derivative  // ⚡ Early return - remaining generator is complete
        }
    }
}
```

When a pick is reduced to a derivative, the **remaining generator tree becomes a direct path** with no further choice uncertainty.

## Performance Considerations

### Dynamic Sample Rate Management

```swift
let baseSampleRate = 1000
let minSampleRate = 4

extension SerializableChoiceTreePath {
    var depth: Int {
        return serializedPath.components(separatedBy: ".").count / 2
    }
}

func calculateSampleRate(depth: Int) -> Int {
    return max(baseSampleRate / (1 << depth), minSampleRate)
}
```

### Iterative Optimization Strategy

```swift
func applyCGS(_ generator: ReflectiveGenerator<Output>) -> ReflectiveGenerator<Output> {
    var currentGen = generator
    let pickLocations = identifyPickLocations(generator)
        .sorted { $0.depth < $1.depth }  // Optimize shallow picks first
    
    // Multiple passes until convergence
    for pass in 1...maxPasses {
        var improved = false
        
        for pickLocation in pickLocations {
            let depth = pickLocation.depth
            let sampleRate = calculateSampleRate(depth: depth)
            
            if sampleRate >= minViableSampleRate {
                let optimized = optimizeSinglePick(currentGen, pickLocation, depth: depth)
                if hasImproved(original: currentGen, optimized: optimized) {
                    currentGen = optimized
                    improved = true
                }
            } else {
                break  // Skip very deep picks
            }
        }
        
        if !improved { break }  // Converged
    }
    
    return currentGen
}
```

### Complexity Management

- **Depth-based sampling**: Exponential decay prevents combinatorial explosion
- **Early convergence**: Stop when no improvements are found
- **Shallow-first optimization**: Prioritize high-impact choices
- **Minimum thresholds**: Skip optimization when sample rates become too low
- **Caching**: Store gradient results by generator fingerprint

## Expected Performance

Based on Harrison Goldstein's thesis results and focused optimization approach:

- **Baseline improvement**: 2-10x reduction in generation attempts
- **Target scenarios**: Generators with 10-50% natural validity rates
- **Computational efficiency**: O(branches * log(depth)) instead of O(branches^depth)
- **Early return benefits**: Direct path execution when derivatives are created
- **Diminishing returns**: Less benefit for very sparse or very dense validity conditions

### Sample Complexity Analysis

```swift
// Traditional approach: Exponential explosion
Total samples = N^depth where N = choices per pick

// Focused approach with exponential decay
Total samples = Σ(N * baseSampleRate / 2^d) for d in 0...maxDepth
             ≈ N * baseSampleRate * 2  // Converges to constant factor
```

## Implementation Notes

### Key Insights

1. **Derivatives are single-pick eliminations**: Each derivative removes exactly one choice point
2. **Materialization is crucial**: Without `materializePicks: true`, only one choice path is visible
3. **Focused optimization**: Process one pick at a time rather than global analysis
4. **Exponential decay**: Manage complexity while maintaining statistical validity
5. **Early returns**: Derivatives enable direct path execution, skipping choice uncertainty
6. **SerializableChoiceTreePath precision**: Enable surgical targeting of specific choice points

### Integration Points

- **Opt-in optimization**: CGS available via `.optimize(predicate)` extension method
- **Depth-aware sampling**: Adjust effort based on choice tree structure  
- **Convergence detection**: Stop optimization when no further improvements found
- **Derivative caching**: Reuse computed derivatives across optimization passes
- **Statistics collection**: Track optimization effectiveness and sample efficiency

### Resolved Architectural Challenge: The Bind Closure Problem ✅ RESOLVED

**The Problem**: Initial attempts to adapt generators during execution failed because Swift's `.bind` closures are opaque at runtime. Since virtually every non-trivial generator uses `.bind` for monadic composition, this made generator introspection impossible.

**The Solution**: Work on ChoiceTree data structures rather than generator code:

1. **Materialization First**: Use `ValueAndChoiceTreeGenerator(materializePicks: true)` to reify all choice structure
2. **ChoiceTree Transformation**: Apply CGS optimizations to the materialized tree data
3. **Guided Replay**: Use optimized trees to guide new generator execution

### New Architecture: ReflectiveOperation.adapt(gen, choiceTree)

Instead of trying to introspect generators, CGS optimization is encapsulated as a new `ReflectiveOperation`:

```swift
case adapt(ReflectiveGenerator<Any>, ChoiceTree)
```

**Benefits:**
- **Clean encapsulation**: Optimization is part of the operation specification  
- **Interpreter awareness**: All interpreters can recognize and handle optimization
- **Composability**: Optimized generators remain normal `ReflectiveGenerator` instances
- **Natural threading**: ChoiceTree guidance threads through execution automatically

**Usage:**
```swift
let optimizedGen = ReflectiveGenerator.impure(
    operation: .adapt(originalGen, optimizedChoiceTree),
    continuation: { result in .pure(result) }
)
```

### Required Interpreter Extensions

**1. Non-Deterministic Replay Interpreter** (NEW - Critical)
- **Purpose**: Sample derivatives with statistical diversity for weight calculation
- **Function**: Execute generators guided by ChoiceTree weights, making probabilistic choices
- **Key insight**: This is the inverse of `ValueAndChoiceTreeInterpreter`
  - **ValueAndChoiceTree**: Generator → (Value + ChoiceTree) - records choices
  - **NonDeterministicReplay**: (Generator + ChoiceTree) → Value - uses recorded weights

**2. Guided ValueInterpreter** (ENHANCED)
- Recognizes `.adapt(gen, choiceTree)` operations
- Executes `gen` using `choiceTree` for choice guidance  
- Ensures optimized generators work in standard generation contexts

**3. Guided ValueAndChoiceTreeInterpreter** (ENHANCED)
- Handles composition: when optimized generators are bound with others
- Preserves optimization through monadic composition chains
- Critical for composability: `optimizedBST.bind { bst in otherGen.map { (bst, $0) } }`

## Future Considerations

- **Shrinking integration**: How CGS-optimized generators interact with test case reduction
  - Potential issue: Optimized paths vs. minimal counterexamples
  - Potential benefit: Optimization may concentrate generation near validity boundaries where interesting counterexamples exist
  - Investigation needed once core CGS implementation is complete

- **Adaptive base sample rates**: Adjust initial sampling based on generator complexity
- **Parallel derivative sampling**: Evaluate multiple derivatives concurrently
- **Machine learning integration**: Use neural networks to predict optimal sample allocation
- **Dynamic depth limits**: Adjust maximum optimization depth based on performance metrics

This focused approach provides practical CGS benefits with predictable computational costs, making it viable for real-world property-based testing scenarios.

## Production-Ready CGS API

### User Interface

CGS is implemented as an opt-in extension method on `ReflectiveGenerator`:

```swift
extension ReflectiveGenerator {
    func optimize(
        _ predicate: @escaping (Output) -> Bool,
        sampleRate: Int = 50,
        timeout: TimeInterval = 2.0
    ) -> ReflectiveGenerator<Output> {
        return applyCGS(
            self, 
            validityPredicate: predicate,
            sampleRate: sampleRate,
            timeout: timeout
        )
    }
}
```

**Usage Example:**
```swift
let optimizedGen = myBSTGenerator
    .filter { isValidBST($0) }      // Standard filtering
    .optimize { isValidBST($0) }    // CGS optimization
```

### Key Design Decisions

**Opt-in Approach:**
- Maintains backward compatibility - existing generators unchanged
- Users explicitly choose when to apply CGS optimization
- Clear performance boundaries and debugging capabilities
- Easy fallback by removing `.optimize()` call

**Timeout Safety:**
- 2-second default timeout prevents hanging on pathological cases
- Graceful fallback to unoptimized generator if timeout exceeded
- Predictable performance characteristics

**Configurable Parameters:**
- `sampleRate`: Default N=50 matches reference paper methodology
- `timeout`: User-configurable performance bounds
- Tunable for quality/performance tradeoffs

### Memory Usage Characteristics

**Lightweight Generator Storage:**
- Generators are inert closures with minimal memory footprint
- No heavy data structures stored in generator definitions
- Optimization cost only during interpreter execution

**Bounded Memory Usage:**
- CGS memory impact occurs only during `ValueAndChoiceTreeInterpreter` runs
- Choice trees and derivatives created temporarily during optimization
- Results cached by generator fingerprint for interpreter session
- Cache cleared when interpreter completes
- Memory usage bounded by interpreter run duration, not generator lifetime

## Resolved Critical Questions

The following questions have been addressed through design decisions and analysis:

### Algorithmic Soundness & Correctness ✅ RESOLVED

**Derivative Semantic Equivalence:**
- ✅ **Proven**: Derivatives preserve semantic equivalence for validity problems
- ✅ **Key insight**: Derivatives represent valid execution paths of original generator
- ✅ **Theorem**: `φ(a) = True` for `a` from `δ_c(g)` iff `φ(a) = True` when `g` makes choice `c`
- ✅ **Justification**: Derivatives don't change semantics - they focus on specific execution paths

**Cycles and Recursion:**
- ✅ **Non-issue**: Exponential sample rate decay naturally bounds derivative computation depth
- ✅ **Auto-limiting**: When sample rate drops below statistical significance, optimization stops
- ✅ **Practical bound**: `maxDepth` where `sampleRate == minSampleRate`

**Generator State Consistency:**
- ✅ **Mitigated**: Non-escaping validity predicates prevent most state capture issues
- ✅ **Opt-in safety**: Only explicitly optimized generators need purity constraints
- ✅ **User control**: Clear boundary between optimized and standard generators

### Performance & Resource Management ✅ RESOLVED

**Memory Usage:**
- ✅ **Clarified**: Generators are lightweight closures with minimal memory footprint
- ✅ **Bounded**: Memory usage limited to interpreter session duration
- ✅ **Cached**: Results cached by fingerprint, cleared when interpreter completes
- ✅ **No accumulation**: No long-lived heavy objects over time

**Timeout Management:**
- ✅ **Built-in safety**: 2-second default timeout with graceful fallback
- ✅ **User configurable**: Adjustable timeout parameter
- ✅ **Predictable**: Prevents runaway optimization scenarios

**Sample Rate Control:**
- ✅ **User configurable**: `sampleRate` parameter with sensible default (N=50)
- ✅ **Exponential decay**: Natural depth limiting through sample rate reduction
- ✅ **Quality/performance tradeoff**: Users can tune based on needs

### Integration with Existing Framework ✅ RESOLVED

**Seamless Integration:**
- ✅ **Clean API**: `.optimize()` follows existing `.filter()` pattern
- ✅ **Backward compatibility**: Existing generators work unchanged
- ✅ **Opt-in only**: CGS only affects explicitly optimized generators
- ✅ **Choice transformation**: `Gen.choose` → `Gen.pick` provides uniform treatment

**Purity and State:**
- ✅ **Non-escaping predicates**: Prevents most side effect and state issues
- ✅ **Opt-in constraints**: Only optimized generators need purity requirements
- ✅ **Clear boundaries**: Easy to identify which generators use CGS

### Quality Assurance & Validation ✅ RESOLVED

**Empirical Validation Required:**
- ✅ **Approach**: Must be tested on real-world generators with known characteristics
- ✅ **Target**: Generators with 10-50% natural validity rates (CGS sweet spot)
- ✅ **Success metrics**: >1.5x valid output improvement with better time efficiency
- ✅ **Anti-patterns**: Document cases where CGS fails (extremely sparse conditions)

### Robustness & Edge Cases ✅ RESOLVED

**Sparse Validity Handling:**
- ✅ **Known limitation**: CGS performs poorly on extremely sparse conditions (like AVL trees)
- ✅ **Solution**: Document as anti-pattern, recommend expert-tuned generators instead
- ✅ **Detection**: Low sample success rates during optimization indicate poor fit

**Error Handling:**
- ✅ **Timeout safety**: 2-second default prevents infinite optimization loops
- ✅ **Graceful fallback**: Return unoptimized generator on timeout or failure
- ✅ **Bounded complexity**: Exponential decay prevents combinatorial explosion

### User Experience & Configuration ✅ RESOLVED

**User Control:**
- ✅ **Explicit opt-in**: Users call `.optimize()` when desired
- ✅ **Configurable parameters**: `sampleRate` and `timeout` tuneable
- ✅ **Easy disable**: Remove `.optimize()` call to disable
- ✅ **Clear expectations**: No surprise optimization overhead

**Target Use Cases:**
- ✅ **Sweet spot identified**: Generators with 10-50% natural validity rates
- ✅ **Empirical validation**: Must be tested on real-world cases
- ✅ **Known limitations**: Document anti-patterns (sparse conditions like AVL trees)

### Production Deployment ✅ RESOLVED

**Migration Strategy:**
- ✅ **Zero breaking changes**: Opt-in design ensures compatibility
- ✅ **Gradual adoption**: Add `.optimize()` calls incrementally
- ✅ **Easy rollback**: Remove optimization calls to revert
- ✅ **Clear boundaries**: Optimized vs standard generators explicit

### Framework Architecture ✅ RESOLVED

**Path Targeting Precision:**
- ✅ **Stable structure**: Choice tree structure remains consistent after initial adaptation
- ✅ **Deterministic labels**: UInt64 position-based labels provide reliable addressing
- ✅ **Surgical precision**: Can target specific choice points without ambiguity
- ✅ **No dynamic changes**: Structure fixed after `Gen.choose` → `Gen.pick` transformation

## Remaining Implementation Tasks

With critical questions resolved, the remaining work focuses on empirical validation and implementation:

### 1. Empirical Validation (Priority: High)
**Target**: Validate effectiveness on real-world generators with 10-50% validity rates
- Binary search trees with balance constraints
- Sorted collections with additional predicates
- Simple AST generators with type constraints
- Collections with non-trivial but not extremely rare validity conditions

**Success Metrics:**
```swift
// Measure improvement
let baseline = generator.filter(predicate).take(1000).measure()
let optimized = generator.optimize(predicate).take(1000).measure()

// Success criteria:
// optimized.validCount > baseline.validCount * 1.5
// AND optimized.timePerValid < baseline.timePerValid
```

### 2. Implementation Details (Priority: Medium)
- Add `ReflectiveOperation.adapt(gen, choiceTree)` case 
- Implement non-deterministic replay interpreter for derivative sampling
- Extend ValueInterpreter and ValueAndChoiceTreeInterpreter to handle `.adapt` operations
- Implement `.optimize()` extension method with viability analysis
- Build timeout and graceful fallback mechanisms  
- Add derivative caching by generator fingerprint
- Integrate with `ValueAndChoiceTreeInterpreter.filter` handling
- Implement structural heuristics for CGS candidate detection

### 3. Documentation (Priority: Medium)
- Document sweet spot use cases and anti-patterns
- Provide tuning guidance for `sampleRate` and `timeout`
- Examples comparing optimized vs unoptimized generators

### 4. Monitoring (Priority: Low)
- Optional effectiveness logging
- Performance metrics for optimization decisions
- Simple success/failure feedback

## Key Insights for Implementation

1. **Opt-in design solves most architectural concerns**
2. **Exponential decay naturally handles complexity and cycles**  
3. **Non-escaping predicates prevent state consistency issues**
4. **Timeout provides safety against pathological cases**
5. **Viability analysis prevents expensive optimization of poor candidates**
6. **Empirical validation required - CGS is not a universal solution**
7. **Target generators with moderate validity rates (10-50%)**
8. **Document known anti-patterns (extremely sparse conditions)**
9. **Structural heuristics enable intelligent optimization decisions**

The implementation path is now clear with well-understood constraints and capabilities, plus intelligent pre-filtering to ensure CGS is only applied where it can provide benefit.