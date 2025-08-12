public enum Gen {
    @inlinable
    public static func liftF<Output>(
        _ op: ReflectiveOperation
    ) -> ReflectiveGenerator<Output> {
        .impure(operation: op) { result in
            if let typedResult = result as? Output {
                return .pure(typedResult)
            }
            throw Interpreters.ReflectionError.reflectedNil(type: String(describing: Output.self))
        }
    }
    
    @inlinable
    static func lens<Input, NewInput>(
        extract path: some PartialPath<NewInput, Input>,
        _ next: ReflectiveGenerator<Input>
    ) -> ReflectiveGenerator<Input> {
        comap(path.extract(from:), next)
    }
    
    @inlinable
    public static func pick<Output>(
        choices: [(weight: UInt64, generator: ReflectiveGenerator<Output>)]
    ) -> ReflectiveGenerator<Output> {
        precondition(choices.isEmpty == false, "At least one choice must be provided")
        // The nested generators must all have the same Output type.
        // We erase it to `Any` for the operation, but the `liftF` call
        // ensures the final monad has the correct `Output` type.
        var array: [(weight: UInt64, label: UInt64, generator: ReflectiveGenerator<Any>)] = []
        array.reserveCapacity(choices.count)
        
        for (index, choice) in choices.enumerated() {
            array.append((
                weight: choice.weight,
                label: UInt64(index) + 1,
                generator: choice.generator.erase()
            ))
        }
        return liftF(.pick(choices: array))
    }
    
    @inlinable
    static func prune<Output>(_ generator: ReflectiveGenerator<Output>) -> ReflectiveGenerator<Output> {
        liftF(.prune(next: generator.erase()))
    }
    
    @inlinable
    static func chooseCharacter(in range: ClosedRange<UInt64>? = nil) -> ReflectiveGenerator<Character> {
        // Default to the lower range
        let actualRange = range ?? Character.bitPatternRanges[0]
        let op = ReflectiveOperation.chooseBits(
            min: actualRange.lowerBound,
            max: actualRange.upperBound,
            type: .character
        )
        
        return .impure(operation: op) { result in
            if let character = result as? UInt64 {
                return .pure(Character(bitPattern64: character))
            } else if let character = result as? Character {
                // Not sure this is ever hit
                return .pure(character)
            } else if let optional = result as? Optional<Character>, optional == nil {
                throw Interpreters.ReflectionError.reflectedNil(type: String(describing: Character.self))
            } else {
                throw GeneratorError.typeMismatch(expected: "Character", actual: String(describing: type(of: result)))
            }
        }
    }
    
    @inlinable
    public static func choose<Output: BitPatternConvertible>(in range: ClosedRange<Output>? = nil, type: Output.Type = Output.self) -> ReflectiveGenerator<Output> {
        let minBits = range?.lowerBound.bitPattern64 ?? Output.bitPatternRanges[0].lowerBound
        let maxBits = range?.upperBound.bitPattern64 ?? Output.bitPatternRanges[0].upperBound

        let sentinel: ChoiceValue.TypeSentinel = switch Output.self {
        case is Double.Type:
                .double
        case is Int.Type:
                .int
        case is UInt.Type:
                .uint
        // More specific, less likely to be used
        case is Float.Type:
                .float
        case is Int64.Type:
                .int64
        case is Int32.Type:
                .int32
        case is Int16.Type:
                .int16
        case is Int8.Type:
                .int8
        case is UInt64.Type:
                .uint64
        case is UInt32.Type:
                .uint32
        case is UInt16.Type:
                .uint16
        case is UInt8.Type:
                .uint8
        case is Character.Type:
                .character // This is handled by `chooseCharacter`
        default:
            fatalError("Unexpected type passed to \(#function): \(Output.self)")
        }
        
        return .impure(operation: .chooseBits(min: minBits, max: maxBits, type: sentinel)) { result in
            switch sentinel {
            case .uint64:
                // This catches [Character] and String
                if let sequence = result as? any Sequence {
                    return .pure(UInt64(sequence.underestimatedCount) as! Output)
                }
                return .pure(result as! Output)
            default:
                guard let convertible = result as? any BitPatternConvertible else {
                    throw GeneratorError.typeMismatch(
                        expected: "any BitPatternConvertible",
                        actual: String(describing: Swift.type(of: result))
                    )
                }
                return .pure(Output(bitPattern64: convertible.bitPattern64))
            }
        }
    }
    
    @inlinable
    static func lmap<NewInput, Input, Output>(_ transform: @escaping (NewInput) throws -> Input, _ generator: ReflectiveGenerator<Output>) -> ReflectiveGenerator<Output> {
        
        return .impure(operation: ReflectiveOperation.lmap(
            // This is where the backwards pass happens
            transform: {
                // Handle optional inputs
                try transform($0 as! NewInput) as Any
            },
            next: generator.erase()
        )) { result in
            if let typed = result as? Output {
                // Backward pass - direct value
                return .pure(typed)
            }
            if let optional = result as? Optional<Output>, optional == nil {
                throw Interpreters.ReflectionError.reflectedNil(type: String(describing: Output.self))
            }
            throw GeneratorError.typeMismatch(
                expected: String(describing: Output.self),
                actual: String(describing: type(of: result))
            )
        }
    }
    
    @inlinable
    static func comap<NewInput, Input, Output>(
        _ transform: @escaping (NewInput) throws -> Input?,
        _ generator: ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        lmap(transform, prune(generator))
    }
    
    // A base generator that produces a single, constant value.
    @inlinable
    static func just<Output>(_ value: Output) -> ReflectiveGenerator<Output> {
        liftF(.just(value))
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
    @inlinable
    static func exact<Value: Equatable>(_ value: Value) -> ReflectiveGenerator<Value> {
        // Use lmap with a transform that validates the target value during reflection.
        // The transform returns nil for mismatches, causing reflection to fail.
        let baseGenerator = just(value as Any)
        
        let transform: (Any) -> Any? = { inputValue in
            guard let typedInput = inputValue as? Value, typedInput == value else {
                return nil  // Reflection fails for non-matching values
            }
            return typedInput
        }
        
        return liftF(.lmap(transform: transform, next: baseGenerator))
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
    @inlinable
    public static func arrayOf<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        _ length: ReflectiveGenerator<UInt64>? = nil
    ) -> ReflectiveGenerator<[Output]> {
        // 2. Use `bind` to get the result of the length generator.
        let sequenceOp = ReflectiveOperation.sequence(
            length: length ?? Gen.getSize().bind {
                Gen.choose(in: ($0 / 10)...$0)
            },
            gen: elementGenerator.erase()
        )
        // 4. Lift the operation. The continuation will decode the `[Any]` result.
        return .impure(operation: sequenceOp) { result in
            guard let array = result as? [Output] else {
                throw GeneratorError.typeMismatch(
                    expected: String(describing: type(of: [Output].self)),
                    actual: String(describing: type(of: result))
                )
            }
            return .pure(array)
        }
    }
    
    @inlinable
    public static func arrayOf<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        within range: ClosedRange<UInt64>
    ) -> ReflectiveGenerator<[Output]> {
        // 2. Use `bind` to get the result of the length generator.
        let sequenceOp = ReflectiveOperation.sequence(
            length: Gen.getSize().bind { size in
                if range.contains(size) {
                    return Gen.choose(in: size...size)
                }
                return Gen.choose(in: range)
                
            },
            gen: elementGenerator.erase()
        )
        // 4. Lift the operation. The continuation will decode the `[Any]` result.
        return .impure(operation: sequenceOp) { result in
            let array = result as! [Output]
            return .pure(array)
        }
    }
    
    @inlinable
    public static func arrayOf<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        exactly: UInt64
    ) -> ReflectiveGenerator<[Output]> {
        arrayOf(elementGenerator, .pure(exactly))
    }
    
    @inlinable
    public static func dictionaryOf<KeyOutput: Hashable, ValueOutput>(
        _ keyGenerator: ReflectiveGenerator<KeyOutput>,
        _ valueGenerator: ReflectiveGenerator<ValueOutput>
    ) -> ReflectiveGenerator<[KeyOutput: ValueOutput]> {
        Gen.zip(
            // These arrays use `getSize()` under the hood and will be the same length
            Gen.arrayOf(keyGenerator),
            Gen.arrayOf(valueGenerator)
        )
        .mapped(
            forward: {
                Dictionary(
                    Swift.zip($0.0, $0.1).map { ($0.0, $0.1) },
                    uniquingKeysWith: { key, _ in key }
                )
            },
            backward: { (Array($0.keys), Array($0.values)) }
        )
    }
    
    /// Retrieves the current size parameter controlling generator complexity.
    /// The size typically grows as tests progress, allowing generators to produce
    /// more complex values over time.
    @inlinable
    public static func getSize() -> ReflectiveGenerator<UInt64> {
        .impure(operation: .getSize) { result in
            if let typedResult = result as? UInt64 {
                return .pure(typedResult)
            }
            throw GeneratorError.typeMismatch(
                expected: "\(UInt64.self)",
                actual: String(describing: type(of: result))
            )
        }
    }
    
    /// Creates a generator with a temporarily modified size parameter.
    /// This is useful for controlling the complexity of nested generators.
    /// 
    /// - Parameters:
    ///   - newSize: The size parameter to use for the nested generator
    ///   - generator: The generator to run with the modified size
    /// - Returns: A generator that runs with the specified size
    @inlinable
    public static func resize<Output>(
        _ newSize: UInt64,
        _ generator: ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        // TODO: We're not handling resize correctly anymore
        liftF(.resize(newSize: newSize, next: generator.erase()))
    }
    
    /// Creates an array generator whose length is controlled by the current size parameter.
    /// This is a convenience method that combines `getSize` with `arrayOf` to create
    /// arrays that grow in complexity as tests progress.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for array elements
    ///   - lengthRange: Optional range to constrain the array length. If nil, uses 0...size
    /// - Returns: A generator that produces arrays with size-controlled length
    @inlinable
    public static func sized<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        lengthRange: ClosedRange<UInt64>? = nil
    ) -> ReflectiveGenerator<[Output]> {
        getSize().bind { size in
            let actualRange = lengthRange ?? (0...size)
            let clampedMin = max(actualRange.lowerBound, 0)
            let clampedMax = min(actualRange.upperBound, size)
            let finalRange = clampedMin...clampedMax

            return arrayOf(elementGenerator, choose(in: finalRange))
        }
    }
}
