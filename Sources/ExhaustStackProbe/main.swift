//
//  main.swift
//  ExhaustStackProbe
//
//  Empirically locates the debug-build stack ceiling for deep-chain generators, in recipe-node units matching GenRecipe.nodeCount. Run one (shape, nodeCount) pair per process so a stack overflow is observable as a crash exit rather than killing a test run. The pipeline mirrors MetaGeneratorPropertyTests (generate via VACTI, reflect, replay, materialize) on a 512 KiB thread matching the Swift Concurrency cooperative pool.
//

import ExhaustCore
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let nodeCount = Int(arguments[2]), nodeCount >= 1 else {
    FileHandle.standardError.write(Data("usage: ExhaustStackProbe <mapped|filtered|filteredDistinct|optional|unique|classified> <nodeCount> [stackKiB]\n".utf8))
    exit(2)
}

let stackKiB = arguments.count >= 4 ? Int(arguments[3]) ?? 512 : 512
let outcome = probe(shape: arguments[1], nodeCount: nodeCount, stackKiB: stackKiB)
switch outcome {
    case .success:
        print("OK")
        exit(0)
    case let .failure(message):
        print("ERROR: \(message)")
        exit(1)
}

// MARK: - Probe

enum ProbeOutcome {
    case success
    case failure(String)
}

func probe(shape: String, nodeCount: Int, stackKiB: Int) -> ProbeOutcome {
    let box = ResultBox(generator: buildChain(shape: shape, nodeCount: nodeCount))
    let semaphore = DispatchSemaphore(value: 0)
    let thread = Thread {
        defer { semaphore.signal() }
        do {
            try runPipeline(box.generator)
        } catch {
            box.message = "\(error)"
        }
    }
    // Default 512 KiB matches the Swift Concurrency cooperative pool's off-main-thread stack size.
    thread.stackSize = stackKiB * 1024
    thread.start()
    semaphore.wait()
    if let message = box.message {
        return .failure(message)
    }
    return .success
}

final class ResultBox: @unchecked Sendable {
    let generator: AnyGenerator
    var message: String?

    init(generator: AnyGenerator) {
        self.generator = generator
    }
}

// MARK: - Pipeline (mirrors MetaGeneratorPropertyTests invariants 1-3)

@Sendable func runPipeline(_ gen: AnyGenerator) throws {
    // Value-only pass first: VI has its own frame profile, and its unique handling delegates to a sub-VACTI interpretation whose stack sits on top of the VI frames.
    var valueInterpreter = ValueInterpreter<Any>(gen, seed: 43, maxRuns: 5)
    while try valueInterpreter.next() != nil {}

    var interpreter = ValueAndChoiceTreeInterpreter<Any>(gen, seed: 42, maxRuns: 5)
    while let (value, _) = try interpreter.next() {
        guard let tree = try Interpreters.reflect(gen, with: value) else {
            continue
        }
        guard let replayed = try Interpreters.replay(gen, using: tree) else {
            continue
        }
        _ = replayed
        let sequence = ChoiceSequence.flatten(tree)
        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) else {
            continue
        }
        _ = materialized
    }
}

// MARK: - Chain Construction (mirrors GenRecipe.buildCombinator node-for-node)

/// Builds a deep chain of `nodeCount` recipe nodes: one leaf plus `nodeCount - 1` nested combinator layers. A chain is the deepest arrangement of a given node count, so its ceiling lower-bounds every other arrangement of the same count.
func buildChain(shape: String, nodeCount: Int) -> AnyGenerator {
    var gen: AnyGenerator = Gen.choose(in: -100 ... 100 as ClosedRange<Int>).erase()
    for nodeIndex in 0 ..< (nodeCount - 1) {
        switch shape {
            case "mapped":
                // GenRecipe .mapped(negate): contramap plus transform(map), two operations per node.
                let inner = gen
                gen = Gen.contramap(
                    { (newOutput: Any) throws -> Any in -(newOutput as! Int) },
                    inner.map { -($0 as! Int) }
                )
            case "filtered":
                // GenRecipe .filtered(always). All levels share one fingerprint (one source location), matching what buildGenerator produces. Exercises the filter expansion-path guard in GenerationContext: without it, the tuned-filter cache entry for the shared fingerprint resolves to a chain containing that same fingerprint and generation recurses forever.
                gen = AnyGenerator.impure(
                    operation: .filter(
                        gen: gen.erase(),
                        fingerprint: Gen.sourceFingerprint(fileID: #fileID, line: #line, column: #column),
                        filterType: .auto,
                        predicate: { _ in true },
                        sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
                    ),
                    continuation: { .pure($0) }
                )
            case "filteredDistinct":
                // Same chain with a distinct fingerprint per level, sidestepping the shared-fingerprint cycle to measure the true stack cost of nested filter tuning.
                gen = AnyGenerator.impure(
                    operation: .filter(
                        gen: gen.erase(),
                        fingerprint: Gen.sourceFingerprint(fileID: #fileID, line: UInt(nodeIndex), column: #column),
                        filterType: .auto,
                        predicate: { _ in true },
                        sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: UInt(nodeIndex), column: #column)
                    ),
                    continuation: { .pure($0) }
                )
            case "unique":
                // GenRecipe .unique with per-level fingerprints (mirrors recipeFingerprint): choice-sequence dedup, so the value-only interpreter delegates each top-level draw to a sub-VACTI interpretation.
                gen = AnyGenerator.impure(
                    operation: .unique(
                        gen: gen.erase(),
                        fingerprint: Gen.sourceFingerprint(fileID: #fileID, line: UInt(nodeIndex), column: #column),
                        keyExtractor: nil
                    ),
                    continuation: { .pure($0) }
                )
            case "classified":
                // GenRecipe .classified: a transparent annotation layer.
                gen = Gen.classify(gen, ("probe", { _ in true }))
            case "optional":
                // GenRecipe .optional: weighted pick of nil against the wrapped inner, with a liftToOptional-style backward on the value branch (mirrors buildCombinator).
                let inner = gen
                let someBranch = AnyGenerator.impure(
                    operation: .contramap(
                        transform: { result in
                            let mirror = Mirror(reflecting: result)
                            guard mirror.displayStyle == .optional else {
                                return result
                            }
                            guard let child = mirror.children.first else {
                                throw ReflectionError.reflectedNil(
                                    type: "Any",
                                    resultType: String(describing: type(of: result))
                                )
                            }
                            return child.value
                        },
                        next: inner
                    ),
                    continuation: { .pure(Any?.some($0) as Any) }
                )
                gen = Gen.pick(choices: [
                    (1, Gen.just(Any?.none as Any)),
                    (5, someBranch),
                ])
            default:
                FileHandle.standardError.write(Data("unknown shape: \(shape)\n".utf8))
                exit(2)
        }
    }
    return gen
}
