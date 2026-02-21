//
//  CGSAdaptationInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 19/12/2025.
//

#warning("Work in progress, but promising")
enum CGSAdaptationInterpreter {
    /// Context for execution with depth tracking
    final class SpeculativeContext {
        let baseSampleCount: UInt64
        let maxSize: UInt64
        var depth: UInt64 = 0
        var rng: Xoshiro256

        init(baseSampleCount: UInt64, maxSize: UInt64, rng: Xoshiro256) {
            self.baseSampleCount = baseSampleCount
            self.maxSize = maxSize
            self.rng = rng
        }

        /// Calculate sample count for current depth using exponential decay
        var currentSampleCount: UInt64 {
            guard depth > 0 else { return baseSampleCount }
            // Reduce sampling exponentially with depth to avoid blowup
            return max(0, baseSampleCount / (2 << min(depth - 1, 10)))
        }
    }

    static func adapt<Output>(
        original: ReflectiveGenerator<Output>,
        samples: UInt64 = 100,
        maxSize: UInt64 = 100,
        seed: UInt64? = nil,
        _ validityPredicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        let context = SpeculativeContext(
            baseSampleCount: samples,
            maxSize: maxSize,
            rng: seed.map(Xoshiro256.init(seed:)) ?? .init(),
        )
        return try adaptRecursive(
            gen: original,
            input: (),
            context: context,
            insideSubdividedChooseBits: false,
            validityPredicate: validityPredicate,
        )
    }

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
            case let .pick(choices):
                // Increment depth for nested pick operations
                context.depth += 1
                defer { context.depth -= 1 }

                let results = try choices
                    .map { tuple in
                        let valueInterpreter = try ValueInterpreter(
                            tuple.generator.bind(continuation),
                            seed: context.rng.next(),
                            maxRuns: context.currentSampleCount,
                        )
                        return ReflectiveOperation.PickTuple(
                            id: tuple.id,
                            weight: UInt64(Array(valueInterpreter).count(where: validityPredicate)),
                            generator: tuple.generator.erase(),
                        )
                    }
                    .filter { $0.weight > 0 } // Remove pruned branches

                if results.isEmpty {
                    return gen
                }

                return ReflectiveGenerator.impure(
                    operation: ReflectiveOperation.pick(choices: ContiguousArray(results)),
                    continuation: continuation,
                )

            case let .chooseBits(lower, upper, _, isRangeExplicit):
                // Only subdivide chooseBits if we're not already inside a subdivided range
                if insideSubdividedChooseBits == false {
                    context.depth += 1
                    defer { context.depth -= 1 }
                    // Replace getSize with a pick over subranges
                    // TODO: respect `resize` override
                    // TODO: Use tags here so the range is appropriate for all number types
                    // TODO: Range heuristic!
                    let ranges = (lower ... upper).split(into: max(4, 20 - Int(context.depth)))
                    let results = try ranges
                        .map {
                            isRangeExplicit
                                ? Gen.choose(in: $0)
                                : Gen.chooseDerived(in: $0)
                        }
                        .map { gen in
                            let recursedGen = try adaptRecursive(
                                gen: gen.bind(continuation),
                                input: input,
                                context: context,
                                insideSubdividedChooseBits: true,
                                validityPredicate: validityPredicate,
                            )
                            return ReflectiveOperation.PickTuple(
                                id: context.rng.next(),
                                weight: UInt64(1),
                                generator: recursedGen.erase(),
                            )
                        }

                    // Convert chooseBits into a pick of subranges for adaptation
                    let pick = ReflectiveGenerator.impure(
                        operation: ReflectiveOperation.pick(choices: ContiguousArray(results)),
                        continuation: { .pure($0 as! Output) },
                    )

                    // Recurse and perform evaluation in pick case
                    return try adaptRecursive(
                        gen: pick,
                        input: input,
                        context: context,
                        insideSubdividedChooseBits: false,
                        validityPredicate: validityPredicate,
                    )

                } else {
                    // Already inside subdivided chooseBits, pass through without further subdivision
                    return gen
                }

            case let .sequence(lengthGen, elementGen):
                break
//                // Adapt sequence length generation if the length generator is chooseBits
//                return try adaptSequenceLengthGeneration(
//                    lengthGen: lengthGen,
//                    elementGen: elementGen,
//                    continuation: continuation,
//                    input: input,
//                    context: context,
//                    insideSubdividedChooseBits: insideSubdividedChooseBits,
//                    validityPredicate: validityPredicate
//                )

