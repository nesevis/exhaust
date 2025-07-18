//
//  PartialPath.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

protocol PartialPath<Root, Value> {
    associatedtype Root
    associatedtype Value
    
    /// Attempts to extract the `Value` from an instance of the `Root`.
    ///
    /// This function is used by the "reflect" interpreter to get the sub-value
    /// it needs to recursively reflect upon.
    ///
    /// - Parameter root: The root value to extract from.
    /// - Returns: The `Value` if extraction is successful, otherwise `nil`.
    func extract(from root: Any) -> Value?
    
    /// Attempts to embed a `Value` back into a `Root` structure.
    ///
    /// This function's primary role is in transformation and shrinking, allowing
    /// a modified sub-value to be placed back into its containing structure.
    ///
    /// - Parameters:
    ///   - value: The new `Value` to embed.
    ///   - root: An `inout` instance of the root value to be modified.
    /// - Returns: `true` if the embedding was successful, otherwise `false`.
    // func embed(_ value: Value, into root: inout Root) -> Bool
    // Not needed for our reflective case?
}

extension KeyPath: PartialPath {
    func extract(from root: Any) -> Value? {
        guard let root = root as? Root else {
            print("KeyPath.extract expected \(Root.self) -> \(Value.self), but root type is \(type(of: root.self))")
            return nil
        }
        return root[keyPath: self]
    }
}
