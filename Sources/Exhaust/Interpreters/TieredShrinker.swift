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
        var wheelsSpun = 0
        while true {
            var shrinkWasImproved = false
            // At this point we should reset the available shrinkers for the recipe
            let iterator = HierarchicalTieredShrinker(currentBestRecipe)
            
            while let candidateRecipe = iterator.next() {
                guard let candidateValue = Interpreters.replay(generator, using: candidateRecipe) else {
                    // This means the recipe is malformed, as any shrinks should return a valid recipe
                    throw ShrinkError.couldNotReplayRecipe(original: recipe, failing: candidateRecipe)
                }
                steps += 1
                guard wheelsSpun < 10 else {
                    break
                }
                let candidateComplexity = candidateRecipe.complexity

                let isValidShrink = property(candidateValue) == false
                
                if isValidShrink {
                    // Successful shrink!
                    shrinkWasImproved = candidateComplexity < recipeComplexity
                    if shrinkWasImproved {
                        currentBestRecipe = candidateRecipe
                        recipeComplexity = candidateComplexity
                        counterExample = candidateValue
                        wheelsSpun = 0
                        // Break inner loop to repeat the shrink process
                        break
                    }
                }
                wheelsSpun += isValidShrink == false ? 1 : 0
            }
            
            if shrinkWasImproved {
                // Start from the top again with the shrunken recipe
                continue
            }

            // If we are here, no improvement could be found
            print("Returning counterexample after \(steps) steps and \(currentBestRecipe.complexity) complexity. recipe:\n \(currentBestRecipe)")
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
