public protocol AnyReflectiveOperation {
//    associatedtype Input
    var associatedRange: ClosedRange<UInt64>? { get }
}

/// The primitive operations that can be performed by the reflective generator system.
/// These operations are only generic over their input types - the output type is managed
/// by the continuation in the containing `ReflectiveGen` to enable the Freer Monad pattern.
public enum ReflectiveOperation {
    /// Transforms the input type of a generator using a lens-like function.
    /// Used by `Gen.lmap` and `Gen.comap` to focus on a specific part of the input.
    /// In the forward pass (generate), the transform is ignored.
    /// In the backward pass (reflect), the transform extracts the relevant part from the target value.
    /// Type erasure is required because Swift enums can't change type parameters across cases.
    case lmap(transform: (Any) throws -> Any?, next: ReflectiveGenerator<Any, Any>)
    
    /// Represents a weighted choice between multiple generators.
    /// Used by `Gen.pick` to select one of several possible generation strategies.
    /// Each choice has a weight (for random selection), a label (for replay), and a generator.
    /// In the forward pass, one choice is selected randomly based on weights.
    /// In the backward pass, all choices are tried against the target value.
    case pick(choices: [(weight: UInt64, label: UInt64, generator: ReflectiveGenerator<Any, Any>)])
    
    /// Handles conditional generation based on optional input values.
    /// Used by `Gen.prune` and `Gen.comap` to filter out invalid inputs.
    /// In the forward pass, generation fails if the input is nil.
    /// In the backward pass, the wrapped generator is tried with the unwrapped target.
    /// Type erasure is needed to handle the Optional<Input> -> Input transformation.
    case prune(next: ReflectiveGenerator<Any, Any>)
    
    /// Generates raw bit patterns within a specified range.
    /// Used by `Gen.choose` as the primitive random number generation operation.
    /// The continuation handles converting the raw UInt64 bits into the desired type.
    /// This unified approach supports all BitPatternConvertible types (Int, Float, etc.).
    case chooseBits(min: UInt64, max: UInt64)
    
    /// Generates a Character from Unicode scalar values.
    /// Used specifically for Character generation to preserve exact representation.
    /// Stores the complete Unicode scalar array to avoid normalization issues.
    case chooseCharacter(min: UInt64, max: UInt64)
    
    /// Generates a sequence of values using a repeated element generator.
    /// Used by `Gen.arrayOf` to create arrays of random length and content.
    /// The length is fixed at operation creation time, and the element generator
    /// is applied iteratively to build the complete sequence.
    case sequence(length: ReflectiveGenerator<Any, UInt64>, gen: ReflectiveGenerator<Any, Any>)
    
    /// A constant value baked into the generator
    case just(Any)
    
    /// Retrieves the current size parameter controlling generator complexity.
    /// Used to scale generation based on test progression (smaller early, larger later).
    /// The continuation receives the current size as a UInt64 value.
    case getSize
    
    /// Temporarily modifies the size parameter for a nested generator.
    /// Used to control complexity of sub-generators (e.g., making smaller arrays).
    /// The nested generator runs with the new size, then the original size is restored.
    case resize(newSize: UInt64, next: ReflectiveGenerator<Any, Any>)
}

extension ReflectiveOperation: AnyReflectiveOperation {
    public var associatedRange: ClosedRange<UInt64>? {
        switch self {
        case .chooseBits(let min, let max):
            return min...max
        case .chooseCharacter(let min, let max):
            return min...max
        default:
            return nil
        }
    }
}
