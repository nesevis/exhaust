//
//  ReflectiveGenerator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

import ExhaustCore

/// Produces arbitrary values for property-based testing.
///
/// Construct generators with static factory methods (`.int()`, `.string()`, `.bool()`, and so on) or the `#gen` macro, then combine them with `.array()`, `.filter()`, `.map()`, and pass the result to `#exhaust`.
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
/// When a property fails, Exhaust automatically reduces (shrinks) the counterexample to a minimal failing case. Generators that support bidirectional transforms — ``mapped(forward:backward:)`` and ``bound(forward:backward:)`` — also enable ``#examine`` to decompose a concrete value back into its generator inputs.
///
/// - Note: `@unchecked Sendable` is safe because the underlying indirect enum stores only `@Sendable` closures and `Sendable` value types. The compiler cannot verify sendability through the indirection automatically.
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
        fileID: StaticString = #fileID,
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

// MARK: - Design Notes
//
// ReflectiveGenerator wraps a FreerMonad<ReflectiveOperation, Output> — an indirect enum with
// .pure and .impure cases. The struct prevents users from constructing those cases directly,
// ensuring all generators go through the combinator API. WMO eliminates the single-field
// wrapper at runtime.
//
// The same generator representation supports three interpreter modes: generation (forward pass
// with entropy), reflection (backward pass decomposing a value into its choice sequence), and
// replay (deterministic forward from a recorded choice sequence). The generator itself is
// mode-agnostic — interpreters select the mode.

// MARK: - CustomDebugStringConvertible

extension ReflectiveGenerator: CustomDebugStringConvertible {
    public var debugDescription: String {
        gen.debugDescription
    }
}
