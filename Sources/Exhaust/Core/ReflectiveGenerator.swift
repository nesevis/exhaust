
public typealias ReflectiveGenerator<Output> = FreerMonad<ReflectiveOperation, Output>

public extension ReflectiveGenerator where Operation == ReflectiveOperation {

    var associatedRange: ClosedRange<UInt64>? {
        switch self {
        case .pure:
            return nil
        case let .impure(op, _):
            guard case .chooseBits(let min, let max, _) = op else {
                return nil
            }
            return min...max
        }
    }

    @inlinable
    func mapped<NewOutput>(
        forward: @escaping (Value) throws -> NewOutput,
        backward: @escaping (NewOutput) throws -> Value
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        try Gen.lmap(backward, self.map(forward))
    }
    
    // extract path: some PartialPath<NewInput, Input>,
    @inlinable
    func mapped<NewOutput>(
        forward: @escaping (Value) throws -> NewOutput,
        backward: some PartialPath<NewOutput, Value>
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        let erasedBackward: (Any) throws -> Any = { newOutput in
            try backward.extract(from: newOutput)!
        }
        let erasedGen = try self
            .map(forward)

        return Gen.lmap(erasedBackward, erasedGen)
    }
    
    @inlinable
    func mapped<NewOutput>(
        forward: some PartialPath<Value, NewOutput>,
        backward: some PartialPath<NewOutput, Value>
    ) throws -> ReflectiveGenerator<NewOutput?> {
        let erasedBackward: (Any) throws -> Any = { newOutput in
            // FIXME: Should we be force unwrapping here? What if it's optional?
            try backward.extract(from: newOutput)!
        }
        let erasedGen = try self
            .map { try forward.extract(from: $0) }
        
        return Gen.lmap(erasedBackward, erasedGen)
    }
    
    @inlinable
    func asOptional() -> ReflectiveGenerator<Value?> {
        let description = String(describing: Value.self)
        return .impure(operation: .lmap(
            transform: { result in
                // Backward pass. The calling function is expecting a non-optional, so we throw the `reflectedNil` error to indicate to the consumer — which should only be a `pick` exploring the nil and non-nil options — that they are trying to parse the `.some` branch using the `.none` value during reflection
                if let optional = result as? Optional<Value>, optional == nil {
                    throw Interpreters.ReflectionError.reflectedNil(type: description)
                }
                return result as! Value
            },
            next: self.erase()
        )) { result in
                .pure(result as? Value)
            }
    }
    
    #warning("This has performance overhead, use with caution")
    private func mapOperation<NewOperation>(_ transform: @escaping (Operation) -> NewOperation) -> FreerMonad<NewOperation, Value> {
        switch self {
        case let .pure(value):
            // If we're at a pure value, there's no operation to transform. Return as is.
            return .pure(value)
            
        case let .impure(operation, continuation):
            // If we have a suspended operation:
            // 1. Transform the current operation.
            let newOperation = transform(operation)
            
            // 2. Create a new continuation. This new continuation must return a monad
            //    with the NewOperation type. We do this by recursively calling
            //    `mapOperation` on the result of the original continuation.
            let newContinuation = { (val: Any) -> FreerMonad<NewOperation, Value> in
                try continuation(val).mapOperation(transform)
            }
            
            // 3. Return a new impure case with the transformed operation and continuation.
            return .impure(operation: newOperation, continuation: newContinuation)
        }
    }
}
