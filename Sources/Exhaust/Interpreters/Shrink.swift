import Foundation

struct DeprecatedShrinker {
    /// Attempts to shrink the `value` according to the `property`
    /// - Parameters:
    ///   - value: The value
    ///   - generator: The generator used to generate the value
    ///   - property: A function that should return `true`, representing a an invariant relationship of the `value`
    /// - Returns: A minimal counterexample to aid in debugging
    public func shrink<Input, Output>(
        _ value: Output,
        using generator: ReflectiveGenerator<Input, Output>,
        where property: (Output) -> Bool
    ) -> Output {
        
        let shrinkingStartTime = Date()
        
        guard var bestPath = Interpreters.reflect(generator, with: value) else {
            fatalError("Could not reflect initial value!")
        }
        
        var smallestValue = value
        var totalShrinkSteps = 0

        // Main loop: will run the greedy algorithm at least once.
        while true {
            var didFindSmallerInGreedyPass = false
            
            // --- PHASE 1: Fast Greedy Pass ---
            let greedyIterator = ShrinkCandidateIterator(tree: bestPath)
            while let candidate = greedyIterator.next() {
                let stepStartTime = Date()
                let candidateValue = Interpreters.replay(generator, using: candidate)
                let stepDuration = Date().timeIntervalSince(stepStartTime)
                totalShrinkSteps += 1
                
                if let candidateValue, property(candidateValue) == false {
                    // Report successful shrink step
                    if TycheReportContext.isReportingEnabled {
                        let metadata = ShrinkingMetadata(
                            originalComplexity: bestPath.complexity,
                            targetComplexity: candidate.complexity,
                            stepType: .greedyCandidate,
                            duration: stepDuration,
                            wasSuccessful: true
                        )
                        TycheReportContext.safeRecordShrinkStep(from: smallestValue, to: candidateValue, metadata: metadata)
                    }
                    
                    bestPath = candidate
                    smallestValue = candidateValue
                    didFindSmallerInGreedyPass = true
                    print("Found shrink in greedy pass \(candidateValue)")
                    break // Found a shrink, restart the greedy search
                } else {
                    // Report failed shrink step
                    if TycheReportContext.isReportingEnabled {
                        let metadata = ShrinkingMetadata(
                            originalComplexity: bestPath.complexity,
                            targetComplexity: candidate.complexity,
                            stepType: .greedyCandidate,
                            duration: stepDuration,
                            wasSuccessful: false
                        )
                        TycheReportContext.safeRecordShrinkStep(from: smallestValue, to: candidateValue ?? "nil", metadata: metadata)
                    }
                    print("Failed shrink")
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
            print("Materialised \(allCandidates.underestimatedCount) shrinks")
            for candidate in allCandidates {
                // Is this candidate potentially better than the best we've found in this polish pass?
                if candidate.complexity < passBestPath.complexity {
                    let stepStartTime = Date()
                    let candidateValue = Interpreters.replay(generator, using: candidate)
                    let stepDuration = Date().timeIntervalSince(stepStartTime)
                    totalShrinkSteps += 1
                    
                    if let candidateValue, property(candidateValue) == false {
                        // Report successful exhaustive shrink step
                        if TycheReportContext.isReportingEnabled {
                            let metadata = ShrinkingMetadata(
                                originalComplexity: passBestPath.complexity,
                                targetComplexity: candidate.complexity,
                                stepType: .exhaustiveCandidate,
                                duration: stepDuration,
                                wasSuccessful: true
                            )
                            TycheReportContext.safeRecordShrinkStep(from: smallestValue, to: candidateValue, metadata: metadata)
                        }
                        print("Found better shrink in polish \(candidateValue)")
                        
                        passBestPath = candidate
                        smallestValue = candidateValue
                        foundBetterInPolish = true
                    } else {
                        // Report failed exhaustive shrink step
                        if TycheReportContext.isReportingEnabled {
                            let metadata = ShrinkingMetadata(
                                originalComplexity: passBestPath.complexity,
                                targetComplexity: candidate.complexity,
                                stepType: .exhaustiveCandidate,
                                duration: stepDuration,
                                wasSuccessful: false
                            )
                            TycheReportContext.safeRecordShrinkStep(from: smallestValue, to: candidateValue ?? "nil", metadata: metadata)
                        }
                        print("failed polish shrink")
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
        
        // Report final shrinking outcome
        if TycheReportContext.isReportingEnabled {
            let totalShrinkingDuration = Date().timeIntervalSince(shrinkingStartTime)
            let outcome = TestOutcome(
                wasSuccessful: false, // We found a counterexample
                counterexampleValue: smallestValue,
                shrinkingSteps: totalShrinkSteps,
                totalDuration: totalShrinkingDuration
            )
            TycheReportContext.safeRecordTestOutcome(outcome)
        }
        
        return smallestValue
    }
}
