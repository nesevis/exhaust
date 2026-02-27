# Choice Gradient Sampling Implementation Insights

This document captures key insights and implementation strategies for Choice Gradient Sampling (CGS) based on analysis of the reference algorithm and practical considerations.

## Algorithm Overview

The CGS algorithm from Figure 3.3 of Harrison Goldstein's thesis follows this pattern:

1. **Setup:** Start with original generator G and empty valid set V
2. **Choice Extraction:** Find all structural choice points in the generator
3. **Derivative Computation:** For each choice c, compute δc(g) - the generator that forces choice c
4. **Fitness Evaluation:** Sample from each derivative and count valid outputs
5. **Reweighting:** Create new generator weighted by fitness scores
6. **Iteration:** Repeat until convergence

## Key Implementation Challenges

### 1. Derivative Computation Gap

**Problem:** The thesis algorithm treats derivative computation as a black box operation:
```
∇g ← ⟨δc(g) | c ∈ C⟩ ⊳ ∇g is the gradient of g
```

**Missing Details:**
- How to identify choice points C
- How to compute δc(g) for each choice c
- How to handle nested/recursive generators
- How to handle different types of choices

**Implementation Strategy:**
`GeneratorTuning` solves this through a recursive top-down walk of the generator tree, pattern-matching on each `ReflectiveOperation` case. For each `.pick`, it samples through continuations with per-choice RNG streams, measures predicate satisfaction rates, and reweights branches accordingly. This avoids the need for an operation-type transformation (`mapOperation` was originally considered but proved unnecessary since adaptation is expressed through weight adjustments on the existing operation type).

### 2. Types of Choice Points

There are two main types of choice points in generator structures:

#### Structural Choices (Gen.pick)
```swift
Gen.pick(choices: [
    (weight: 1, label: 0, Gen.just(.leaf)),     // Choice: "pick leaf"
    (weight: 3, label: 1, nodeGenerator)       // Choice: "pick node"
])
```
- **Impact:** High - affects overall structure
- **Derivatives:** Each branch becomes a separate derivative
- **Optimization:** Adjust weights based on fitness

#### Value Choices (Gen.choose)
```swift
Gen.choose(in: 0...9)  // Choose specific integer value
```
- **Impact:** Variable - depends on domain
- **Derivatives:** Each value could be a separate derivative
- **Challenge:** Can create many choice points for large ranges

### 3. Value Choice Transformation Strategy

**Recommended Approach:** Transform value choices into equally weighted picks:

**Original:**
```swift
Gen.choose(in: 0...9)  // One choice point, 10 possible values
```

**Transformed:**
```swift
Gen.pick(choices: [
    (weight: 1, label: 0, Gen.just(0)),
    (weight: 1, label: 1, Gen.just(1)),
    (weight: 1, label: 2, Gen.just(2)),
    // ... continue for all values
    (weight: 1, label: 9, Gen.just(9))
])
```

**Benefits:**
- Uniform treatment of all choice points
- Natural derivatives: δ₀(g) = Gen.just(0)
- Automatic optimization through existing algorithm
- Range compression when certain values prove more successful

## Performance Optimization Strategies

### 1. Computational Complexity

**Cost per iteration:** O(N × samples × property_cost)
- N = number of choice points
- samples = samples per derivative
- property_cost = cost of validity checking

### 2. Early Abortion Strategies

#### Statistical Confidence Thresholds
```
After 10 samples: 0 valid → 95% confidence fitness ≈ 0
After 20 samples: 1 valid → Can estimate fitness with error bars
```

#### Fitness Threshold Cutoffs
```
After 25% of samples: fitness < 0.1 → Abort, set fitness = 0
```

#### Comparative Abandonment
```
Derivative A: 40/50 valid samples
Derivative B: 2/50 valid samples → Abort B early
```

#### Adaptive Sample Sizing
```
Phase 1: 10 samples per derivative (quick screening)
Phase 2: 50 samples for top 20% of derivatives  
Phase 3: 200 samples for top 5%
```

### 3. Depth-Adaptive Sampling

**Problem:** Choice points grow exponentially with tree depth
```
Depth 0: 1 choice point (root decision)
Depth 1: 2 choice points (left + right subtrees)
Depth 2: 4 choice points (4 subtrees)  
Depth 3: 8 choice points (8 subtrees)
```

