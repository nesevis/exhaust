//
//  PartialPath.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import CasePaths
import Foundation

public protocol PartialPath<Root, Value> {
    associatedtype Root
    associatedtype Value

    /// Attempts to extract the `Value` from an instance of the `Root`.
    ///
    /// This function is used by the "reflect" interpreter to get the sub-value
    /// it needs to recursively reflect upon.
    ///
    /// - Parameter root: The root value to extract from.
    /// - Returns: The `Value` if extraction is successful, otherwise `nil`.
    func extract(from root: Any) throws -> Value?

    // Attempts to embed a `Value` back into a `Root` structure.
    //
    // This function's primary role is in transformation and shrinking, allowing
    // a modified sub-value to be placed back into its containing structure.
    //
    // - Parameters:
    //   - value: The new `Value` to embed.
    //   - root: An `inout` instance of the root value to be modified.
    // - Returns: `true` if the embedding was successful, otherwise `false`.
    // func embed(_ value: Value, into root: inout Root) -> Bool
    // Not needed for our reflective case?
}

extension AnyCasePath: PartialPath {
    public func extract(from root: Any) throws -> Value? {
        // Handle nil case
        if case Optional<Any>.none = root {
            return nil
        }

        // Unwrap if wrapped in Optional
        let actualRoot: Any
        let mirror = Mirror(reflecting: root)
        if mirror.displayStyle == .optional,
           let child = mirror.children.first
        {
            if child.label == "some" {
                actualRoot = child.value
            } else {
                return nil // nil case
            }
        } else {
            actualRoot = root
        }

        guard let typedRoot = actualRoot as? Root else {
            return nil
        }

        return extract(from: typedRoot)
    }
}

extension KeyPath: PartialPath {
    public func extract(from root: Any) throws -> Value? {
        guard let root = root as? Root else {
            throw PartialPathError.wrongRootType(expected: "\(Root.self)", actual: "\(root.self)")
        }
        return root[keyPath: self]
    }
}

enum PartialPathError: LocalizedError {
    case wrongRootType(expected: String, actual: String)
}
