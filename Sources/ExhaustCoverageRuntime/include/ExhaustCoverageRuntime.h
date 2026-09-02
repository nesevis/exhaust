// SanitizerCoverage callbacks: the trace-cmp operand harvest, which collects the constants a comparison wanted so the fuzz mutator can inject them, and the trace-pc-guard edge recorder, which gives each run an isolated per-attempt coverage map.
//
// The hooks must live in an uninstrumented C translation unit. A Swift hook pays a lazy-initialization guard on every global access (measured ~9x the C cost), and an instrumented hook recurses into its own guard comparison until the stack overflows. C globals have neither problem, and __builtin_return_address gives a call-site key that Swift cannot obtain cheaply.

#ifndef EXHAUST_COVERAGE_RUNTIME_H
#define EXHAUST_COVERAGE_RUNTIME_H

#include <stdint.h>
#include <stddef.h>

// MARK: - Harvest Control (called from Swift)
//
// These four read the process-global ring, which serves the inline-8bit-counter model. A trace-pc-guard run reads its own ring through the exhaust_tpg_cmp_* functions below; the hooks write to whichever ring the calling thread's binding selects.

// Enables or disables operand recording. Disabled between attempts so only the property evaluation's comparisons enter the buffer.
void exhaust_cmp_set_enabled(int enabled);

// Clears the operand buffer, dropping every pair recorded so far. Called at the start of each attempt bracket.
void exhaust_cmp_reset(void);

// The number of live comparison records in the buffer, saturating at its capacity. Recording past the capacity wraps around and overwrites the oldest records (last-N-wins), so the count stays at the capacity while the contents keep advancing.
size_t exhaust_cmp_record_count(void);

// The record buffer base. Record i occupies words 3i (call-site pc), 3i+1 (arg1), and 3i+2 (arg2). Valid for exhaust_cmp_record_count() records until the next reset. Once the buffer has wrapped, index order is no longer chronological; the pool groups by site and does not depend on record order.
const uint64_t *exhaust_cmp_records(void);


// MARK: - Trace-PC-Guard Edge Recording

// One run's isolated edge state. Opaque: the layout is an implementation detail of the C hook.
struct exhaust_tpg_context;

// Total edges registered by the guard-init callback, or zero when the build lacks `trace-pc-guard`.
size_t exhaust_tpg_edge_total(void);

// Allocates one run's edge state, or NULL when the build is not instrumented for trace-pc-guard.
struct exhaust_tpg_context *exhaust_tpg_create(void);
void exhaust_tpg_destroy(struct exhaust_tpg_context *context);

// Marks the calling thread as a run's lane without binding a context. A run calls this before it generates anything: edges its own lane fires outside a bracket (screening's first rows, reduction probes) are excluded by design and must not land in the off-lane count, and until the first bind nothing else would tell the hook the thread is a run's.
void exhaust_tpg_adopt_thread(void);

// Routes this thread's edges to the given context, or to nothing when the context is NULL. A run binds around each property evaluation and unbinds after reading it, so edges fired between brackets (generation, reduction probes) take the early return. exhaust_tpg_destroy also clears the binding when it is destroying the bound context, so no thread-local outlives its allocation.
void exhaust_tpg_bind(struct exhaust_tpg_context *context);

// Clears the previous attempt in O(edges it lit), not O(edges the binary contains).
void exhaust_tpg_reset(struct exhaust_tpg_context *context);

// Edges hit since the last reset, in first-hit order, and their saturating counts.
const uint32_t *exhaust_tpg_covered(struct exhaust_tpg_context *context);
size_t exhaust_tpg_covered_count(struct exhaust_tpg_context *context);
uint8_t exhaust_tpg_hit_count(struct exhaust_tpg_context *context, uint32_t edge);

// The saturating count table itself, indexed by guard id, valid until the next reset. Lets a reader copy every covered edge's count in one loop instead of one call per edge.
const uint8_t *exhaust_tpg_hits(struct exhaust_tpg_context *context);

// Whether the calling thread's binding is this context.
_Bool exhaust_tpg_is_bound(struct exhaust_tpg_context *context);

// Edges fired, while at least one context existed, on a thread that no run ever bound: property work that escaped to another executor, or another test exercising the instrumented code concurrently. Monotonic for the process; a run reads it at start and end and reports the difference.
size_t exhaust_tpg_dropped_hit_count(void);

// The context's own comparison-operand ring, with the same semantics as the process-global exhaust_cmp_* functions. Comparisons fired while the context is bound land here, so two trace-pc-guard runs in one process harvest independently.
void exhaust_tpg_cmp_set_enabled(struct exhaust_tpg_context *context, int enabled);
void exhaust_tpg_cmp_reset(struct exhaust_tpg_context *context);
size_t exhaust_tpg_cmp_record_count(struct exhaust_tpg_context *context);
const uint64_t *exhaust_tpg_cmp_records(struct exhaust_tpg_context *context);

// MARK: - Test Support

// The SanitizerCoverage callbacks, declared so an uninstrumented test binary can drive the recorders with synthetic guards and comparisons.
void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop);
void __sanitizer_cov_trace_pc_guard(uint32_t *guard);
void __sanitizer_cov_trace_cmp8(uint64_t arg1, uint64_t arg2);

// Forgets every registered guard and clears the calling thread's binding. Defined in debug builds only: the production registry is append-only for the process lifetime, and a consumer of the released library must not be able to disable coverage for every later run. The declaration stays unconditional because the clang importer does not see the build configuration; the Swift caller is itself under `#if DEBUG`, so a release build never references the missing symbol.
void exhaust_tpg_reset_registry_for_testing(void);


#endif
