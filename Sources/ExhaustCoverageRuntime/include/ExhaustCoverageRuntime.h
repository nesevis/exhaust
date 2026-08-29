// SanitizerCoverage callbacks: the trace-cmp operand harvest, which collects the constants a comparison wanted so the fuzz mutator can inject them, and the trace-pc-guard edge recorder, which gives each run an isolated per-attempt coverage map.
//
// The hooks must live in an uninstrumented C translation unit. A Swift hook pays a lazy-initialization guard on every global access (measured ~9x the C cost), and an instrumented hook recurses into its own guard comparison until the stack overflows. C globals have neither problem, and __builtin_return_address gives a call-site key that Swift cannot obtain cheaply.

#ifndef EXHAUST_COVERAGE_RUNTIME_H
#define EXHAUST_COVERAGE_RUNTIME_H

#include <stdint.h>
#include <stddef.h>

// MARK: - Harvest Control (called from Swift)

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

// Routes this thread's edges to the given context. Edges on unbound threads are dropped, which is the correct attribution: they belong to no attempt. There is no unbind: exhaust_tpg_destroy clears the binding when it is destroying the bound context, so no thread-local outlives its allocation.
void exhaust_tpg_bind(struct exhaust_tpg_context *context);

// Clears the previous attempt in O(edges it lit), not O(edges the binary contains).
void exhaust_tpg_reset(struct exhaust_tpg_context *context);

// Edges hit since the last reset, in first-hit order, and their saturating counts.
const uint32_t *exhaust_tpg_covered(struct exhaust_tpg_context *context);
size_t exhaust_tpg_covered_count(struct exhaust_tpg_context *context);
uint8_t exhaust_tpg_hit_count(struct exhaust_tpg_context *context, uint32_t edge);


#endif
