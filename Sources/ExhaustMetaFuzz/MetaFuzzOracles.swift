//
//  MetaFuzzOracles.swift
//  ExhaustMetaFuzz
//
//  The oracle roster for self-fuzzing runs. Each oracle is a claim about the ExhaustCore pipeline that must hold for every recipe; each violation is a distinct error type because the fault inventory's FailureSymptom keys on the dynamic error type name, giving every oracle its own reduction-gate cap.
//

import ExhaustCore

// MARK: - Violations

/// `.exact` materialization of a tree's own flattening failed to reproduce the value or the sequence.
public struct ExactRoundTripViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Guided materialization of a mutated sequence reported an out-of-range convergence.
public struct GuidedTotalityViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Guided materialization of the same sequence, seed, and fallback produced different outcomes.
public struct GuidedDeterminismViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// A flattened sequence's structural markers do not balance.
public struct FlattenBalanceViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Flat-emission materialization diverged from tree-building materialization of identical inputs: a different outcome, a sequence that differs from the fresh tree's flattening, or a different convergence.
public struct FlatEmissionParityViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// The same recipe and seed produced different value streams on two runs.
public struct DeterminismViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Exact value-only and value-and-tree interpreters disagreed on a value, exhaustion point, or recoverable generation failure.
public struct ExactInterpreterParityViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Exact value-only and value-and-tree interpreters left different PRNG states after the same successful execution.
public struct RandomProgressionParityViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Replaying a tree produced by exact generation failed to reproduce that generation's value.
public struct GeneratedWitnessReplayViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// A reduced value passed the property its original failed.
public struct ReductionPreservationViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// A reduced sequence shortlex-exceeds the original.
public struct ReductionShortlexViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// The reducer's reported sequence does not materialize to its reported value.
public struct ReductionClosedLoopViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Re-reducing an already-reduced tree enlarged the sequence.
public struct ReductionMonotonicityViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Two materializations of the same sequence produced different cluster keys.
public struct ClusterKeyStabilityViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// A choice sequence did not survive the persistence codec round trip.
public struct CodecRoundTripViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// Mapping through the identity transform changed the value stream.
public struct FunctorIdentityViolation: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

// MARK: - Check

public extension MetaFuzz {
    /// Values evaluated per case in the main oracle walk. Small deliberately: the whole walk is one fuzz attempt, and throughput is the mode's currency.
    package static let valuesPerCase: UInt64 = 5

    /// Runs the oracle roster against one fuzz case, throwing the first violation.
    ///
    /// A throw from generation itself is treated as a vacuous pass: legitimate rejection paths (filter exhaustion, recoverable reflection failures) throw by design, and clustering them would flood the inventory with false positives. Engine defects that manifest as traps are caught by the run machinery, not here.
    static func check(_ fuzzCase: MetaFuzzCase) throws {
        try checkExactInterpreterParity(fuzzCase)

        let gen = buildOracleGenerator(from: fuzzCase.recipe)
        let property = failingProperty(for: fuzzCase.recipe.outputType)
        var prng = Xoshiro256(seed: fuzzCase.perturbationSeed)

        try checkDeterminism(fuzzCase)
        try checkFunctorIdentity(fuzzCase)

        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: fuzzCase.valueSeed, maxRuns: valuesPerCase)
        var reductionChecked = false
        while true {
            let element: (value: Any, tree: ChoiceTree)?
            do {
                element = try iterator.next()
            } catch {
                return
            }
            guard let (value, tree) = element else {
                return
            }

            let sequence = ChoiceSequence.flatten(tree)
            try checkGeneratedWitnessReplay(gen, tree: tree, value: value, fuzzCase)
            try checkMarkerBalance(sequence, fuzzCase)
            try checkExactRoundTrip(gen, sequence: sequence, tree: tree, value: value, fuzzCase)
            try checkCodecRoundTrip(sequence, fuzzCase)
            try checkFlatEmissionParity(gen, prefix: sequence, mode: .exact, fallbackTree: tree, fuzzCase)

            let intensity = pickIntensity(&prng)
            let mutated = FuzzMutator.mutate(sequence, intensity: intensity, prng: &prng)
            try checkCodecRoundTrip(mutated, fuzzCase)
            try checkGuidedTotality(gen, mutated: mutated, fallbackTree: tree, fuzzCase, prng: &prng)
            try checkFlatEmissionParity(
                gen,
                prefix: mutated,
                mode: .guided(seed: prng.next(), fallbackTree: tree),
                fallbackTree: tree,
                fuzzCase
            )

            if reductionChecked == false, property(value) == false {
                try checkReduction(gen, tree: tree, value: value, property: property, fuzzCase)
                reductionChecked = true
            }
        }
    }
}