**Solution:** Decrease sample rate with depth
```
Depth 0 (root): 100 samples per choice
Depth 1: 50 samples per choice
Depth 2: 25 samples per choice
Depth 3: 10 samples per choice
Depth 4+: 5 samples per choice (minimum)
```

**Formula:** `samples = base_samples / (2^depth)`

**Rationale:**
- Root choices affect entire tree structure (high impact)
- Deep choices affect small subtrees (lower impact)
- Less variance at depth means fewer samples needed for signal detection
- Efficient allocation of computational budget

### 4. Practical Bounds

**Recommended limits:**
- **Max choice points per iteration:** 50-100
- **Base samples per choice:** 10-50 for screening, up to 200 for finalists
- **Early abort threshold:** Stop if fitness clearly < 0.1 after 25% of samples
- **Maximum depth:** Limit derivative extraction to reasonable depth (e.g., 5-7 levels)

## Algorithm Differences from Reference

### Thesis Algorithm (Figure 3.3)
- **Fitness calculation:** Raw count `fc ← |v|`
- **Weight application:** Direct `frequency[(fc, δcg)]`
- **Structure:** Single-pass main loop
- **Fallback:** When max fitness = 0, use original weights

### Many Implementations (Including Original Exhaust)
- **Fitness calculation:** Proportions (0.0-1.0)
- **Weight application:** Complex multiplier tiers
- **Structure:** Multi-iteration with convergence detection
- **Complexity:** Additional optimizations and heuristics

**Recommendation:** Stay closer to thesis algorithm for baseline implementation, add optimizations incrementally.

## BST-Specific Insights

### The Pathological Case Issue

CGS can exhibit pathological behavior when generators have an "easy path" to validity:

```swift
Gen.pick(choices: [
    (weight: 1, Gen.just(.leaf)),      // Always valid (100% success)
    (weight: 3, complexNodeGen)       // Sometimes valid (depends on structure)
])
```

**Problem:** CGS learns to heavily favor the 100% success path (leaves), leading to:
- High validity rates but trivial/degenerate solutions
- Loss of structural diversity
- "Gaming" the metric rather than solving the problem

**Solutions:**
- Diversity constraints to prevent degenerate solutions
- Multi-objective optimization (validity + structural complexity)
- Coverage-aware fitness functions
- Regularization to penalize overly conservative solutions

### Recursive Choice Extraction

Choice point extraction **must be recursive** for tree structures:

```
extractChoices(bstGenerator(5))
├── Choice: "leaf vs node" (at this level)
├── extractChoices(leftSubtree)  // Recurse into left subtree
│   ├── Choice: "leaf vs node" (in left subtree)
│   └── ... (more nested choices)
└── extractChoices(rightSubtree) // Recurse into right subtree
    ├── Choice: "leaf vs node" (in right subtree)
    └── ... (more nested choices)
```

Without recursion, most choice points would be missed and the algorithm would be ineffective.

## Future Improvements

### 1. Smarter Choice Point Selection
- Focus on high-impact structural choices
- Ignore or group similar choice points
- Use static analysis to predict choice importance

### 2. Hierarchical Optimization
- Optimize high-level structure first
- Refine details in subsequent passes
- Multi-resolution approach

### 3. Learning Across Iterations
- Cache fitness information for similar choice patterns
- Transfer learning between related generators
- Build fitness models rather than pure sampling

### 4. Domain-Specific Heuristics
- For BSTs: Focus on structural balance rather than specific values
- For sorted lists: Emphasize ordering relationships
- For typed expressions: Prioritize type-preserving choices

## Conclusion

CGS is a powerful technique but requires careful implementation of several complex components. The key insights are:

1. **Derivative computation** is the hardest part and not well-specified in the literature
2. **Value choice transformation** provides elegant uniformity
3. **Adaptive sampling strategies** are essential for performance
4. **Pathological optimization** must be guarded against
5. **Recursive extraction** is mandatory for nested structures

Success with CGS depends on balancing algorithmic fidelity with practical performance considerations, while avoiding the trap of optimizing for metrics rather than meaningful improvements.