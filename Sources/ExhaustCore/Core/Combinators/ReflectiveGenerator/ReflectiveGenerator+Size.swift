//
//  ReflectiveGenerator+Size.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension ReflectiveGenerator {
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
