//
//  Interpreters+Dispatch.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/3/2026.
//

public extension Interpreters {
    /// Dispatches to either the Bonsai reducer or the standard reducer based on the `useBonsai` flag.
    static func dispatchReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: TCRConfiguration,
        useBonsai: Bool,
        humanOrderPostProcess: Bool = false,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        if useBonsai {
            var bonsaiConfig = BonsaiReducerConfiguration(from: config)
            bonsaiConfig.humanOrderPostProcess = humanOrderPostProcess
            return try bonsaiReduce(
                gen: gen,
                tree: tree,
                config: bonsaiConfig,
                property: property
            )
        } else {
            return try reduce(gen: gen, tree: tree, config: config, property: property)
        }
    }
}
