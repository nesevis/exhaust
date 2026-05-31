//
//  ValueInterpreter+Length.swift
//  Exhaust
//

// MARK: - Length Interpreter

extension ValueInterpreter {
    /// Interprets a `Generator<UInt64>` length generator by routing it through the main value-only engine and casting the result.
    ///
    /// Erasing the length generator is O(1) per node (continuations already produce `Any`), so the dedicated typed walker this replaced is no longer worth its duplication of the main switch.
    static func interpretLength(
        _ gen: Generator<UInt64>,
        context: inout GenerationContext
    ) throws -> UInt64? {
        try generateRecursiveAny(gen.erase(), with: (), context: &context) as? UInt64
    }
}
