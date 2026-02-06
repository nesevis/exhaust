# Flat Replay Shrinking Architecture

## The Problem: Cross-Boundary Shrinking

Exhaust's `ChoiceTree` structure is excellent for maintaining semantic structure and type safety, but it creates a fundamental limitation for shrinking: **the tree structure is rigid**.

### Example: Nested Array Shrinking

```swift
// Initial failing case: [[5, 8], [3], [1, 9]]
ChoiceTree.sequence(length: 3, elements: [
    .sequence(length: 2, elements: [.choice(5), .choice(8)]),
    .sequence(length: 1, elements: [.choice(3)]),
    .sequence(length: 2, elements: [.choice(1), .choice(9)])
])

// Desired shrink: [[5], [1]]
ChoiceTree.sequence(length: 2, elements: [
    .sequence(length: 1, elements: [.choice(5)]),
    .sequence(length: 1, elements: [.choice(1)])
])
```

With tree-based shrinking, we cannot:
- ❌ Delete elements from different inner arrays in one step
- ❌ Move values between sequences
- ❌ Merge or flatten nested structures
- ❌ Reorder elements across boundaries

The tree structure enforces these boundaries at the type level.

## Hypothesis's Solution: Flat Choice Sequences with Spans

Hypothesis doesn't have a tree structure during shrinking - it operates on a **flat list of choices**:

```python
# Hypothesis representation of [[5, 8], [3], [1, 9]]
choices = [
    Choice(type='integer', value=3, constraints={'min': 0}),  # outer length
    Choice(type='integer', value=2, constraints={'min': 0}),  # inner[0] length
    Choice(type='integer', value=5, constraints={}),          # inner[0][0]
    Choice(type='integer', value=8, constraints={}),          # inner[0][1]
    Choice(type='integer', value=1, constraints={'min': 0}),  # inner[1] length
    Choice(type='integer', value=3, constraints={}),          # inner[1][0]
    Choice(type='integer', value=2, constraints={'min': 0}),  # inner[2] length
    Choice(type='integer', value=1, constraints={}),          # inner[2][0]
    Choice(type='integer', value=9, constraints={}),          # inner[2][1]
]
```

With a flat representation, Hypothesis can:
- ✅ Delete any individual choice
- ✅ Delete contiguous ranges of choices
- ✅ Swap any two choices
- ✅ Minimize any choice value independently

The key insight: **mutations happen on the flat sequence, then the generator is replayed to validate and reconstruct the tree**.

### The Boundary Problem: How Does Hypothesis Track Structure?

With choices flattened into a linear array, how does Hypothesis know which choices belong together? The answer is **spans**: overlays that track semantic boundaries without constraining the flat representation.

A **span** is metadata that marks a contiguous range of choices as belonging to a semantic unit:

```python
# Span representation for [[5, 8], [3], [1, 9]]
spans = [
    Span(start=0, end=9, label='outer_list'),       # The entire outer list
    Span(start=1, end=4, label='inner_list[0]'),    # First inner list [5, 8]
    Span(start=4, end=6, label='inner_list[1]'),    # Second inner list [3]
    Span(start=6, end=9, label='inner_list[2]'),    # Third inner list [1, 9]
]
```

Spans solve the boundary problem by providing **semantic hints** to the shrinker without enforcing structural constraints:
- Spans tell the shrinker which choices form logical units
- Spans enable span-aware shrinking strategies (delete entire spans, replace span with child)
- Spans are **advisory, not mandatory** - the shrinker can still cross span boundaries
- Invalid mutations are caught during replay, not during span validation

## The Architecture: Dual Representation

Exhaust should maintain both representations:

1. **ChoiceTree**: Structured, semantic, type-safe (for generation, reflection, display)
2. **FlatChoiceSequence**: Linear, unstructured, flexible (for shrinking)

### Core Types

```swift
extension ChoiceTree {
    /// A flattened choice with breadcrumb path back to tree position
    struct FlatChoice {
        let value: ChoiceValue
        let metadata: ChoiceMetadata
        let path: [PathComponent]
    }

    enum PathComponent {
        case sequenceLength
        case sequenceElement(Int)
        case branchLabel
        case branchChild(Int)
        case groupMember(Int)
    }
    
    /// A span marks a contiguous range of choices as a semantic unit
    /// This mirrors Hypothesis's span system for tracking structure in flat representations
    struct Span {
        let start: Int      // Index into flat choice array (inclusive)
        let end: Int        // Index into flat choice array (exclusive)
        let label: String   // Semantic label (e.g., "sequence", "branch_child", "list_element")
        let depth: Int      // Nesting depth (0 = root)
        
        var isEmpty: Bool { start >= end }
        var count: Int { end - start }
    }

    func flattenToChoices() -> [FlatChoice] {
        var result: [FlatChoice] = []

        func visit(_ tree: ChoiceTree, path: [PathComponent]) {
            switch tree {
            case let .choice(value, metadata):
                result.append(FlatChoice(
                    value: value,
                    metadata: metadata,
                    path: path
                ))

            case let .sequence(length, elements, metadata):
                // The length itself is a choice!
                result.append(FlatChoice(
                    value: .unsigned(length),
                    metadata: metadata,
                    path: path + [.sequenceLength]
                ))

                for (i, element) in elements.enumerated() {
                    visit(element, path: path + [.sequenceElement(i)])
                }

            case let .branch(weight, label, children):
                // Which branch was taken is a choice!
                result.append(FlatChoice(
                    value: .unsigned(label),
                    metadata: ChoiceMetadata(validRanges: [0...UInt64(children.count - 1)]),
                    path: path + [.branchLabel]
                ))

                // Only include the selected child
                if Int(label) < children.count {
                    visit(children[Int(label)], path: path + [.branchChild(Int(label))])
                }

            case let .group(members):
                for (i, member) in members.enumerated() {
                    visit(member, path: path + [.groupMember(i)])
                }

            case .just, .getSize:
                // Not choices - these are constants
                break

            case let .resize(_, choices):
                for choice in choices {
                    visit(choice, path: path)
                }

            case .important(let inner), .selected(let inner):
                visit(inner, path: path)
            }
        }

        visit(self, path: [])
        return result
    }
    
    func extractSpans() -> [Span] {
        var spans: [Span] = []
        var currentIndex = 0
        
        func visit(_ tree: ChoiceTree, depth: Int, label: String) -> Int {
            let startIndex = currentIndex
            
            switch tree {
            case .choice:
                currentIndex += 1
                
            case let .sequence(_, elements, _):
                // Length choice
                currentIndex += 1
                
                // Each element gets its own span
                for (i, element) in elements.enumerated() {
                    let elementStart = currentIndex
                    let consumed = visit(element, depth: depth + 1, label: "\(label).element[\(i)]")
                    spans.append(Span(
                        start: elementStart,
                        end: currentIndex,
                        label: "\(label).element[\(i)]",
                        depth: depth + 1
                    ))
                }
                
            case let .branch(_, selectedLabel, children):
                // Branch label choice
                currentIndex += 1
                
                // Only visit the selected child
                if Int(selectedLabel) < children.count {
                    _ = visit(children[Int(selectedLabel)], depth: depth + 1, label: "\(label).branch[\(selectedLabel)]")
                }
                
            case let .group(members):
                for (i, member) in members.enumerated() {
                    _ = visit(member, depth: depth, label: "\(label).member[\(i)]")
                }
                
            case .just, .getSize:
                break
                
            case let .resize(_, choices):
                for choice in choices {
                    _ = visit(choice, depth: depth, label: label)
                }
                
            case .important(let inner), .selected(let inner):
                _ = visit(inner, depth: depth, label: label)
            }
            
            let endIndex = currentIndex
            if startIndex < endIndex {
                spans.append(Span(start: startIndex, end: endIndex, label: label, depth: depth))
            }
            
            return endIndex - startIndex
        }
        
        _ = visit(self, depth: 0, label: "root")
        return spans
    }
}
```

