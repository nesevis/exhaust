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
    
    static func lens<Input, Output, NewInput>(
        into path: some PartialPath<NewInput, Input>,
        _ next: ReflectiveGen<Input, Output>
    ) -> ReflectiveGen<Any, Output> {
        comap(path.extract(from:), next)
            .mapOperation(eraseInputType(from:))
    }
    
    static func pick<Input, Output>(
        choices: [(weight: UInt64, generator: ReflectiveGen<Input, Output>)]
    ) -> ReflectiveGen<Input, Output> {
        // The nested generators must all have the same Output type.
        // We erase it to `Any` for the operation, but the `liftF` call
        // ensures the final monad has bthe correct `Output` type.
        let erasedChoices = zip(choices, UInt64(1)...).map { ($0.0.weight, $0.1, $0.0.generator.map { $0 as Any }) }
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
            let result = choices.map { ($0.weight, $0.label, $0.generator.mapOperation(eraseInputType(from:))) }
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
        case let .lens(path, next):
            return .lens(path, next: next.mapOperation(eraseInputType(from:)))
        case let .chooseBits(min, max):
            return .chooseBits(min: min, max: max)
        case let .sequence(length, gen):
            return .sequence(length: length, gen: gen.mapOperation(eraseInputType(from:)))
        }
    }
    
//    static func choose<Input, Output: BitPatternConvertible & Strideable>(
//        in range: Range<Output>,
//        input: Input.Type = Input.self
//    ) -> ReflectiveGen<Input, Output> where Output.Stride : SignedInteger {
//        
//        // 1. Determine the effective upper bound. For a range `a..<b`, the last
//        //    integer value is `b - 1`. The `advanced(by: -1)` method is the
//        //    generic way to do this for any Strideable type.
//        let inclusiveUpperBound = range.upperBound.advanced(by: -1)
//        
//        // 2. Check that the resulting range is valid.
//        precondition(range.lowerBound <= inclusiveUpperBound, "The range is empty or invalid")
//        
//        // 3. Create a new *ClosedRange* from the calculated bounds.
//        let inclusiveRange = range.lowerBound...inclusiveUpperBound
//        
//        // 4. Delegate to the existing `choose(in: ClosedRange<T>)` function.
//        //    This avoids code duplication and keeps the core logic in one place.
//        return choose(in: inclusiveRange)
//    }
    
    static func choose<Input, Output: BitPatternConvertible>(in range: ClosedRange<Output>? = nil, type: Output.Type = Output.self, input: Input.Type = Input.self) -> ReflectiveGen<Input, Output> {
        
        // 1. Determine the range of raw UInt64 bits to generate.
        //    This logic delegates the responsibility of defining the range to the type `T` itself.
        //    For example, for `Int`, this will now be the full `UInt64` range to support negatives.
        let minBits = range?.lowerBound.bitPattern64 ?? Output.bitPatternRange.lowerBound
        let maxBits = range?.upperBound.bitPattern64 ?? Output.bitPatternRange.upperBound

        // 2. Create the unified, type-agnostic operation. The interpreter only needs to know
        //    how to generate a UInt64 within these bounds.
        let op = ReflectiveOperation<Input>.chooseBits(min: minBits, max: maxBits)
        
        // 3. Construct the FreerMonad by embedding the type-specific decoding logic
        //    inside the continuation. This is the core of the design.
        return .impure(operation: op) { result in
            // a. The interpreter will execute the operation and pass the raw `UInt64` result here.
            guard let convertible = result as? (any BitPatternConvertible) else {
                // This signifies a bug in the interpreter, not user code.
                fatalError("Interpreter failed to provide a UInt64 for a chooseBits operation.")
            }
            
            // b. The continuation uses the protocol's required initializer to convert the
            //    raw bits back into the final, strongly-typed `T`. This is where the
            //    magic of two's complement or IEEE 754 happens, specific to type `T`.
            // Kolbu: This works both in generate and reflect
            let finalValue = Output(bitPattern: convertible.bitPattern64)
            
            // c. Wrap the final value in `.pure` to complete this branch of the monadic computation.
            return .pure(finalValue)
        }
    }
    
    static func lmap<NewInput, Input, Output>(_ transform: @escaping (NewInput) -> Input, _ generator: ReflectiveGen<Input, Output>) -> ReflectiveGen<NewInput, Output> {
        
        let erasedTransform: (Any) -> Any = { newInput in
            return transform(newInput as! NewInput) as Any
        }
        
        let erasedGen = generator
            .mapOperation { eraseInputType(from: $0) }
            .map { $0 as Any }

        return .impure(operation: ReflectiveOperation.lmap(transform: erasedTransform, next: erasedGen)) { result in
            if let typed = result as? Output {
                // Forward pass
                return .pure(typed)
                
            } else if let gen = result as? ReflectiveGen<NewInput, Any> {
                // Backward pass
                return gen.map { $0 as! Output }
            }
            fatalError("Interpreter error in handling of Op.lens case")
        }
    }
    
    static func comap<NewInput, Input, Output>(
        _ transform: @escaping (NewInput) -> Input?,
        _ generator: ReflectiveGen<Input, Output>
    ) -> ReflectiveGen<NewInput, Output> {
        lmap(transform, prune(generator))
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
    
    /// Creates a generator for an array of random values.
    ///
    /// This implementation is stack-safe and can generate very large arrays without overflowing.
    /// It works by first generating a random length, then using a primitive `.sequence` operation
    /// which the interpreter can execute iteratively.
    ///
    /// - Parameters:
    ///   - elementGenerator: A self-contained (`<Void, Element>`) generator for the elements of the array.
    ///   - lengthRange: The desired range for the array's length. Defaults to `0...size`.
    /// - Returns: A generator that produces an array of elements.
    public static func arrayOf<Input, Output>(
        _ elementGenerator: ReflectiveGen<Input, Output>,
        _ length: UInt64
    ) -> ReflectiveGen<Input, [Output]> {
        // 2. Use `bind` to get the result of the length generator.
        let sequenceOp = ReflectiveOperation<Input>.sequence(
            length: length,
            gen: elementGenerator.map { $0 as Any }
        )
        // 4. Lift the operation. The continuation will decode the `[Any]` result.
        return .impure(operation: sequenceOp) { result in
            guard let array = result as? [Output] else {
                fatalError("Oh no!")
            }
            return .pure(array)
        }
    }
}
