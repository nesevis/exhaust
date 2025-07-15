enum Gen {
    static func liftF<Input, Output>(
        _ op: ReflectiveOperation<Input>
    ) -> ReflectiveGen<Input, Output> {
        return .impure(operation: op) { result in
            guard let typedResult = result as? Output else {
                fatalError("Interpreter provided wrong type. Expected \(Output.self), got \(type(of: result))")
            }
            return .pure(typedResult)
        }
    }
    
    static func pick<Output>(
        choices: [(weight: Int, choice: String?, generator: ReflectiveGen<Void, Output>)]
    ) -> ReflectiveGen<Void, Output> {
        // The nested generators must all have the same Output type.
        // We erase it to `Any` for the operation, but the `liftF` call
        // ensures the final monad has the correct `Output` type.
        let erasedChoices = choices.map { ($0.weight, $0.choice, $0.generator.map { $0 as Any }) }
        return liftF(.pick(choices: erasedChoices))
    }
    
    static func prune<Input, Output>(_ generator: ReflectiveGen<Input, Output>) -> ReflectiveGen<Optional<Input>, Output> {
        // The implementation is very similar to lmap: it uses mapOperation to erase
        // the input type and wraps the generator in the .prune operation.
        let erasedGenerator = generator.mapOperation(eraseInputType).map { $0 as Any }
        
        let op = ReflectiveOperation<Optional<Input>>.prune(next: erasedGenerator)
        
        return liftF(op)
    }
    
    // The transformation function that changes the Operation's Input type to Any.
    // This function needs to be defined recursively for the `.pick` case.
    static func eraseInputType<Input>(from op: ReflectiveOperation<Input>) -> ReflectiveOperation<Any> {
        switch op {
        case .pick(let choices):
            let result = choices.map { ($0.weight, $0.choice, $0.generator.mapOperation(eraseInputType(from:))) }
            return .pick(choices: result)
        case let .prune(next):
            return .prune(next: next)
        case .lmap(let transform, let next):
            // This case is tricky because it's already partially erased.
            // A simple way to handle it is to create a new transform from Any.
            // Note: This reveals a slight awkwardness in the enum design, but it works.
            let newTransform: (Any) -> Any = { anyInput in
                guard let typedInput = anyInput as? Input else {
                    fatalError("Type mismatch during lmap erasure.")
                }
                return transform(typedInput)
            }
            return .lmap(transform: newTransform, next: next)
        case .getSize:
            return .getSize
        case let .resize(to, next):
            let newNext = next.mapOperation(eraseInputType(from:))
            return .resize(to: to, next: newNext)
        }
    }
    
    static func lmap<NewInput, Input, Output>(_ transform: @escaping (NewInput) -> Input, _ generator: ReflectiveGen<Input, Output>) -> ReflectiveGen<NewInput, Output> {
        
        let erasedTransform: (NewInput) -> Any = { newInput in
            transform(newInput) as Any
        }
        
        let erasedGen = generator
            .mapOperation { eraseInputType(from: $0) }
            .map { $0 as Any }

        return .impure(operation: ReflectiveOperation.lmap(transform: erasedTransform, next: erasedGen)) { _ in
            // This continuation should not be called in a correct interpreter for lmap
            fatalError("Lmap's continuation should be handled by the interpreter.")
        }
    }
    
    static func comap<NewInput, Input, Output>(
        _ transform: @escaping (NewInput) -> Input?,
        _ generator: ReflectiveGen<Input, Output>
    ) -> ReflectiveGen<NewInput, Output> {
        
        let lmapGen = lmap({ (input: NewInput) -> Input? in
            transform(input)
        }, prune(generator))
        
        return lmapGen
    }
    
    // A base generator that produces a single, constant value.
    static func just<Output>(_ value: Output) -> ReflectiveGen<Any, Output> {
        return .pure(value)
    }

    // exact is the canonical leaf generator. It generates a constant value and, crucially, in the backward pass, it fails if the input doesn't match that constant.
    static func exact<Value: Equatable>(_ value: Value) -> ReflectiveGen<Value, Value> {
        // 1. Start with a generator that just produces the value.
        let baseGenerator = just(value)
        
        // 2. Use `comap` to check for equality.
        // The transform returns the value if it matches, or nil otherwise.
        return comap({ (inputValue: Value) -> Value? in
            inputValue == value ? inputValue : nil
        }, baseGenerator)
    }
    
    /// Creates a generator that produces the current size from the interpreter's context.
    static func getSize() -> ReflectiveGen<Void, Int> {
        liftF(.getSize)
    }
    
    /// Creates a generator that runs a sub-generator within a context with a new size.
    static func resize<Input, Output>(to size: Int, _ generator: ReflectiveGen<Input, Output>) -> ReflectiveGen<Input, Output> {
        // Wrap the provided generator in the resize operation.
        let op = ReflectiveOperation<Input>.resize(to: size, next: generator.map { $0 as Any })
        
        // The continuation simply passes through the result of the inner generator.
        return liftF(op)
    }
}
