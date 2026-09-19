extension ValueAndChoiceTreeInterpreter {
    /// Records every constructor identity in the analysis template without recursively generating unselected alternatives whose payload parameters the pick model does not inspect.
    ///
    /// Skipping an arm costs the template every choice that arm would have contributed, which is only sound while the caller knows the enumeration was partial. Each skipped arm is asked, from its generator rather than from the tree it never produced, whether its shape depends on a drawn value, and an arm that says yes is recorded on the context.
    static func handleAnalysisPick(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        selectedChoice: ReflectiveOperation.PickTuple,
        continuation: (Any) throws -> AnyGenerator,
        context: inout GenerationContext
    ) throws -> (Any, ChoiceTree)? {
        let savedMaterializePicks = context.materializePicks
        context.materializePicks = false
        defer { context.materializePicks = savedMaterializePicks }
        guard let result = try generateRecursiveAny(selectedChoice.generator, context: &context),
              let final = try runContinuation(
                  result: result.0,
                  calleeChoiceTree: result.1,
                  calleeStart: 0,
                  continuation: continuation,
                  context: &context
              )
        else {
            throw GeneratorError.choiceTreeConstructionFailed
        }
        for choice in choices where choice.id != selectedChoice.id {
            guard choice.generator.hasDataDependentShape else {
                continue
            }
            context.hasElidedDataDependentArm = true
            break
        }
        let branches = choices.map { choice in
            ChoiceTree.branch(
                fingerprint: choice.fingerprint,
                weight: choice.weight,
                id: choice.id,
                branchCount: UInt64(choices.count),
                choice: choice.id == selectedChoice.id ? final.1 : .just,
                isSelected: choice.id == selectedChoice.id
            )
        }
        return (final.0, .group(branches))
    }
}
