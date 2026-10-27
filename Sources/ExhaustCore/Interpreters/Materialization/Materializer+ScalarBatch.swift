extension Materializer {
    /// Resolves each element through ``resolveChooseBits``, then returns the collected bits for a single batch conversion. The batch construction contract makes element continuations pure, so only the collected bits need conversion.
    @inline(never)
    static func resolveScalarBatchBits(
        length: UInt64,
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling?,
        typeTagPayload: TypeTagPayload?,
        elementFallbacks: [ChoiceTree]?,
        elements: inout [ChoiceTree],
        context: inout Context
    ) throws -> [UInt64] {
        var bits: [UInt64] = []
        bits.reserveCapacity(Int(length))
        var elementIndex = 0
        var remaining = length
        while remaining > 0 {
            let elementFallback: ChoiceTree? = elementFallbacks.flatMap { fallbacks in
                elementIndex < fallbacks.count ? fallbacks[elementIndex] : nil
            }
            let (elementCalleeFallback, _) = decomposeNonGroupFallback(elementFallback)
            let resolved = try resolveChooseBits(
                min: min, max: max, tag: tag,
                isRangeExplicit: isRangeExplicit,
                scaling: scaling, typeTagPayload: typeTagPayload,
                context: &context, calleeFallback: elementCalleeFallback
            )
            bits.append(resolved.bits)
            if context.skipTree == false {
                elements.append(resolved.tree)
            }
            elementIndex += 1
            remaining -= 1
        }
        return bits
    }

    /// Resolves exact value-only scalar runs without repeating cursor and emission policy for each element.
    ///
    /// Guided replay, floating-point patterns, reseeds, and emitted histories retain the general resolver. A failed cursor probe consumes nothing, so transparent wrappers and malformed candidates still take their original path.
    /// Kept outlined so the packed-buffer work does not enlarge the general recursive resolver's frame.
    @inline(never)
    static func tryReplayScalarBits(
        length: UInt64,
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        context: inout Context
    ) throws -> [UInt64]? {
        guard length >= context.minimumBulkScalarReplayLength,
              context.mode == .exact,
              context.skipTree,
              context.emitsFlat == false,
              context.hasPendingReseed == false,
              tag.isFloatingPoint == false,
              let count = Int(exactly: length)
        else {
            return nil
        }

        if isRangeExplicit,
           context.boundDepth == 0,
           let first = context.cursor.peekScalarValue(expecting: tag),
           first < min || first > max
        {
            throw RejectionError()
        }
        guard var bits = context.cursor.tryConsumeScalarValues(count: count, expecting: tag) else {
            return nil
        }

        if count > 0 {
            context.decodingReport?.record(sources: .prefix)
        }
        guard min != 0 || max != UInt64.max else {
            return bits
        }
        if context.boundDepth > 0 || isRangeExplicit == false {
            clampScalarReplayBits(&bits, min: min, max: max)
            return bits
        }
        guard scalarReplayBitsAreValid(bits, min: min, max: max) else {
            throw RejectionError()
        }
        return bits
    }

    // These packed loops stay outside the enum-decoding loop so release optimisation can vectorise them.

    @inline(never)
    private static func scalarReplayBitsAreValid(_ bits: [UInt64], min: UInt64, max: UInt64) -> Bool {
        bits.withUnsafeBufferPointer { buffer in
            let width = max &- min
            var violations: UInt64 = 0
            for index in buffer.indices {
                violations |= (buffer[index] &- min) > width ? 1 : 0
            }
            return violations == 0
        }
    }

    @inline(never)
    private static func clampScalarReplayBits(_ bits: inout [UInt64], min: UInt64, max: UInt64) {
        bits.withUnsafeMutableBufferPointer { buffer in
            for index in buffer.indices {
                buffer[index] = Swift.min(Swift.max(buffer[index], min), max)
            }
        }
    }
}
