//
//  RefGen.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

import ExhaustCore

/// TODO: Update docstring
/// Wraps the underlying monadic representation of the generator
public struct RefGen<Output> {
    package let gen: ReflectiveGenerator<Output>
    
    package init(_ gen: () throws -> ReflectiveGenerator<Output>) rethrows {
        self.gen = try gen()
    }
    
    /// Sequences two computations; uses the result of this one to determine the next.
    ///
    /// For `.pure`, applies the transform immediately. For `.impure`, extends the continuation chain so the transform runs after the operation is interpreted. This is the invisible plumbing behind every generator combinator: `Gen.arrayOf`, `Gen.pick`, and `Gen.zip` all compose via `_bind`.
    ///
    /// - Parameter transform: A function that takes the current value and produces a new computation.
    /// - Returns: A new computation representing the sequenced effects.
    /// - Throws: Rethrows any errors from the transform function.
    func bind<NewOutput>(
        _ transform: @escaping (Output) throws -> RefGen<NewOutput>
    ) rethrows -> RefGen<NewOutput> {
        switch gen {
        case let .pure(value):
            try transform(value)
        case let .impure(operation, continuation):
            RefGen<NewOutput> {
                .impure(operation: operation) {
                    try continuation($0)._bind { try transform($0).gen }
                }
            }
        }
    }

    /// Transforms the eventual result without introducing new effects.
    ///
    /// Unlike `_bind`, which can introduce additional operations, `_map` only changes the value at the end of the chain. The effect structure (which operations run, in what order) remains unchanged. This is the invisible `_map` that powers `Gen.contramap` and the macro's backward-mapping infrastructure.
    ///
    /// - Parameter transform: A pure function to apply to the final value.
    /// - Returns: A computation that produces the transformed value.
    /// - Throws: Rethrows any errors from the transform function.
    func map<NewOutput>(
        _ transform: @escaping (Output) throws -> NewOutput
    ) rethrows -> RefGen<NewOutput> {
        try RefGen<NewOutput> {
            switch gen {
            case let .pure(value):
                try .pure(transform(value))
            case let .impure(operation, continuation):
                .impure(operation: operation) { try continuation($0)._map(transform) }
            }
        }
    }
}

// MARK: - CustomDebugStringConvertible

extension RefGen: CustomDebugStringConvertible {
    public var debugDescription: String {
        gen.debugDescription
    }
}
