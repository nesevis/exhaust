import Foundation

struct Shrinker {
    public func shrink<Input, Output>(
        _ value: Output,
        using generator: ReflectiveGen<Input, Output>,
        where testIsFailing: (Output) -> Bool
    ) -> Output {
        
        let initialPath = Interpreters.reflect(generator, with: value)
        guard var bestPath = initialPath else {
            fatalError("Could not shrink initial value!")
        }
        
        var smallestValue = value
        var passHasFoundSmaller: Bool = true

        while passHasFoundSmaller {
            passHasFoundSmaller = false
            
            // 1. Create a new lazy iterator for the current best path.
            let candidateIterator = ShrinkCandidateIterator(tree: bestPath)
            
            // 2. Loop through candidates one-by-one, in order of simplicity.
            while let candidatePath = candidateIterator.next() {
                guard let candidateValue = Interpreters.replay(generator, using: candidatePath) else {
                    continue
                }
                
                if testIsFailing(candidateValue) {
                    // Success! We found a smaller failing value.
                    bestPath = candidatePath
                    smallestValue = candidateValue
                    passHasFoundSmaller = true
                    
                    // Greedy approach: break and restart the whole process
                    // with a new iterator for our new, smaller 'bestPath'.
                    break
                }
            }
        }
        return smallestValue
    }
}
