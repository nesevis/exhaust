// ExhaustCore's user-facing types are re-exported individually. A new `public` declaration in ExhaustCore does not join the Exhaust module's surface until a matching line is added here.

import ExhaustCore
@_exported import enum ExhaustCore.__ExhaustRuntime
@_exported import struct ExhaustCore.ChoiceGraphStats
@_exported import struct ExhaustCore.CoOccurrenceMatrix
@_exported import struct ExhaustCore.CouplingEdge
@_exported import enum ExhaustCore.DateStride
@_exported import enum ExhaustCore.EncoderName
@_exported import struct ExhaustCore.FilterObservation
@_exported import struct ExhaustCore.FilterSourceLocation
@_exported import enum ExhaustCore.FilterType
@_exported import enum ExhaustCore.GeneratorError
@_exported import enum ExhaustCore.LogFormat
@_exported import enum ExhaustCore.LogLevel
@_exported import struct ExhaustCore.NumericTypeCoverage
@_exported import struct ExhaustCore.OpenPBTStatsLine
@_exported import struct ExhaustCore.ReductionStats
@_exported import enum ExhaustCore.ReflectionError
@_exported import struct ExhaustCore.ReflectiveGenerator
@_exported import enum ExhaustCore.ReplaySeed
@_exported import enum ExhaustCore.SizeScaling
@_exported import enum ExhaustCore.UnfoldStep
@_exported import enum ExhaustCore.UnicodeVersion

// MARK: - Internal typealiases

typealias ChoiceTreeAnalysis = ExhaustCore.ChoiceTreeAnalysis
typealias CoveringArrayReplay = ExhaustCore.CoveringArrayReplay
typealias ChoiceSequence = ExhaustCore.ChoiceSequence
