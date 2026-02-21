//
//  SpeculativeAdaptationInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/12/2024.
//

import Foundation

// A speculative execution adaptation interpreter that forks at pick points
// to evaluate which choice leads to the highest success rate.
#warning("Largely outdated")
enum SpeculativeAdaptationInterpreter {
    // MARK: - Speculative Execution Strategy

    /*
     SPECULATIVE EXECUTION APPROACH:

     Instead of running complete generators multiple times or testing isolated choices,
     we use speculative execution at pick points:

     1. When encountering a pick operation, pause execution
     2. For each choice, create a "complete generator" by composing:
        - The choice generator
        - The continuation (rest of computation)
     3. Run each complete generator multiple times to test success rates
     4. Select the choice with highest success rate
     5. Continue execution with that choice's actual result

     This is much more efficient because:
     - We only fork at decision points that matter
     - We evaluate actual impact of each choice on final validity
     - We preserve all randomness in the selected path
     */

    // MARK: - Main Adaptation Entry Point

    static func adapt<Output>(
        original: ReflectiveGenerator<Output>,
        samples: UInt64 = 100,
        maxSize: UInt64 = 100,
        _ validityPredicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        let context = SpeculativeContext(baseSampleCount: samples, maxSize: maxSize)
        return try adaptRecursive(
            gen: original,
            input: (),
            context: context,
            insideSubdividedChooseBits: false,
            validityPredicate: validityPredicate,
        )
    }

    // MARK: - Recursive Adaptation with Speculative Execution

    private static func adaptRecursive<Output>(
        gen: ReflectiveGenerator<Output>,
        input: some Any,
        context: SpeculativeContext,
        insideSubdividedChooseBits: Bool,
        validityPredicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        switch gen {
        case .pure:
            return gen

        case let .impure(op, continuation):
            switch op {
            case let .contramap(transform, next):
                // For contramap, we can't apply the original predicate to the inner generator
                // since it may have a different output type. Just recurse without adaptation.
                return gen

            case let .pick(choices):
                // Increment depth for nested pick operations
                context.depth += 1
                defer { context.depth -= 1 }

                // This is where the magic happens - speculative execution
                return try speculativelyAdaptPick(
                    choices: choices,
                    continuation: continuation,
                    input: input,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    validityPredicate: validityPredicate,
                )

            case let .prune(next):
                // For prune, the inner generator is type-erased, so we can't adapt it
                return .impure(operation: .prune(next: next), continuation: continuation)

            case let .chooseBits(min, max, tag, isRangeExplicit):
                // Only subdivide chooseBits if we're not already inside a subdivided range
                if insideSubdividedChooseBits == false {
                    // Convert chooseBits into a pick of subranges for adaptation
                    return try adaptChooseBitsToPickOfSubranges(
                        min: min,
                        max: max,
                        tag: tag,
                        isRangeExplicit: isRangeExplicit,
                        continuation: continuation,
                        input: input,
                        context: context,
                        validityPredicate: validityPredicate,
                    )
                } else {
                    // Already inside subdivided chooseBits, pass through without further subdivision
                    return gen
                }

            case let .sequence(lengthGen, elementGen):
                // Adapt sequence length generation if the length generator is chooseBits
                return try adaptSequenceLengthGeneration(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    continuation: continuation,
                    input: input,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    validityPredicate: validityPredicate,
                )

            case let .zip(gens):
                // Turn zip into a pick where each choice focuses adaptation on one component
                // This provides signal about which component is most critical for validity
                return try adaptZipToPickOfFocusedComponents(
                    gens: gens,
                    continuation: continuation,
                    input: input,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    validityPredicate: validityPredicate,
                )

            case .getSize:
                // getSize is difficult to adapt because the generator structure depends on
                // runtime size values. For now, pass through without adaptation.
                // TODO: Could potentially adapt for representative sizes and cache results
                let lengthGen = try adaptChooseBitsToPickOfSubranges(
                    min: 0,
                    max: context.maxSize,
                    tag: .uint64,
                    isRangeExplicit: false,
                    continuation: continuation,
                    input: input,
                    context: context,
                    validityPredicate: validityPredicate,
                )
                return try adaptRecursive(
                    gen: lengthGen,
                    input: (),
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    validityPredicate: validityPredicate,
                )

            case .just:
                return gen

            case let .resize(newSize, next):
                // For resize, the inner generator is type-erased, so we can't adapt it
                return gen

            case let .filter(subGen, fingerprint, predicate):
                // For filter, the inner generator is type-erased, so we can't adapt it
                return gen

            case let .classify(subGen, fingerprint, classifiers):
                // For classify, the inner generator is type-erased, so we can't adapt it
                return gen
            }
        }
    }

