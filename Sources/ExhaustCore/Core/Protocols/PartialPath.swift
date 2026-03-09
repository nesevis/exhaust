//
//  PartialPath.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

public protocol PartialPath<Root, Value> {
    associatedtype Root
    associatedtype Value

    /// Attempts to extract the `Value` from an instance of the `Root`.
    ///
    /// This function is used by the "reflect" interpreter to get the sub-value it needs to recursively reflect upon.
    ///
    /// - Parameter root: The root value to extract from.
    /// - Returns: The `Value` if extraction is successful, otherwise `nil`.
    func extract(from root: Any) throws -> Value?
}

extension KeyPath: PartialPath {
    public func extract(from root: Any) throws -> Value? {
        guard let root = root as? Root else {
            throw PartialPathError.wrongRootType(expected: "\(Root.self)", actual: "\(root.self)")
        }
        return root[keyPath: self]
    }
}

public enum PartialPathError: LocalizedError {
    case wrongRootType(expected: String, actual: String)
}
