import Foundation

/// A class responsible for shrinking a failing test case to a minimal example.
/// It uses a `reflect`/`replay` loop to operate on the generator's `choicePath`.
struct Shrinker {
    /// Shrinks a failing value to the smallest possible version that still causes the test to fail.
    ///
    /// The process is as follows:
    /// 1. Use `reflect` to get the choice path of the initial failing value.
    /// 2. Repeatedly generate simpler, "smaller" versions of that choice path.
    /// 3. Use `replay` to turn each simplified path back into a value.
    /// 4. If the new value still fails the test, it becomes the new "best" candidate,
    ///    and we restart the shrinking process from there.
    /// 5. This continues until no smaller failing example can be found in a full pass.
    ///
    /// - Parameters:
    ///   - value: The initial, large value that failed the test.
    ///   - generator: An aligned generator (`<Value, Value>`) capable of producing the value.
    ///   - test: A closure that returns `true` if the value is "bad" (i.e., the test fails).
    /// - Returns: The smallest value found that still makes the test fail.
    public func shrink<Input, Output>(
        _ value: Output,
        using generator: ReflectiveGen<Input, Output>,
        where testIsFailing: (Output) -> Bool
    ) -> Output {
        
        // 1. Get the initial script for the failing value.
        let paths = Interpreters.reflect(generator, with: value)
        
        guard let paths else {
            fatalError("Could not shrink initial value!")
        }
        
        var bestPath = paths
        var smallestValue = value
        
        var foundSmallerInPass = true
        
        // 2. Loop until we can no longer find a smaller failing example.
        while foundSmallerInPass {
            foundSmallerInPass = false
            
            // Generate all possible "one-step" shrinks from the current best path.
            let candidatePaths = generateShrinks(for: bestPath)
            
            // Sort candidates by potential effectiveness (smaller/simpler first)
            let sortedCandidates = candidatePaths.sorted { lhs, rhs in
                return estimateComplexity(lhs) < estimateComplexity(rhs)
            }
            
            for candidatePath in sortedCandidates {
                // 3. Replay the simplified path to get a new value.
                guard let candidateValue = Interpreters.replay(generator, using: candidatePath) else {
                    // This path was invalid for the generator, skip it.
                    continue
                }
                
                // 4. Run the test on the new, smaller value.
                if testIsFailing(candidateValue) {
                    // Success! We found a smaller value that still fails.
                    // Success! Found a smaller failing value
                    bestPath = candidatePath
                    smallestValue = candidateValue
                    foundSmallerInPass = true
                    
                    // Greedy approach: restart the shrinking process from this new, better path.
                    break
                }
            }
        }
        
        return smallestValue
    }
    
    // MARK: - Private Shrinking Helpers
    
    /// Generates shrinks for a single element with a specific valid range
    private func generateShrinksForElement(_ tree: ChoiceTree, validRange: ClosedRange<UInt64>) -> [ChoiceTree] {
        switch tree {
        case .choice(let bits):
            // Use the valid range to filter shrinks
            return shrinkNumberAggressively(bits, validRange: validRange).map { .choice($0) }
        default:
            // For non-choice elements, use regular shrinking
            return generateShrinks(for: tree)
        }
    }
    
    // In Shrinker
    // In Shrinker
    private func generateShrinks(for tree: ChoiceTree) -> [ChoiceTree] {
        var shrinks: [ChoiceTree] = []
        
        switch tree {
        case .choice(let bits):
            // Aggressive shrinking for primitive values - no valid range available at this level
            shrinks.append(contentsOf: shrinkNumberAggressively(bits).map { .choice($0) })
            
        case .sequence(let length, let elements, let range):
            // AGGRESSIVE SEQUENCE SHRINKING
            
            // Strategy 0: Filter out invalid elements entirely
            let validElements = elements.filter { element in
                if case .choice(let bits) = element {
                    return range.contains(bits)
                }
                return true
            }
            
            // If we have fewer valid elements, create a shorter sequence
            if validElements.count < elements.count && !validElements.isEmpty {
                shrinks.append(.sequence(length: UInt64(validElements.count), elements: validElements, validRange: range))
            }
            
            // Strategy 1: Try progressively smaller lengths (most aggressive)
            // Start with very small sizes and work up
            let maxTries = min(10, Int(length))
            for targetLength in 1...maxTries {
                if targetLength < length {
                    let targetCount = targetLength
                    if validElements.count >= targetCount {
                        // Try prefix (keeping first elements)
                        let prefix = Array(validElements.prefix(targetCount))
                        if prefix.count == targetCount {
                            shrinks.append(.sequence(length: UInt64(targetLength), elements: prefix, validRange: range))
                        }
                        
                        // Try suffix (keeping last elements)
                        let suffix = Array(validElements.suffix(targetCount))
                        if suffix.count == targetCount && suffix != prefix {
                            shrinks.append(.sequence(length: UInt64(targetLength), elements: suffix, validRange: range))
                        }
                        
                        // Try middle section
                        if validElements.count > targetCount {
                            let startIndex = (validElements.count - targetCount) / 2
                            let middle = Array(validElements[startIndex..<(startIndex + targetCount)])
                            if middle.count == targetCount && middle != prefix && middle != suffix {
                                shrinks.append(.sequence(length: UInt64(targetLength), elements: middle, validRange: range))
                            }
                        }
                    }
                }
            }
            
            // Strategy 2: Binary search style shrinking (for larger sequences)
            let binarySearchShrinks = shrinkNumber(length).filter({ $0 > maxTries && $0 < length })
            for shrunkLength in binarySearchShrinks {
                let targetCount = Int(shrunkLength)
                if validElements.count >= targetCount {
                    let prefix = Array(validElements.prefix(targetCount))
                    if prefix.count == targetCount {
                        shrinks.append(.sequence(length: shrunkLength, elements: prefix, validRange: range))
                    }
                }
            }
            
            // Strategy 3: Element-wise shrinking (for sequences that can't be shortened much)
            if length <= 20 { // Only for reasonably sized sequences
                for i in 0..<validElements.count {
                    let elementShrinks = generateShrinksForElement(validElements[i], validRange: range)
                    for shrunkElement in elementShrinks {
                        var newElements = validElements
                        newElements[i] = shrunkElement
                        shrinks.append(.sequence(length: UInt64(newElements.count), elements: newElements, validRange: range))
                    }
                }
            }
            
        case .group(let children):
            // Recursively shrink each child
            for i in 0..<children.count {
                let childShrinks = generateShrinks(for: children[i])
                for shrunkChild in childShrinks {
                    var newChildren = children
                    newChildren[i] = shrunkChild
                    shrinks.append(.group(newChildren))
                }
            }
            
        case .branch(let label, let children):
            // Recursively shrink each child
            for i in 0..<children.count {
                let childShrinks = generateShrinks(for: children[i])
                for shrunkChild in childShrinks {
                    var newChildren = children
                    newChildren[i] = shrunkChild
                    shrinks.append(.branch(label: label, children: newChildren))
                }
            }
        }
        
        return shrinks
    }

