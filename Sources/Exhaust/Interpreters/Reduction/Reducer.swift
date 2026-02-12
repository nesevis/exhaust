//
//  Reducer.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation

extension Interpreters {
    
    public enum ShrinkConfiguration {
        case fast
        
        var maxStalls: Int {
            switch self {
            case .fast:
                8
            }
        }
    }
    
    public static func reduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: ShrinkConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output?)? {
        // Mutable variables
        var currentSequence = ChoiceSequence.flatten(tree)
        // I don't think we need to reflect to regenerate this?
        // There is then a hard dependency on having to have reflectable generators, which is a pain
        let currentTree = tree
        var currentOutput = try materialize(gen, with: tree, using: currentSequence)
        let stallBudget = config.maxStalls
        
        while stallBudget > 0 {
            var didImprove = false

            let containerSpans = ChoiceSequence.extractContainerSpans(from: currentSequence)
            // Pass 1: Adaptive container span deletion, ie the […] and (…) spans in [(V)(V)]
            if containerSpans.isEmpty == false, let (newSequence, output) = try adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: containerSpans) {
                currentSequence = newSequence
                currentOutput = output
                didImprove = true
                // TODO: Continue to next pass, do not return from here
                return (currentSequence, currentOutput)
            }
            // Pass 2a: Collapse sequence boundaries, i.e [[V][V][V]] -> [[VVV]]
            let boundarySpans = ChoiceSequence.extractSequenceBoundarySpans(from: currentSequence)
            if boundarySpans.isEmpty == false, let (newSequence, output) = try adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: boundarySpans) {
                currentSequence = newSequence
                currentOutput = output
                didImprove = true
                // TODO: Continue to next pass, do not return from here
                return (currentSequence, currentOutput)
            }
            // Pass 2b: Sequence element deletion, i.e the individual Vs in [VVVVV]
            let valueSpans = ChoiceSequence.extractValueSpans(from: currentSequence)
            if valueSpans.isEmpty == false, let (newSequence, output) = try adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: valueSpans) {
                currentSequence = newSequence
                currentOutput = output
                didImprove = true
                // TODO: Continue to next pass, do not return from here
                return (currentSequence, currentOutput)
            }
            print(didImprove)
            // Pass 3: Zero within range
            // Set all values to their semantic zero. Can use value span extraction
            // Pass 4: Pass to descendant
            // "For each span taht contains child spans, try replacing the parent span with each child span individually"
            // I wonder if this will work well for Exhaust's architecture
            // Pass 5: Minimise individual values
            // Set all values to their semantic zero. Can use value span extraction
            // Pass 5: Shortlex order results for consistency?
        }
        
        return (currentSequence, nil)
    }
    
    private static func adaptiveDeleteSpans<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        spans: [ChoiceSequence.ChoiceSpan]
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?
        
        // Sort spans by depth (outermost first = lowest depth), preserving order within depth
        let sortedSpans = spans.sorted { $0.depth < $1.depth }

        var i = 0
        while i < sortedSpans.count {
            let span = sortedSpans[i]

            // Use the adaptive probe `findInteger` to find the largest batch we can delete
            let k = AdaptiveProbe.findInteger { (size: Int) in
                // Holy shit this entire closure is so expensive!
                var rangesToDelete = [ClosedRange<Int>]()
                var ii = 0
                while ii < size {
                    let index = i + ii

                    guard index < sortedSpans.count else {
                        return false
                    }

                    // Only batch spans at the same depth
                    guard sortedSpans[index].depth == span.depth else {
                        return false
                    }
                    rangesToDelete.append(sortedSpans[index].range)

                    ii += 1
                }

                // Apply deletion
                var candidate = current
                candidate.removeSubranges(rangesToDelete)
                if candidate.shortLexPrecedes(current) {
                    do {
                        guard let output = try materialize(gen, with: tree, using: candidate) else {
                            return false
                        }
                        return property(output) == false
                    } catch {
                        return false
                    }
                }
                return false
            }

            if k > 0 {
                // Apply the deletion
                var rangeSet = RangeSet<Int>()
                for j in 0..<k {
                    rangeSet.insert(contentsOf: sortedSpans[i + j].range.asRange)
                }
                
                var candidate = current
                candidate.removeSubranges(rangeSet)
                
                // Get the output for the accepted candidate
                if let output = try? materialize(gen, with: tree, using: candidate) {
                    current = candidate
                    latestOutput = output
                    progress = true
                    // Don't advance - try deleting more from the same position
                    // But we need to rebuild spans now that the subranges have been removed
                    return (current, output)
                }
            }
            i += 1
        }

        return nil
    }
}
