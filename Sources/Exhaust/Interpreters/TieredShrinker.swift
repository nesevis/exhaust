//
//  TieredShrinker.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

import Foundation

extension Interpreters {
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
        guard let recipe = Interpreters.reflect(generator, with: value) else {
            throw ShrinkError.couldNotReflect
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
        var recipeComplexity = currentBestRecipe.complexity
        var steps = 0
        var counterExample = value
        var seen = [ChoiceTree: Bool]()
        var previousValid: (recipe: ChoiceTree, value: Output) = (recipe, value)
        var isLockedIn = false
        while true {
            var shrinkWasImproved = false
            // At this point we should reset the available shrinkers for the recipe
            let iterator = HierarchicalTieredShrinker(currentBestRecipe)
            while let candidateRecipe = iterator.next() {
                guard let candidateValue = Interpreters.replay(generator, using: candidateRecipe) else {
                    // This means the recipe is malformed, as any shrinks should return a valid recipe
                    throw ShrinkError.couldNotReplayRecipe(original: recipe, failing: candidateRecipe)
                }
                guard seen[candidateRecipe] == nil else {
                    print("Recipe seen already:\n\(candidateRecipe)")
                    continue
                }
                steps += 1
                guard steps < (isLockedIn ? 100 : 1000) else {
                    break
                }
                let candidateComplexity = candidateRecipe.complexity

                let isValidShrink = property(candidateValue) == false
                seen[candidateRecipe] = isValidShrink
                
                if isValidShrink {
                    previousValid = (candidateRecipe, candidateValue)
                    // Successful shrink!
                    shrinkWasImproved = candidateComplexity < recipeComplexity
                    // Break inner loop to repeat the shrink process
                    if shrinkWasImproved {
                        print("Improved shrink:\n\(candidateRecipe)")
                        currentBestRecipe = candidateRecipe.resetStrategies()
                        recipeComplexity = candidateComplexity
                        counterExample = candidateValue
                        break
                    }
                } else if previousValid.recipe != recipe {
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
                    // Create a lock here
//                    counterExample = previousValid.value
//                    currentBestRecipe = previousValid.recipe
//                    shrinkWasImproved = false
//                    break
                }
            }
            
            if shrinkWasImproved {
                // Start from the top again with the shrunken recipe
                continue
            }

            // If we are here, no improvement could be found
            print("Returning counterexample after \(steps) steps and \(currentBestRecipe.complexity) complexity. There were \(seen.count) unique attempts and \(seen.values.count(where: { $0 })) valid shrinks. Recipe:\n \(currentBestRecipe)")
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
