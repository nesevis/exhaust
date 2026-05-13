//
//  RefGen.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

import ExhaustCore

/// TODO: Update docstring
/// Wraps the underlying monadic representation of the generator
public struct RefGen<Output>: @unchecked Sendable {
    package let gen: Generator<Output>
    
    package init(_ gen: () throws -> Generator<Output>) rethrows {
        self.gen = try gen()
    }
    
    /// Chains this generator with a dependent generator whose structure depends on the produced value.
    ///
    /// Use `.bind` when the next generator genuinely depends on the value from this one — for example, generating an array whose length is determined by a previously generated integer. When generators are independent, prefer `#refGen(a, b) { ... }` — they compose without introducing a dependency edge in the choice graph.
    ///
    /// - Parameter transform: A function that takes the generated value and returns a new generator.
    /// - Returns: A generator that sequences the two computations.
    public func bind<NewOutput>(
        _ transform: @escaping (Output) throws -> RefGen<NewOutput>,
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> RefGen<NewOutput> {
        RefGen<NewOutput> {
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
    /// Reduction is unaffected: the reducer operates on the choice sequence, not the transformed output. Reflection is not supported through this transform. For reflection support, use ``mapped(forward:backward:)``.
    ///
    /// - Parameter transform: A function to apply to each generated value.
    /// - Returns: A generator producing the transformed values.
    public func map<NewOutput>(
        _ transform: @escaping (Output) throws -> NewOutput
    ) rethrows -> RefGen<NewOutput> {
        RefGen<NewOutput> {
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

extension RefGen: CustomDebugStringConvertible {
    public var debugDescription: String {
        gen.debugDescription
    }
}
