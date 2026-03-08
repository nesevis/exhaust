//
//  Replay.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

// MARK: - Academic Provenance

//
// Implements the `parse` interpretation P⟦·⟧ (Goldstein §3.3.3) from a hierarchical ChoiceTree. The dissertation parses from flat choice sequences; Exhaust adds tree-structured replay for precise structural matching.

extension Interpreters {
    // ... `generate` and `reflect` and their helpers ...

    // MARK: - Public-Facing Replay Function

    /// Deterministically reproduces a value by executing a generator with a structured `ChoiceTree`.
    ///
    /// - Parameters:
    ///   - gen: The generator to execute.
    ///   - choiceTree: The structured script of choices to follow.
    /// - Returns: The deterministically generated value, or `nil` if the tree does not match the generator's structure.
    public static func replay<Output>(
        _ gen: ReflectiveGenerator<Output>,
        using choiceTree: ChoiceTree,
    ) throws -> Output? {
        // Start the recursive process. The helper returns the value and any *unconsumed*
        // parts of the tree. A successful top-level replay should consume the entire tree.
        try replayRecursive(gen, with: choiceTree)

        // We can add a check here to ensure no parts of the tree were left over,
        // but the recursive logic should handle this correctly.
    }

    // MARK: - Private Recursive Replay Engine

    private static func replayWithChoices<Output>(
        _ gen: ReflectiveGenerator<Output>,
        choices: [ChoiceTree],
    ) throws -> Output? {
        var remainingChoices = choices
        return try replayWithChoicesHelper(gen, choices: &remainingChoices)
    }

