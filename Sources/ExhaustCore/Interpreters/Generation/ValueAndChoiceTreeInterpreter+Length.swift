//
//  ValueAndChoiceTreeInterpreter+Length.swift
//  Exhaust
//

// MARK: - Length Interpreter

extension ValueAndChoiceTreeInterpreter {
    /// Interprets a `Generator<UInt64>` directly without type-erasing to `<Any>`.
    ///
    /// Length generators produce a `UInt64` that is consumed immediately by ``handleSequence``. Their continuations are typed `(Any) throws -> Generator<UInt64>`, so this interpreter avoids the `FreerMonad.erase()` spine traversal and the generic metadata resolution in the erased continuation closures.
    ///
    /// Handles `chooseBits` and `getSize` inline. Wrapper operations (`resize`, `contramap`, `prune`) delegate their inner `<Any>` sub-generator to ``generateRecursiveAny`` and thread the result through the typed continuation.
    static func interpretLength(
        _ gen: Generator<UInt64>,
        context: inout GenerationContext
    ) throws -> (UInt64, ChoiceTree)? {
        switch gen {
        case let .pure(value):
            return (value, .just)

        case let .impure(operation, continuation):
            let result: Any
            let calleeTree: ChoiceTree

            switch operation {
            case let .chooseBits(min, max, tag, isRangeExplicit, scaling):
                let effectiveRange: ClosedRange<UInt64>
                if let scaling {
                    let size = consumeSize(&context)
                    effectiveRange = Gen.applyScaling(
                        min: min, max: max, tag: tag, scaling: scaling, size: size
                    )
                } else {
                    effectiveRange = min ... max
                }
                let rawBits = context.prng.next(in: effectiveRange)
                let randomBits = tag.isFloatingPoint
                    ? tag.linearlyDistributed(rawBits: rawBits, in: effectiveRange)
                    : rawBits
                result = randomBits
                calleeTree = .choice(
                    ChoiceValue(randomBits, tag: tag),
                    .init(validRange: min ... max, isRangeExplicit: isRangeExplicit)
                )

            case .getSize:
                let size = consumeSize(&context)
                result = size
                calleeTree = .getSize(size)

            case let .resize(newSize, inner):
                context.sizeOverride = newSize
                guard let (innerResult, innerTree) = try generateRecursiveAny(
                    inner, with: (), context: &context
                ) else {
                    return nil
                }
                return try interpretLengthContinuation(
                    result: innerResult,
                    calleeTree: .resize(newSize: newSize, choices: [innerTree]),
                    continuation: continuation,
                    context: &context
                )

            case let .contramap(_, nextGen):
                guard let (innerResult, innerTree) = try generateRecursiveAny(
                    nextGen, with: (), context: &context
                ) else {
                    return nil
                }
                return try interpretLengthContinuation(
                    result: innerResult,
                    calleeTree: innerTree,
                    continuation: continuation,
                    context: &context
                )

            case let .prune(nextGen):
                guard InterpreterWrapperHandlers.unwrapPruneInput(()) != nil else {
                    return nil
                }
                guard let (innerResult, innerTree) = try generateRecursiveAny(
                    nextGen, with: (), context: &context
                ) else {
                    return nil
                }
                return try interpretLengthContinuation(
                    result: innerResult,
                    calleeTree: innerTree,
                    continuation: continuation,
                    context: &context
                )

            case let .transform(kind, inner):
                switch kind {
                case let .map(forward, _, _):
                    guard let (innerValue, innerTree) = try generateRecursiveAny(
                        inner, with: (), context: &context
                    ) else {
                        return nil
                    }
                    return try interpretLengthContinuation(
                        result: try forward(innerValue),
                        calleeTree: innerTree,
                        continuation: continuation,
                        context: &context
                    )
                case let .bind(fingerprint, forward, _, _, _):
                    guard let (innerValue, innerTree) = try generateRecursiveAny(
                        inner, with: (), context: &context
                    ) else {
                        return nil
                    }
                    let boundGen = try forward(innerValue)
                    guard let (boundValue, boundTree) = try generateRecursiveAny(
                        boundGen, with: (), context: &context
                    ) else {
                        return nil
                    }
                    return try interpretLengthContinuation(
                        result: boundValue,
                        calleeTree: .bind(fingerprint: fingerprint, inner: innerTree, bound: boundTree),
                        continuation: continuation,
                        context: &context
                    )
                default:
                    guard let (value, tree) = try generateRecursiveAny(
                        gen.erase(), with: (), context: &context
                    ) else { return nil }
                    // swiftlint:disable:next force_cast
                    return (value as! UInt64, tree)
                }

            default:
                return try generateRecursive(gen, with: (), context: &context)
            }

            return try interpretLengthContinuation(
                result: result,
                calleeTree: calleeTree,
                continuation: continuation,
                context: &context
            )
        }
    }

    @inline(__always)
    static func interpretLengthContinuation(
        result: Any,
        calleeTree: ChoiceTree,
        continuation: (Any) throws -> Generator<UInt64>,
        context: inout GenerationContext
    ) throws -> (UInt64, ChoiceTree)? {
        let nextGen = try continuation(result)
        if calleeTree.isChoice, case let .pure(value) = nextGen {
            return (value, calleeTree)
        }
        if let (continuationResult, innerTree) = try interpretLength(
            nextGen, context: &context
        ) {
            if nextGen.isPure {
                return (continuationResult, calleeTree)
            } else {
                return (continuationResult, .group([calleeTree, innerTree]))
            }
        }
        return nil
    }
}
