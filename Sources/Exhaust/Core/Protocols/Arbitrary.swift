import Foundation

protocol Arbitrary {
    
    /// The default, canonical `ReflectiveGenerator` for this type.
    ///
    /// This generator should aim to produce a wide and useful distribution of values.
    /// The `@Property` trait will use this generator by default for test function
    /// parameters of this type.
    static var arbitrary: ReflectiveGenerator<Any, Self> { get }
    static var strategies: ShrinkingStrategies { get }
}