    private static func replayWithChoicesHelper<Output>(
        _ gen: ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree],
    ) throws -> Output? {
        switch gen {
        case let .pure(value):
            // Base case: return the value
            value

        case let .impure(operation, continuation):
            try replayWithChoicesOperation(
                operation,
                continuation: continuation,
                choices: &choices,
            )
        }
    }

    private static func replayWithChoicesOperation<Output>(
        _ operation: ReflectiveOperation,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree],
    ) throws -> Output? {
        switch operation {
        case .chooseBits:
            return try replayWithChoicesChooseBits(continuation: continuation, choices: &choices)
        case let .pick(pickChoices):
            return try replayWithChoicesPick(
                pickChoices: pickChoices,
                continuation: continuation,
                choices: &choices,
            )
        case let .sequence(_, elementGenerator):
            return try replayWithChoicesSequence(
                elementGenerator: elementGenerator,
                continuation: continuation,
                choices: &choices,
            )
        case let .zip(generators):
            return try replayWithChoicesZip(
                generators: generators,
                continuation: continuation,
                choices: &choices,
            )
        case let .contramap(_, subGenerator), let .prune(subGenerator):
            return try replayWithChoicesWrapped(
                subGenerator: subGenerator,
                continuation: continuation,
                choices: &choices,
            )
        case let .just(value):
            return try replayWithChoicesJust(value: value, continuation: continuation, choices: &choices)
        case .getSize:
            return try replayWithChoicesGetSize(continuation: continuation, choices: &choices)
        case let .resize(_, subGenerator):
            return try replayWithChoicesResize(
                subGenerator: subGenerator,
                continuation: continuation,
                choices: &choices,
            )
        case let .filter(gen, _, _, predicate):
            guard let inner = try replayWithChoicesHelper(gen, choices: &choices), predicate(inner) else {
                return nil
            }
            return inner as? Output
        case let .classify(gen, _, _), let .unique(gen, _, _):
            return try replayWithChoicesHelper(gen, choices: &choices) as? Output
        }
    }

    @inline(__always)
    private static func replayWithChoicesChooseBits<Output>(
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree],
    ) throws -> Output? {
        guard choices.isEmpty == false else {
            return nil
        }
        let choice = choices.removeFirst()
        guard case let .choice(bits, _) = choice else {
            return nil
        }

        let nextGen = try continuation(bits.convertible)
        return try replayWithChoicesHelper(nextGen, choices: &choices)
    }

    private static func replayWithChoicesPick<Output>(
        pickChoices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree],
    ) throws -> Output? {
        guard choices.isEmpty == false else {
            return nil
        }
        let choice = choices.removeFirst()
        guard case var .group(branches) = choice else {
            throw ReplayError.wrongInputChoice
        }

        branches = PickBranchResolution.normalizeReplayBranches(branches)

        let nextGen = try branches.firstNonNil { branch -> ReflectiveGenerator<Output>? in
            guard let resolved = PickBranchResolution.unpack(branch) else {
                throw ReplayError.wrongInputChoice
            }
            guard let chosenGen = PickBranchResolution.generator(for: resolved.id, in: pickChoices),
                  let result = try replayWithChoices(chosenGen, choices: [resolved.choice])
            else {
                return nil
            }
            return try continuation(result)
        }

        guard let nextGen else {
            throw ReplayError.noSuccessfulBranch
        }

        return try replayWithChoicesHelper(nextGen, choices: &choices)
    }

    private static func replayWithChoicesSequence<Output>(
        elementGenerator: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree],
    ) throws -> Output? {
        guard choices.isEmpty == false else {
            return nil
        }
        let choice = choices.removeFirst()
        guard case let .sequence(_, elements, _) = choice else {
            throw ReplayError.wrongInputChoice
        }

        var accumulatedValues: [Any] = []
        accumulatedValues.reserveCapacity(elements.count)
        let didSucceed = try SequenceExecutionKernel.run(over: elements) { elementScript in
            guard let elementValue = try replayRecursive(elementGenerator, with: elementScript) else {
                return false
            }
            accumulatedValues.append(elementValue)
            return true
        }
        guard didSucceed else {
            return nil
        }

        let nextGen = try continuation(accumulatedValues)
        return try replayWithChoicesHelper(nextGen, choices: &choices)
    }

    private static func replayWithChoicesZip<Output>(
        generators: ContiguousArray<ReflectiveGenerator<Any>>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree],
    ) throws -> Output? {
        // Unwrap a single non-branch group wrapper (produced by reflect's
        // reflectZipOperation which wraps flat choices in .group(...)).
        if choices.count == 1,
           case let .group(children) = choices[0],
           children.allSatisfy({ $0.isBranch || $0.isSelected }) == false
        {
            choices = children
        }

        // Each generator consumes sequentially from the shared choices.
        var subResults = [Any]()
        for gen in generators {
            guard let result = try replayWithChoicesHelper(gen, choices: &choices) else {
                return nil
            }
            subResults.append(result)
        }
        let nextGen = try continuation(subResults)
        return try replayWithChoicesHelper(nextGen, choices: &choices)
    }

    @inline(__always)
    private static func replayWithChoicesWrapped<Output>(
        subGenerator: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree],
    ) throws -> Output? {
        try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: { try replayWithChoicesHelper(subGenerator, choices: &choices) },
            runContinuation: { subResult in
                let nextGen = try continuation(subResult)
                return try replayWithChoicesHelper(nextGen, choices: &choices)
            },
        )
    }

    @inline(__always)
    private static func replayWithChoicesJust<Output>(
        value: Any,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree],
    ) throws -> Output? {
        guard choices.isEmpty == false else {
            return nil
        }
        let choice = choices.removeFirst()
        guard case .just = choice else {
            return nil
        }

        let nextGen = try continuation(value)
        return try replayWithChoicesHelper(nextGen, choices: &choices)
    }

    @inline(__always)
    private static func replayWithChoicesGetSize<Output>(
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree],
    ) throws -> Output? {
        guard choices.isEmpty == false else {
            return nil
        }
        let choice = choices.removeFirst()
        guard case let .getSize(size) = choice else {
            return nil
        }

        let nextGen = try continuation(size)
        return try replayWithChoicesHelper(nextGen, choices: &choices)
    }

    @inline(__always)
    private static func replayWithChoicesResize<Output>(
        subGenerator: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        choices: inout [ChoiceTree],
    ) throws -> Output? {
        guard choices.isEmpty == false else {
            return nil
        }
        let choice = choices.removeFirst()
        guard case let .resize(_, subChoices) = choice else {
            return nil
        }

        var subChoicesCopy = subChoices
        guard let subResult = try replayWithChoicesHelper(subGenerator, choices: &subChoicesCopy) else {
            return nil
        }
        let nextGen = try continuation(subResult)
        return try replayWithChoicesHelper(nextGen, choices: &choices)
    }

    private static func replayRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with script: ChoiceTree,
    ) throws -> Output? {
        // Handle group scripts by distributing choices to the generator
        // Groups containing branches represent `picks` and are handled together
        if case let .group(choices) = script {
            if choices.allSatisfy({ $0.isBranch || $0.isSelected }) == false {
                return try replayWithChoices(gen, choices: choices)
            }
            // Handle all the pick branches together
            return try replayWithChoices(gen, choices: [script])
        }

        switch gen {
        case let .pure(value):
            // Base case: The generator is done. Return the final value.
            // Any remaining script would indicate a mismatch, but the logic
            // for the calling operation handles passing the correct sub-tree.
            return value

        case let .impure(operation, continuation):
            // This helper simplifies calling the continuation with a result.
            let runContinuation = { (result: Any) -> Output? in
                // The crucial difference: we are NOT passing the script down.
                // The continuation represents the rest of the generator, which
                // will be handled by the next level of the .impure case.
                let nextGen = try continuation(result)
                // We replay the rest of the generator with the *same* script,
                // as the operation itself doesn't consume the whole tree.
                return try self.replayRecursive(nextGen, with: script)
            }

            return try replayRecursiveOperation(
                operation,
                script: script,
                continuation: continuation,
                runContinuation: runContinuation,
            )
        }
    }

    private static func replayRecursiveOperation<Output>(
        _ operation: ReflectiveOperation,
        script: ChoiceTree,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        switch operation {
        case let .zip(generators):
            return try replayRecursiveZip(generators: generators, script: script, runContinuation: runContinuation)
        case .chooseBits:
            return try replayRecursiveChooseBits(script: script, runContinuation: runContinuation)
        case let .just(value):
            return try replayRecursiveJust(value: value, script: script, runContinuation: runContinuation)
        case .getSize:
            return try replayRecursiveGetSize(script: script, runContinuation: runContinuation)
        case let .resize(_, nextGen):
            return try replayRecursiveResize(
                nextGen: nextGen,
                script: script,
                runContinuation: runContinuation,
            )
        case let .pick(choices):
            return try replayRecursivePick(choices: choices, script: script)
        case let .sequence(lengthGen, elementGenerator):
            return try replayRecursiveSequence(
                lengthGen: lengthGen,
                elementGenerator: elementGenerator,
                script: script,
                runContinuation: runContinuation,
            )
        case let .contramap(_, subGenerator):
            return try replayRecursiveContramap(
                subGenerator: subGenerator,
                script: script,
                continuation: continuation,
            )
        case let .prune(subGenerator):
            return try replayRecursive(subGenerator, with: script) as? Output
        case let .filter(gen, _, _, predicate):
            guard let inner = try replayRecursive(gen, with: script),
                  predicate(inner)
            else { return nil }
            return inner as? Output
        case let .classify(gen, _, _), let .unique(gen, _, _):
            return try replayRecursive(gen, with: script) as? Output
        }
    }

    @inline(__always)
    private static func replayRecursiveChooseBits<Output>(
        script: ChoiceTree,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        guard case let .choice(bits, _) = script else {
            return nil
        }
        return try runContinuation(bits.convertible)
    }

    @inline(__always)
    private static func replayRecursiveJust<Output>(
        value: Any,
        script: ChoiceTree,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        guard case .just = script else {
            return nil
        }
        return try runContinuation(value)
    }

    @inline(__always)
    private static func replayRecursiveGetSize<Output>(
        script: ChoiceTree,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        switch script {
        case let .choice(.unsigned(value, _), _):
            try runContinuation(value)
        case let .getSize(value):
            try runContinuation(value)
        default:
            nil
        }
    }

    @inline(__always)
    private static func replayRecursiveResize<Output>(
        nextGen: ReflectiveGenerator<Any>,
        script: ChoiceTree,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        guard case let .resize(_, subChoices) = script,
              let firstChoice = subChoices.first,
              let subResult = try replayRecursive(nextGen, with: firstChoice)
        else {
            return nil
        }
        return try runContinuation(subResult)
    }

    @inline(__always)
    private static func replayRecursivePick<Output>(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        script: ChoiceTree,
    ) throws -> Output? {
        guard let resolved = PickBranchResolution.unpack(script),
              let chosenGen = PickBranchResolution.generator(for: resolved.id, in: choices),
              let result = try replayRecursive(chosenGen, with: resolved.choice)
        else {
            return nil
        }
        return result as? Output
    }

    private static func replayRecursiveSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGenerator: ReflectiveGenerator<Any>,
        script: ChoiceTree,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        guard case let .sequence(length, elements, _) = script else {
            return nil
        }

        let lengthMetadata = ChoiceMetadata(
            validRange: lengthGen.associatedRange ?? length ... length,
            isRangeExplicit: lengthGen.associatedRange != nil,
        )
        guard try replayRecursive(lengthGen, with: .choice(.unsigned(length, .uint64), lengthMetadata)) != nil else {
            return nil
        }

        var accumulatedValues: [Any] = []
        accumulatedValues.reserveCapacity(elements.count)
        let didSucceed = try SequenceExecutionKernel.run(over: elements) { elementScript in
            guard let elementValue = try replayRecursive(elementGenerator, with: elementScript) else {
                return false
            }
            accumulatedValues.append(elementValue)
            return true
        }
        guard didSucceed else {
            return nil
        }

        return try runContinuation(accumulatedValues)
    }

    private static func replayRecursiveZip<Output>(
        generators: ContiguousArray<ReflectiveGenerator<Any>>,
        script: ChoiceTree,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        guard case let .group(children) = script else {
            return nil
        }

        // 1:1 mapping: each generator gets its own subtree. Works for both
        // VACTI (structured groups) and flat (simple choice nodes).
        if children.count == generators.count {
            var subResults = [Any]()
            var didSucceed = true
            for (gen, tree) in zip(generators, children) {
                guard let result = try replayRecursive(gen, with: tree) else {
                    didSucceed = false
                    break
                }
                subResults.append(result)
            }
            if didSucceed {
                return try runContinuation(subResults)
            }
        }

        // Flat sequential consumption (reflected trees where children
        // count differs from generators count).
        var remaining = children
        var subResults = [Any]()
        for gen in generators {
            guard let result = try replayWithChoicesHelper(gen, choices: &remaining) else {
                return nil
            }
            subResults.append(result)
        }
        return try runContinuation(subResults)
    }

    @inline(__always)
    private static func replayRecursiveContramap<Output>(
        subGenerator: ReflectiveGenerator<Any>,
        script: ChoiceTree,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
    ) throws -> Output? {
        try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: { try replayRecursive(subGenerator, with: script) },
            runContinuation: { subResult in
                let nextGen = try continuation(subResult)
                return try replayRecursive(nextGen, with: script)
            },
        )
    }

    enum ReplayError: LocalizedError {
        case wrongInputChoice
        case noSuccessfulBranch
        case mismatchInChoicesAndGenerators
    }
}