// MARK: - Individual Oracles

extension MetaFuzz {
    /// Encoders covered by the strict shortlex reduction oracle.
    ///
    /// IMPORTANT: `.numericReorder` is intentionally removed from this set. It is a final
    /// presentation pass that replaces shortlex order with natural numeric order, so including it
    /// would make the shortlex oracle report valid presentation reordering as a reduction defect.
    private static let shortlexReductionEncoders = Set(EncoderName.allCases).subtracting([
        .numericReorder,
    ])

    /// Exact interpreter parity: the value-only and value-and-tree interpreters must produce the same observable stream for one recipe, seed, and run budget.
    private static func checkExactInterpreterParity(_ fuzzCase: MetaFuzzCase) throws {
        var valueInterpreter = ValueInterpreter(
            buildOracleGenerator(from: fuzzCase.recipe),
            seed: fuzzCase.valueSeed,
            maxRuns: valuesPerCase
        )
        var treeInterpreter = ValueAndChoiceTreeInterpreter(
            buildOracleGenerator(from: fuzzCase.recipe),
            seed: fuzzCase.valueSeed,
            maxRuns: valuesPerCase
        )

        for iteration in 0 ..< valuesPerCase {
            let valueOutcome = nextValueOutcome(&valueInterpreter)
            let treeOutcome = nextTreeValueOutcome(&treeInterpreter)

            switch (valueOutcome, treeOutcome) {
                case let (.value(value), .value(treeValue)):
                    guard anyEquals(value, treeValue) else {
                        throw ExactInterpreterParityViolation(
                            "value-only produced \(value), value-and-tree produced \(treeValue), recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed), iteration \(iteration)"
                        )
                    }
                    let valueSnapshot = valueInterpreter.randomNumberGeneratorSnapshot
                    let treeSnapshot = treeInterpreter.randomNumberGeneratorSnapshot
                    guard randomNumberGeneratorSnapshotsEqual(
                        valueSnapshot,
                        treeSnapshot
                    ) else {
                        throw RandomProgressionParityViolation(
                            "interpreter PRNG states differed after recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed), iteration \(iteration): value-only \(valueSnapshot), value-and-tree \(treeSnapshot)"
                        )
                    }
                case (.exhausted, .exhausted):
                    return
                case let (.failure(valueFailure), .failure(treeFailure)):
                    guard valueFailure == treeFailure else {
                        throw ExactInterpreterParityViolation(
                            "interpreter failures differed: value-only \(valueFailure), value-and-tree \(treeFailure), recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed), iteration \(iteration)"
                        )
                    }
                    return
                default:
                    throw ExactInterpreterParityViolation(
                        "interpreter outcomes differed: value-only \(valueOutcome), value-and-tree \(treeOutcome), recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed), iteration \(iteration)"
                    )
            }
        }
    }

    /// Generated-witness replay: a tree emitted beside a value must replay to that value without requiring reflection.
    private static func checkGeneratedWitnessReplay(
        _ generator: AnyGenerator,
        tree: ChoiceTree,
        value: Any,
        _ fuzzCase: MetaFuzzCase
    ) throws {
        do {
            guard let replayed = try Interpreters.replay(generator, using: tree) else {
                throw GeneratedWitnessReplayViolation(
                    "replay returned nil for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)"
                )
            }
            guard anyEquals(replayed, value) else {
                throw GeneratedWitnessReplayViolation(
                    "replay produced \(replayed), not \(value), for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)"
                )
            }
        } catch let violation as GeneratedWitnessReplayViolation {
            throw violation
        } catch {
            throw GeneratedWitnessReplayViolation(
                "replay threw \(error) for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)"
            )
        }
    }

