package extension ReflectiveGenerator where Operation == ReflectiveOperation {
    /// Lifts this generator's output from `T` to `T?` so reflection can distinguish the `.some` branch from `.none`.
    ///
    /// Without this, reflecting on a `nil` target has no way to prune the non-optional path: the reflector would attempt to decompose `nil` as if it were a valid `T`, and fail. With it, `nil` throws `ReflectionError.reflectedNil`, which the enclosing `pick` catches to eliminate that branch.
    ///
    /// - Returns: A generator that produces optional versions of the original values.
    func liftToOptional() -> ReflectiveGenerator<Value?> {
        let description = String(describing: Value.self)
        return .impure(operation: .contramap(
            transform: { result in
                if let optional = result as? Value?, optional == nil {
                    throw Interpreters.ReflectionError.reflectedNil(
                        type: description,
                        resultType: String(describing: type(of: result))
                    )
                }
                return result as! Value
            },
            next: erase()
        )) { result in
            .pure(result as? Value)
        }
    }
}
