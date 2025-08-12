
public enum FreerMonad<Operation, Value> {
    /// A pure value — the termination point of this operation
    case pure(Value)
    /// An impure value representing a suspended operation
    indirect case impure(operation: Operation, continuation: (Any) throws -> FreerMonad<Operation, Value>)
}

// MARK: - Functor and Monad
extension FreerMonad {
    @inlinable
    func bind<NewValue>(_ transform: @escaping (Value) throws -> FreerMonad<Operation, NewValue>) rethrows -> FreerMonad<Operation, NewValue> {
        switch self {
        case let .pure(value):
            try transform(value)
        case let .impure(operation, continuation):
            .impure(operation: operation) { try continuation($0).bind(transform) }
        }
    }
    
    @inlinable
    func map<NewValue>(_ transform: @escaping (Value) throws -> NewValue) rethrows -> FreerMonad<Operation, NewValue> {
        try self.bind { try .pure(transform($0)) }
    }
    
    @inlinable
    func erase() -> FreerMonad<Operation, Any> {
        switch self {
            case let .pure(value):
                .pure(value as Any)
            case let .impure(operation, continuation):
                .impure(operation: operation) { try continuation($0).erase() }
        }
    }
}

extension FreerMonad where Value == Any {
    // This shouldn't be called, but on the off chance that erase is called on an already-erased generator, it is now a noop
    @inlinable
    func erase() -> FreerMonad<Operation, Any> {
        self
    }
}
