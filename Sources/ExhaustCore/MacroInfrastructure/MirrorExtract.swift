extension __ExhaustRuntime {
    /// Extracts a single child value from a Mirror by label.
    ///
    /// Returns `nil` when the label does not match any child — for example when init parameter labels differ from stored property names (such as `CGRect(x:y:width:height:)` whose stored properties are `origin` and `size`).
    static func _mirrorExtract(_ value: Any, label: String) -> Any? {
        Mirror(reflecting: value).children.first(where: { $0.label == label })?.value
    }

    /// Extracts multiple child values from a Mirror by labels, returning them as `[Any]`.
    ///
    /// Returns `nil` when any label does not match a child — for example when init parameter labels differ from stored property names (such as `CGRect(x:y:width:height:)` whose stored properties are `origin` and `size`).
    ///
    /// The labels must be in the order matching the generator/tuple parameter order.
    static func _mirrorExtractAll(_ value: Any, labels: [String]) -> [Any]? {
        let mirror = Mirror(reflecting: value)
        var result: [Any] = []
        result.reserveCapacity(labels.count)
        for label in labels {
            guard let child = mirror.children.first(where: { $0.label == label }) else {
                return nil
            }
            result.append(child.value)
        }
        return result
    }

    /// Extracts the expected number of associated values from a named enum case in declaration order.
    ///
    /// Mirror represents both one unlabeled tuple payload and multiple unlabeled associated values as a tuple. `associatedValueCount` comes from the macro's source-level arity and resolves that ambiguity. Non-enum values and other cases return `nil`, which lets a qualified static factory share the same macro expansion without masquerading as an enum case during reflection.
    static func _mirrorExtractEnumCase(
        _ value: Any,
        caseName: String,
        associatedValueCount: Int
    ) -> [Any]? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .enum,
              let caseChild = mirror.children.first,
              caseChild.label == caseName
        else {
            return nil
        }

        let payloadMirror = Mirror(reflecting: caseChild.value)
        if associatedValueCount == 1 {
            if payloadMirror.displayStyle == .tuple,
               payloadMirror.children.count == 1,
               let wrappedPayload = payloadMirror.children.first
            {
                return [wrappedPayload.value]
            }
            return [caseChild.value]
        }
        guard payloadMirror.displayStyle == .tuple,
              payloadMirror.children.count == associatedValueCount
        else {
            return nil
        }
        return payloadMirror.children.map(\.value)
    }
}
