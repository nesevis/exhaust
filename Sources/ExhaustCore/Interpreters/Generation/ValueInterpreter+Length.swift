//
//  ValueInterpreter+Length.swift
//  Exhaust
//

// MARK: - Length Interpreter

extension ValueInterpreter {
    /// Interprets a `Generator<UInt64>` directly without type-erasing to `<Any>`.
    ///
    /// Value-only variant of ``ValueAndChoiceTreeInterpreter/interpretLength(_:context:)`` — returns the `UInt64` length without constructing a ``ChoiceTree``.
    static func interpretLength(
        _ gen: Generator<UInt64>,
        context: inout GenerationContext
    ) throws -> UInt64? {
        switch gen {
        case let .pure(value):
            return value

        case let .impure(operation, continuation):
            let result: Any

            switch operation {
            case let .chooseBits(min, max, tag, _, scaling):
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
                result = tag.isFloatingPoint
                    ? tag.linearlyDistributed(rawBits: rawBits, in: effectiveRange)
                    : rawBits

            case .getSize:
                result = consumeSize(&context)

            case let .resize(newSize, inner):
                context.sizeOverride = newSize
                defer { context.sizeOverride = nil }
                guard let innerResult = try generateRecursiveAny(
                    inner, with: (), context: &context
                ) else {
                    return nil
                }
                return try interpretLengthContinuation(
                    result: innerResult, continuation: continuation, context: &context
                )

            case let .contramap(_, nextGen):
                guard let innerResult = try generateRecursiveAny(
                    nextGen, with: (), context: &context
                ) else {
                    return nil
                }
                return try interpretLengthContinuation(
                    result: innerResult, continuation: continuation, context: &context
                )

            case let .prune(nextGen):
                guard InterpreterWrapperHandlers.unwrapPruneInput(()) != nil else {
                    return nil
                }
                guard let innerResult = try generateRecursiveAny(
                    nextGen, with: (), context: &context
                ) else {
                    return nil
                }
                return try interpretLengthContinuation(
                    result: innerResult, continuation: continuation, context: &context
                )

            case let .transform(kind, inner):
                switch kind {
                case let .map(forward, _, _):
                    guard let innerValue = try generateRecursiveAny(
                        inner, with: (), context: &context
                    ) else {
                        return nil
                    }
                    return try interpretLengthContinuation(
                        result: try forward(innerValue), continuation: continuation, context: &context
                    )
                case let .bind(_, forward, _, _, _):
                    guard let innerValue = try generateRecursiveAny(
                        inner, with: (), context: &context
                    ) else {
                        return nil
                    }
                    let boundGen = try forward(innerValue)
                    guard let boundValue = try generateRecursiveAny(
                        boundGen, with: (), context: &context
                    ) else {
                        return nil
                    }
                    return try interpretLengthContinuation(
                        result: boundValue, continuation: continuation, context: &context
                    )
                default:
                    return try generateRecursiveAny(
                        gen.erase(), with: (), context: &context
                    ) as? UInt64
                }

            default:
                return try generateRecursiveAny(
                    gen.erase(), with: (), context: &context
                ) as? UInt64
            }

            return try interpretLengthContinuation(
                result: result, continuation: continuation, context: &context
            )
        }
    }

    @inline(__always)
    static func interpretLengthContinuation(
        result: Any,
        continuation: (Any) throws -> Generator<UInt64>,
        context: inout GenerationContext
    ) throws -> UInt64? {
        let nextGen = try continuation(result)
        if case let .pure(value) = nextGen {
            return value
        }
        return try interpretLength(nextGen, context: &context)
    }
}
