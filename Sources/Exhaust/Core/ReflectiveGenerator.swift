
/// A declarative, bidirectional generator for property-based testing that supports
/// generation, reflection, and replay operations through a unified interface.
///
/// `ReflectiveGenerator` is the core abstraction that enables powerful property-based testing
/// capabilities. Unlike traditional generators that execute immediately, it builds an inert
/// data structure describing the generation process, which can then be interpreted in multiple ways.
///
/// ## Architecture: The Freer Monad Pattern
///
/// `ReflectiveGenerator` is implemented as a type alias for `FreerMonad<ReflectiveOperation<Input>, Output>`.
/// This design separates the description of generation from its execution, enabling multiple interpretations
/// of the same generator structure. Each generator either contains a pure value (`.pure`) or a suspended
/// operation with a continuation (`.impure`).
///
/// ## Three Modes of Operation
///
/// The declarative nature enables three distinct but related operations:
///
/// ### 1. Generation (Forward Pass)
/// **Purpose:** Produce random values using entropy
/// **Input:** Random number generator + optional input context
/// **Output:** A randomly generated value of type `Output`
/// **Usage:** `Interpreters.generate(generator, using: rng)`
///
/// During generation, operations are executed with randomness:
/// - `chooseBits`: Generates random UInt64 within range
/// - `pick`: Selects one branch based on weights
/// - `sequence`: Generates arrays by repeating element generation
/// - `lmap`/`prune`: Transform or filter input context
///
/// ### 2. Reflection (Backward Pass)
/// **Purpose:** Deconstruct a value into possible generation paths
/// **Input:** A concrete value to analyze
/// **Output:** `ChoiceTree` representing all ways the value could have been generated
/// **Usage:** `Interpreters.reflect(generator, with: value)`
///
/// During reflection, operations work backwards from the target:
/// - `chooseBits`: Checks if value's bit pattern falls within range
/// - `pick`: Tries all branches against the target value
/// - `sequence`: Decomposes arrays into element-by-element paths
/// - `lmap`/`prune`: Transforms target through lens or checks optionality
///
/// ### 3. Replay (Deterministic Forward Pass)
/// **Purpose:** Recreate exact values from recorded choice paths
/// **Input:** `ChoiceTree` from reflection
/// **Output:** Deterministically reconstructed value
/// **Usage:** `Interpreters.replay(generator, using: choiceTree)`
///
/// During replay, operations consume pre-recorded choices:
/// - `chooseBits`: Uses recorded bit pattern from choice tree
/// - `pick`: Follows recorded branch selection
/// - `sequence`: Replays each element using recorded sub-trees
/// - `lmap`/`prune`: Passes through recorded decisions
///
/// ## Generic Parameters
///
/// - **`Input`**: External context type that generators can depend on. Used primarily
///   in reflection to provide the value being deconstructed. For self-contained generators,
///   this is typically `Void` or `Any`. Modified via `Gen.lmap` and `Gen.comap`.
///
/// - **`Output`**: The type of value this generator produces. All paths through the
///   generator must ultimately yield this type.
///
/// ## Construction and Usage
///
/// **Never construct directly** - use the `Gen` enum's smart constructors:
///
/// ```swift
/// // Basic value generation
/// let intGen = Gen.choose(in: 1...100)
/// let boolGen = Gen.pick(choices: [(1, Gen.just(true)), (1, Gen.just(false))])
///
/// // Context-dependent generation
/// let userAgeGen: ReflectiveGenerator<User, Int> = Gen.lmap(\.age, Gen.choose(in: 18...65))
///
/// // Composite generation
/// let arrayGen = Gen.arrayOf(intGen, 5)
/// ```
///
/// **Execution requires interpretation:**
///
/// ```swift
/// // Generate random values
/// let value = Interpreters.generate(intGen)
///
/// // Reflect on existing values
/// let choiceTree = Interpreters.reflect(intGen, with: 42)
///
/// // Replay from recorded choices
/// let recreated = Interpreters.replay(intGen, using: choiceTree)
/// ```
///
/// ## Shrinking Integration
///
/// The three-way relationship between generation, reflection, and replay enables
/// sophisticated test case shrinking:
///
/// 1. **Generate** a random failing test case
/// 2. **Reflect** to discover all possible generation paths
/// 3. **Generate shrink candidates** from the `ChoiceTree`
/// 4. **Replay** each candidate to test if it still fails
/// 5. **Repeat** with the smallest failing case
///
/// This bidirectional approach ensures that shrunk test cases are always valid
/// according to the original generator's constraints.
///
/// - SeeAlso: `ReflectiveOperation`, `Gen`, `Interpreters`, `ChoiceTree`
typealias ReflectiveGenerator<Input, Output> = FreerMonad<ReflectiveOperation<Input>, Output>

typealias AlignedReflectiveGenerator<Value> = ReflectiveGenerator<Value, Value>

extension ReflectiveGenerator where Operation: AnyReflectiveOperation {
    var isLens: Bool {
        switch self {
        case .pure:
            return false
        case let .impure(op, _):
            if let castOp = op as? ReflectiveOperation<Operation.Input>, case .lmap = castOp {
                return true
            }
            return false
        }
    }
    
    var associatedRange: ClosedRange<UInt64>? {
        switch self {
        case .pure:
            return nil
        case let .impure(op, _):
            return op.associatedRange
        }
    }
}

extension ReflectiveGenerator {
    
    func mapOperation<NewOperation>(_ transform: @escaping (Operation) -> NewOperation) -> FreerMonad<NewOperation, Value> {
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
                continuation(val).mapOperation(transform)
            }
            
            // 3. Return a new impure case with the transformed operation and continuation.
            return .impure(operation: newOperation, continuation: newContinuation)
        }
    }
}
