#include "ExhaustCoverageRuntime.h"

// MARK: - Site-Keyed Operand Ring Buffer
//
// Each record carries the comparison's call-site address (the return address into the instrumented system under test), so the harvest can group operands by the comparison that produced them. Grouping matters because a shallow comparison in a cascade fires on every attempt and would otherwise flood a flat pool, drowning the constants of deeper comparisons that only fire once earlier ones match.
//
// Past the capacity within one attempt, new records overwrite the oldest: last-N-wins. The alternative, dropping the tail, is the wrong bias for exactly the cascades the pool exists to solve: deep comparisons fire late in a comparison-heavy attempt, so a first-N policy would discard the frontier operands and keep the shallow decoys.
//
// The cursor and writes are deliberately non-atomic, matching the inline-8bit-counter model: an instrumented SUT may run comparisons on more than one thread, and a lost or torn record is harmless.

#define EXHAUST_CMP_CAPACITY 4096

// Each record is three words: call-site pc, arg1, arg2.
static uint64_t exhaust_cmp_buffer[EXHAUST_CMP_CAPACITY * 3];
static size_t exhaust_cmp_cursor = 0;
static int exhaust_cmp_enabled = 0;

static inline void exhaust_cmp_record(uint64_t site, uint64_t arg1, uint64_t arg2) {
    if (!exhaust_cmp_enabled) {
        return;
    }
    size_t slot = (exhaust_cmp_cursor % EXHAUST_CMP_CAPACITY) * 3;
    exhaust_cmp_buffer[slot] = site;
    exhaust_cmp_buffer[slot + 1] = arg1;
    exhaust_cmp_buffer[slot + 2] = arg2;
    exhaust_cmp_cursor += 1;
}

// MARK: - Harvest Control

void exhaust_cmp_set_enabled(int enabled) {
    exhaust_cmp_enabled = enabled;
}

void exhaust_cmp_reset(void) {
    exhaust_cmp_cursor = 0;
}

size_t exhaust_cmp_record_count(void) {
    size_t cursor = exhaust_cmp_cursor;
    return cursor < EXHAUST_CMP_CAPACITY ? cursor : EXHAUST_CMP_CAPACITY;
}

const uint64_t *exhaust_cmp_records(void) {
    return exhaust_cmp_buffer;
}

// MARK: - SanitizerCoverage Hooks
//
// The call-site key is __builtin_return_address(0) read in the hook itself (not the shared helper), so it is the address in the instrumented SUT immediately after the call, which makes it distinct per comparison site. Every width widens into the same u64 slots; the mutator filters injected values against each site's declared range regardless of the width the comparison used.

void __sanitizer_cov_trace_cmp1(uint8_t arg1, uint8_t arg2) {
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), (uint64_t)arg1, (uint64_t)arg2);
}

void __sanitizer_cov_trace_cmp2(uint16_t arg1, uint16_t arg2) {
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), (uint64_t)arg1, (uint64_t)arg2);
}

void __sanitizer_cov_trace_cmp4(uint32_t arg1, uint32_t arg2) {
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), (uint64_t)arg1, (uint64_t)arg2);
}

void __sanitizer_cov_trace_cmp8(uint64_t arg1, uint64_t arg2) {
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), arg1, arg2);
}

void __sanitizer_cov_trace_const_cmp1(uint8_t arg1, uint8_t arg2) {
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), (uint64_t)arg1, (uint64_t)arg2);
}

void __sanitizer_cov_trace_const_cmp2(uint16_t arg1, uint16_t arg2) {
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), (uint64_t)arg1, (uint64_t)arg2);
}

void __sanitizer_cov_trace_const_cmp4(uint32_t arg1, uint32_t arg2) {
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), (uint64_t)arg1, (uint64_t)arg2);
}

void __sanitizer_cov_trace_const_cmp8(uint64_t arg1, uint64_t arg2) {
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), arg1, arg2);
}

// The switch hook reports the switched value and a table: cases[0] is the case count, cases[1] the operand bit width, and cases[2..] the case constants. Each case constant is paired against the live value under the switch's own call-site key.
void __sanitizer_cov_trace_switch(uint64_t value, uint64_t *cases) {
    if (cases == 0) {
        return;
    }
    uint64_t site = (uint64_t)__builtin_return_address(0);
    uint64_t count = cases[0];
    for (uint64_t index = 0; index < count; index += 1) {
        exhaust_cmp_record(site, value, cases[2 + index]);
    }
}