    // MARK: - ChooseBits Adaptation

    /// Convert chooseBits to a pick of subranges for adaptation
    private static func adaptChooseBitsToPickOfSubranges<Output>(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        input: some Any,
        context: SpeculativeContext,
        validityPredicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        // Split the range into N subranges (use 4 to reduce complexity)
        let numberOfSubranges = Swift.min(4, max - min + 1) // Don't create more ranges than values
        guard numberOfSubranges > 1 else {
            // If range is too small, fall back to original chooseBits
            return .impure(operation: .chooseBits(min: min, max: max, tag: tag, isRangeExplicit: isRangeExplicit), continuation: continuation)
        }

        let rangeSize = (max - min + 1) / numberOfSubranges
        let remainder = (max - min + 1) % numberOfSubranges

        // Create subrange generators
        var choices: ContiguousArray<ReflectiveOperation.PickTuple> = []
        var branchIDRNG = Xoshiro256()
        var currentStart = min

        for i in 0 ..< numberOfSubranges {
            // Calculate subrange bounds
            let extraValue = i < remainder ? 1 : 0 // Distribute remainder across first few ranges
            let currentEnd = currentStart + rangeSize + UInt64(extraValue) - 1
            let actualEnd = Swift.min(currentEnd, max) // Ensure we don't exceed max

            // Create generator for this subrange
            let subrangeGenerator = ReflectiveGenerator<Any>.impure(
                operation: .chooseBits(min: currentStart, max: actualEnd, tag: tag, isRangeExplicit: isRangeExplicit),
            ) { value in
                .pure(value)
            }

            choices.append(.init(
                id: branchIDRNG.next(),
                weight: 1, // Start with equal weights
                generator: subrangeGenerator,
            ))

            currentStart = actualEnd + 1
            if currentStart > max { break }
        }

        // Test the subranges to see if subdivision provides meaningful signal
        let subdivisionResult = try evaluateSubdivisionValue(
            choices: choices,
            continuation: continuation,
            input: input,
            context: context,
            validityPredicate: validityPredicate,
        )

        // If subdivision doesn't provide significant benefit, revert to original chooseBits
//        if subdivisionResult.isSignificant == false {
//            return .impure(operation: .chooseBits(min: min, max: max, tag: tag), continuation: continuation)
//        }

        // Subdivision is beneficial, use speculative adaptation on these subranges
        // Set the flag to true since we're now inside subdivided chooseBits
        return try speculativelyAdaptPick(
            choices: choices,
            continuation: continuation,
            input: input,
            context: context,
            insideSubdividedChooseBits: true,
            validityPredicate: validityPredicate,
        )
    }

    // MARK: - Sequence Length Adaptation

    /// Adapt sequence generation by potentially splitting the length generator
    private static func adaptSequenceLengthGeneration<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        input: some Any,
        context: SpeculativeContext,
        insideSubdividedChooseBits: Bool,
        validityPredicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        // Check if the length generator contains chooseBits that we can split
        var foundChooseBits: (min: UInt64, max: UInt64, isRangeExplicit: Bool)?