## Modified Replay: Choice Source Abstraction

The key is to abstract the source of choices during replay:

```swift
/// Abstraction over different sources of choices for replay
protocol ChoiceIterator {
    mutating func nextChoice(
        tag: TypeTag,
        validRanges: [ClosedRange<UInt64>]
    ) throws -> ChoiceValue

    mutating func nextSequenceLength(
        validRanges: [ClosedRange<UInt64>]
    ) throws -> UInt64

    mutating func nextBranchLabel(
        optionCount: Int
    ) throws -> UInt64
}

/// Replays using structured ChoiceTree (current behavior)
struct TreeChoiceIterator: ChoiceIterator {
    private let tree: ChoiceTree
    private var path: [PathComponent] = []

    mutating func nextChoice(
        tag: TypeTag,
        validRanges: [ClosedRange<UInt64>]
    ) throws -> ChoiceValue {
        let node = try navigate(tree, along: path)

        guard case .choice(let value, _) = node else {
            throw ReplayError.typeMismatch
        }

        advancePath()
        return value
    }

    // ... similar implementations for other operations
}

/// Replays using flat choice sequence (enables cross-boundary shrinking!)
struct FlatChoiceIterator: ChoiceIterator {
    private let choices: [ChoiceTree.FlatChoice]
    private var index: Int = 0

    mutating func nextChoice(
        tag: TypeTag,
        validRanges: [ClosedRange<UInt64>]
    ) throws -> ChoiceValue {
        guard index < choices.count else {
            throw ReplayError.insufficientChoices
        }

        let choice = choices[index]
        index += 1

        // Validate against constraints from generator
        guard choice.value.fits(in: validRanges) else {
            throw ReplayError.constraintViolation
        }

        return choice.value
    }

    mutating func nextSequenceLength(
        validRanges: [ClosedRange<UInt64>]
    ) throws -> UInt64 {
        // In flat representation, length is just another choice
        let value = try nextChoice(tag: .uint64, validRanges: validRanges)

        guard case .unsigned(let length) = value else {
            throw ReplayError.typeMismatch
        }

        return length
    }

    mutating func nextBranchLabel(
        optionCount: Int
    ) throws -> UInt64 {
        let value = try nextChoice(
            tag: .uint64,
            validRanges: [0...UInt64(optionCount - 1)]
        )

        guard case .unsigned(let label) = value else {
            throw ReplayError.typeMismatch
        }

        return label
    }
}
```

## Shrinking with Flat Representation and Spans

Now shrinking can operate on the flat sequence, using spans to guide (but not constrain) its operations:

