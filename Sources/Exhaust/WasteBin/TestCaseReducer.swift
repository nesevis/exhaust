////
////  TestCaseReducer.swift
////  Exhaust
////
////  Created by Chris Kolbu on 29/7/2025.
////
//
// #warning("Deprecated; will be removed")
// enum TestCaseReducer {
//    /// Attempts to shrink the `value` according to the `property`
//    /// - Parameters:
//    ///   - value: The value
//    ///   - generator: The generator used to generate the value
//    ///   - property: A function that should return `true`, representing a an invariant relationship of the `value`
//    /// - Returns: A minimal counterexample to aid in debugging
//    public static func shrink<Output>(
//        _ value: Output,
//        recipe: ChoiceTree? = nil,
//        using generator: ReflectiveGenerator<Output>,
//        where property: (Output) -> Bool
//    ) throws -> Output {
//        guard let reflectedRecipe = try recipe ?? (try Interpreters.reflect(generator, with: value)) else {
//            throw Interpreters.ShrinkError.couldNotReflect
//        }
//        // If this recipe had reflected a `pick` with multiple `.branch` choices and one was selected
//        // we need to deselect it to open the value up to shrinking. No we don't
//        let recipe = reflectedRecipe
//            .map { choice in
//                if case let .selected(selected) = choice {
//                    return selected
//                }
//                return choice
//            }
//        guard property(value) == false else {
//            throw Interpreters.ShrinkError.counterExampleMustFail
//        }
//        return try self.shrinkImpl(value, using: generator, recipe: recipe, where: property)
//    }
//
//    public static func normalize<Output>(
//        _ value: Output,
//        generator: ReflectiveGenerator<Output>,
//        limit: Int = 30,
//        property: (Output) -> Bool,
//        recipe: ChoiceTree
//    ) throws -> ChoiceTree {
//        let recipe = recipe
//            .map { choice in
//                if case let .selected(selected) = choice {
//                    return selected
//                }
//                return choice
//            }
//        // Let's generate a few samples
//        let iterator = ValueInterpreter(generator, maxRuns: UInt64(limit))
//        let candidates = Array(iterator.prefix(limit))
//        let (failing, passing) = candidates.partitioned(by: property)
//        // Is it better to start with the failing?
//        var normalized = recipe
//        print("Normalized using \(limit) generations")
//        print("Before:\n\(recipe)")
//        for fail in failing {
//            // The ranges of both `normalized` and `fail` are both — possibly — somewhere outside of the valid range, but we are here to reduce, and if 0...1 fails, then that's a pretty minimal counterexample
//            // FIXME: We need to respect the original range here. If the number falls within it, don't do anything?
//            // E.g if we're searching for Int16.min like in one of the tests but constrict the range to what we've seen, we won't be able to shrink properly.
//            // So can we even normalize on failures? By virtue of being generated, the value **must** be in the range of the generator's range.
//            // Switch to the least absolutely complex value that is still within the range? The lowest one?
//
//            guard let choices = try Interpreters.reflect(generator, with: fail) else {
//                print("–Failed to reflect on fail")
//                continue
//            }
//            normalized = choices.valueComplexity < normalized.valueComplexity ? choices : normalized
////            normalized.refineEndOfRange(using: choices, direction: .towardsLowerBound)
//        }
//        print("After \(failing.count) fails:\n\(normalized)")
//        for pass in passing {
//            guard let choices = try Interpreters.reflect(generator, with: pass) else {
//                print("–Failed to reflect on pass")
//                continue
//            }
//            // What happens is that if the boundary into passes exists on the lower end,
//            // it is a predicate like x < y. Conversely, x > y would trim the top end of the range
//            // This is an important signal. Trimming both ends means it's x < y && x > y
//            normalized = normalized.refineEndOfRange(using: choices, direction: .towardsLowerBound)
//        }
//        print("After \(passing.count) passes:\n\(normalized)")
//
//        // Final pass to set the hard coded values in `normalized` to the minimum it can be according to the range.
////        let minimized = normalized.map { choiceTree in
////            switch choiceTree {
////            // Only handle leaf values
////            case .choice(let choiceValue, let choiceMetadata):
////                switch choiceValue {
////                case .unsigned:
////                    return .choice(.unsigned(choiceMetadata.validRanges[0].lowerBound), choiceMetadata)
////                case .signed:
////                    let castRange = choiceMetadata.validRanges[0].cast(type: Int64.self)
////                    return .choice(ChoiceValue(castRange.lowerBound), choiceMetadata)
////                case .floating:
////                    let castRange = choiceMetadata.validRanges[0].cast(type: Double.self)
////                    return .choice(ChoiceValue(castRange.lowerBound), choiceMetadata)
////                case .character(let character):
////                    // TODO: Need to fix character minimisation first
////                    return choiceTree
////                }
////            case .sequence(_, let elements, let choiceMetadata):
////                let newLength = choiceMetadata.validRanges[0].lowerBound
////                return .sequence(length: newLength, elements: Array(elements.prefix(Int(newLength))), choiceMetadata)
////            default:
////                return choiceTree
////            }
////        }
//
//        print("After minimisation:\n\(normalized)")
//
//        return normalized
//    }
//
//    private static func shrinkImpl<Output>(
//        _ value: Output,
//        using generator: ReflectiveGenerator<Output>,
//        recipe: ChoiceTree,
//        where property: (Output) -> Bool
//    ) throws -> Output {
//        typealias ReferencePair = (recipe: ChoiceTree, value: Output)
//
//        // Ok. We have a normalised value based on the other instances of `Output` in the test run (if available)
//        // We know `value` fails the `property` test
//
//        // First let's create a shrinking iterator from the recipe
//        // Let's stash and keep these updated to we can refer back to them
//        var previousFailing: ReferencePair = (recipe, value)
//        var steps = 0
//        var cacheHits = 0
//        var seen = [ChoiceTree: Bool]()
//        var combinatoryComplexities = [recipe.combinatoryComplexity]
//
//        // This is the outer loop. It creates a new shrinking iterator
//        outer: while true {
//            // Let's create a new iterator based on the previous best shrink, starting with the initial recipe
//            // This is either the first go-round, or the previous iterator ran out
//            let direction = ShrinkingDirection.towardsLowerBound
//            if previousFailing.recipe != recipe {
//                previousFailing.recipe = previousFailing.recipe.resetStrategies(direction: direction)
//            }
//            // We've run out of shrinking strategies for at least one of the choice values
//            // How do we find a better proxy for more complex objects?
//            // Strings have _tons_ of choices.
//            if previousFailing.recipe.contains(\.rangeIsExhausted) {
//                break outer
//            }
//            let iterator = ShrinkingIterator(previousFailing.recipe)
//            print("New iterator:\n \(previousFailing.recipe)")
//
//            // Now let's iterate over the shrinks it provides. If it generates values outside of the allowed range of each recipe ingredient, it will cycle to the next strategy until it returns nil
//            inner: while let candidate = iterator.next() {
//                guard seen[candidate] == nil else {
//                    cacheHits += 1
//                    print("Cache hit")
//                    continue
//                }
//
//                // Let's make sure we can replay this
//                guard let candidateValue = try Interpreters.replay(generator, using: candidate) else {
//                    // If we can't, the recipe is invalid, so we should throw. Any shrunk candidate should be a valid simplification of the original
//                    throw Interpreters.ShrinkError.couldNotReplayRecipe(original: recipe, failing: candidate)
//                }
//                steps += 1
//
//                guard steps < 500, cacheHits < 100 else {
//                    break outer
//                }
//
//                // Now let's see if the property still fails for this shrunk value
//                let isValidShrink = property(candidateValue) == false
//                // And let's add it to the cache
//                seen[candidate] = isValidShrink
//
//                if isValidShrink {
//                    let complexity = candidate.combinatoryComplexity
//                    // This didn't work
////                    if let previous = combinatoryComplexities.last, previous == complexity {
////                        continue
////                    }
//                    // Ok, this is a valid reduction. In this case, the iterator is onto something, and we should let it keep rolling until it exhausts itself or produces an invalid shrink, or in other words, a passing value.
//
//                    // Here, we should refine the allowable range of the values based on their new values.
//
//                    // Shortlex is fast and gives an indication of structural simplicity,
//                    // but the ultimate gauge of how "narrowed" a shrink has become is the aggregate range size.
//                    if candidate.shortlexLength <= previousFailing.recipe.shortlexLength {
//                        // Ok, this reduction is structurally simpler than the previous shrink
//                        // But that does not mean we should constrict anything but the top or bottom range depending on what direction we went in
//                        let refined = candidate
//                            .refineEndOfRange(using: previousFailing.recipe, direction: direction)
//
//                        previousFailing = (refined, candidateValue)
//                    } else {
//                        print("Shrink isn't shortlex better:\n\(candidate.shortlexLength) vs \(previousFailing.recipe.shortlexLength)")
//                        // How can we check that it isn't incrementally better?
//                    }
//
//                    // How do we recognise that we are:
//                    // - In a local minimum, and should anneal or allow for exploration?
//                    // - At the "best" reduction. Do we measure the allowable range for all values and quit once it's below a certain threshold?
//
//                    // This is where this routine will exit by breaking the outer loop
//                } else {
//                    // Ok, we have a passing value, which means whatever value just changed must be important. The ShrinkingIterator will only modify one value per call to `next`, so we know that the one that changed must be important.
//                    // Now do we roll back to the previous value, or do we reverse the direction and go up?
//                    // Here we will need to mark this property as `.important` so that the shrinker will focus on it for the next go around.
//                    // We will also need to, depending on the strategy `direction`, narrow the range based on the passing value.
//                    // FIXME: Now that we have refined the range, how can we validate that the next results from the current iterator fall in that range?
//                    let amalgated = previousFailing.recipe
//                        .refineEntireRange(using: candidate, direction: direction, markChangesAsImportant: true)
//                    previousFailing = (amalgated, candidateValue)
//                    print("Passed. Amalgated: \n\(previousFailing)")
//                    break inner
//                    // It somehow ends up being double wrapped in .important
////                    if amalgated == previousFailing.recipe {
////                        print("The amalgated result is the same; iterator must have given OOR value")
////                    }
//                    // If we decide to switch directions, we'll need to reset strategies and their directions. By what metric do we decide to switch directions?
//                }
//            }
//            print("Inner loop finished: \(steps) steps, \(cacheHits) cache hits")
//            guard steps < 500, cacheHits < 100 else {
//                break outer
//            }
//            // Ok, the iterator is exhausted, which means it has shrunk each value in the recipe as much as it can within the range restrictions of each value. We should add back relevant strategies and go again
//        }
//        guard let finalOutput = try Interpreters.replay(generator, using: previousFailing.recipe) else {
//            fatalError("Invalid output!")
//        }
//        print("Outer loop finished")
//        print("Returning test case reduction after \(steps) steps and \(cacheHits) cache hits:")
//        print("Original:\n\(recipe)")
//        print("Reduced:\n\(previousFailing.recipe)")
//
//        // Various data about number of shrinking steps, etc
//        return finalOutput
//    }
// }
//