        // Look for chooseBits in the length generator structure
        if case let .impure(.chooseBits(min, max, _, isRangeExplicit), _) = lengthGen {
            foundChooseBits = (min, max, isRangeExplicit)
        } else if case let .impure(.getSize, lengthContinuation) = lengthGen {
            // Try to resolve the getSize and recurse
            let lengthGenContinuation = try adaptChooseBitsToPickOfSubranges(
                min: 0,
                max: context.maxSize,
                tag: .uint64,
                isRangeExplicit: false,
                continuation: lengthContinuation,
                input: input,
                context: context,
                validityPredicate: { _ in true },
            )
            return try adaptSequenceLengthGeneration(
                lengthGen: lengthGenContinuation,
                elementGen: elementGen,
                continuation: continuation,
                input: input,
                context: context,
                insideSubdividedChooseBits: insideSubdividedChooseBits,
                validityPredicate: validityPredicate,
            )
        } else if case let .pure(val) = lengthGen {
            // Fixed length, no adaptation needed for length
        }

        if let (min, max, isRangeExplicit) = foundChooseBits, !insideSubdividedChooseBits {
            // Try to adapt the length generation by splitting into length ranges
            return try adaptSequenceLengthRanges(
                lengthMin: min,
                lengthMax: max,
                isRangeExplicit: isRangeExplicit,
                elementGen: elementGen,
                continuation: continuation,
                input: input,
                context: context,
                validityPredicate: validityPredicate,
            )
        } else {
            // Can't adapt the length generator, but we can still adapt the element generator
            let adaptedElementGen = try adaptRecursive(
                gen: elementGen,
                input: input,
                context: context,
                insideSubdividedChooseBits: insideSubdividedChooseBits,
                validityPredicate: { _ in true }, // Element generator can't be tested with Output predicate
            )
            return .impure(operation: .sequence(length: lengthGen, gen: adaptedElementGen), continuation: continuation)
        }
    }

    /// Adapt sequence by splitting length ranges and testing which lengths lead to valid sequences
    private static func adaptSequenceLengthRanges<Output>(
        lengthMin: UInt64,
        lengthMax: UInt64,
        isRangeExplicit: Bool,
        elementGen: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        input: some Any,
        context: SpeculativeContext,
        validityPredicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        let lengthTag: TypeTag = .uint64
        // Calculate statistically sound number of subranges for sequence lengths
        let totalRange = lengthMax - lengthMin + 1

        // Trust the depth-based effort allocation - use most of the available samples
        let sampleBudget = UInt64(context.currentSampleCount * 3 / 4) // Use 75% of available samples

        // Rule 1: Minimum 5 samples per subrange (reduced from 10 since depth system handles this)
        let maxSubrangesFromSamples = max(2, sampleBudget / 5)

        // Rule 2: Don't subdivide ranges smaller than 3 (reduced for finer granularity)
        let maxSubrangesFromRange = max(2, totalRange / 3)

        // Rule 3: Cap at reasonable maximum (increased since depth system prevents blowup)
        let maxReasonableSubranges: UInt64 = 8

        let numberOfSubranges = Swift.min(
            maxSubrangesFromSamples,
            maxSubrangesFromRange,
            maxReasonableSubranges,
            totalRange, // Never more subranges than values
        )

        guard numberOfSubranges > 1 else {
            ExhaustLog.debug(
                category: .adaptation,
                event: "sequence_range_not_subdivided",
                metadata: [
                    "number_of_subranges": "\(numberOfSubranges)",
                ],
            )
            // Range too small, fall back to original sequence
            return .impure(operation: .sequence(length: .impure(operation: .chooseBits(min: lengthMin, max: lengthMax, tag: lengthTag, isRangeExplicit: isRangeExplicit)) { .pure($0 as! UInt64) }, gen: elementGen), continuation: continuation)
        }

        let rangeSize = (lengthMax - lengthMin + 1) / numberOfSubranges
        let remainder = (lengthMax - lengthMin + 1) % numberOfSubranges

        // Create length range generators
        var lengthRangeChoices: ContiguousArray<ReflectiveOperation.PickTuple> = []
        var branchIDRNG = Xoshiro256()
        var currentStart = lengthMin

        for i in 0 ..< numberOfSubranges {
            // Calculate length subrange bounds
            let extraValue = i < remainder ? 1 : 0
            let currentEnd = currentStart + rangeSize + UInt64(extraValue) - 1
            let actualEnd = Swift.min(currentEnd, lengthMax)

            // Create a generator that produces sequences with lengths in this range
            let lengthRangeGenerator = ReflectiveGenerator<Any>.impure(
                operation: .sequence(
                    length: .impure(operation: .chooseBits(min: currentStart, max: actualEnd, tag: lengthTag, isRangeExplicit: isRangeExplicit)) { .pure($0 as! UInt64) },
                    gen: elementGen,
                ),
            ) { value in
                .pure(value)
            }

            lengthRangeChoices.append(.init(
                id: branchIDRNG.next(),
                weight: 1, // Start with equal weights
                generator: lengthRangeGenerator,
            ))

            currentStart = actualEnd + 1
            if currentStart > lengthMax { break }
        }

        // Test the length ranges to see if subdivision provides meaningful signal
        let subdivisionResult = try evaluateSequenceLengthSubdivisionValue(
            choices: lengthRangeChoices,
            continuation: continuation,
            input: input,
            context: context,
            validityPredicate: validityPredicate,
        )

        // If subdivision doesn't provide significant benefit, revert to original sequence
//        if !subdivisionResult.isSignificant {
//            return .impure(operation: .sequence(length: .impure(operation: .chooseBits(min: lengthMin, max: lengthMax, tag: lengthTag)) { .pure($0 as! UInt64) }, gen: elementGen), continuation: continuation)
//        }

        // Subdivision is beneficial, use speculative adaptation on these length ranges
        return try speculativelyAdaptPick(
            choices: lengthRangeChoices,
            continuation: continuation,
            input: input,
            context: context,
            insideSubdividedChooseBits: true, // Prevent further subdivision
            validityPredicate: validityPredicate,
        )
    }

    /// Evaluate whether sequence length subdivision provides statistically significant benefit
    private static func evaluateSequenceLengthSubdivisionValue<Output>(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        input: some Any,
        context: SpeculativeContext,
        validityPredicate: @escaping (Output) -> Bool,
    ) throws -> SubdivisionEvaluation {
        var successRates: [Double] = []
        let sampleSize = max(5, context.currentSampleCount / 6) // Use smaller sample for sequence evaluation

        for choice in choices {
            // Test each length range to get its success rate
            let completeGenerator: ReflectiveGenerator<Output> = try choice.generator.bind { choiceResult in
                try continuation(choiceResult)
            }

            let (successCount, totalAttempts) = try evaluateSuccessRate(
                generator: completeGenerator,
                input: input,
                sampleCount: sampleSize,
                validityPredicate: validityPredicate,
            )

            let successRate = totalAttempts > 0 ? Double(successCount) / Double(totalAttempts) : 0.0
            successRates.append(successRate)
        }

        // Test for statistical significance (use slightly lower threshold for sequence lengths)
        let isSignificant = isSequenceLengthSubdivisionStatisticallySignificant(
            successRates: successRates,
            sampleSize: sampleSize,
        )

        return SubdivisionEvaluation(
            isSignificant: isSignificant,
            successRates: successRates,
            totalSamples: sampleSize * UInt64(choices.count),
        )
    }

    /// Test if sequence length subdivision provides meaningful signal
    private static func isSequenceLengthSubdivisionStatisticallySignificant(
        successRates: [Double],
        sampleSize: UInt64,
    ) -> Bool {
        guard successRates.count >= 2 else { return false }

        // Calculate mean and variance
        let mean = successRates.reduce(0, +) / Double(successRates.count)
        let variance = successRates.map { pow($0 - mean, 2) }.reduce(0, +) / Double(successRates.count)
        let standardDeviation = sqrt(variance)

        // For sequence lengths, use a slightly lower threshold since length often matters more
        let minRate = successRates.min() ?? 0
        let maxRate = successRates.max() ?? 0
        let range = maxRate - minRate

        // Adjust threshold based on sample size - smaller samples need smaller thresholds
        let baseThreshold = sampleSize >= 20 ? 0.15 : (sampleSize >= 10 ? 0.10 : 0.05)
        let significantThreshold = max(baseThreshold, 1.5 * standardDeviation)
        return range > significantThreshold && sampleSize >= 3
    }

    // MARK: - Statistical Significance Testing

    /// Result of evaluating whether subdivision provides meaningful signal
    struct SubdivisionEvaluation {
        let isSignificant: Bool
        let successRates: [Double]
        let totalSamples: UInt64
    }

    /// Evaluate whether subdivision provides statistically significant benefit
    private static func evaluateSubdivisionValue<Output>(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        input: some Any,
        context: SpeculativeContext,
        validityPredicate: @escaping (Output) -> Bool,
    ) throws -> SubdivisionEvaluation {
        var successRates: [Double] = []
        let sampleSize = max(10, context.currentSampleCount / 4) // Use smaller sample for quick evaluation

        for choice in choices {
            // Test each subrange to get its success rate
            let completeGenerator: ReflectiveGenerator<Output> = try choice.generator.bind { choiceResult in
                try continuation(choiceResult)
            }

            let (successCount, totalAttempts) = try evaluateSuccessRate(
                generator: completeGenerator,
                input: input,
                sampleCount: sampleSize,
                validityPredicate: validityPredicate,
            )

            let successRate = totalAttempts > 0 ? Double(successCount) / Double(totalAttempts) : 0.0
            successRates.append(successRate)
        }

        // Test for statistical significance using simple variance analysis
        let isSignificant = isSubdivisionStatisticallySignificant(
            successRates: successRates,
            sampleSize: sampleSize,
        )

        return SubdivisionEvaluation(
            isSignificant: isSignificant,
            successRates: successRates,
            totalSamples: sampleSize * UInt64(choices.count),
        )
    }

    /// Test if the variance in success rates is statistically significant
    private static func isSubdivisionStatisticallySignificant(
        successRates: [Double],
        sampleSize: UInt64,
    ) -> Bool {
        guard successRates.count >= 2 else { return false }

        // Calculate mean and variance
        let mean = successRates.reduce(0, +) / Double(successRates.count)
        let variance = successRates.map { pow($0 - mean, 2) }.reduce(0, +) / Double(successRates.count)
        let standardDeviation = sqrt(variance)

        // Simple significance test: if the range of success rates spans more than 2 standard deviations
        // and the difference between best and worst is > 20%, consider it significant
        let minRate = successRates.min() ?? 0
        let maxRate = successRates.max() ?? 0
        let range = maxRate - minRate

        let significantThreshold = max(0.2, 2 * standardDeviation) // At least 20% difference or 2 std devs
        return range > significantThreshold && sampleSize >= 5
    }

    // MARK: - Zip Adaptation

    /// Adapt zip by creating a pick where each choice focuses on adapting one component
    private static func adaptZipToPickOfFocusedComponents<Output>(
        gens: ContiguousArray<ReflectiveGenerator<Any>>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        input: some Any,
        context: SpeculativeContext,
        insideSubdividedChooseBits: Bool,
        validityPredicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        guard !gens.isEmpty else {
            // Empty zip, just return it as-is
            return .impure(operation: .zip(gens), continuation: continuation)
        }

        // Only adapt zips at shallow depths to prevent exponential blowup and recursion
        // Zip adaptation is expensive (creates N choices for N components), so limit it
        guard context.depth <= 1 else {
            // Too deep, return as-is without adaptation
            return .impure(operation: .zip(gens), continuation: continuation)
        }

        // Increment depth for zip adaptation
        context.depth += 1
        defer { context.depth -= 1 }

        // For single-component zips, just adapt that component directly
        if gens.count == 1 {
            let adaptedGen = try adaptRecursive(
                gen: gens[0],
                input: input,
                context: context,
                insideSubdividedChooseBits: insideSubdividedChooseBits,
                validityPredicate: { componentValue in
                    // Test if this component value leads to valid output
                    do {
                        let continuationResult = try continuation(componentValue)
                        var rng = Xoshiro256()
                        if let output = try ValueInterpreter<Output>.generate(continuationResult, maxRuns: 1, using: &rng) {
                            return validityPredicate(output)
                        }
                        return false
                    } catch {
                        return false
                    }
                },
            )
            return .impure(operation: .zip(ContiguousArray([adaptedGen])), continuation: continuation)
        }

        // Create a choice for each component, where that component gets focused adaptation
        var choices: ContiguousArray<ReflectiveOperation.PickTuple> = []
        var branchIDRNG = Xoshiro256()

        for focusIndex in 0 ..< gens.count {
            // Adapt the focused component with a sampling-based predicate
            let adaptedFocusedGen = try adaptRecursive(
                gen: gens[focusIndex],
                input: input,
                context: context,
                insideSubdividedChooseBits: insideSubdividedChooseBits,
                validityPredicate: { focusedValue in
                    // Sample other components to test if this focused value contributes to validity
                    // Use small sample count to keep it fast (depth system handles budget)
                    let sampleCount = 3
                    var rng = Xoshiro256()

                    for _ in 0 ..< sampleCount {
                        // Generate values for all components
                        var allValues: [Any] = []
                        var generationSucceeded = true

                        for (i, gen) in gens.enumerated() {
                            if i == focusIndex {
                                allValues.append(focusedValue)
                            } else {
                                if let value = try? ValueInterpreter<Any>.generate(gen, maxRuns: 1, using: &rng) {
                                    allValues.append(value)
                                } else {
                                    generationSucceeded = false
                                    break
                                }
                            }
                        }

                        if generationSucceeded {
                            // Test the tuple with continuation
                            do {
                                let continuationResult = try continuation(allValues as Any)
                                if let output = try ValueInterpreter<Output>.generate(continuationResult, maxRuns: 1, using: &rng) {
                                    if validityPredicate(output) {
                                        return true // Found at least one valid combination
                                    }
                                }
                            } catch {
                                continue
                            }
                        }
                    }

                    return false // No valid combination found in samples
                },
            )

            // Create a zip with the focused component adapted and others unadapted
            var gensForThisChoice = gens
            gensForThisChoice[focusIndex] = adaptedFocusedGen

            let zipGenerator = ReflectiveGenerator<Any>.impure(
                operation: .zip(gensForThisChoice),
            ) { value in
                .pure(value)
            }

            choices.append(.init(
                id: branchIDRNG.next(),
                weight: 1,
                generator: zipGenerator,
            ))
        }

        // Use speculative adaptation to find which component matters most
        return try speculativelyAdaptPick(
            choices: choices,
            continuation: continuation,
            input: input,
            context: context,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
            validityPredicate: validityPredicate,
        )
    }

    // MARK: - Speculative Pick Adaptation

    /// Fork execution at a pick point to evaluate which choice leads to highest success rate
    private static func speculativelyAdaptPick<Output>(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        input: some Any,
        context: SpeculativeContext,
        insideSubdividedChooseBits: Bool,
        validityPredicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        guard !choices.isEmpty else {
            throw SpeculativeAdaptationError.emptyChoices
        }

        // For each choice, create a complete generator and collect both success count AND adapted generator
        var choiceSuccessCounts: [(Int, UInt64)] = []
        var adaptedChoices: [ReflectiveOperation.PickTuple] = []

        for (choiceIndex, choice) in choices.enumerated() {
            var capturedAdaptedGenerator: ReflectiveGenerator<Any>? = nil

            // Create a complete generator that captures the adapted inner generator
            let completeGenerator: ReflectiveGenerator<Output> = try choice.generator.bind { choiceResult in
                let continuationResult = try continuation(choiceResult)
                // Recursively adapt the continuation result and capture any adapted generators
                return try adaptRecursive(
                    gen: continuationResult,
                    input: input,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    validityPredicate: validityPredicate,
                )
            }

            // The problem is I need to capture the adapted choice generator, not just the continuation result
            // Let me try a different approach: adapt the choice generator with a wrapper predicate
            let adaptedChoiceGenerator = try adaptRecursive(
                gen: choice.generator,
                input: input,
                context: context,
                insideSubdividedChooseBits: insideSubdividedChooseBits,
                validityPredicate: { anyValue in
                    // Test if this choice value, when run through the continuation, produces a valid output
                    do {
                        let continuationResult = try continuation(anyValue)
                        var rng = Xoshiro256()
                        if let output = try ValueInterpreter<Output>.generate(continuationResult, maxRuns: 1, using: &rng) {
                            return validityPredicate(output)
                        }
                        return false
                    } catch {
                        return false
                    }
                },
            )

            // Now create complete generator with adapted choice
            let completeGeneratorWithAdaptedChoice: ReflectiveGenerator<Output> = try adaptedChoiceGenerator.bind { choiceResult in
                try continuation(choiceResult)
            }

            // Run this complete generator multiple times to evaluate success count
            let (successCount, totalAttempts) = try evaluateSuccessRate(
                generator: completeGeneratorWithAdaptedChoice,
                input: input,
                sampleCount: context.currentSampleCount,
                validityPredicate: validityPredicate,
            )

            choiceSuccessCounts.append((choiceIndex, successCount))

            // Store the adapted choice generator
            adaptedChoices.append(.init(
                id: choice.id,
                weight: choice.weight,
                generator: adaptedChoiceGenerator,
            ))
        }

        // Create new choices array with weights reflecting actual success counts using the adapted generators
        let finalAdaptedChoices = choiceSuccessCounts.map { index, successCount in
            let choice = adaptedChoices[index]
            // Use the actual success count as the weight (0 means never select this choice)
            let newWeight = successCount
            return ReflectiveOperation.PickTuple(
                id: choice.id,
                weight: newWeight,
                generator: choice.generator,
            )
        }

        // Safety check: if all choices have weight 0, fall back to equal weights
        let totalWeight = finalAdaptedChoices.reduce(0) { $0 + $1.weight }
        let safeChoices: ContiguousArray<ReflectiveOperation.PickTuple> = if totalWeight == 0 {
            // All choices failed - fall back to equal weights to avoid total failure
            ContiguousArray(adaptedChoices.map { choice in
                ReflectiveOperation.PickTuple(
                    id: choice.id,
                    weight: 1,
                    generator: choice.generator,
                )
            })
        } else {
            ContiguousArray(finalAdaptedChoices)
        }

        // Return the pick with adapted weights
        return .impure(operation: .pick(choices: safeChoices), continuation: continuation)
    }

    // MARK: - Success Rate Evaluation

    /// Evaluate how often a complete generator produces valid outputs
    /// Returns (successCount, totalAttempts) instead of just success rate
    private static func evaluateSuccessRate<Output>(
        generator: ReflectiveGenerator<Output>,
        input _: some Any,
        sampleCount: UInt64,
        validityPredicate: @escaping (Output) -> Bool,
    ) throws -> (successes: UInt64, attempts: UInt64) {
        var successes: UInt64 = 0
        var attempts: UInt64 = 0

        for _ in 0 ..< sampleCount {
            attempts += 1
            do {
                // Generate a value using the complete generator
                var rng = Xoshiro256()
                if let output = try ValueInterpreter<Output>.generate(generator, maxRuns: 1, using: &rng) {
                    if validityPredicate(output) {
                        successes += 1
                    }
                }
            } catch {
                // If generation fails, count as invalid
                continue
            }
        }

        return (successes, attempts)
    }

    // MARK: - Context and Errors

    /// Context for speculative execution with depth tracking
    final class SpeculativeContext {
        let baseSampleCount: UInt64
        let maxSize: UInt64
        var depth: UInt64 = 0

        init(baseSampleCount: UInt64, maxSize: UInt64) {
            self.baseSampleCount = baseSampleCount
            self.maxSize = maxSize
        }

        /// Calculate sample count for current depth using exponential decay
        var currentSampleCount: UInt64 {
            guard depth > 0 else { return baseSampleCount }
            // Reduce sampling exponentially with depth to avoid blowup
            return max(1, baseSampleCount / (2 << min(depth - 1, 10)))
        }
    }

    enum SpeculativeAdaptationError: LocalizedError {
        case emptyChoices
        case noValidChoice
        case evaluationFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyChoices:
                "Cannot adapt empty choices array"
            case .noValidChoice:
                "No valid choice found during speculative evaluation"
            case let .evaluationFailed(reason):
                "Speculative evaluation failed: \(reason)"
            }
        }
    }
}
