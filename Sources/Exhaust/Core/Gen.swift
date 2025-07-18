enum Gen {
    static func liftF<Input, Output>(
        _ op: ReflectiveOperation<Input>
    ) -> ReflectiveGenerator<Input, Output> {
        return .impure(operation: op) { result in
            guard let typedResult = result as? Output else {
                fatalError("Interpreter provided wrong type. Expected \(Output.self), got \(type(of: result))")
            }
            return .pure(typedResult)
        }
    }
    
    static func lens<Input, NewInput>(
        extract path: some PartialPath<NewInput, Input>,
        _ next: ReflectiveGenerator<Any, Input>
    ) -> ReflectiveGenerator<Any, Input> {
        comap(path.extract(from:), next)
    }
    
    static func pick<Input, Output>(
        choices: [(weight: UInt64, generator: ReflectiveGenerator<Input, Output>)]
    ) -> ReflectiveGenerator<Input, Output> {
        // The nested generators must all have the same Output type.
        // We erase it to `Any` for the operation, but the `liftF` call
        // ensures the final monad has bthe correct `Output` type.
        let erasedChoices = zip(choices, UInt64(1)...).map { ($0.0.weight, $0.1, $0.0.generator.map { $0 as Any }) }
        return liftF(.pick(choices: erasedChoices))
    }
    
    static func prune<Input, Output>(_ generator: ReflectiveGenerator<Input, Output>) -> ReflectiveGenerator<Optional<Input>, Output> {
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
        case let .pick(choices):
            let result = choices.map { ($0.weight, $0.label, $0.generator.mapOperation(eraseInputType(from:))) }
            return .pick(choices: result)
        case let .prune(next):
            return .prune(next: next)
        case let .lmap(transform, next):
            // This case is tricky because it's already partially erased.
            // A simple way to handle it is to create a new transform from Any.
            // Note: This reveals a slight awkwardness in the enum design, but it works.
            let newTransform: (Any) -> Any = { anyInput in
                guard let typedInput = anyInput as? Input else {
                    fatalError("Type mismatch during lmap erasure.")
                }
                return transform(typedInput) ?? ()
            }
            return .lmap(transform: newTransform, next: next)
        case let .chooseBits(min, max):
            return .chooseBits(min: min, max: max)
        case let .sequence(length, gen):
            return .sequence(
                length: length.mapOperation(eraseInputType(from:)),
                gen: gen.mapOperation(eraseInputType(from:))
            )
        case let .just(value):
            return .just(value as Any)
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
    
    static func choose<Input, Output: BitPatternConvertible>(in range: ClosedRange<Output>? = nil, type: Output.Type = Output.self, input: Input.Type = Input.self) -> ReflectiveGenerator<Input, Output> {
        
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
            var convertibleValue: (any BitPatternConvertible)?
            if let convertible = result as? (any BitPatternConvertible) {
                convertibleValue = convertible
            }
            else if let convertible = result as? (any Sequence) {
                convertibleValue = convertible.underestimatedCount
            }
            
            if let convertibleValue {
                return .pure(Output(bitPattern: convertibleValue.bitPattern64))
            } else {
                fatalError("Interpreter failed to provide a UInt64 for a chooseBits operation.")
            }
//            guard let convertible = result as? (any BitPatternConvertible) else {
//                // This signifies a bug in the interpreter, not user code.
//            }
            
            // b. The continuation uses the protocol's required initializer to convert the
            //    raw bits back into the final, strongly-typed `T`. This is where the
            //    magic of two's complement or IEEE 754 happens, specific to type `T`.
            // Kolbu: This works both in generate and reflect
//            let finalValue = Output(bitPattern: convertible.bitPattern64)
            
            // c. Wrap the final value in `.pure` to complete this branch of the monadic computation.
//            return .pure(finalValue)
        }
    }
    
    static func lmap<NewInput, Input, Output>(_ transform: @escaping (NewInput) -> Input, _ generator: ReflectiveGenerator<Input, Output>) -> ReflectiveGenerator<NewInput, Output> {
        
        let erasedTransform: (Any) -> Any = { newInput in
            return transform(newInput as! NewInput) as Any
        }
        
        let erasedGen = generator
            .mapOperation { eraseInputType(from: $0) }
            .map { $0 as Any }

        return .impure(operation: ReflectiveOperation.lmap(transform: erasedTransform, next: erasedGen)) { result in
            if let typed = result as? Output {
                // Forward pass - direct value
                return .pure(typed)
                
            } else if let gen = result as? ReflectiveGenerator<NewInput, Any> {
                // Backward pass - generator
                return gen.map { $0 as! Output }
                
            } else {
                // Backward pass - raw value that needs to be converted
                // This handles cases where replay provides a raw value instead of a generator
                // Try to convert the raw value to the expected output type
                if let convertedValue = result as? Output {
                    return .pure(convertedValue)
                }
                fatalError("Interpreter error in handling of Op.lmap case: unexpected result type \(type(of: result))")
            }
        }
    }
    
    static func comap<NewInput, Input, Output>(
        _ transform: @escaping (NewInput) -> Input?,
        _ generator: ReflectiveGenerator<Input, Output>
    ) -> ReflectiveGenerator<NewInput, Output> {
        lmap(transform, prune(generator))
    }
    
    // A base generator that produces a single, constant value.
    static func just<Output>(_ value: Output) -> ReflectiveGenerator<Any, Output> {
        // 1. Create the specific `.just` operation, erasing the value's type for storage.
        let op = ReflectiveOperation<Output>.just(value)
        
        return liftF(op)
            .mapOperation(eraseInputType(from:))
    }


    // exact is the canonical leaf generator. It generates a constant value and, crucially, in the backward pass, it fails if the input doesn't match that constant.
    static func exact<Value: Equatable>(_ value: Value) -> ReflectiveGenerator<Value, Value> {
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
        _ elementGenerator: ReflectiveGenerator<Input, Output>,
        _ length: ReflectiveGenerator<Input, UInt64>
    ) -> ReflectiveGenerator<Input, [Output]> {
        // 2. Use `bind` to get the result of the length generator.
        let sequenceOp = ReflectiveOperation<Input>.sequence(
            length: length,
            gen: elementGenerator.map { $0 as Any }
        )
        // 4. Lift the operation. The continuation will decode the `[Any]` result.
        return .impure(operation: sequenceOp) { result in
            let array = result as! [Output]
//            guard let array = result as! [Output] else {
//                fatalError("Oh no!")
//            }
            return .pure(array)
        }
    }
}