    /// Determinism: the same recipe and seed must produce the same value stream twice.
    private static func checkDeterminism(_ fuzzCase: MetaFuzzCase) throws {
        let held = checkPairedValues(
            buildOracleGenerator(from: fuzzCase.recipe),
            buildOracleGenerator(from: fuzzCase.recipe),
            seed: fuzzCase.valueSeed,
            maxRuns: valuesPerCase,
            check: anyEquals
        )
        guard held else {
            throw DeterminismViolation("same seed produced different values for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
        }
    }

    /// Functor identity: mapping through the identity transform must not change the value stream.
    private static func checkFunctorIdentity(_ fuzzCase: MetaFuzzCase) throws {
        let mappedRecipe = GenRecipe.combinator(.mapped(fuzzCase.recipe, .identity))
        let held = checkPairedValues(
            buildOracleGenerator(from: fuzzCase.recipe),
            buildOracleGenerator(from: mappedRecipe),
            seed: fuzzCase.valueSeed,
            maxRuns: valuesPerCase,
            check: anyEquals
        )
        guard held else {
            throw FunctorIdentityViolation("map(identity) changed the value stream for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
        }
    }

    /// Flatten faithfulness: opening and closing structural markers must balance. A partial stand-in for full field-by-field verification, which needs a second flattening authority; the exact-round-trip sequence equality covers field fidelity.
    private static func checkMarkerBalance(_ sequence: ChoiceSequence, _ fuzzCase: MetaFuzzCase) throws {
        var depth = 0
        for entry in sequence {
            switch entry {
                case .group(true), .sequence(true, validRange: _, isLengthExplicit: _), .bind(true):
                    depth += 1
                case .group(false), .sequence(false, validRange: _, isLengthExplicit: _), .bind(false):
                    depth -= 1
                    if depth < 0 {
                        throw FlattenBalanceViolation("closing marker with no opener in flattening of recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
                    }
                case .branch, .value, .just:
                    continue
            }
        }
        guard depth == 0 else {
            throw FlattenBalanceViolation("\(depth) unclosed markers in flattening of recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
        }
    }

    /// Exact round trip: `.exact` materialization of a tree's own flattening must reproduce the value, and the fresh tree must re-flatten to the same sequence, field for field. The sequence half is the consuming check for every entry field at once — a dropped or wrong field (the flatten-fingerprint class) surfaces here even when no downstream reader exists yet.
    private static func checkExactRoundTrip(
        _ gen: AnyGenerator,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        value: Any,
        _ fuzzCase: MetaFuzzCase
    ) throws {
        switch Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) {
            case let .success(materialized, freshTree, _):
                guard anyEquals(materialized, value) else {
                    throw ExactRoundTripViolation("exact materialization produced \(materialized), not \(value), for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
                }
                let reflattened = ChoiceSequence.flatten(freshTree)
                guard reflattened == sequence else {
                    throw ExactRoundTripViolation("re-flattening after exact materialization changed the sequence for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
                }
            case .rejected, .failed:
                throw ExactRoundTripViolation("exact materialization rejected the tree's own flattening for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
        }
    }

    /// Codec round trip: the persistence codec must round-trip every sequence it is given.
    private static func checkCodecRoundTrip(_ sequence: ChoiceSequence, _ fuzzCase: MetaFuzzCase) throws {
        let decoded = ChoiceSequenceCodec.decode(ChoiceSequenceCodec.encode(sequence))
        guard let decoded, decoded == sequence else {
            throw CodecRoundTripViolation("codec round trip \(decoded == nil ? "failed to decode" : "changed the sequence") for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
        }
    }

    /// Guided totality and cluster-key stability: guided materialization of an arbitrary mutation must complete cleanly with a sane convergence, and repeating it with the same seed and fallback must produce the same outcome and cluster key.
    private static func checkGuidedTotality(
        _ gen: AnyGenerator,
        mutated: ChoiceSequence,
        fallbackTree: ChoiceTree,
        _ fuzzCase: MetaFuzzCase,
        prng: inout Xoshiro256
    ) throws {
        let guidedSeed = prng.next()
        let mode = Materializer.Mode.guided(seed: guidedSeed, fallbackTree: fallbackTree)
        switch Materializer.materialize(gen, prefix: mutated, mode: mode) {
            case let .success(_, freshTree, report):
                if let convergence = report?.convergence, (0.0 ... 1.0).contains(convergence) == false {
                    throw GuidedTotalityViolation("convergence \(convergence) outside 0...1 for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
                }
                let key = ChoiceSequence.flatten(freshTree, skipBindInners: true).clusterKey
                switch Materializer.materialize(gen, prefix: mutated, mode: mode) {
                    case let .success(_, secondTree, _):
                        let secondKey = ChoiceSequence.flatten(secondTree, skipBindInners: true).clusterKey
                        guard key == secondKey else {
                            throw ClusterKeyStabilityViolation("same guided materialization produced different cluster keys for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
                        }
                    case .rejected, .failed:
                        throw GuidedDeterminismViolation("guided materialization succeeded then failed on identical input for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
                }
            case .rejected, .failed:
                // A clean discard is inside the guided contract: filters can reject the materialized value.
                return
        }
    }

    /// Flat-emission parity: the flat-emission walk must reach the same outcome as tree-building materialization of identical inputs, its sequence must equal the fresh tree's flattening entry for entry, and both paths must report the same convergence.
    private static func checkFlatEmissionParity(
        _ gen: AnyGenerator,
        prefix: ChoiceSequence,
        mode: Materializer.Mode,
        fallbackTree: ChoiceTree?,
        _ fuzzCase: MetaFuzzCase
    ) throws {
        let treeResult = Materializer.materializeAny(gen, prefix: prefix, mode: mode, fallbackTree: fallbackTree)
        let flatResult = Materializer.materializeAnyFlat(gen, prefix: prefix, mode: mode, fallbackTree: fallbackTree)
        switch (treeResult, flatResult) {
            case let (.success(_, freshTree, treeReport), .success(_, flatSequence, flatReport)):
                let flattened = ChoiceSequence.flatten(freshTree)
                guard flatSequence == flattened else {
                    throw FlatEmissionParityViolation("flat emission \(flatSequence.shortString) diverged from flattened tree \(flattened.shortString) for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
                }
                guard treeReport?.convergence == flatReport?.convergence else {
                    throw FlatEmissionParityViolation("flat emission convergence \(String(describing: flatReport?.convergence)) diverged from tree path \(String(describing: treeReport?.convergence)) for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
                }
            case (.rejected, .rejected), (.failed, .failed):
                return
            default:
                throw FlatEmissionParityViolation("flat emission outcome diverged from tree materialization for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
        }
    }

    /// Reduction soundness: property-preserving reduction, shortlex direction, closed loop, and monotonicity — the four claims ported from the in-tree reduction oracles, run on the first failing value of a case.
    private static func checkReduction(
        _ gen: AnyGenerator,
        tree: ChoiceTree,
        value: Any,
        property: @escaping (Any) -> Bool,
        _ fuzzCase: MetaFuzzCase
    ) throws {
        let originalSequence = ChoiceSequence.flatten(tree)
        let outcome = try? Interpreters.choiceGraphReduce(
            gen: gen,
            tree: tree,
            output: value,
            config: .init(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: FuzzTunables.reductionDeadlineNanoseconds,
                enabledEncoders: shortlexReductionEncoders
            ),
            property: property
        )
        guard case let .reduced(reducedSequence, reducedTree, shrunk) = outcome else {
            return
        }
        guard property(shrunk) == false else {
            throw ReductionPreservationViolation("reduced value \(shrunk) passes the property its original failed for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
        }
        // `shortLexPrecedes` is strict: distinct sequences can belong to the same equivalence
        // class. Match the reducer's monotonicity contract by rejecting only a strictly larger
        // result, where the original sequence precedes the reduced sequence.
        guard originalSequence.shortLexPrecedes(reducedSequence) == false else {
            throw ReductionShortlexViolation("reduction enlarged the sequence for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
        }
        switch Materializer.materialize(gen, prefix: reducedSequence, mode: .exact, fallbackTree: reducedTree) {
            case let .success(materialized, _, _):
                guard anyEquals(materialized, shrunk) else {
                    throw ReductionClosedLoopViolation("reduced sequence materializes to \(materialized), not the reported \(shrunk), for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
                }
            case .rejected, .failed:
                throw ReductionClosedLoopViolation("reduced sequence failed to materialize for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
        }
        let secondOutcome = try? Interpreters.choiceGraphReduce(
            gen: gen,
            tree: reducedTree,
            output: shrunk,
            config: .init(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: FuzzTunables.reductionDeadlineNanoseconds,
                enabledEncoders: shortlexReductionEncoders
            ),
            property: property
        )
        if case let .reduced(secondSequence, _, _) = secondOutcome {
            guard reducedSequence.shortLexPrecedes(secondSequence) == false else {
                throw ReductionMonotonicityViolation("re-reduction enlarged the sequence for recipe \(fuzzCase.recipe), seed \(fuzzCase.valueSeed)")
            }
        }
    }

    /// Uniform draw over the mutation intensity bands.
    private static func pickIntensity(_ prng: inout Xoshiro256) -> MutationIntensity {
        let bands = MutationIntensity.allCases
        return bands[Int(prng.next(upperBound: UInt64(bands.count)))]
    }
}

/// Rebuilds recipes from one synthetic source location so source-fingerprinted operations denote the same generator in every oracle.
private func buildOracleGenerator(from recipe: GenRecipe) -> AnyGenerator {
    buildGenerator(
        from: recipe,
        fileID: "ExhaustMetaFuzz/OracleGenerator",
        filePath: "ExhaustMetaFuzz/OracleGenerator.swift",
        line: 1,
        column: 1
    )
}

private func randomNumberGeneratorSnapshotsEqual(
    _ first: (seed: UInt64, state: Xoshiro256.StateType),
    _ second: (seed: UInt64, state: Xoshiro256.StateType)
) -> Bool {
    first.seed == second.seed
        && first.state.0 == second.state.0
        && first.state.1 == second.state.1
        && first.state.2 == second.state.2
        && first.state.3 == second.state.3
}

private enum InterpreterGenerationOutcome: CustomStringConvertible {
    case value(Any)
    case exhausted
    case failure(String)

    var description: String {
        switch self {
            case let .value(value):
                "value(\(value))"
            case .exhausted:
                "exhausted"
            case let .failure(failure):
                "failure(\(failure))"
        }
    }
}

private func nextValueOutcome(
    _ interpreter: inout ValueInterpreter<Any>
) -> InterpreterGenerationOutcome {
    do {
        guard let value = try interpreter.next() else {
            return .exhausted
        }
        return .value(value)
    } catch {
        return .failure("\(type(of: error)): \(error)")
    }
}

private func nextTreeValueOutcome(
    _ interpreter: inout ValueAndChoiceTreeInterpreter<Any>
) -> InterpreterGenerationOutcome {
    do {
        guard let value = try interpreter.next()?.value else {
            return .exhausted
        }
        return .value(value)
    } catch {
        return .failure("\(type(of: error)): \(error)")
    }
}

// MARK: - Paired Values Helper

/// Checks that two generators produce pairwise-equal values from the same seed.
package func checkPairedValues(
    _ gen1: AnyGenerator,
    _ gen2: AnyGenerator,
    seed: UInt64 = 42,
    maxRuns: UInt64 = 10,
    check: (Any, Any) -> Bool
) -> Bool {
    do {
        var iter1 = ValueInterpreter(gen1, seed: seed, maxRuns: maxRuns)
        var iter2 = ValueInterpreter(gen2, seed: seed, maxRuns: maxRuns)
        while let v1 = try iter1.next(), let v2 = try iter2.next() {
            if check(v1, v2) == false {
                return false
            }
        }
    } catch {
        return true
    }
    return true
}
