protocol AnyFreerMonad {
    associatedtype Value
}

enum FreerMonad<Operation, Value>: AnyFreerMonad {
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
}
