//
//  ValueAndChoiceTreeInterpreter+Length.swift
//  Exhaust
//

// MARK: - Length Interpreter

extension ValueAndChoiceTreeInterpreter {
    /// Interprets a `Generator<UInt64>` length generator by routing it through the main engine and casting the result.
    ///
    /// Erasing the length generator is O(1) per node (continuations already produce `Any`), so the dedicated typed walker this replaced — and its bespoke tree grouping — is no longer worth its duplication of the main switch; the length tree is now built by the same path as every other choice.
    static func interpretLength(
        _ gen: Generator<UInt64>,
        context: inout GenerationContext
    ) throws -> (UInt64, ChoiceTree)? {
        guard let (value, tree) = try generateRecursiveAny(gen.erase(), with: (), context: &context) else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (value as! UInt64, tree)
    }
}