// MARK: - Trace-PC-Guard Edge Recording
//
// The isolated alternative to inline-8bit-counters. Instrumented with `-sanitize-coverage=edge,trace-pc-guard,pc-table`, every edge calls the hook below instead of incrementing a fixed global byte, which buys two things the counter model cannot express.
//
// Isolation: the hook reads a thread-local context, so two runs in one process write to different arrays instead of clearing each other's. Exhaust's property always executes on the runner's own thread, since `blockingAwait` drains an async property's continuations through `LaneExecutor` on the calling thread. A thread-local key is therefore correct by construction here, and none of the task-local inheritance machinery a general-purpose fuzzer needs applies.
//
// Sparsity: the hook appends each edge to a covered list on its first hit, so reset and read are both O(edges the attempt lit) rather than O(edges the binary contains). The counter model has no record of which counters moved, so it must clear and rescan the whole table every attempt: 17.7 µs on an 89,832-edge build against 0.46 µs for the clear alone.

#include <stdlib.h>
#include <string.h>

struct exhaust_tpg_context {
    uint8_t *hits;              // saturating per-edge count, indexed by guard id
    uint32_t *covered;          // edge ids in first-hit order
    size_t covered_count;
    size_t capacity;            // edge count + 1, since guard ids are 1-based
};

static size_t exhaust_tpg_edge_count = 0;
// Edges fire before any run binds a context (module constructors, test-framework startup). A null binding drops them, which is the correct attribution: they belong to no attempt.
static _Thread_local struct exhaust_tpg_context *exhaust_tpg_current = NULL;

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
    if (start == stop || *start) {
        return;
    }
    for (uint32_t *guard = start; guard < stop; guard++) {
        *guard = (uint32_t)(++exhaust_tpg_edge_count);
    }
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    struct exhaust_tpg_context *context = exhaust_tpg_current;
    if (context == NULL) {
        return;
    }
    uint32_t edge = *guard;
    if (edge == 0 || edge >= context->capacity) {
        return;
    }
    uint8_t seen = context->hits[edge];
    if (seen == 0) {
        context->covered[context->covered_count++] = edge;
        context->hits[edge] = 1;
        return;
    }
    // AFL's top bucket is 128+, so once a count reaches it no further hit can move the bucket. Returning here skips the store for exactly the edges hit most often.
    if (seen >= 128) {
        return;
    }
    context->hits[edge] = seen + 1;
}

size_t exhaust_tpg_edge_total(void) {
    return exhaust_tpg_edge_count;
}

struct exhaust_tpg_context *exhaust_tpg_create(void) {
    if (exhaust_tpg_edge_count == 0) {
        return NULL;
    }
    struct exhaust_tpg_context *context = calloc(1, sizeof(struct exhaust_tpg_context));
    if (context == NULL) {
        return NULL;
    }
    context->capacity = exhaust_tpg_edge_count + 1;
    context->hits = calloc(context->capacity, sizeof(uint8_t));
    context->covered = calloc(context->capacity, sizeof(uint32_t));
    if (context->hits == NULL || context->covered == NULL) {
        free(context->hits);
        free(context->covered);
        free(context);
        return NULL;
    }
    return context;
}

void exhaust_tpg_destroy(struct exhaust_tpg_context *context) {
    if (context == NULL) {
        return;
    }
    // Clearing the binding here rather than at the call site is what keeps the thread-local from outliving the allocation: an edge firing on this thread afterwards would otherwise dereference freed memory. Only this thread's binding is reachable, so a context destroyed from a thread other than the one that bound it leaves that dangling pointer behind. Destruction runs on the lane that bound the context, because the source is a local of the run and the run owns the lane for its whole life.
    if (exhaust_tpg_current == context) {
        exhaust_tpg_current = NULL;
    }
    free(context->hits);
    free(context->covered);
    free(context);
}

void exhaust_tpg_bind(struct exhaust_tpg_context *context) {
    exhaust_tpg_current = context;
}

void exhaust_tpg_reset(struct exhaust_tpg_context *context) {
    if (context == NULL) {
        return;
    }
    for (size_t index = 0; index < context->covered_count; index++) {
        context->hits[context->covered[index]] = 0;
    }
    context->covered_count = 0;
}

const uint32_t *exhaust_tpg_covered(struct exhaust_tpg_context *context) {
    return context == NULL ? NULL : context->covered;
}

size_t exhaust_tpg_covered_count(struct exhaust_tpg_context *context) {
    return context == NULL ? 0 : context->covered_count;
}

uint8_t exhaust_tpg_hit_count(struct exhaust_tpg_context *context, uint32_t edge) {
    if (context == NULL || edge >= context->capacity) {
        return 0;
    }
    return context->hits[edge];
}
