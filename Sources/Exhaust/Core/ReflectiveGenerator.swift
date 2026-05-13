//
//  ReflectiveGenerator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

import ExhaustCore

/// Produces arbitrary values and supports reflection, replay, and reduction.
///
/// `ReflectiveGenerator` is the public face of the generator system. It wraps the internal monadic representation (a `FreerMonad<ReflectiveOperation, Output>`) in a struct that hides the enum cases from users. Construct generators with static factory methods (`.int()`, `.string()`, `.bool()`, and so on) or the `#gen` macro, then pass them to `#exhaust` for property testing.
///
/// ```swift
/// let gen = ReflectiveGenerator.int(in: 0...100)
///     .array(length: 1...10)
///     .filter { $0.contains(where: { $0 > 50 }) }
///
/// #exhaust(gen) { array in
///     array.sorted() == array // finds unsorted arrays
/// }
/// ```
///
/// ## Three Modes
///
/// The same generator supports generation (forward pass with entropy), reflection (backward pass that decomposes a value into its choice sequence), and replay (deterministic forward from a recorded choice sequence). Interpreters select the mode; the generator itself is mode-agnostic.
///
/// ## Why a Struct
///
/// The underlying `FreerMonad` is an `indirect enum` whose `.pure` and `.impure` cases would otherwise be constructible by users, bypassing the combinator API. The struct hides those cases while adding zero overhead — WMO eliminates the single-field wrapper entirely.
///
/// - Note: `@unchecked Sendable` is safe because the wrapped `FreerMonad` stores only `@Sendable` closures and `Sendable` value types. The `indirect enum` representation prevents the compiler from verifying this automatically.
public struct ReflectiveGenerator<Output>: @unchecked Sendable {
    package let gen: Generator<Output>

    /// Wraps a generator-producing closure, evaluating it immediately.
    package init(_ gen: () throws -> Generator<Output>) rethrows {
        self.gen = try gen()
    }

    /// Chains this generator with a dependent generator whose structure depends on the produced value.
    ///
    /// Use `.bind` when the next generator genuinely depends on the value from this one — for example, generating an array whose length is determined by a previously generated integer. When generators are independent, prefer `#gen(a, b) { ... }` — they compose without introducing a dependency edge in the choice graph.
    ///
    /// - Parameter transform: A function that takes the generated value and returns a new generator.
    /// - Returns: A generator that sequences the two computations.
    public func bind<NewOutput>(
        _ transform: @escaping (Output) throws -> ReflectiveGenerator<NewOutput>,
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        ReflectiveGenerator<NewOutput> {
            let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
            return Gen.liftF(.transform(
                kind: .bind(
                    fingerprint: fingerprint,
                    forward: { try transform($0 as! Output).gen.erase() },
                    backward: nil,
                    inputType: Output.self,
                    outputType: NewOutput.self
                ),
                inner: gen.erase()
            ))
        }
    }

    /// Applies a forward-only transform to the generated value.
    ///
    /// Reduction is unaffected: the reducer operates on the choice sequence, not the transformed output. Reflection is not supported through this transform — ``#examine`` will report a forward-only warning. For reflection support, use ``mapped(forward:backward:)`` or ``#gen`` with a trailing closure.
    ///
    /// ```swift
    /// let lengths = #gen(.asciiString()).map { $0.count }
    /// ```
    ///
    /// - Parameter transform: A function to apply to each generated value.
    /// - Returns: A generator producing the transformed values.
    public func map<NewOutput>(
        _ transform: @escaping (Output) throws -> NewOutput
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        ReflectiveGenerator<NewOutput> {
            Gen.liftF(.transform(
                kind: .map(
                    forward: { try transform($0 as! Output) },
                    inputType: Output.self,
                    outputType: NewOutput.self
                ),
                inner: gen.erase()
            ))
        }
    }
}

// MARK: - CustomDebugStringConvertible

extension ReflectiveGenerator: CustomDebugStringConvertible {
    public var debugDescription: String {
        gen.debugDescription
    }
}
