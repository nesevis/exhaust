//
//  Interpreters+Dispatch.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/3/2026.
//

public extension Interpreters {
    /// Dispatches test case reduction using the Bonsai reducer.
    static func dispatchReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: ReductionBudget,
        humanOrderPostProcess: Bool = false,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        var bonsaiConfig = BonsaiReducerConfiguration(from: config)
        bonsaiConfig.humanOrderPostProcess = humanOrderPostProcess
        return try bonsaiReduce(
            gen: gen,
            tree: tree,
            config: bonsaiConfig,
            property: property
        )
    }
}
