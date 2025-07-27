//
//  TieredShrinker.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

import Foundation

enum Interpreters {
    /// Attempts to shrink the `value` according to the `property`
    /// - Parameters:
    ///   - value: The value
    ///   - generator: The generator used to generate the value
    ///   - property: A function that should return `true`, representing a an invariant relationship of the `value`
    /// - Returns: A minimal counterexample to aid in debugging
    public static func shrink<Input, Output>(
    _ value: Output,
    using generator: ReflectiveGenerator<Input, Output>,
    where property: (Output) -> Bool
    ) throws -> Output {
        // At this stage we know that `value`'s values represent a higher or a lower bound beyond the generator
        // Can we 'cheat' and encode that?
        guard let reflectedRecipe = try Interpreters.reflect(generator, with: value) else {
            throw ShrinkError.couldNotReflect
        }
        // If this recipe had reflected a `pick` with multiple `.branch` choices and one was selected
        // we need to deselect it to open the value up to shrinking
        let recipe = reflectedRecipe
            .map { choice in
                if case let .selected(selected) = choice {
                    return selected
                }
                return choice
            }
        guard property(value) == false else {
            throw ShrinkError.counterExampleMustFail
        }
        return try self.shrinkImpl(value, using: generator, recipe: recipe, where: property)
    }
    
    private static func shrinkImpl<Input, Output>(
        _ value: Output,
        using generator: ReflectiveGenerator<Input, Output>,
        recipe: ChoiceTree,
        where property: (Output) -> Bool
    ) throws -> Output {
        
        var currentBestRecipe = recipe
        var currentBestRecipeComplexity = currentBestRecipe.complexity
        var steps = 0
        var cacheHits = 0
        var counterExample = value
        var seen = [ChoiceTree: Bool]()
        var previousValid: (recipe: ChoiceTree, value: Output) = (recipe, value)
        var previousInvalidRecipe: ChoiceTree? // Used to clamp the range of the locked recipe
        var isLockedIn = false
        
        while true {
            var shrinkWasImproved = false
            // At this point we should reset the available shrinkers for the recipe
            let iterator = HierarchicalTieredShrinker(currentBestRecipe)
            while let candidateRecipe = iterator.next() {
                guard let candidateValue = try Interpreters.replay(generator, using: candidateRecipe) else {
                    // This means the recipe is malformed, as any shrinks should return a valid recipe
                    throw ShrinkError.couldNotReplayRecipe(original: recipe, failing: candidateRecipe)
                }
                steps += 1
                guard seen[candidateRecipe] == nil else {
                    cacheHits += 1
                    print("Cache hit for \(candidateRecipe)")
                    if cacheHits > 1000 {
                        print("Cache hit limit reached; breaking")
                        break
                    }
                    continue
                }
                if seen.isEmpty {
                    seen[recipe] = false
                }
                guard steps < (isLockedIn ? 500 : 1000) else {
                    break
                }
                let candidateComplexity = candidateRecipe.complexity

                let isValidShrink = property(candidateValue) == false
                seen[candidateRecipe] = isValidShrink
                
                if isValidShrink {
                    // Successful shrink!
                    // FIXME: If you end up in a local minimum of zero, the complexity check will never be successful
                    shrinkWasImproved = currentBestRecipeComplexity == 0 || candidateComplexity < currentBestRecipeComplexity
                    var validCandidate = candidateRecipe
                    if isLockedIn, let previousInvalidRecipe {
                        validCandidate = ChoiceTree.diffAndLockChanges(in: candidateRecipe, from: previousInvalidRecipe)
                    }
                    // Break inner loop to repeat the shrink process
                    if shrinkWasImproved {
                        let direction: ShrinkingDirection = validCandidate.contains { $0.metadata.strategies.contains(where: { $0.direction == .towardsLowerBound }) }
                            ? .towardsLowerBound
                            : .towardsHigherBound
                        previousValid = (validCandidate, candidateValue)
                        // How do we continually adjust the boundary to make the pool of valid choices smaller?
                        // This is possible for single values, but very hard for groups of possibly interrelated ones
                        print("Improved \(direction) shrink:\n\(validCandidate)")
                        currentBestRecipe = validCandidate.resetStrategies(direction: direction)
                        currentBestRecipeComplexity = candidateComplexity
                        counterExample = candidateValue
                        break
                    } else {
                        print("Shrink was not improved:\n\(validCandidate)")
                        print("Candidate complexity: \(candidateComplexity)")
                        print("Best complexity: \(currentBestRecipeComplexity)")
                        
                    }
                } else {
                    previousInvalidRecipe = candidateRecipe
                    // We now have a passing result, return the previous valid shrink?
                    // This when the property takes longer to get to. In cases where the fundamental shrink removes it we'd still like more detail about what's going wrong...
                    // This is a dead end I think.
                    
                    // The real trick here is that once this starts repeating we're in a local minimum so we should try to discard the next one.
                    let locked = ChoiceTree.diffAndLockChanges(in: previousValid.recipe, from: candidateRecipe)
                    print("Property was satisfied. Locking in the previous shrink:\n\(locked)")
                    counterExample = previousValid.value
                    shrinkWasImproved = locked != currentBestRecipe
                    currentBestRecipe = locked
                    isLockedIn = true
                    if shrinkWasImproved == false {
                        continue
                    }
                    break
                }
//                else {
//                    // Whaat
//                    previousInvalidRecipe = candidateRecipe
//                    // It's possible
//                    print("Invalid shrink, there has been no valid shrinks yet")
//                }
            }
            
            if shrinkWasImproved {
                // Start from the top again with the shrunken recipe
                continue
            }

            // If we are here, no improvement could be found
            print("Returning counterexample after \(steps) steps, \(cacheHits) cache hits and \(currentBestRecipe.complexity) complexity. There were \(seen.count) unique attempts and \(seen.values.count(where: { $0 })) valid shrinks. Recipe:\n \(currentBestRecipe)")
            _ = currentBestRecipe.map { component in
                if component.isImportant {
                    print("Of particular interest is the value: \(component.elementDescription)")
                }
                return component
            }
            break
        }
        
        return counterExample
    }
    
    enum ShrinkError: LocalizedError {
        case couldNotReflect
        case counterExampleMustFail
        case couldNotReplayRecipe(original: ChoiceTree, failing: ChoiceTree)
    }
}
