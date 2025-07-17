protocol AnyFreerMonad {
    associatedtype Value
}

enum FreerMonad<Operation, Value>: AnyFreerMonad {
    /// A pure value — the termination point of this operation
    case pure(Value)
    /// An impure value representing a suspended operation
    indirect case impure(operation: Operation, continuation: (Any) -> FreerMonad<Operation, Value>)
}

// MARK: - Functor and Monad
extension FreerMonad {
    func bind<NewValue>(_ transform: @escaping (Value) -> FreerMonad<Operation, NewValue>) -> FreerMonad<Operation, NewValue> {
        switch self {
        case let .pure(value):
            transform(value)
        case let .impure(operation, continuation):
            .impure(operation: operation) { continuation($0).bind(transform) }
        }
    }
    
    func map<NewValue>(_ transform: @escaping (Value) -> NewValue) -> FreerMonad<Operation, NewValue> {
        self.bind { .pure(transform($0)) }
    }
}
