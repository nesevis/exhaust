// ExhaustTestSupport historically owned the shared test generators and now also fronts the self-fuzzing support: re-exporting keeps every existing `import ExhaustTestSupport` site working after the split into the Testing-free ExhaustMetaFuzz target (plain executables like MetaFuzzProbe cannot load Testing.framework).
@_exported import ExhaustMetaFuzz
