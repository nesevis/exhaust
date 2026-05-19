package extension Generator where Operation == ReflectiveOperation {
    /// Wraps the output as `T?` so the reflection interpreter can prune this branch when the target is `nil`.
    ///
    /// Without the lift, reflecting on a `nil` target would attempt to decompose it as a valid `T` and fail. The lifted version throws ``ReflectionError/reflectedNil(type:resultType:)`` on nil targets, which the enclosing ``pick`` catches to eliminate the `.some` branch and select `.none` instead.
    ///
    /// - Returns: A generator that produces optional versions of the original values.
    func liftToOptional() -> Generator<Value?> {
        let description = String(describing: Value.self)
        return .impure(operation: .contramap(
            transform: { result in
                if let optional = result as? Value?, optional == nil {
                    throw ReflectionError.reflectedNil(
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
