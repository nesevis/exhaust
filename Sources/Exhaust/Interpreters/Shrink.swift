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
        
        var bestPath = paths
        var smallestValue = value
        
        var foundSmallerInPass = true
        
        // 2. Loop until we can no longer find a smaller failing example.
        while foundSmallerInPass {
            foundSmallerInPass = false
            
            // Generate all possible "one-step" shrinks from the current best path.
            let candidatePaths = generateShrinks(for: bestPath)
            
            for candidatePath in candidatePaths {
                // 3. Replay the simplified path to get a new value.
                guard let candidateValue = Interpreters.replay(generator, using: candidatePath) else {
                    // This path was invalid for the generator, skip it.
                    continue
                }
                
                // 4. Run the test on the new, smaller value.
                if testIsFailing(candidateValue) {
                    // Success! We found a smaller value that still fails.
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
    
    // In Shrinker
    // In Shrinker
    private func generateShrinks(for tree: ChoiceTree) -> [ChoiceTree] {
        var shrinks: [ChoiceTree] = []
        
        switch tree {
        case .choice(let bits):
            // Simple shrinking for primitive values
            shrinks.append(contentsOf: shrinkNumber(bits).map { .choice($0) })
            
        case .sequence(let length, let elements):
            // Only shrink sequences by reducing length
            for shrunkLength in shrinkNumber(length).filter({ $0 > 0 && $0 < length }) {
                let targetCount = Int(shrunkLength)
                if elements.count >= targetCount {
                    let prefix = Array(elements.prefix(targetCount))
                    if prefix.count == targetCount {
                        shrinks.append(.sequence(length: shrunkLength, elements: prefix))
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
    
    /// Generates a list of candidate "smaller" choice paths from a given path.
    ///
    /// The strategies are ordered from most aggressive (deletion) to most subtle (element-wise).
//    private func generateShrinks(for path: [String]) -> [[String]] {
//        var shrinks: [[String]] = []
//        
//        // Strategy 1: Deletion. Try removing each element one by one.
//        for i in 0..<path.count {
//            var newPath = path
//            newPath.remove(at: i)
//            shrinks.append(newPath)
//        }
//        
//        // Strategy 2: Element-wise shrinking.
//        for (i, element) in path.enumerated() {
//            // Try to shrink the element if it's a number.
//            if let number = UInt64(element) {
//                let shrunkenNumbers = shrinkNumber(number)
//                for shrunkNum in shrunkenNumbers {
//                    var newPath = path
//                    newPath[i] = String(shrunkNum)
//                    shrinks.append(newPath)
//                }
//            }
//        }
//        
//        return shrinks
//    }
    
    // Helper functions for constraint validation
    private func isValidElementForSequence(_ element: ChoiceTree) -> Bool {
        switch element {
        case .choice(let bits):
            // For Character elements, ensure they're in valid ASCII range
            return (33...125).contains(bits)
        default:
            return true
        }
    }
    
    private func shrinkNumberConservatively(_ n: UInt64) -> [UInt64] {
        var shrinks: [UInt64] = []
        
        // For character values, try meaningful shrinks
        if (33...125).contains(n) {
            // Try common minimal characters first
            let commonChars: [UInt64] = [65, 97, 48] // 'A', 'a', '0'
            for char in commonChars {
                if char < n {
                    shrinks.append(char)
                }
            }
        }
        
        // Then try standard binary search shrinking
        if n > 0 {
            var x = n / 2
            while x > 0 {
                shrinks.append(n - x)
                x /= 2
            }
        }
        
        return shrinks
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
