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
        guard let initialPath = paths.first else {
            // The generator couldn't have produced this value, so we can't shrink it.
            print("Shrinker Warning: Could not reflect on initial value. Returning original.")
            return value
        }
        
        var bestPath = initialPath
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
                    print("Shrinker found smaller failing value. Path length: \(candidatePath.count)")
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
    
    /// Generates a list of candidate "smaller" choice paths from a given path.
    ///
    /// The strategies are ordered from most aggressive (deletion) to most subtle (element-wise).
    private func generateShrinks(for path: [String]) -> [[String]] {
        var shrinks: [[String]] = []
        
        // Strategy 1: Deletion. Try removing each element one by one.
        for i in 0..<path.count {
            var newPath = path
            newPath.remove(at: i)
            shrinks.append(newPath)
        }
        
        // Strategy 2: Element-wise shrinking.
        for (i, element) in path.enumerated() {
            // Try to shrink the element if it's a number.
            if let number = UInt64(element) {
                let shrunkenNumbers = shrinkNumber(number)
                for shrunkNum in shrunkenNumbers {
                    var newPath = path
                    newPath[i] = String(shrunkNum)
                    shrinks.append(newPath)
                }
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
