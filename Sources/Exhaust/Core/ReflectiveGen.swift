
/// A data structure that declaratively represents a bidirectional, property-based testing generator.
///
/// `ReflectiveGen` is the central type of the framework. It does not represent a function or an
/// executable action; instead, it is an inert, hierarchical data structure that **describes**
/// the steps required to generate a `Value`. This separation of description from execution is the
/// key to its power, allowing the structure to be "interpreted" in multiple ways.
///
///
/// ## The Core Concept: Description vs. Execution
///
/// Rather than executing code immediately, creating a `ReflectiveGen` builds a tree of suspended
/// operations (using the Freer Monad pattern). For example, `Gen.choose()` does not
/// actually pick a random number; it creates a `ReflectiveGen` containing a `ReflectiveOperation.chooseBits`
/// instruction.
///
/// This description can then be passed to an `Interpreter` which walks the structure and executes
/// the operations, giving them meaning.
///
///
/// ## The Three Interpretations
///
/// The declarative nature of `ReflectiveGen` allows for three main interpretations:
///
/// 1.  **`generate` (Forward):** Takes the generator and a source of randomness to produce a random `Value`.
///     This is the traditional "run" function for a property-based test.
///     `(Randomness) -> Value`
///
/// 2.  **`reflect` (Backward):** Takes a concrete `Value` and deconstructs it according to the generator's
///     structure, producing a list of all possible "choice paths" that could have generated it.
///     `Value -> [ChoicePath]`
///
/// 3.  **`replay` (Forward, Deterministic):** Takes a `ChoicePath` (the output of `reflect`) and
///     deterministically re-creates the exact `Value`. This is the engine for test-case shrinking.
///     `ChoicePath -> Value`
///
///
/// ## Generic Parameters
///
/// -   **`Input`**: The type of the external data the generator might depend on. This is primarily
///     used by the `reflect` interpreter as the type of the value being deconstructed. For most
///     self-contained generators (like `choose`, `getSize`), this defaults to `Void`, and the user
///     can ignore it. It is introduced and manipulated via `lmap` and `biFrom`.
///
/// -   **`Value`**: The type of the value that this monadic chain will ultimately produce. This is
///     the generator's output.
///
///
/// ## How to Use
///
/// **Construction:**
/// You should never construct a `ReflectiveGen` directly using its `.pure` or `.impure` cases.
/// Instead, use the suite of "smart constructor" functions provided in the `Gen` enum.
///
/// ```swift
/// // A self-contained generator for an ASCII character. Input is implicitly Void.
/// let charGen = Gen.choose()
///
/// // A generator that depends on an external `User` object to produce an `Int`.
/// let ageGen: ReflectiveGen<User, Int> = Gen.lmap({ $0.age }, Gen.choose())
/// ```
///
/// **Execution:**
/// To give a `ReflectiveGen` meaning, pass it to an `Interpreter` instance.
///
/// ```swift
/// let interpreter = Interpreter()
///
/// // Running a self-contained generator
/// if let randomChar = interpreter.generate(charGen) {
///     print(randomChar)
/// }
///
/// // Running a generator that requires an input
/// let user = User(age: 42)
/// if let age = interpreter.generate(ageGen, with: user) {
///     print(age)
/// }
/// ```
///
/// - SeeAlso: `FreerMonad`, `ReflectiveOperation`, `Gen`, `Interpreter`.
typealias ReflectiveGen<Input, Output> = FreerMonad<ReflectiveOperation<Input>, Output>

extension ReflectiveGen {
    func mapOperation<NewOperation>(_ transform: @escaping (Operation) -> NewOperation) -> FreerMonad<NewOperation, Value> {
            switch self {
            case .pure(let value):
                // If we're at a pure value, there's no operation to transform. Return as is.
                return .pure(value)
                
            case .impure(let operation, let continuation):
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
