// ExhaustCore's generator-facing types are re-exported individually. A new `public` declaration in ExhaustCore does not join the ExhaustGenerators module's surface until a matching line is added here. Test-run-facing types (settings enums, report components) are re-exported by the Exhaust module instead.

@_exported import enum ExhaustCore.__ExhaustRuntime
@_exported import enum ExhaustCore.DateStride
@_exported import enum ExhaustCore.GeneratorError
@_exported import enum ExhaustCore.ReflectionError
@_exported import struct ExhaustCore.ReflectiveGenerator
@_exported import enum ExhaustCore.SizeScaling
@_exported import enum ExhaustCore.UnfoldStep
@_exported import enum ExhaustCore.UnicodeVersion

// Re-export the annotation and its expansion infrastructure so clients can use `@Exhaustable` without a second import.
// Unlike the ExhaustCore types above, this module is re-exported whole: a macro has no import kind, so `@Exhaustable` cannot be listed on its own. Every `public` declaration in Exhaustable therefore reaches clients without a line here.
@_exported import Exhaustable
