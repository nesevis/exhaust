// The app-safe generator surface (ReflectiveGenerator, its factory catalogue, #gen, and the generator-facing ExhaustCore types) comes through ExhaustGenerators, so a test target importing Exhaust sees the whole API. ExhaustCore's remaining user-facing types are re-exported individually: a new `public` declaration in ExhaustCore does not join the Exhaust module's surface until a matching line is added here.

import ExhaustCore
@_exported import protocol ExhaustCore.AsyncStateMachineSpec
@_exported import struct ExhaustCore.CoOccurrenceMatrix
@_exported import struct ExhaustCore.CommandResponse
@_exported import enum ExhaustCore.ConcurrencyLevel
@_exported import enum ExhaustCore.ExecutionModel
@_exported import struct ExhaustCore.FilterObservation
@_exported import struct ExhaustCore.FilterSourceLocation
@_exported import enum ExhaustCore.FilterType
@_exported import enum ExhaustCore.LogFormat
@_exported import enum ExhaustCore.LogLevel
@_exported import struct ExhaustCore.NumericTypeCoverage
@_exported import enum ExhaustCore.ReplaySeed
@_exported import enum ExhaustCore.SearchableExecutionModel
@_exported import struct ExhaustCore.StateMachineCheckFailure
@_exported import enum ExhaustCore.StateMachineDiscoveryMethod
@_exported import struct ExhaustCore.StateMachineResult
@_exported import struct ExhaustCore.StateMachineSkip
@_exported import protocol ExhaustCore.StateMachineSpec
@_exported import protocol ExhaustCore.StateMachineSpecBase
@_exported import struct ExhaustCore.TraceStep
@_exported import ExhaustGenerators

// MARK: - Internal typealiases

typealias ChoiceTreeAnalysis = ExhaustCore.ChoiceTreeAnalysis
typealias CoveringArrayReplay = ExhaustCore.CoveringArrayReplay
typealias ChoiceSequence = ExhaustCore.ChoiceSequence