```swift
struct FlatShrinker<T> {
    let generator: ReflectiveGenerator<T>

    func shrinkCrossBoundaries(
        tree: ChoiceTree,
        oracle: (T) -> Bool
    ) throws -> ChoiceTree? {
        // 1. Flatten the tree and extract spans
        let flat = tree.flattenToChoices()
        let spans = tree.extractSpans()

        // 2. Generate shrink candidates by manipulating flat sequence
        // Spans guide the shrinker but don't constrain it
        let candidates = generateFlatCandidates(flat, spans: spans)

        // 3. Replay each candidate to see if it's valid and still fails
        for candidate in candidates {
            do {
                // Create replay interpreter with flat choices
                var iterator = FlatChoiceIterator(choices: candidate)
                let (value, newTree) = try interpret(generator, using: &iterator)

                // Test with oracle
                if oracle(value) {
                    // Found a valid shrink!
                    return newTree
                }
            } catch {
                // Invalid candidate (violated constraints), skip
                continue
            }
        }

        return nil
    }

    func generateFlatCandidates(
        _ flat: [ChoiceTree.FlatChoice],
        spans: [ChoiceTree.Span]
    ) -> [[ChoiceTree.FlatChoice]] {
        var candidates: [[ChoiceTree.FlatChoice]] = []

        // Strategy 1: Delete entire spans (respects semantic boundaries)
        // This is Hypothesis's primary deletion strategy
        for span in spans where !span.isEmpty {
            let deleted = Array(flat[..<span.start] + flat[span.end...])
            candidates.append(deleted)
        }

        // Strategy 2: Delete individual choices (crosses boundaries, more aggressive)
        for i in flat.indices {
            let deleted = Array(flat[..<i] + flat[(i+1)...])
            candidates.append(deleted)
        }

        // Strategy 3: Delete contiguous ranges (crosses boundaries)
        for i in flat.indices {
            for j in (i+1)..<flat.count {
                let deleted = Array(flat[..<i] + flat[j...])
                candidates.append(deleted)
            }
        }

        // Strategy 4: Minimize individual values (within-boundary)
        for i in flat.indices {
            for smaller in shrinkValue(flat[i].value, metadata: flat[i].metadata) {
                var modified = flat
                modified[i] = ChoiceTree.FlatChoice(
                    value: smaller,
                    metadata: flat[i].metadata,
                    path: flat[i].path
                )
                candidates.append(modified)
            }
        }

        // Strategy 5: Reorder compatible choices within same span (span-aware)
        for span in spans {
            for i in span.start..<span.end {
                for j in (i+1)..<span.end where canSwap(flat[i], flat[j]) {
                    var swapped = flat
                    swapped.swapAt(i, j)
                    candidates.append(swapped)
                }
            }
        }

        // Strategy 6: Replace span with one of its sub-spans (semantic simplification)
        // This is powerful for nested structures: replace [[1,2],[3]] with just [1,2]
        for span in spans {
            let subSpans = spans.filter { $0.depth == span.depth + 1 && $0.start >= span.start && $0.end <= span.end }
            for subSpan in subSpans {
                let replacement = Array(flat[subSpan.start..<subSpan.end])
                candidates.append(replacement)
            }
        }

        // Sort by shortlex: shorter sequences first, then lower complexity
        candidates.sort { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }
            return lhs.lexicographicallyPrecedes(rhs) { a, b in
                a.value.complexity < b.value.complexity
            }
        }

        return candidates
    }

    func canSwap(_ a: ChoiceTree.FlatChoice, _ b: ChoiceTree.FlatChoice) -> Bool {
        // Only swap if they have compatible metadata
        // (e.g., both are integers with overlapping valid ranges)
        guard a.metadata.validRanges.count == b.metadata.validRanges.count else {
            return false
        }

        // Check if ranges overlap
        for (rangeA, rangeB) in zip(a.metadata.validRanges, b.metadata.validRanges) {
            if rangeA.overlaps(rangeB) {
                return true
            }
        }

        return false
    }
}
```

## Automatic Validation via Replay

The beauty of this approach: **invalid shrinks automatically fail during replay**.

### Example: Deleting Too Many Choices

```swift
// Original: [[5, 8], [3]]
let flat = [
    FlatChoice(.unsigned(2), ...),  // outer length = 2
    FlatChoice(.unsigned(2), ...),  // inner[0] length = 2
    FlatChoice(.unsigned(5), ...),  // inner[0][0]
    FlatChoice(.unsigned(8), ...),  // inner[0][1]
    FlatChoice(.unsigned(1), ...),  // inner[1] length = 1
    FlatChoice(.unsigned(3), ...),  // inner[1][0]
]

// Shrink candidate: Delete indices 1-3 (remove entire first inner array)
let candidate = [
    FlatChoice(.unsigned(2), ...),  // outer length still says 2!
    FlatChoice(.unsigned(1), ...),  // but only 1 inner array follows
    FlatChoice(.unsigned(3), ...),
]

// During replay:
var iterator = FlatChoiceIterator(choices: candidate)
let outerLength = try iterator.nextSequenceLength(...)  // = 2

// Generator tries to read 2 inner arrays:
for _ in 0..<outerLength {
    let innerLength = try iterator.nextSequenceLength(...)  // = 1
    for _ in 0..<innerLength {
        let value = try iterator.nextChoice(...)  // = 3
    }
    // Try to read second inner array...
    let innerLength2 = try iterator.nextSequenceLength(...)  // ← Throws!
}

// Result: ReplayError.insufficientChoices
// Candidate is automatically rejected!
```

This automatic validation is the key advantage: you don't need to manually check structural consistency.

## Hybrid Two-Phase Shrinking

Combine tree-based and flat-based shrinking for best results:

```swift
struct HybridShrinker<T> {
    let generator: ReflectiveGenerator<T>
    let treeShrinker: TreeBasedShrinker<T>
    let flatShrinker: FlatShrinker<T>

    func shrink(tree: ChoiceTree, oracle: (T) -> Bool) -> ChoiceTree {
        var current = tree
        var improved = true

        while improved {
            improved = false

            // Phase 1: Tree-based shrinking (fast, respects structure)
            // Good for: narrowing ranges, minimizing individual values
            if let shrunk = treeShrinker.shrinkWithinBoundaries(current, oracle: oracle) {
                current = shrunk
                improved = true
                continue
            }

            // Phase 2: Flat shrinking (slower, crosses boundaries)
            // Good for: deleting elements, restructuring, reordering
            if let shrunk = try? flatShrinker.shrinkCrossBoundaries(
                tree: current,
                oracle: oracle
            ) {
                current = shrunk
                improved = true
                continue
            }
        }

        return current
    }
}
```

### When to Use Each Phase

**Tree-Based Shrinking** (Phase 1):
- Fast: No replay overhead
- Respects structure: Works within existing boundaries
- Type-safe: Can't create invalid structures
- Best for: Minimizing primitive values, narrowing ranges

**Flat-Based Shrinking** (Phase 2):
- Flexible: Can cross boundaries
- Powerful: Can restructure data
- Self-validating: Invalid shrinks rejected automatically
- Best for: Deleting elements, merging structures, reordering

