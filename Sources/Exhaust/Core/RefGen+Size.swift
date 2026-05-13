//
//  RefGen+Size.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension RefGen {
    /// Runs this generator with a temporarily modified size parameter.
    ///
    /// ```swift
    /// let small = #gen(.int().array()).resize(10)
    /// ```
    func resize(_ newSize: UInt64) -> RefGen<Output> {
        RefGen {
            Gen.liftF(.resize(newSize: newSize, next: gen.erase()))
        }
    }

    /// Runs this generator with a temporarily modified size parameter.
    ///
    /// ```swift
    /// let small = #gen(.int().array()).resize(10)
    /// ```
    func resize(_ newSize: Int) -> RefGen<Output> {
        precondition(newSize >= 0, "Size must be non-negative")
        return resize(UInt64(newSize))
    }
}
