import Foundation

struct Shrinker {
    public func shrink<Input, Output>(
        _ value: Output,
        using generator: ReflectiveGen<Input, Output>,
        where testIsFailing: (Output) -> Bool
    ) -> Output {
        
        guard var bestPath = Interpreters.reflect(generator, with: value) else {
            fatalError("Could not reflect initial value!")
        }
        
        var smallestValue = value

        // Main loop: will run the greedy algorithm at least once.
        while true {
            var didFindSmallerInGreedyPass = false
            
            // --- PHASE 1: Fast Greedy Pass ---
            let greedyIterator = ShrinkCandidateIterator(tree: bestPath)
            while let candidate = greedyIterator.next() {
                if let candidateValue = Interpreters.replay(generator, using: candidate), testIsFailing(candidateValue) {
                    bestPath = candidate
                    smallestValue = candidateValue
                    didFindSmallerInGreedyPass = true
                    break // Found a shrink, restart the greedy search
                }
            }
            
            // If the fast pass found a smaller value, we loop again to be greedy.
            if didFindSmallerInGreedyPass {
                continue
            }

            // --- PHASE 2: Final Exhaustive Polish Pass ---
            // The greedy pass completed without finding anything. Let's be certain.
            var passBestPath = bestPath
            var foundBetterInPolish = false

            // This iterator is not designed to be a Sequence, but for demonstration:
            let allCandidates = ShrinkCandidateSequence(tree: bestPath) // Materialize all shrinks
            for candidate in allCandidates {
                // Is this candidate potentially better than the best we've found in this polish pass?
                if candidate.complexity < passBestPath.complexity {
                    if let candidateValue = Interpreters.replay(generator, using: candidate), testIsFailing(candidateValue) {
                        passBestPath = candidate
                        smallestValue = candidateValue
                        foundBetterInPolish = true
                    }
                }
            }
            
            // If the exhaustive pass squeezed out a final improvement, update the bestPath
            // and run the whole process again from that even better starting point.
            if foundBetterInPolish {
                bestPath = passBestPath
                continue
            }
            
            // If we get here, neither the greedy nor the exhaustive pass could find an improvement.
            // We are truly done.
            break
        }
        
        return smallestValue
    }
}