            // TODO: This is hard. Can we just recurse through?
            case let .zip(gens):
                context.depth += 1
                defer { context.depth -= 1 }
                // Recurse over the generators.
                // The continuation expects to be fed the zip operation, so to get any meaningful signal here
                // we need to modify _one_ generator per zip, at a time, and create a pick of zips?
                // Order matters here, so we should do an in-order mutation?

                // Create a dictionary of ValueInterpreters per position in the zip tuple
//                var standardValueInterpreters = Dictionary(grouping: gens.enumerated(), by: \.offset)
//                    .mapValues {
//                        ValueInterpreter(
//                            $0[0].element,
//                            seed: context.rng.next(),
//                            maxRuns: context.currentSampleCount * UInt64(gens.count)
//                        )
//                    }
                // Create somewhere to store tested generators
                var recursedGens = [(offset: Int, gen: ReflectiveGenerator<Output>, success: Int)]()

                for (index, current) in gens.enumerated() {
                    // Run a full set of evaluations of all of these changing only the value at the index
                    var thisValueInterpreter = ValueInterpreter(
                        current,
                        seed: context.rng.next(),
                        maxRuns: context.currentSampleCount,
                    )
                    var gens = gens

                    var wins = 0

                    let recursedGen = try adaptRecursive(
                        gen: current,
                        input: (),
                        context: context,
                        insideSubdividedChooseBits: false,
                        validityPredicate: { output in
                            context.depth += 1
                            defer { context.depth -= 1 }
                            // Override output of generator for this check
                            gens[index] = current.map { _ in output }

                            let tupleInterpreter = ValueInterpreter(
                                .impure(operation: .zip(gens), continuation: continuation),
                                seed: context.rng.next(),
                                maxRuns: context.currentSampleCount,
                            )

                            wins += Array(tupleInterpreter).count(where: validityPredicate)
                            return true
                        },
                    )

                    recursedGens.append((index, gen, wins))
                }

                let results = try gens.map { gen in
                    let recursedGen = try adaptRecursive(
                        gen: gen.bind(continuation),
                        input: input,
                        context: context,
                        insideSubdividedChooseBits: false,
                        validityPredicate: validityPredicate,
                    )
                    return try adaptRecursive(
                        gen: recursedGen,
                        input: input,
                        context: context,
                        insideSubdividedChooseBits: false,
                        validityPredicate: validityPredicate,
                    ).erase()
                }
                // We have to pass the continuation in to each generator so recurse them.
                return .impure(operation: .zip(ContiguousArray(results))) { .pure($0 as! Output) }

            case .getSize:
                // TODO: can we recast this as a pick and do the value interpretation and counting through the pick handling?
                context.depth += 1
                defer { context.depth -= 1 }
                // Replace getSize with a pick over subranges
                // TODO: respect `resize` override
                let ranges = (0 ... context.maxSize).split(into: max(4, 10 - Int(context.depth)))
                let results = try ranges
                    .map { Gen.choose(in: $0) }
                    .map { gen in
                        let recursedGen = try adaptRecursive(
                            gen: gen.bind(continuation),
                            input: input,
                            context: context,
                            insideSubdividedChooseBits: false,
                            validityPredicate: validityPredicate,
                        )
                        return ReflectiveOperation.PickTuple(
                            id: context.rng.next(),
                            weight: UInt64(1),
                            generator: recursedGen.erase(),
                        )
                    }

                let pick = ReflectiveGenerator.impure(
                    operation: ReflectiveOperation.pick(choices: ContiguousArray(results)),
                    continuation: { .pure($0 as! Output) },
                )
                // Perform evaluation in pick case
                return try adaptRecursive(
                    gen: pick,
                    input: input,
                    context: context,
                    insideSubdividedChooseBits: false,
                    validityPredicate: validityPredicate,
                )

            case .just:
                // Do nothing, this is a fixed value
                break

            case let .resize(newSize, next):
                // Respect sizeOverride in the same way that ValueInterpreter does
                break

            case let .filter(subGen, fingerprint, predicate):
                // This should be returned, as it's orthogonal to CGS?
                break

            case let .classify(subGen, fingerprint, classifiers):
                // For classify, the inner generator is type-erased, so we can't adapt it
                // We'll have to reproduce the logic here as we recurse through and optimise?
                break

            case let .contramap(transform, next):
//                let transformed = try transform(input)
                return try adaptRecursive(
                    gen: next.bind { try continuation(transform($0)) },
                    input: input,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    validityPredicate: validityPredicate,
                )

            case let .prune(next):
                // Check if inputValue is nil. If it is, return gen, otherwise recurse
                return gen
            }

            return gen
        }
    }
}
