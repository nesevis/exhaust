//
//  ChoiceTreeClassifier.swift
//  Exhaust
//
//  Created by Chris Kolbu on 4/8/2025.
//

import See5

/// Maps ChoiceTree structures to See5 decision tree format for test case reduction
//public struct ChoiceTreeClassifier {
//    private let classifier = C50Classifier(schema: Self.schema)
//    
//    /// Schema defining the structural features extracted from ChoiceTree
//    static let schema = DataSchema(
//        attributes: [
//            AttributeDefinition(name: "structuralComplexity", type: .continuous),
//            AttributeDefinition(name: "combinatoryComplexity", type: .continuous),
//            AttributeDefinition(name: "totalComplexity", type: .continuous),
//            AttributeDefinition(name: "depth", type: .continuous),
//            AttributeDefinition(name: "nodeCount", type: .continuous),
//            AttributeDefinition(name: "choiceNodeCount", type: .continuous),
//            AttributeDefinition(name: "sequenceNodeCount", type: .continuous),
//            AttributeDefinition(name: "branchNodeCount", type: .continuous),
//            AttributeDefinition(name: "groupNodeCount", type: .continuous),
//            AttributeDefinition(name: "importantNodeCount", type: .continuous),
//            AttributeDefinition(name: "hasImportantNodes", type: .discrete(values: ["true", "false"])),
//            AttributeDefinition(name: "hasSelectedNodes", type: .discrete(values: ["true", "false"])),
//            AttributeDefinition(name: "dominantNodeType", type: .discrete(values: ["choice", "sequence", "branch", "group", "mixed"])),
//            AttributeDefinition(name: "maxSequenceLength", type: .continuous),
//            AttributeDefinition(name: "avgSequenceLength", type: .continuous),
//            AttributeDefinition(name: "maxBranchChildren", type: .continuous),
//            AttributeDefinition(name: "avgBranchChildren", type: .continuous),
//            AttributeDefinition(name: "maxGroupSize", type: .continuous),
//            AttributeDefinition(name: "avgGroupSize", type: .continuous),
//            AttributeDefinition(name: "unsignedChoiceRatio", type: .continuous),
//            AttributeDefinition(name: "signedChoiceRatio", type: .continuous),
//            AttributeDefinition(name: "floatingChoiceRatio", type: .continuous),
//            AttributeDefinition(name: "characterChoiceRatio", type: .continuous),
//            AttributeDefinition(name: "avgChoiceComplexity", type: .continuous),
//            AttributeDefinition(name: "maxChoiceComplexity", type: .continuous)
//        ],
//        classes: ["reducible", "irreducible"]
//    )
//    
//    public init() async throws {
//        try await classifier.__init__(schema: Self.schema)
//    }
//    
//    /// Train the classifier with labeled ChoiceTree examples
//    public func train(data: [(ChoiceTree, ChoiceTreeReductionOutcome)], options: TrainingOptions = .default) async throws {
//        let trainingData = TrainingData(cases: data.map { tree, outcome in
//            LabeledDataCase(
//                values: Self.extractFeatures(from: tree),
//                targetClass: outcome.classLabel,
//                weight: nil,
//                caseID: nil
//            )
//        })
//        
//        try await classifier.train(data: trainingData, options: options)
//    }
//    
//    /// Predict whether a ChoiceTree is likely reducible
//    public func predict(_ tree: ChoiceTree) async throws -> ChoiceTreeReductionPrediction {
//        let features = Self.extractFeatures(from: tree)
//        let dataCase = DataCase(values: features, caseID: nil)
//        let result = try await classifier.classify(dataCase)
//        
//        return ChoiceTreeReductionPrediction(
//            isReducible: result.predictedClass == "reducible",
//            confidence: result.confidence,
//            reducibilityProbability: result.classProbabilities["reducible"] ?? 0.0,
//            irreducibilityProbability: result.classProbabilities["irreducible"] ?? 0.0
//        )
//    }
//    
//    /// Extract structural features from a ChoiceTree for classification
//    static func extractFeatures(from tree: ChoiceTree) -> [AttributeValue?] {
//        let analysis = ChoiceTreeAnalysis(tree: tree)
//        
//        return [
//            .continuous(Double(tree.structuralComplexity)),
//            .continuous(tree.combinatoryComplexity),
//            .continuous(Double(tree.complexity)),
//            .continuous(Double(analysis.depth)),
//            .continuous(Double(analysis.nodeCount)),
//            .continuous(Double(analysis.choiceNodeCount)),
//            .continuous(Double(analysis.sequenceNodeCount)),
//            .continuous(Double(analysis.branchNodeCount)),
//            .continuous(Double(analysis.groupNodeCount)),
//            .continuous(Double(analysis.importantNodeCount)),
//            .discrete(analysis.hasImportantNodes ? "true" : "false"),
//            .discrete(analysis.hasSelectedNodes ? "true" : "false"),
//            .discrete(analysis.dominantNodeType.rawValue),
//            .continuous(Double(analysis.maxSequenceLength)),
//            .continuous(analysis.avgSequenceLength),
//            .continuous(Double(analysis.maxBranchChildren)),
//            .continuous(analysis.avgBranchChildren),
//            .continuous(Double(analysis.maxGroupSize)),
//            .continuous(analysis.avgGroupSize),
//            .continuous(analysis.unsignedChoiceRatio),
//            .continuous(analysis.signedChoiceRatio),
//            .continuous(analysis.floatingChoiceRatio),
//            .continuous(analysis.characterChoiceRatio),
//            .continuous(analysis.avgChoiceComplexity),
//            .continuous(Double(analysis.maxChoiceComplexity))
//        ]
//    }
//}
//
///// Result of reduction attempt for training data
//public enum ChoiceTreeReductionOutcome {
//    case reducible
//    case irreducible
//    
//    var classLabel: String {
//        switch self {
//        case .reducible: return "reducible"
//        case .irreducible: return "irreducible"
//        }
//    }
//}
//
///// Prediction result for ChoiceTree reducibility
//public struct ChoiceTreeReductionPrediction {
//    public let isReducible: Bool
//    public let confidence: Double
//    public let reducibilityProbability: Double
//    public let irreducibilityProbability: Double
//}
//
///// Comprehensive structural analysis of a ChoiceTree
//private struct ChoiceTreeAnalysis {
//    let depth: UInt64
//    let nodeCount: UInt64
//    let choiceNodeCount: UInt64
//    let sequenceNodeCount: UInt64
//    let branchNodeCount: UInt64
//    let groupNodeCount: UInt64
//    let importantNodeCount: UInt64
//    let hasImportantNodes: Bool
//    let hasSelectedNodes: Bool
//    let dominantNodeType: NodeType
//    let maxSequenceLength: UInt64
//    let avgSequenceLength: Double
//    let maxBranchChildren: UInt64
//    let avgBranchChildren: Double
//    let maxGroupSize: UInt64
//    let avgGroupSize: Double
//    let unsignedChoiceRatio: Double
//    let signedChoiceRatio: Double
//    let floatingChoiceRatio: Double
//    let characterChoiceRatio: Double
//    let avgChoiceComplexity: Double
//    let maxChoiceComplexity: UInt64
//    
//    enum NodeType: String {
//        case choice
//        case sequence
//        case branch
//        case group
//        case mixed
//    }
//    
//    init(tree: ChoiceTree) {
//        var nodeCount: UInt64 = 0
//        var choiceCount: UInt64 = 0
//        var sequenceCount: UInt64 = 0
//        var branchCount: UInt64 = 0
//        var groupCount: UInt64 = 0
//        var importantCount: UInt64 = 0
//        var hasImportant = false
//        var hasSelected = false
//        var maxDepth: UInt64 = 0
//        var sequenceLengths: [UInt64] = []
//        var branchChildCounts: [UInt64] = []
//        var groupSizes: [UInt64] = []
//        var choiceValues: [ChoiceValue] = []
//        
//        func analyze(_ node: ChoiceTree, depth: UInt64) {
//            nodeCount += 1
//            maxDepth = max(maxDepth, depth)
//            
//            switch node {
//            case let .choice(value, _):
//                choiceCount += 1
//                choiceValues.append(value)
//                
//            case .just:
//                break
//                
//            case let .sequence(length, elements, _):
//                sequenceCount += 1
//                sequenceLengths.append(length)
//                for element in elements {
//                    analyze(element, depth: depth + 1)
//                }
//                
//            case let .branch(_, children):
//                branchCount += 1
//                branchChildCounts.append(UInt64(children.count))
//                for child in children {
//                    analyze(child, depth: depth + 1)
//                }
//                
//            case let .group(children):
//                groupCount += 1
//                groupSizes.append(UInt64(children.count))
//                for child in children {
//                    analyze(child, depth: depth + 1)
//                }
//                
//            case .getSize:
//                break
//                
//            case let .resize(_, choices):
//                for choice in choices {
//                    analyze(choice, depth: depth + 1)
//                }
//                
//            case let .important(child):
//                importantCount += 1
//                hasImportant = true
//                analyze(child, depth: depth)
//                
//            case let .selected(child):
//                hasSelected = true
//                analyze(child, depth: depth)
//            }
//        }
//        
//        analyze(tree, depth: 0)
//        
//        // Calculate statistics
//        self.depth = maxDepth
//        self.nodeCount = nodeCount
//        self.choiceNodeCount = choiceCount
//        self.sequenceNodeCount = sequenceCount
//        self.branchNodeCount = branchCount
//        self.groupNodeCount = groupCount
//        self.importantNodeCount = importantCount
//        self.hasImportantNodes = hasImportant
//        self.hasSelectedNodes = hasSelected
//        
//        // Determine dominant node type
//        let counts = [(choiceCount, NodeType.choice), (sequenceCount, NodeType.sequence), 
//                     (branchCount, NodeType.branch), (groupCount, NodeType.group)]
//        let maxCount = counts.max { $0.0 < $1.0 }?.0 ?? 0
//        let dominantTypes = counts.filter { $0.0 == maxCount }.map { $1 }
//        self.dominantNodeType = dominantTypes.count == 1 ? dominantTypes[0] : .mixed
//        
//        // Sequence statistics
//        self.maxSequenceLength = sequenceLengths.max() ?? 0
//        self.avgSequenceLength = sequenceLengths.isEmpty ? 0.0 : Double(sequenceLengths.reduce(0, +)) / Double(sequenceLengths.count)
//        
//        // Branch statistics  
//        self.maxBranchChildren = branchChildCounts.max() ?? 0
//        self.avgBranchChildren = branchChildCounts.isEmpty ? 0.0 : Double(branchChildCounts.reduce(0, +)) / Double(branchChildCounts.count)
//        
//        // Group statistics
//        self.maxGroupSize = groupSizes.max() ?? 0
//        self.avgGroupSize = groupSizes.isEmpty ? 0.0 : Double(groupSizes.reduce(0, +)) / Double(groupSizes.count)
//        
//        // Choice value type ratios
//        let totalChoices = Double(choiceValues.count)
//        if totalChoices > 0 {
//            let unsignedCount = Double(choiceValues.count { if case .unsigned = $0 { return true }; return false })
//            let signedCount = Double(choiceValues.count { if case .signed = $0 { return true }; return false })
//            let floatingCount = Double(choiceValues.count { if case .floating = $0 { return true }; return false })
//            let characterCount = Double(choiceValues.count { if case .character = $0 { return true }; return false })
//            
//            self.unsignedChoiceRatio = unsignedCount / totalChoices
//            self.signedChoiceRatio = signedCount / totalChoices
//            self.floatingChoiceRatio = floatingCount / totalChoices
//            self.characterChoiceRatio = characterCount / totalChoices
//            
//            // Choice complexity statistics
//            let complexities = choiceValues.map { $0.complexity }
//            self.maxChoiceComplexity = complexities.max() ?? 0
//            self.avgChoiceComplexity = Double(complexities.reduce(0, +)) / totalChoices
//        } else {
//            self.unsignedChoiceRatio = 0.0
//            self.signedChoiceRatio = 0.0
//            self.floatingChoiceRatio = 0.0
//            self.characterChoiceRatio = 0.0
//            self.maxChoiceComplexity = 0
//            self.avgChoiceComplexity = 0.0
//        }
//    }
//}
