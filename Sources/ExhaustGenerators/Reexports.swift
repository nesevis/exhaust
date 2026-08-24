// ExhaustCore's generator-facing types are re-exported individually. A new `public` declaration in ExhaustCore does not join the ExhaustGenerators module's surface until a matching line is added here. Test-run-facing types (settings enums, report components) are re-exported by the Exhaust module instead.

@_exported import enum ExhaustCore.__ExhaustRuntime
@_exported import enum ExhaustCore.DateStride
@_exported import enum ExhaustCore.GeneratorError
@_exported import enum ExhaustCore.ReflectionError
@_exported import struct ExhaustCore.ReflectiveGenerator
@_exported import enum ExhaustCore.SizeScaling
@_exported import enum ExhaustCore.UnfoldStep
@_exported import enum ExhaustCore.UnicodeVersion
