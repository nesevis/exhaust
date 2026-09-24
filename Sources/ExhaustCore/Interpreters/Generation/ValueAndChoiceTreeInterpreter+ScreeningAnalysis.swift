extension ValueAndChoiceTreeInterpreter {
    /// Records every constructor identity in the analysis template without recursively generating unselected alternatives whose payload parameters the pick model does not inspect.
    ///
    /// Skipping an arm costs the template every choice that arm would have contributed, which is only sound while the caller knows the enumeration was partial. The pick model counts the branch index alone, so any draw inside an arm is outside it. Each unselected arm is asked, from its generator rather than from a tree it never produced, whether its graph draws; an arm that says yes is skipped and recorded on the context. An arm whose graph looks constant is cheap, so it is materialized: the graph cannot see through a continuation, and the recorded subtree lets ``ChoiceTree/hidesChoiceFromScreening`` judge that arm the same way it judges the selected one.
    static func handleAnalysisPick(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        selectedChoice: ReflectiveOperation.PickTuple,
        jumpSeed: UInt64,
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
        let selectedBranch = ChoiceTree.branch(
            fingerprint: selectedChoice.fingerprint,
            weight: selectedChoice.weight,
            id: selectedChoice.id,
            branchCount: UInt64(choices.count),
            choice: final.1,
            isSelected: true
        )
        let branches = try recordAnalysisBranches(
            choices,
            selectedBranch: selectedBranch,
            selectedID: selectedChoice.id,
            jumpSeed: jumpSeed,
            continuation: continuation,
            context: &context
        )
        return (final.0, .group(branches))
    }

    /// Records every arm of an analysis pick around the already-recorded selected branch, eliding unselected arms that draw.
    ///
    /// Shared by committed and backtrack picks, which differ only in how the selected arm was chosen. An unselected arm whose graph draws, or whose materialization fails, is recorded as a placeholder and flagged on the context: dropping it would shrink the pick's branch index domain and hide its draws from ``ChoiceTree/hidesChoiceFromScreening``.
    static func recordAnalysisBranches(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        selectedBranch: ChoiceTree,
        selectedID: UInt64,
        jumpSeed: UInt64,
        continuation: (Any) throws -> AnyGenerator,
        context: inout GenerationContext
    ) throws -> [ChoiceTree] {
        let branchCount = UInt64(choices.count)
        var branches = [ChoiceTree]()
        branches.reserveCapacity(choices.count)
        for choice in choices {
            if choice.id == selectedID {
                branches.append(selectedBranch)
                continue
            }
            if choice.generator.drawsChoice == false,
               let branch = try materializeUnselectedBranch(
                   choice,
                   fingerprint: choice.fingerprint,
                   branchCount: branchCount,
                   jumpSeed: jumpSeed,
                   continuation: continuation,
                   context: &context
               )
            {
                branches.append(branch)
                continue
            }
            context.hasElidedDrawingArm = true
            branches.append(.branch(
                fingerprint: choice.fingerprint,
                weight: choice.weight,
                id: choice.id,
                branchCount: branchCount,
                choice: .just,
                isSelected: false
            ))
        }
        return branches
    }
}
