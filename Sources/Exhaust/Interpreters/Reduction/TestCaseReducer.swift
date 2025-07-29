//
//  TestCaseReducer.swift
//  Exhaust
//
//  Created by Chris Kolbu on 29/7/2025.
//

enum TestCaseReducer {
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
        guard let reflectedRecipe = try Interpreters.reflect(generator, with: value) else {
            throw Interpreters.ShrinkError.couldNotReflect
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
            throw Interpreters.ShrinkError.counterExampleMustFail
        }
        return try self.shrinkImpl(value, using: generator, recipe: recipe, where: property)
    }
    
    //    private func normalize<Output>(_ value: Output, others: [Bool: [Output]], recipe: ChoiceTree) -> ChoiceTree {
    //        return recipe
    //    }
    private static func shrinkImpl<Input, Output>(
        _ value: Output,
        using generator: ReflectiveGenerator<Input, Output>,
        recipe: ChoiceTree,
        where property: (Output) -> Bool
    ) throws -> Output {
        typealias ReferencePair = (recipe: ChoiceTree, value: Output)
        fatalError()
        
        // Ok. We have a normalised value based on the other instances of `Output` in the test run (if available)
        // We know `value` fails the `property` test
        
        // First let's create a shrinking iterator from the recipe
        // Let's stash and keep these updated to we can refer back to them
        var previousFailing: ReferencePair = (recipe, value)
        var previousPassing: ChoiceTree?
        
        // This is the outer loop. It creates a new shrinking iterator
        outer: while true {
            // Let's create a new iterator based on the previous best shrink, starting with the initial recipe
            // This is either the first go-round, or
            let iterator = ShrinkingIterator(previousFailing.recipe)
            
            // Now let's iterate over the shrinks it provides. If it generates values outside of the allowed range of each recipe ingredient, it will cycle to the next strategy until it returns nil
            inner: while let candidate = iterator.next() {
                // TODO: Caching goes here?
                
                // Let's make sure we can replay this
                guard let candidateValue = try Interpreters.replay(generator, using: candidate) else {
                    // If we can't, the recipe is invalid, so we should throw. Any shrunk candidate should be a valid simplification of the original
                    throw Interpreters.ShrinkError.couldNotReplayRecipe(original: recipe, failing: candidate)
                }
                
                // Now let's see if the property still fails for this shrunk value
                let isValidShrink = property(candidateValue) == false
                
                if isValidShrink {
                    // Ok, this is a valid reduction. In this case, the iterator is onto something, and we should let it keep rolling until it exhausts itself or produces an invalid shrink, or in other words, a passing value.
                    
                    // Here, we should refine the allowable range of the values based on their new values.
                    
                    // How do we recognise that we are:
                    // - In a local minimum, and should anneal or allow for exploration?
                    // - At the "best" reduction. Do we measure the allowable range for all values and quit once it's below a certain threshold?
                    // This is where this routine will exit by breaking the outer loop
                } else {
                    // Ok, we have a passing value, which means whatever value just changed must be important. The ShrinkingIterator will only modify one value per call to `next`, so we know that the one that changed must be important.
                    // Now do we roll back to the previous value, or do we reverse the direction and go up?
                    // Here we will need to mark this property as `.important` so that the shrinker will focus on it for the next go around.
                    // We will also need to, depending on the strategy `direction`, narrow the range based on the passing value.
                    let amalgated = previousFailing.recipe
                        .mapWhereDifferent(to: candidate) { failing, passing in
                            switch (failing, passing) {
                            case let (.choice(failingChoice, _), .choice(passingChoice, passingMeta)):
                                let failingBound = failingChoice.convertible.bitPattern64
                                let passingBound = passingChoice.convertible.bitPattern64
                                let newRange: ClosedRange<UInt64>
                                switch passingMeta.strategies[0].direction {
                                case .towardsHigherBound:
                                    // Ok, so the passing value was increasing, which means its value -1 should represent the upper bound, and the failing value the lower bound
                                    newRange = ClosedRange(failingBound..<passingBound)
                                case .towardsLowerBound:
                                    // Ok, the passing value was decreasing which means its value +1 should represent the lower bound
                                    // Adding UInt64 values here can mess up the range when it's represented in the true type
                                    newRange = passingBound+1...failingBound
                                    break
                                }
                            case let (.sequence(failingLength, failingElements, _), .sequence(passingLength, passingElements, _)):
                                fatalError()
                            default:
                                return nil
                            }
                            return failing
                        }
                }
                return value
            }
            // Ok, the iterator is exhausted, which means it has shrunk each value in the recipe as much as it can within the range restrictions of each value. We should add back relevant strategies and go again
        }
        
        // Various data about number of shrinking steps, etc
        return previousFailing.value
    }
}

extension ChoiceValue {
    var bitPattern64: UInt64 {
        switch self {
        case let .unsigned(uint):
            uint
        case let .signed(_, uint):
            uint
        case let .floating(_, uint):
            uint
        case let .character(char):
            char.bitPattern64
        }
    }
    
    func refineRange(against other: ChoiceValue, direction: ShrinkingDirection) -> ClosedRange<UInt64>? {
        // If increasing, the range should be lhs..<rhs, if decreasing rhs...lhs
        switch direction {
        case .towardsHigherBound:
            let minVal = min(self.bitPattern64, other.bitPattern64)
            let maxVal = max(self.bitPattern64, other.bitPattern64)
            return minVal == maxVal ? minVal...maxVal : ClosedRange(minVal..<maxVal)
        case .towardsLowerBound:
            return min(self.bitPattern64, other.bitPattern64)...max(self.bitPattern64, other.bitPattern64)
        }
    }
}
