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
        return self.shrinkImpl(value, using: generator, recipe: recipe, where: property)
    }
    
    private static func shrinkImpl<Input, Output>(
        _ value: Output,
        using generator: ReflectiveGenerator<Input, Output>,
        recipe: ChoiceTree,
        where property: (Output) -> Bool,
        runSecondStage: Bool = false
    ) -> Output {
        
        var recipe = recipe
        var recipeComplexity = recipe.complexity
        var steps = 0
        var counterExample = value
        
        while true {
            var shrinkWasImproved = false
            // At this point we should reset the available shrinkers for the recipe
            let iterator = HierarchicalTieredShrinker(recipe)
            
            while let candidate = iterator.next() {
                let candidateValue = Interpreters.replay(generator, using: candidate)
                steps += 1
                
                if let candidateValue {
                    if candidate.complexity < recipeComplexity, property(candidateValue) == false {
                        // Successful shrink!
                        recipe = candidate.resetStrategies()
                        recipeComplexity = recipe.complexity
                        counterExample = candidateValue
                        shrinkWasImproved = true
                        // Break inner loop to repeat the shrink process
                        break
                    }
                }
            }
            
            if shrinkWasImproved {
                // Start from the top again with the shrunken recipe
                continue
            }
            
            if runSecondStage {
                counterExample = shrinkImpl(counterExample, using: generator, recipe: recipe.resetStrategies(), where: property, runSecondStage: false)
            } else {
                // If we are here, no improvement could be found
                print("Returning counterexample after \(steps) steps and \(recipe.complexity) complexity. recipe:\n \(recipe)")
            }
            

            break
        }
        
        return counterExample
    }
    
    enum ShrinkError: LocalizedError {
        case couldNotReflect
        case counterExampleMustFail
    }
}
