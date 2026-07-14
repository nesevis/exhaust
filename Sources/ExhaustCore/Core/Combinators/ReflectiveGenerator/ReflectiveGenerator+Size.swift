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
    /// - Parameter forward: A closure that receives the current size and returns the generator to run.
    /// - Returns: A generator that produces the result of the size-dependent generator.
    static func getSize(
        _ forward: @Sendable @escaping (UInt64) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        Gen.getSize { size in
            forward(size).gen
        }.wrapped
    }

    /// Runs this generator with a temporarily modified size parameter.
    ///
    /// ```swift
    /// let small = #gen(.int().array()).resize(10)
    /// ```
    func resize(_ newSize: Int) -> ReflectiveGenerator<Output> {
        precondition(newSize >= 0, "Size must be non-negative")
        return Gen.liftF(.resize(newSize: UInt64(newSize), next: gen.erase())).wrapped
    }
}