Run tree-based shrinking first (it's faster), then use flat-based shrinking when tree-based reaches a fixed point.

## Spans: Advisory vs. Prescriptive Structure

The key insight about spans is that they are **advisory, not prescriptive**:

### Hypothesis's Span Philosophy

Spans in Hypothesis serve as **hints** to the shrinker about semantic structure:
- **Guidance**: "These choices probably form a semantic unit"
- **Efficiency**: Delete entire spans before trying individual deletions
- **Hierarchy**: Try replacing parent spans with child spans

But spans are NOT rigid constraints:
- The shrinker can still delete across span boundaries
- Invalid mutations are caught by replay, not span validation
- Spans are rebuilt after each successful shrink

### Example: Span-Guided vs. Span-Crossing Operations

```swift
// Flat: [outer_len=2, inner_len=2, val=5, val=8, inner_len=1, val=3]
// Spans: [Span(0,6,"outer"), Span(1,4,"inner[0]"), Span(4,6,"inner[1]")]

// Span-guided: Delete entire inner[0] span
let candidate1 = [outer_len=2, inner_len=1, val=3]  // Removes indices 1-3
// Result: [[3]] (if valid after replay)

// Span-crossing: Delete individual values from different inner lists
let candidate2 = [outer_len=2, inner_len=2, val=5, inner_len=1]  // Removes val=8 and val=3
// Result: [[5], []] (if valid after replay)
```

Both operations are attempted. Spans prioritize the first (more likely to succeed), but don't prevent the second.

## Connection to Hypothesis

This architecture mirrors Hypothesis's approach while keeping Exhaust's structured advantages:

| Aspect | Hypothesis | Exhaust with Flat Replay |
|--------|-----------|--------------------------|
| Primary representation | Flat choice list | ChoiceTree |
| Shrinking representation | Same flat list | Flattened from tree |
| Validation | Replay generator | Replay generator |
| Tree structure | Implicit (spans) | Explicit (ChoiceTree) |
| Span tracking | Built during generation | Extracted from ChoiceTree |
| Cross-boundary ops | Native | Via flat shrinking |
| Type safety | Runtime | Compile + runtime |

Exhaust gets the best of both worlds:
- Structured representation for generation and reflection
- Flat representation for powerful shrinking
- Automatic validation via replay
- Spans provide semantic guidance without rigid constraints

## Implementation Priority

1. **Core infrastructure**:
   - `ChoiceIterator` protocol
   - `FlatChoiceIterator` implementation
   - `flattenToChoices()` method
   - `extractSpans()` method

2. **Basic flat shrinking**:
   - Delete entire spans (span-guided)
   - Delete individual choices (span-crossing)
   - Minimize individual values
   - Replay validation

3. **Advanced flat shrinking**:
   - Delete ranges (span-crossing)
   - Replace parent spans with child spans (span-guided)
   - Reorder choices within spans (span-aware)
   - Merge strategies

4. **Span optimization**:
   - Rebuild spans after each shrink
   - Cache span computations
   - Span-based candidate prioritization

5. **Hybrid integration**:
   - Two-phase shrinking loop
   - Performance tuning
   - Strategy selection heuristics

## Benefits

1. **Solves the cross-boundary problem**: Can now perform arbitrary structural mutations
2. **Automatic validation**: Invalid shrinks fail during replay
3. **Maintains type safety**: ChoiceTree still used for primary operations
4. **Hypothesis-level power**: Can perform same transformations as Hypothesis
5. **Incremental adoption**: Can add flat shrinking without breaking existing tree shrinking
6. **Span-guided efficiency**: Spans prioritize semantically meaningful operations without constraining flexibility
7. **Advisory structure**: Spans provide guidance without rigid enforcement, allowing both span-aware and span-crossing operations

## Insights from Genetic Algorithms

The shrinking process shares conceptual similarities with genetic algorithms, and several GA techniques can enhance shrinking effectiveness:

### 1. Adaptive Mutation Rates

Adjust shrinking aggressiveness based on progress, similar to adaptive mutation in GAs:

```swift
struct AdaptiveShrinkingStrategy {
    var consecutiveFailures = 0
    
    mutating func nextCandidates(
        flat: [FlatChoice],
        spans: [Span]
    ) -> [[FlatChoice]] {
        if consecutiveFailures < 3 {
            // Conservative: delete small spans (exploitation)
            return spans
                .filter { $0.count <= 2 }
                .map { deleteSpan(flat, $0) }
        } else if consecutiveFailures < 10 {
            // Moderate: delete any span (balanced exploration)
            return spans.map { deleteSpan(flat, $0) }
        } else {
            // Aggressive: large random deletions (escape local optima)
            return generateRandomDeletions(flat, maxDeletionSize: flat.count / 2)
        }
    }
}
```

**Insight**: When stuck at a local optimum, increase mutation aggressiveness to explore unexplored regions of the search space.

### 2. Diversity Maintenance

Track attempted mutations to avoid redundant replay operations:

```swift
struct DiversityTracker {
    private var attempted: Set<Int> = []
    
    mutating func shouldTry(_ candidate: [FlatChoice]) -> Bool {
        let hash = candidate.map(\.value.bitPattern).hashValue
        guard !attempted.contains(hash) else {
            return false  // Skip - already explored this region
        }
        attempted.insert(hash)
        return true
    }
    
    mutating func reset() {
        // Periodically reset to allow revisiting with different context
        if attempted.count > 10000 {
            attempted.removeAll(keepingCapacity: true)
        }
    }
}
```

**Insight**: Maintain population diversity to prevent premature convergence to suboptimal solutions.

### 3. Schema Preservation (Building Blocks)

Identify successful sub-structures and preserve them during shrinking:

```swift
struct SchemaLearner {
    private var successfulSpans: [String: Int] = [:]
    
    mutating func recordSuccess(_ spans: [Span]) {
        for span in spans {
            successfulSpans[span.label, default: 0] += 1
        }
    }
    
    func protectedSpans(_ allSpans: [Span]) -> Set<String> {
        // Protect spans that frequently appear in successful shrinks
        let threshold = successfulSpans.values.max().map { $0 / 2 } ?? 0
        return Set(successfulSpans.filter { $0.value >= threshold }.keys)
    }
    
    func generateCandidates(
        _ flat: [FlatChoice],
        spans: [Span]
    ) -> [[FlatChoice]] {
        let protected = protectedSpans(spans)
        
        // Only delete non-protected spans
        return spans
            .filter { !protected.contains($0.label) }
            .map { deleteSpan(flat, $0) }
    }
}
```

**Insight**: Short, high-fitness "building blocks" that consistently appear in successful shrinks should be preserved.

### 4. Lamarckian Evolution (Learned Bounds)

Update metadata based on shrinking discoveries (acquired traits inheritance):

```swift
struct LamarckianRangeNarrowing {
    mutating func updateFromSuccess(
        _ tree: ChoiceTree,
        learnedBounds: inout [PathComponent: ClosedRange<UInt64>]
    ) {
        let flat = tree.flattenToChoices()
        
        for choice in flat {
            // Learn that values above the successful value are unnecessary
            if case .unsigned(let value) = choice.value {
                let key = choice.path.hashValue
                if let existing = learnedBounds[key] {
                    // Tighten upper bound
                    learnedBounds[key] = existing.lowerBound...min(existing.upperBound, value)
                } else {
                    learnedBounds[key] = 0...value
                }
            }
        }
    }
    
    func applyLearnedBounds(
        _ metadata: ChoiceMetadata,
        path: [PathComponent],
        learnedBounds: [PathComponent: ClosedRange<UInt64>]
    ) -> ChoiceMetadata {
        guard let learned = learnedBounds[path.hashValue] else {
            return metadata
        }
        
        // Intersect learned bounds with original ranges
        let tightened = metadata.validRanges.compactMap { range in
            range.clamped(to: learned)
        }
        
        return ChoiceMetadata(validRanges: tightened)
    }
}
```

**Insight**: Unlike biological evolution, shrinking can "remember" what works and update constraints accordingly.

### 5. Fitness Landscape Exploration

Avoid greedy hill-climbing by exploring multiple promising candidates:

```swift
func exploreFitnessNeighborhood(
    candidates: [[FlatChoice]],
    oracle: (T) -> Bool,
    topK: Int = 5
) -> [FlatChoice]? {
    // Sort by complexity (shortlex)
    let sorted = candidates.sorted { lhs, rhs in
        if lhs.count != rhs.count {
            return lhs.count < rhs.count
        }
        return lhs.lexicographicallyPrecedes(rhs) { a, b in
            a.value.complexity < b.value.complexity
        }
    }
    
    // Test top-k candidates, not just the first
    // This helps escape local optima where the "simplest" candidate doesn't work
    for candidate in sorted.prefix(topK) {
        do {
            var iterator = FlatChoiceIterator(choices: candidate)
            let (value, _) = try interpret(generator, using: &iterator)
            
            if oracle(value) {
                return candidate
            }
        } catch {
            continue
        }
    }
    
    return nil
}
```

**Insight**: The simplest candidate isn't always viable. Testing multiple candidates helps find viable paths when the greedy choice fails.

### 6. Island Models (Parallel Strategies)

Run multiple shrinking strategies concurrently and combine results:

```swift
func parallelShrink(
    tree: ChoiceTree,
    oracle: (T) -> Bool
) async -> ChoiceTree {
    // Run different strategies as independent "islands"
    async let spanGuided = spanGuidedStrategy.shrink(tree, oracle)
    async let flatAggressive = flatAggressiveStrategy.shrink(tree, oracle)
    async let valueMinimization = valueMinimizationStrategy.shrink(tree, oracle)
    async let rangeNarrowing = rangeNarrowingStrategy.shrink(tree, oracle)
    
    let results = await [spanGuided, flatAggressive, valueMinimization, rangeNarrowing]
    
    // Return the simplest successful result
    return results.min { $0.complexity < $1.complexity }!
}
```

**Insight**: Different strategies excel in different scenarios. Parallel execution maximizes the chance of finding the optimal shrink.

### 7. Crossover and Recombination

When multiple failing cases exist, combine their features:

```swift
func crossoverShrink(
    parent1: [FlatChoice],
    parent2: [FlatChoice],
    spans1: [Span],
    spans2: [Span]
) -> [[FlatChoice]] {
    var candidates: [[FlatChoice]] = []
    
    // Strategy: Take structure from parent1, values from parent2
    for span1 in spans1 where span1.end <= parent2.count {
        var hybrid = parent1
        // Replace span's choices with corresponding choices from parent2
        for i in span1.start..<span1.end {
            if i < parent2.count,
               parent1[i].metadata.validRanges.contains(where: { 
                   $0.contains(parent2[i].value.bitPattern) 
               }) {
                hybrid[i] = parent2[i]
            }
        }
        candidates.append(hybrid)
    }
    
    return candidates
}
```

**Insight**: Combining features from multiple failing cases can reveal minimal examples that exhibit characteristics from both.

### Summary: GA-Inspired Shrinking Strategies

| GA Technique | Shrinking Application | Benefit |
|--------------|----------------------|---------|
| Adaptive mutation | Adjust deletion aggressiveness based on progress | Escape local optima when stuck |
| Diversity maintenance | Track attempted candidates, avoid redundancy | Reduce wasted replay operations |
| Schema preservation | Protect frequently-successful sub-structures | Avoid re-deleting good building blocks |
| Lamarckian evolution | Update `validRanges` from successful shrinks | Progressive constraint learning |
| Fitness landscape exploration | Test top-k candidates, not just simplest | Find viable paths when greedy fails |
| Island models | Parallel strategy execution | Robustness across different problem types |
| Crossover | Combine features from multiple failures | Discover minimal common characteristics |

These techniques transform shrinking from simple hill-climbing into a sophisticated search process that can navigate complex fitness landscapes.

## Insights from Test Case Minimization Research

The **TestReduce** algorithm (Bansal et al., 2023) provides insights from test case minimization research that apply directly to property-based test shrinking. While TestReduce focuses on reducing test suite size, its multi-parameter optimization approach offers valuable lessons for shrinking individual failing cases.

### Multi-Parameter Fitness Functions

TestReduce uses a composite objective function that considers multiple quality dimensions simultaneously:

```swift
struct ShrinkingObjectiveFunction {
    let priorityWeight: Double
    let associationWeight: Double
    let rectificationWeight: Double
    let dependencyWeight: Double

    func fitness(_ candidate: [FlatChoice], context: ShrinkingContext) -> Double {
        // P: Test priority (simpler = higher priority)
        let priorityScore = Double(context.originalCount - candidate.count) / Double(context.originalCount)

        // DA: Association degree (how many spans are preserved)
        let associationScore = Double(preservedSpans(candidate, context.spans).count) / Double(context.spans.count)

        // DI: Rectification score (how many known issues still reproduced)
        let rectificationScore = Double(context.reproducedIssues.count) / Double(context.totalIssues)

        // DR: Dependency preservation (critical building blocks maintained)
        let dependencyScore = Double(preservedDependencies(candidate, context.dependencies).count) / Double(context.dependencies.count)

        return priorityWeight * priorityScore +
               associationWeight * associationScore +
               rectificationWeight * rectificationScore +
               dependencyWeight * dependencyScore
    }

    private func preservedSpans(_ candidate: [FlatChoice], _ originalSpans: [Span]) -> [Span] {
        // Which spans from the original are still present in the candidate?
        originalSpans.filter { span in
            candidate.indices.contains(where: { $0 >= span.start && $0 < span.end })
        }
    }

    private func preservedDependencies(
        _ candidate: [FlatChoice],
        _ dependencies: Set<DependencyEdge>
    ) -> Set<DependencyEdge> {
        // Which inter-span dependencies are still satisfied?
        dependencies.filter { dep in
            candidate.contains { choice in
                choice.path.contains(where: { component in
                    dep.involves(component)
                })
            }
        }
    }
}
```

**Key Insight**: Shrinking quality isn't just about minimizing size. A good shrink should:
1. **Reduce complexity** (priority score)
2. **Preserve structure** when semantically meaningful (association score)
3. **Maintain failure reproduction** (rectification score)
4. **Keep critical dependencies** (dependency score)

### Hierarchical Shrinking Strategy

TestReduce operates at multiple abstraction levels: requirements → modules → test cases. This hierarchical approach maps naturally to property-based shrinking:

```swift
struct HierarchicalShrinker<T> {
    let generator: ReflectiveGenerator<T>

    func hierarchicalShrink(
        tree: ChoiceTree,
        oracle: (T) -> Bool
    ) -> ChoiceTree {
        var current = tree

        // Level 1: Structure-level (coarsest granularity)
        current = shrinkStructure(current, oracle: oracle)

        // Level 2: Span-level (medium granularity)
        current = shrinkSpans(current, oracle: oracle)

        // Level 3: Value-level (finest granularity)
        current = shrinkValues(current, oracle: oracle)

        return current
    }

    func shrinkStructure(_ tree: ChoiceTree, oracle: (T) -> Bool) -> ChoiceTree {
        // Operate on major structural components
        // Example: Delete entire sequences, branches, or groups
        let flat = tree.flattenToChoices()
        let spans = tree.extractSpans()

        // Group spans by depth (0 = root level structures)
        let topLevelSpans = spans.filter { $0.depth <= 1 }

        for span in topLevelSpans.sorted(by: { $0.count > $1.count }) {
            // Try removing entire top-level structures
            let candidate = Array(flat[..<span.start] + flat[span.end...])
            if let shrunk = try? replayAndTest(candidate, oracle: oracle) {
                return shrunk
            }
        }

        return tree
    }

    func shrinkSpans(_ tree: ChoiceTree, oracle: (T) -> Bool) -> ChoiceTree {
        // Operate on semantic units (spans)
        // Example: Delete individual list elements, branch children
        let flat = tree.flattenToChoices()
        let spans = tree.extractSpans()

        // Group spans by semantic type
        let leafSpans = spans.filter { span in
            !spans.contains { other in
                other.depth == span.depth + 1 &&
                other.start >= span.start &&
                other.end <= span.end
            }
        }

        for span in leafSpans.sorted(by: { $0.count < $1.count }) {
            // Try removing leaf-level spans first (less likely to break structure)
            let candidate = Array(flat[..<span.start] + flat[span.end...])
            if let shrunk = try? replayAndTest(candidate, oracle: oracle) {
                return shrunk
            }
        }

        return tree
    }

    func shrinkValues(_ tree: ChoiceTree, oracle: (T) -> Bool) -> ChoiceTree {
        // Operate on individual choice values
        // Example: Minimize integers, simplify characters
        let flat = tree.flattenToChoices()

        for (i, choice) in flat.enumerated() {
            // Try minimizing each value in isolation
            for smallerValue in generateSmallerValues(choice.value, choice.metadata) {
                var candidate = flat
                candidate[i] = FlatChoice(
                    value: smallerValue,
                    metadata: choice.metadata,
                    path: choice.path
                )
                if let shrunk = try? replayAndTest(candidate, oracle: oracle) {
                    return shrunk
                }
            }
        }

        return tree
    }
}
```

**Key Insight**: Different granularity levels require different strategies. Coarse-grained deletions (structure-level) are fast but risky. Fine-grained minimizations (value-level) are safe but slow. Process from coarse to fine for efficiency.

### Dependency Tracking

TestReduce analyzes module dependencies to avoid removing test cases that exercise critical integration points. For property-based shrinking, this translates to tracking **inter-span dependencies**:

```swift
struct DependencyEdge: Hashable {
    let from: String  // Span label
    let to: String    // Span label
    let type: DependencyType

    enum DependencyType {
        case valueReference  // One span uses a value from another
        case structuralNesting  // One span contains another
        case sequencing  // One span must appear before another
    }

    func involves(_ component: PathComponent) -> Bool {
        // Check if this dependency relates to a given path component
        // Implementation depends on how paths map to span labels
        true  // Simplified
    }
}

struct DependencyAnalyzer {
    func extractDependencies(_ tree: ChoiceTree) -> Set<DependencyEdge> {
        let spans = tree.extractSpans()
        var dependencies: Set<DependencyEdge> = []

        // Structural nesting dependencies
        for parent in spans {
            for child in spans where child.depth == parent.depth + 1 {
                if child.start >= parent.start && child.end <= parent.end {
                    dependencies.insert(DependencyEdge(
                        from: parent.label,
                        to: child.label,
                        type: .structuralNesting
                    ))
                }
            }
        }

        // Sequencing dependencies (for ordered structures)
        for i in 0..<spans.count {
            for j in (i+1)..<spans.count {
                if spans[i].end == spans[j].start && spans[i].depth == spans[j].depth {
                    dependencies.insert(DependencyEdge(
                        from: spans[i].label,
                        to: spans[j].label,
                        type: .sequencing
                    ))
                }
            }
        }

        return dependencies
    }

    func criticalSpans(
        _ spans: [Span],
        dependencies: Set<DependencyEdge>
    ) -> Set<String> {
        // Identify spans with high dependency fanout
        var fanoutCounts: [String: Int] = [:]

        for dep in dependencies {
            fanoutCounts[dep.from, default: 0] += 1
        }

        // Critical = above-median fanout
        let median = fanoutCounts.values.sorted()[fanoutCounts.count / 2]
        return Set(fanoutCounts.filter { $0.value > median }.keys)
    }
}

struct DependencyAwareShrinking {
    let dependencyAnalyzer = DependencyAnalyzer()

    func shrinkWithDependencies(
        _ tree: ChoiceTree,
        oracle: (T) -> Bool
    ) -> ChoiceTree {
        let flat = tree.flattenToChoices()
        let spans = tree.extractSpans()
        let dependencies = dependencyAnalyzer.extractDependencies(tree)
        let critical = dependencyAnalyzer.criticalSpans(spans, dependencies: dependencies)

        // Prioritize deletion of non-critical spans
        let deletionOrder = spans.sorted { lhs, rhs in
            let lhsCritical = critical.contains(lhs.label)
            let rhsCritical = critical.contains(rhs.label)

            if lhsCritical != rhsCritical {
                return !lhsCritical  // Non-critical first
            }
            return lhs.count < rhs.count  // Smaller spans first
        }

        for span in deletionOrder {
            let candidate = Array(flat[..<span.start] + flat[span.end...])
            if let shrunk = try? replayAndTest(candidate, oracle: oracle) {
                return shrunk
            }
        }

        return tree
    }
}
```

**Key Insight**: Not all spans are equally deletable. Some spans (critical nodes in the dependency graph) are more likely to be structurally necessary. Prioritize deletion of leaf nodes and low-fanout spans.

### Requirement Association Analysis

TestReduce uses the 100-Dollar technique to prioritize requirements by stakeholder value. In shrinking, this translates to **user-specified importance markers**:

```swift
extension ChoiceTree {
    // Already exists in Exhaust!
    case important(ChoiceTree)
    case selected(ChoiceTree)
}

struct ImportanceAwareShrinking {
    func prioritizeByImportance(_ spans: [Span], _ tree: ChoiceTree) -> [Span] {
        // Extract importance markers from tree
        let importantPaths = extractImportantPaths(tree)

        // Sort spans: non-important first, important last
        spans.sorted { lhs, rhs in
            let lhsImportant = importantPaths.contains(where: { $0.overlaps(lhs) })
            let rhsImportant = importantPaths.contains(where: { $0.overlaps(rhs) })

            if lhsImportant != rhsImportant {
                return !lhsImportant  // Try deleting non-important spans first
            }
            return lhs.count < rhs.count
        }
    }

    func extractImportantPaths(_ tree: ChoiceTree) -> [Span] {
        var important: [Span] = []
        var currentIndex = 0

        func visit(_ tree: ChoiceTree, depth: Int) -> Int {
            let start = currentIndex

            switch tree {
            case .important(let inner):
                let consumed = visit(inner, depth: depth)
                important.append(Span(start: start, end: currentIndex, label: "important", depth: depth))
                return consumed

            case .selected(let inner):
                let consumed = visit(inner, depth: depth)
                important.append(Span(start: start, end: currentIndex, label: "selected", depth: depth))
                return consumed

            case .choice:
                currentIndex += 1
                return 1

            // ... other cases
            default:
                return 0
            }
        }

        _ = visit(tree, depth: 0)
        return important
    }
}
```

**Key Insight**: Exhaust already has `.important` and `.selected` markers. These can guide shrinking priority: try removing non-marked spans before marked ones.

### Ripple Effect Analysis

TestReduce considers downstream effects when removing test cases. For shrinking, this means analyzing **how span deletions affect replay success probability**:

```swift
struct RippleEffectPredictor {
    func predictImpact(
        removing span: Span,
        from flat: [FlatChoice],
        allSpans: [Span]
    ) -> RippleImpact {
        var affectedSpans: [Span] = []

        // Find spans that come after this one
        let downstream = allSpans.filter { $0.start >= span.end }

        // Check if removing this span breaks length constraints
        for downstreamSpan in downstream {
            // If this span contains a sequence length choice
            if span.label.contains("length") {
                // Removing it will affect all subsequent spans in that sequence
                if downstreamSpan.label.hasPrefix(span.label.split(separator: ".").dropLast().joined(separator: ".")) {
                    affectedSpans.append(downstreamSpan)
                }
            }
        }

        return RippleImpact(
            directlyAffected: affectedSpans.count,
            estimatedReplayFailureProbability: Double(affectedSpans.count) / Double(allSpans.count)
        )
    }
}

struct RippleImpact {
    let directlyAffected: Int
    let estimatedReplayFailureProbability: Double
}

struct RippleAwareShrinking {
    let predictor = RippleEffectPredictor()

    func shrinkWithRippleConsideration(
        _ tree: ChoiceTree,
        oracle: (T) -> Bool
    ) -> ChoiceTree {
        let flat = tree.flattenToChoices()
        let spans = tree.extractSpans()

        // Calculate ripple impact for each span
        let spansWithImpact = spans.map { span in
            (span, predictor.predictImpact(removing: span, from: flat, allSpans: spans))
        }

        // Sort by ripple impact: lower impact first
        let sortedByImpact = spansWithImpact.sorted { lhs, rhs in
            lhs.1.estimatedReplayFailureProbability < rhs.1.estimatedReplayFailureProbability
        }

        for (span, impact) in sortedByImpact {
            // Skip spans with very high ripple impact (likely to fail replay)
            if impact.estimatedReplayFailureProbability > 0.8 {
                continue
            }

            let candidate = Array(flat[..<span.start] + flat[span.end...])
            if let shrunk = try? replayAndTest(candidate, oracle: oracle) {
                return shrunk
            }
        }

        return tree
    }
}
```

**Key Insight**: Not all deletions are equally likely to succeed. Predict which deletions will break replay constraints and try low-risk deletions first.

### Integration: Multi-Objective Shrinking

Combining TestReduce insights into a unified strategy:

```swift
struct MultiObjectiveShrinker<T> {
    let generator: ReflectiveGenerator<T>
    let dependencyAnalyzer = DependencyAnalyzer()
    let ripplePredictor = RippleEffectPredictor()

    func shrink(tree: ChoiceTree, oracle: (T) -> Bool) -> ChoiceTree {
        var current = tree
        var improved = true

        while improved {
            improved = false

            let flat = current.flattenToChoices()
            let spans = current.extractSpans()
            let dependencies = dependencyAnalyzer.extractDependencies(current)
            let critical = dependencyAnalyzer.criticalSpans(spans, dependencies: dependencies)
            let important = extractImportantPaths(current)

            // Multi-objective candidate scoring
            let scoredSpans = spans.map { span in
                (
                    span: span,
                    score: scoreSpan(
                        span,
                        critical: critical,
                        important: important,
                        flat: flat,
                        allSpans: spans
                    )
                )
            }

            // Try deletions in priority order
            for (span, _) in scoredSpans.sorted(by: { $0.score > $1.score }) {
                let candidate = Array(flat[..<span.start] + flat[span.end...])
                if let shrunk = try? replayAndTest(candidate, oracle: oracle) {
                    current = shrunk
                    improved = true
                    break
                }
            }
        }

        return current
    }

    func scoreSpan(
        _ span: Span,
        critical: Set<String>,
        important: [Span],
        flat: [FlatChoice],
        allSpans: [Span]
    ) -> Double {
        var score = 100.0

        // Penalize critical spans (harder to delete without breaking structure)
        if critical.contains(span.label) {
            score -= 30.0
        }

        // Penalize important spans (user wants to keep these)
        if important.contains(where: { $0.overlaps(span) }) {
            score -= 40.0
        }

        // Penalize large ripple effect (likely to fail replay)
        let ripple = ripplePredictor.predictImpact(removing: span, from: flat, allSpans: allSpans)
        score -= ripple.estimatedReplayFailureProbability * 50.0

        // Reward simpler spans (lower complexity is better)
        score += Double(allSpans.map(\.count).max() ?? 1 - span.count) / Double(allSpans.map(\.count).max() ?? 1) * 20.0

        return score
    }

    private func extractImportantPaths(_ tree: ChoiceTree) -> [Span] {
        // Implementation as shown above
        []
    }
}

extension Span {
    func overlaps(_ other: Span) -> Bool {
        !(end <= other.start || start >= other.end)
    }
}
```

**Key Insight**: Shrinking is inherently multi-objective. The best deletion candidate balances:
1. Simplicity (shortlex ordering)
2. Structural safety (avoiding critical dependencies)
3. Semantic preservation (respecting importance markers)
4. Replay viability (minimizing ripple effects)

### Summary: TestReduce Contributions to Shrinking

| TestReduce Concept | Property-Based Shrinking Application | Benefit |
|--------------------|--------------------------------------|---------|
| Multi-parameter optimization | Composite fitness function (size + structure + semantics) | Better shrink quality beyond just "smaller" |
| Hierarchical approach | Structure → Span → Value levels | Efficient coarse-to-fine search |
| Dependency analysis | Inter-span dependency tracking | Avoid breaking structural invariants |
| Requirement prioritization | Respect `.important`/`.selected` markers | User-guided shrinking |
| Ripple effect analysis | Predict replay failure probability | Reduce wasted replay attempts |
| Association analysis | Preserve semantically-related spans | Maintain interpretability |

The TestReduce algorithm shows that effective minimization requires **context-aware prioritization**, not just blind search. By considering multiple quality dimensions and structural relationships, shrinking can achieve both minimal size and maximal clarity.

## Open Questions

1. **Performance**: How expensive is the replay validation? May need caching/memoization
2. **Strategy ordering**: Which flat operations to try first for fastest shrinking?
3. **Hybrid tuning**: When to switch from tree to flat shrinking?
4. **Range learning**: Can we update `validRanges` based on replay failures?
5. **Span granularity**: How fine-grained should spans be? Should every choice have a span?
6. **Span caching**: Should spans be cached with the ChoiceTree, or computed on-demand?
7. **Span priorities**: Should some spans (e.g., marked with `.important`) be prioritized in deletion order?
8. **GA integration**: Which genetic algorithm techniques provide the best cost/benefit ratio?
9. **Adaptive strategy selection**: Can we learn which strategies work best for different generator types?

## The Projection-Replay Validation Pattern

This architecture represents a general design pattern that may have broader applicability beyond property-based testing:

### Pattern Structure

**Projection-Replay Validation** consists of three key phases:

1. **Structural Projection**: Transform a rigid hierarchical structure into a flat linear sequence with advisory metadata overlay
   - Forward: `Tree --deterministic--> Flat + Spans`
   - The projection is purely structural (deterministic, information-preserving)
   - Metadata (spans) capture semantic boundaries without enforcing constraints

2. **Unconstrained Mutation**: Perform arbitrary operations on the flat representation
   - Operations that would be structurally impossible in the tree form become trivial
   - Mutations ignore structural invariants completely
   - The flat form enables cross-boundary transformations

3. **Generative Validation**: Validate mutations by replaying through the generative process
   - Backward: `Flat ----generator----> Tree (or failure)`
   - The generator interprets the flat sequence, enforcing constraints dynamically
   - Invalid mutations fail naturally during replay, not through structural checks
   - Successful replay reconstructs the tree structure

### Key Properties

This pattern exhibits crucial **asymmetry**:
- **Forward direction** (projection): Deterministic structural transformation
- **Backward direction** (validation): Generative interpretation with potential failure

The power comes from **deferring validation** from mutation-time (where it would constrain operations) to replay-time (where it happens naturally through the generator's logic).

### Why This Works

Traditional dual representations use **structural validation**:
```
Mutate → Check invariants → Accept/Reject
```

Projection-Replay uses **generative validation**:
```
Mutate → Replay through generator → Succeeds/Fails naturally
```

The generator encodes all constraints implicitly through its control flow, branching logic, and state management. By replaying mutations through the generator, we get validation "for free" without explicitly checking invariants.

### Potential Applications

This pattern might apply wherever:
1. A rigid structure constrains desired operations
2. A generative process can validate mutations
3. The generative process naturally encodes all necessary invariants

Examples might include:
- Program transformation with type-checking as validation
- Database query optimization with cost model validation  
- Configuration mutation with deployment validation
- Any domain with a "generator" that encodes complex constraints

## Summary

By maintaining both a structured `ChoiceTree` and a flattened choice sequence, Exhaust can achieve Hypothesis-style shrinking power while preserving the semantic benefits of a structured representation. The key insight is that **replay provides automatic validation**, allowing aggressive structural mutations that would be unsafe with manual tree manipulation.
This architectural approach instantiates the **Projection-Replay Validation** pattern: a general technique for enabling flexible mutations on structured data by deferring validation to a generative reconstruction process.

