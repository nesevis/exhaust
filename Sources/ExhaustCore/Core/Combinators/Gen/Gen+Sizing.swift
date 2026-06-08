// Operations for controlling and accessing the size parameter in generators.
// The size parameter is used to control the complexity and scale of generated values.

package extension Gen {
    /// Retrieves the raw size parameter without a backward comap.
    ///
    /// Use this for framework internals that need the true interpreter size. User-facing code should use ``getSize(_:)`` instead, which adds a backward comap of 100 so reflection through size-dependent generators works without requiring the original size.
    static func rawGetSize() -> Generator<UInt64> {
        .impure(operation: .getSize) { result in
            if let typedResult = result as? UInt64 {
                return .pure(typedResult)
            }
            throw GeneratorError.typeMismatch(
                expected: "\(UInt64.self)",
                actual: String(describing: type(of: result))
            )
        }
    }

    /// Retrieves the current size parameter and feeds it into a generator-producing closure.
    ///
    /// The size parameter (1-100) controls generated-value complexity. It starts small and grows as tests progress, so simple counterexamples are found first. The closure receives the current size and returns a generator to run. Reflection through size-dependent generators works automatically — the backward comap supplies a default size of 100 so the reflector does not need to know the original.
    ///
    /// - Parameter forward: A closure that receives the current size and returns a generator.
    /// - Returns: A generator that produces the result of the size-dependent inner generator.
    static func getSize<Output>(
        _ forward: @escaping (UInt64) -> Generator<Output>
    ) -> Generator<Output> {
        rawGetSize()._bound(forward: forward, backward: { _ in 100 })
    }

    /// Overrides the size parameter for a nested generator scope.
    ///
    /// Use this to cap complexity of nested generators — for example, forcing small collections inside a larger structure, or limiting recursive depth independently of the outer test's size progression. The override is lexically scoped: any ``getSize(_:)`` or ``chooseBits`` with scaling inside `generator` sees `newSize`, but the enclosing generator's size is restored after `generator` completes.
    ///
    /// - Parameters:
    ///   - newSize: The size parameter to use for the nested generator.
    ///   - generator: The generator to run with the modified size.
    /// - Returns: A generator that runs with the specified size parameter.
    static func resize<Output>(
        _ newSize: UInt64,
        _ generator: Generator<Output>
    ) -> Generator<Output> {
        liftF(.resize(newSize: newSize, next: generator.erase()))
    }
}
