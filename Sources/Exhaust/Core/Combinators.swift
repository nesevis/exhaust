enum Gen {
    static func liftF<Input, Output>(
        _ op: ReflectiveOperation<Input>
    ) -> ReflectiveGenerator<Input, Output> {
        return .impure(operation: op) { result in
            if let typedResult = result as? Output {
                return .pure(typedResult)
            }
            fatalError("Interpreter provided wrong type. Expected \(Output.self), got \(type(of: result))")
        }
    }
    
    static func lens<Input, NewInput>(
        extract path: some PartialPath<NewInput, Input>,
        _ next: ReflectiveGenerator<Any, Input>
    ) -> ReflectiveGenerator<Any, Input> {
        comap(path.extract(from:), next)
    }
    
    // We have to enforce equatable here so we can prune the pick in the reflection process
    static func pick<Input, Output: Equatable>(
        choices: [(weight: UInt64, generator: ReflectiveGenerator<Input, Output>)]
    ) -> ReflectiveGenerator<Input, Output> {
        // The nested generators must all have the same Output type.
        // We erase it to `Any` for the operation, but the `liftF` call
        // ensures the final monad has bthe correct `Output` type.
        let erasedChoices = Swift.zip(choices, UInt64(1)...).map { ($0.0.weight, $0.1, $0.0.generator.map { $0 as Any }) }
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
            let newTransform: (Any) throws -> Any = { anyInput in
                guard let typedInput = anyInput as? Input else {
                    fatalError("Type mismatch during lmap erasure.")
                }
                return try transform(typedInput) ?? ()
            }
            return .lmap(transform: newTransform, next: next)
        case let .chooseBits(min, max):
            return .chooseBits(min: min, max: max)
        case let .chooseCharacter(min, max):
            return .chooseCharacter(min: min, max: max)
        case let .sequence(length, gen):
            return .sequence(
                length: length.mapOperation(eraseInputType(from:)),
                gen: gen.mapOperation(eraseInputType(from:))
            )
        case let .just(value):
            return .just(value as Any)
        case .getSize:
            return .getSize
        case let .resize(newSize, next):
            return .resize(newSize: newSize, next: next.mapOperation(eraseInputType(from:)))
        }
    }
    
    static func chooseCharacter<Input>(in range: ClosedRange<UInt64>? = nil, input: Input.Type = Input.self) -> ReflectiveGenerator<Input, Character> {
        // Default to the lower range
        let actualRange = range ?? Character.bitPatternRanges[0]
        let op = ReflectiveOperation<Input>.chooseCharacter(min: actualRange.lowerBound, max: actualRange.upperBound)
        
        return .impure(operation: op) { result in
            if let character = result as? Character {
                return .pure(character)
            } else {
                fatalError("Interpreter failed to provide a Character for a chooseCharacter operation.")
            }
        }
    }
    
    static func choose<Input, Output: BitPatternConvertible>(in range: ClosedRange<Output>? = nil, type: Output.Type = Output.self, input: Input.Type = Input.self) -> ReflectiveGenerator<Input, Output> {
        
        // 1. Determine the range of raw UInt64 bits to generate.
        //    This logic delegates the responsibility of defining the range to the type `T` itself.
        //    For example, for `Int`, this will now be the full `UInt64` range to support negatives.
        let minBits = range?.lowerBound.bitPattern64 ?? Output.bitPatternRanges[0].lowerBound
        let maxBits = range?.upperBound.bitPattern64 ?? Output.bitPatternRanges[0].upperBound

        // 2. Create the unified, type-agnostic operation. The interpreter only needs to know
        //    how to generate a UInt64 within these bounds.
        let op = ReflectiveOperation<Input>.chooseBits(min: minBits, max: maxBits)
        
        // 3. Construct the FreerMonad by embedding the type-specific decoding logic
        //    inside the continuation. This is the core of the design.
        return .impure(operation: op) { result in
            // a. The interpreter will execute the operation and pass the raw `UInt64` result here.
            var convertibleValue: (any BitPatternConvertible)?
            // Forward pass
            if let convertible = result as? (any BitPatternConvertible) {
                convertibleValue = convertible
            }
            // Backward pass through reflect, passing a `ChoiceValue`
            else if let convertible = (result as? ChoiceValue)?.convertible {
                convertibleValue = convertible
            }
            // Forward pass, sequence
            else if let convertible = result as? (any Sequence) {
                convertibleValue = UInt64(convertible.underestimatedCount)
            }
            
            if let convertibleValue {
                return .pure(Output(bitPattern64: convertibleValue.bitPattern64))
            } else {
                fatalError("Interpreter failed to provide a UInt64 for a chooseBits operation.")
            }
        }
    }
    
    static func lmap<NewInput, Input, Output>(_ transform: @escaping (NewInput) throws -> Input, _ generator: ReflectiveGenerator<Input, Output>) -> ReflectiveGenerator<NewInput, Output> {
        
        let erasedTransform: (Any) throws -> Any = { newInput in
            return try transform(newInput as! NewInput) as Any
        }
        
        let erasedGen = generator
            .mapOperation { eraseInputType(from: $0) }
            .map { $0 as Any }

        return .impure(operation: ReflectiveOperation.lmap(transform: erasedTransform, next: erasedGen)) { result in
            if let typed = result as? Output {
                // Backward pass - direct value
                return .pure(typed)
                
            }
            fatalError("Interpreter error in handling of Op.lmap case: unexpected result type \(type(of: result))")
        }
    }
    
    static func comap<NewInput, Input, Output>(
        _ transform: @escaping (NewInput) throws -> Input?,
        _ generator: ReflectiveGenerator<Input, Output>
    ) -> ReflectiveGenerator<NewInput, Output> {
        lmap(transform, prune(generator))
    }
    
    // A base generator that produces a single, constant value.
    static func just<Output>(_ value: Output) -> ReflectiveGenerator<Any, Output> {
        liftF(ReflectiveOperation<Output>.just(value))
            .mapOperation(eraseInputType(from:))
    }


    /// Creates a generator that produces an exact constant value with validation during reflection.
    ///
    /// **Key difference from `Gen.just`:**
    /// - **`Gen.just`**: Always succeeds during reflection regardless of target value
    /// - **`Gen.exact`**: Only succeeds during reflection if target value exactly matches the constant
    ///
    /// **Forward pass (generation):** Always produces the constant value
    /// **Backward pass (reflection):** Fails if the target value doesn't match exactly
    ///
    /// This validation behavior makes `Gen.exact` essential for property-based testing
    /// where you need to verify that generated structures contain specific expected values.
    ///
    /// - Parameter value: The constant value to generate and validate against
    /// - Returns: A generator that produces the constant and validates during reflection
    static func exact<Value: Equatable>(_ value: Value) -> ReflectiveGenerator<Value, Value> {
        // Use lmap with a transform that validates the target value during reflection.
        // The transform returns nil for mismatches, causing reflection to fail.
        let baseGenerator = just(value).mapOperation(eraseInputType).map { $0 as Any }
        
        let transform: (Any) -> Any? = { inputValue in
            guard let typedInput = inputValue as? Value, typedInput == value else {
                return nil  // Reflection fails for non-matching values
            }
            return typedInput
        }
        
        return liftF(ReflectiveOperation<Value>.lmap(transform: transform, next: baseGenerator))
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
        _ length: ReflectiveGenerator<Input, UInt64>? = nil
    ) -> ReflectiveGenerator<Input, [Output]> {
        // 2. Use `bind` to get the result of the length generator.
        let sequenceOp = ReflectiveOperation<Input>.sequence(
            length: length ?? Gen.getSize().bind {
                Gen.choose(in: $0...$0)
            },
            gen: elementGenerator.map { $0 as Any }
        )
        // 4. Lift the operation. The continuation will decode the `[Any]` result.
        return .impure(operation: sequenceOp) { result in
            let array = result as! [Output]
            return .pure(array)
        }
    }
    
    public static func arrayOf<Input, Output>(
        _ elementGenerator: ReflectiveGenerator<Input, Output>,
        within range: ClosedRange<UInt64>
    ) -> ReflectiveGenerator<Input, [Output]> {
        // 2. Use `bind` to get the result of the length generator.
        let sequenceOp = ReflectiveOperation<Input>.sequence(
            length: Gen.getSize().bind { size in
                if range.contains(size) {
                    return Gen.choose(in: size...size)
                }
                return Gen.choose(in: range)
                
            },
            gen: elementGenerator.map { $0 as Any }
        )
        // 4. Lift the operation. The continuation will decode the `[Any]` result.
        return .impure(operation: sequenceOp) { result in
            let array = result as! [Output]
            return .pure(array)
        }
    }
    
    public static func arrayOf<Input, Output>(
        _ elementGenerator: ReflectiveGenerator<Input, Output>,
        exactly: UInt64
    ) -> ReflectiveGenerator<Input, [Output]> {
        // 2. Use `bind` to get the result of the length generator.
        let sequenceOp = ReflectiveOperation<Input>.sequence(
            length: .pure(exactly), // How do we wrap this in a Gen.just?
            gen: elementGenerator.map { $0 as Any }
        )
        // 4. Lift the operation. The continuation will decode the `[Any]` result.
        return .impure(operation: sequenceOp) { result in
            let array = result as! [Output]
            return .pure(array)
        }
    }
    
    /// Retrieves the current size parameter controlling generator complexity.
    /// The size typically grows as tests progress, allowing generators to produce
    /// more complex values over time.
    public static func getSize<Input>() -> ReflectiveGenerator<Input, UInt64> {
        return .impure(operation: .getSize) { result in
            if let typedResult = result as? UInt64 {
                return .pure(typedResult)
            }
            fatalError("Interpreter provided wrong type. Expected \(UInt64.self), got \(type(of: result))")
        }
    }
    
    /// Creates a generator with a temporarily modified size parameter.
    /// This is useful for controlling the complexity of nested generators.
    /// 
    /// - Parameters:
    ///   - newSize: The size parameter to use for the nested generator
    ///   - generator: The generator to run with the modified size
    /// - Returns: A generator that runs with the specified size
    public static func resize<Input, Output>(
        _ newSize: UInt64,
        _ generator: ReflectiveGenerator<Input, Output>
    ) -> ReflectiveGenerator<Input, Output> {
        let erasedGenerator = generator.map { $0 as Any }
        let op = ReflectiveOperation<Input>.resize(newSize: newSize, next: erasedGenerator)
        return liftF(op)
    }
    
    /// Creates an array generator whose length is controlled by the current size parameter.
    /// This is a convenience method that combines `getSize` with `arrayOf` to create
    /// arrays that grow in complexity as tests progress.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for array elements
    ///   - lengthRange: Optional range to constrain the array length. If nil, uses 0...size
    /// - Returns: A generator that produces arrays with size-controlled length
    public static func sized<Input, Output>(
        _ elementGenerator: ReflectiveGenerator<Input, Output>,
        lengthRange: ClosedRange<UInt64>? = nil
    ) -> ReflectiveGenerator<Input, [Output]> {
        getSize().bind { size in
            let actualRange = lengthRange ?? (0...size)
            let clampedMin = max(actualRange.lowerBound, 0)
            let clampedMax = min(actualRange.upperBound, size)
            let finalRange = clampedMin...clampedMax
            
            let lengthGen = choose(in: finalRange, input: Input.self)
            return arrayOf(elementGenerator, lengthGen)
        }
    }
}
