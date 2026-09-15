//
//  ReflectiveGenerator+Size.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension ReflectiveGenerator {
    /// Creates a generator whose definition depends on the current size parameter.
    ///
    /// The size parameter grows from 1 through 100 as a property test progresses. Use it to increase generated complexity over time, such as widening a numeric range or increasing a recursive depth. During reflection, Exhaust uses size 100 so the dependent generator exposes its full range.
    ///
    /// ```swift
    /// let adaptive = ReflectiveGenerator<UInt64>.getSize { size in
    ///     .uint64(in: 0 ... size)
    /// }
    /// ```
    ///
    /// The size a counterexample was generated with is part of the counterexample: during reduction Exhaust can lower it, so the closure may run with a smaller size than any the test itself reached. A size set by ``resize(_:)`` reaches the closure clamped to 1 through 100.
    ///
    /// `forward` runs once per distinct size and the generator it returns is reused, so it must be pure: for equal sizes it must return structurally identical generators, or replay and reduction lose determinism.
    ///
    /// - Parameter forward: A pure closure that receives the current size and returns the generator to run.
    /// - Returns: A generator that produces the result of the size-dependent generator.
    static func getSize(
        _ forward: @Sendable @escaping (UInt64) -> ReflectiveGenerator<Output>,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        // The forward closure runs at generation time and cannot be inspected here; reflection still rejects a value the produced generator cannot decompose.
        Gen.reducibleGetSize(
            fingerprint: Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
        ) { size in
            forward(size).gen
        }.wrapped(isReflective: true)
    }

    /// Runs this generator with a temporarily modified size parameter.
    ///
    /// ```swift
    /// let small = #gen(.int().array()).resize(10)
    /// ```
    func resize(_ newSize: Int) -> ReflectiveGenerator<Output> {
        precondition(newSize >= 0, "Size must be non-negative")
        return Gen.liftF(.resize(newSize: UInt64(newSize), next: gen.erase())).wrapped(isReflective: isReflective)
    }
}
