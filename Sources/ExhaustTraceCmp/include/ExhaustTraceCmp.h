// SanitizerCoverage trace-cmp hooks: harvests comparison operands from an instrumented system under test so the fuzz mutator can inject the constants a comparison wanted.
//
// The hooks must live in an uninstrumented C translation unit. A Swift hook pays a lazy-initialization guard on every global access (measured ~9x the C cost), and an instrumented hook recurses into its own guard comparison until the stack overflows. C globals have neither problem, and __builtin_return_address gives a call-site key that Swift cannot obtain cheaply.

#ifndef EXHAUST_TRACE_CMP_H
#define EXHAUST_TRACE_CMP_H

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

#endif