    /// Strategy 2: Shrink the elements of the sequence, keeping the length the same.
    private func shrinkSequenceElements(_ path: [String]) -> [[String]] {
        guard let lengthString = path.first, let length = Int(lengthString), length > 0 else {
            return []
        }
        
        // We assume the first element is the length, and the rest are for the elements.
        let elementPath = Array(path.dropFirst())
        var shrinks: [[String]] = []
        
        // Try shrinking each element's choice(s) individually.
        for i in 0..<elementPath.count {
            let elementChoice = elementPath[i]
            
            // If the element's choice is a number, shrink it.
            if let number = UInt64(elementChoice) {
                let shrunkenNumbers = shrinkNumber(number)
                for shrunkNum in shrunkenNumbers {
                    var newElementPath = elementPath
                    newElementPath[i] = String(shrunkNum)
                    
                    // Prepend the original length choice to form a complete path.
                    shrinks.append([lengthString] + newElementPath)
                }
            }
        }
        return shrinks
    }

    /// Strategy 3: Generic fallback shrinks (from before).
    private func shrinkGeneric(_ path: [String]) -> [[String]] {
        // ... try deleting elements, etc.
        return []
    }
    
    // Helper functions for constraint validation
    private func isValidElementForSequence(_ element: ChoiceTree) -> Bool {
        switch element {
        case .choice(let bits):
            // For Character elements, ensure they're in valid ASCII range
            return (32...125).contains(bits)
        default:
            return true
        }
    }
    
    private func shrinkNumberAggressively(_ number: UInt64, validRange: ClosedRange<UInt64>) -> [UInt64] {
        var shrinks: Set<UInt64> = []
        
        // Use the valid range's lower bound instead of 0
        let effectiveMin = validRange.lowerBound
        
        // For Character values, try meaningful character values first
        if (32...125).contains(number) {
            // Common minimal characters in ascending order of preference
            let commonChars: [UInt64] = [65, 97, 48, 32] // 'A', 'a', '0', ' '
            for char in commonChars {
                if char < number && validRange.contains(char) {
                    shrinks.insert(char)
                }
            }
        }
        
        // For small numbers, try every integer down to effective minimum
        if number <= 10 {
            for i in (validRange.lowerBound..<number).reversed() {
                shrinks.insert(i)
            }
        } else {
            // For larger numbers, use more aggressive steps but respect valid range
            let steps: [UInt64] = [1, 2, 3, 5, 10, 25, 50, 100]
            for step in steps {
                if step <= number { // Prevent underflow
                    let candidate = number - step
                    if candidate >= effectiveMin && validRange.upperBound >= candidate {
                        shrinks.insert(candidate)
                    }
                }
            }
            
            // Then use binary search approach
            var x = number / 2
            while x > 100 {
                if x <= number { // Prevent underflow
                    let candidate = number - x
                    if candidate >= effectiveMin && validRange.upperBound >= candidate {
                        shrinks.insert(candidate)
                    }
                }
                x /= 2
            }
        }
        let result = shrinks.sorted(by: >)
        return result // Return in descending order for better performance
    }
    
    // Keep the original function for backward compatibility
    private func shrinkNumberAggressively(_ n: UInt64) -> [UInt64] {
        return shrinkNumberAggressively(n, validRange: UInt64.min...UInt64.max)
    }
    
    /// Estimates the complexity of a ChoiceTree for sorting shrink candidates
    private func estimateComplexity(_ tree: ChoiceTree) -> Int {
        switch tree {
        case .choice(let bits):
            return Int(bits) // Lower numbers are simpler
        case .sequence(let length, let elements, let range):
            return Int(length) * 10 + elements.reduce(0) { $0 + estimateComplexity($1) }
        case .group(let children):
            return children.reduce(0) { $0 + estimateComplexity($1) }
        case .branch(_, let children):
            return 1000 + children.reduce(0) { $0 + estimateComplexity($1) } // Branches are complex
        }
    }
    
    /// A simple algorithm to shrink a number towards zero.
    private func shrinkNumber(_ n: UInt64) -> [UInt64] {
        var shrinks: [UInt64] = []
        if n != 0 {
            shrinks.append(0)
        }
        
        var x = n / 2
        while x > 0 {
            shrinks.append(n - x)
            x /= 2
        }
        return shrinks
    }
}
