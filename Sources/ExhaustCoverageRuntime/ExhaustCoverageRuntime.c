#include "ExhaustCoverageRuntime.h"

// MARK: - Site-Keyed Operand Ring Buffer
//
// Each record carries the comparison's call-site address (the return address into the instrumented system under test), so the harvest can group operands by the comparison that produced them. Grouping matters because a shallow comparison in a cascade fires on every attempt and would otherwise flood a flat pool, drowning the constants of deeper comparisons that only fire once earlier ones match.
//
// Past the capacity within one attempt, new records overwrite the oldest: last-N-wins. The alternative, dropping the tail, is the wrong bias for exactly the cascades the pool exists to solve: deep comparisons fire late in a comparison-heavy attempt, so a first-N policy would discard the frontier operands and keep the shallow decoys.
//
// There are two rings, and they have different thread models.
//
// A trace-pc-guard run owns one inside its context, so two trace-pc-guard runs in one process harvest independently, the same isolation the edge recorder gives them. Only the bound lane reaches it, because `exhaust_cmp_bound_ring` returns NULL on every other thread, so its cursor and writes are single-threaded by construction and stay non-atomic.
//
// The process-global ring serves the inline-8bit-counter model, which has no context and already requires the process to itself. Every thread of an instrumented SUT can still reach it, concurrently with the lane that drains it, so it is mutually excluded. "A torn record is harmless" is a claim about the value; concurrent non-atomic access is undefined behaviour, which is a claim about the program, and only the second one binds the optimiser.
//
// The exclusion is a spin lock over a four-store critical section rather than a platform mutex: `atomic_flag` is C11 and needs no per-platform header, and the hold time is a handful of stores with no calls in it. Swap it for a real mutex if contention ever shows on a comparison-heavy target.
//
// The enabled flag is read before the lock, so a build harvesting nothing pays one relaxed load per comparison and never touches the lock. That is also what confines the lock to the counter model: under trace-pc-guard the global ring's flag is never set, so the off-lane threads whose records nothing would harvest bail at the load.

#define EXHAUST_CMP_CAPACITY 4096

#include <stdatomic.h>
#include <string.h>

struct exhaust_cmp_ring {
    uint64_t buffer[EXHAUST_CMP_CAPACITY * 3]; // three words per record: call-site pc, arg1, arg2
    size_t cursor;
    int enabled;
};

static struct exhaust_cmp_ring exhaust_cmp_global;
static _Atomic int exhaust_cmp_global_enabled = 0;
static atomic_flag exhaust_cmp_global_lock = ATOMIC_FLAG_INIT;

// The drain's own copy. Written and read only by the lane that drains, so it needs no exclusion of its own, and handing Swift a pointer into it means no reader ever walks storage a hook can still be writing.
static uint64_t exhaust_cmp_snapshot_buffer[EXHAUST_CMP_CAPACITY * 3];
static size_t exhaust_cmp_snapshot_count = 0;

static inline void exhaust_cmp_global_acquire(void) {
    while (atomic_flag_test_and_set_explicit(&exhaust_cmp_global_lock, memory_order_acquire)) {
    }
}

static inline void exhaust_cmp_global_release(void) {
    atomic_flag_clear_explicit(&exhaust_cmp_global_lock, memory_order_release);
}

static inline void exhaust_cmp_ring_store(struct exhaust_cmp_ring *ring, uint64_t site, uint64_t arg1, uint64_t arg2) {
    size_t slot = (ring->cursor % EXHAUST_CMP_CAPACITY) * 3;
    ring->buffer[slot] = site;
    ring->buffer[slot + 1] = arg1;
    ring->buffer[slot + 2] = arg2;
    ring->cursor += 1;
}

// The per-context ring: single-threaded, so the enabled check and the store need no exclusion.
static inline void exhaust_cmp_ring_record(struct exhaust_cmp_ring *ring, uint64_t site, uint64_t arg1, uint64_t arg2) {
    if (!ring->enabled) {
        return;
    }
    exhaust_cmp_ring_store(ring, site, arg1, arg2);
}

static inline size_t exhaust_cmp_ring_count(const struct exhaust_cmp_ring *ring) {
    return ring->cursor < EXHAUST_CMP_CAPACITY ? ring->cursor : EXHAUST_CMP_CAPACITY;
}

// Forward declaration: the bound context is defined with the edge recorder below, and the comparison hooks need it to pick a ring.
struct exhaust_tpg_context;
static struct exhaust_cmp_ring *exhaust_cmp_bound_ring(void);

static inline void exhaust_cmp_record(uint64_t site, uint64_t arg1, uint64_t arg2) {
    struct exhaust_cmp_ring *bound = exhaust_cmp_bound_ring();
    if (bound != NULL) {
        exhaust_cmp_ring_record(bound, site, arg1, arg2);
        return;
    }
    if (!atomic_load_explicit(&exhaust_cmp_global_enabled, memory_order_relaxed)) {
        return;
    }
    exhaust_cmp_global_acquire();
    exhaust_cmp_ring_store(&exhaust_cmp_global, site, arg1, arg2);
    exhaust_cmp_global_release();
}

// MARK: - Harvest Control

void exhaust_cmp_set_enabled(int enabled) {
    // Release ordering: a hook that observes the flag set also observes this run's reset of the cursor.
    atomic_store_explicit(&exhaust_cmp_global_enabled, enabled, memory_order_release);
}

void exhaust_cmp_reset(void) {
    exhaust_cmp_global_acquire();
    exhaust_cmp_global.cursor = 0;
    exhaust_cmp_global_release();
}

size_t exhaust_cmp_snapshot(void) {
    // Taking the lock is what makes clearing the enabled flag sufficient: a hook that passed the load before the lane cleared it is still inside the critical section, and this copy waits for it.
    exhaust_cmp_global_acquire();
    size_t count = exhaust_cmp_ring_count(&exhaust_cmp_global);
    memcpy(exhaust_cmp_snapshot_buffer, exhaust_cmp_global.buffer, count * 3 * sizeof(uint64_t));
    exhaust_cmp_global_release();
    exhaust_cmp_snapshot_count = count;
    return count;
}

size_t exhaust_cmp_record_count(void) {
    return exhaust_cmp_snapshot_count;
}

const uint64_t *exhaust_cmp_records(void) {
    return exhaust_cmp_snapshot_buffer;
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

// The const_cmp hooks receive the comparison's compile-time constant as arg1. The runtime operand is the one value injection never needs — it already came from some input — so the constant is recorded into both operand slots: the record layout stays three words, and every pool draw from a constant-gate site yields the gate's constant.
void __sanitizer_cov_trace_const_cmp1(uint8_t arg1, uint8_t arg2) {
    (void)arg2;
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), (uint64_t)arg1, (uint64_t)arg1);
}

void __sanitizer_cov_trace_const_cmp2(uint16_t arg1, uint16_t arg2) {
    (void)arg2;
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), (uint64_t)arg1, (uint64_t)arg1);
}

void __sanitizer_cov_trace_const_cmp4(uint32_t arg1, uint32_t arg2) {
    (void)arg2;
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), (uint64_t)arg1, (uint64_t)arg1);
}

void __sanitizer_cov_trace_const_cmp8(uint64_t arg1, uint64_t arg2) {
    (void)arg2;
    exhaust_cmp_record((uint64_t)__builtin_return_address(0), arg1, arg1);
}

// The switch hook reports the switched value and a table: cases[0] is the case count, cases[1] the operand bit width, and cases[2..] the case constants. Each case constant is paired against the live value under the switch's own call-site key.
void __sanitizer_cov_trace_switch(uint64_t value, uint64_t *cases) {
    if (cases == NULL) {
        return;
    }
    struct exhaust_cmp_ring *bound = exhaust_cmp_bound_ring();
    uint64_t site = (uint64_t)__builtin_return_address(0);
    uint64_t count = cases[0];
    if (bound != NULL) {
        for (uint64_t index = 0; index < count; index += 1) {
            exhaust_cmp_ring_record(bound, site, value, cases[2 + index]);
        }
        return;
    }
    if (!atomic_load_explicit(&exhaust_cmp_global_enabled, memory_order_relaxed)) {
        return;
    }
    // One acquisition for the whole case table rather than one per case: every pair belongs to the same comparison site.
    exhaust_cmp_global_acquire();
    for (uint64_t index = 0; index < count; index += 1) {
        exhaust_cmp_ring_store(&exhaust_cmp_global, site, value, cases[2 + index]);
    }
    exhaust_cmp_global_release();
}

// MARK: - Trace-PC-Guard Edge Recording
//
// The isolated alternative to inline-8bit-counters. Instrumented with `-sanitize-coverage=edge,trace-pc-guard,pc-table`, every edge calls the hook below instead of incrementing a fixed global byte, which buys two things the counter model cannot express.
//
// Isolation: the hook reads a thread-local context, so two runs in one process write to different arrays instead of clearing each other's. Exhaust's property always executes on the runner's own thread, since `blockingAwait` drains an async property's continuations through `LaneExecutor` on the calling thread. A thread-local key is therefore correct by construction here, and none of the task-local inheritance machinery a general-purpose fuzzer needs applies.
//
// Sparsity: the hook appends each edge to a covered list on its first hit, so reset and read are both O(edges the attempt lit) rather than O(edges the binary contains). The counter model has no record of which counters moved, so it must clear and rescan the whole table every attempt: 17.7 µs on an 89,832-edge build against 0.46 µs for the clear alone.

#include <stdlib.h>

struct exhaust_tpg_context {
    uint8_t *hits;              // saturating per-edge count, indexed by guard id
    uint32_t *covered;          // edge ids in first-hit order
    size_t covered_count;
    size_t capacity;            // edge count + 1, since guard ids are 1-based
    struct exhaust_cmp_ring *comparisons; // this run's operand ring; the hooks write here while the context is bound
};

// Atomic: `__sanitizer_cov_trace_pc_guard_init` runs once per image, and a concurrent `dlopen` would otherwise race the reservation against a reader.
static _Atomic size_t exhaust_tpg_edge_count = 0;
// Edges fire before any run binds a context (module constructors, test-framework startup). A null binding drops them, which is the correct attribution: they belong to no attempt.
static _Thread_local struct exhaust_tpg_context *exhaust_tpg_current = NULL;
// Set while a thread hosts a run: the run's own lane is deliberately unbound between brackets, and edges it fires there (generation, reduction probes) are excluded by design, not lost. Edges fired on a thread that hosts no run are the loss the caller cannot see: property work that escaped to another executor, or another test exercising the instrumented code concurrently. Those are counted below while at least one context exists. The flag is cleared when the hosting thread destroys its context, so a recycled GCD lane starts clean; it is not exact while a lane hosts one run's bracket and, at the same time, another run's escaped work, which a per-context owner-thread check would close.
static _Thread_local int exhaust_tpg_thread_owned = 0;
// Atomic: contexts are created and destroyed on different lanes, and a lost update here would either over-count drops after the last run or, worse, read zero while contexts exist and silence the diagnostic for the rest of the process.
static _Atomic size_t exhaust_tpg_live_contexts = 0;
// Atomic: every off-lane thread that fires an edge while a context is live increments this, so a plain counter would be a data race even though a lost update only costs one unit of a diagnostic count.
static _Atomic size_t exhaust_tpg_dropped_hits = 0;

static struct exhaust_cmp_ring *exhaust_cmp_bound_ring(void) {
    struct exhaust_tpg_context *context = exhaust_tpg_current;
    return context == NULL ? NULL : context->comparisons;
}

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
    if (start == stop || *start) {
        return;
    }
    // Reserve the whole range in one step: incrementing per guard would let a concurrently loading image interleave ids into this one's span.
    size_t span = (size_t)(stop - start);
    size_t base = atomic_fetch_add_explicit(&exhaust_tpg_edge_count, span, memory_order_relaxed);
    uint32_t next = (uint32_t)(base + 1);
    for (uint32_t *guard = start; guard < stop; guard++) {
        *guard = next++;
    }
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    struct exhaust_tpg_context *context = exhaust_tpg_current;
    if (context == NULL) {
        if (!exhaust_tpg_thread_owned && atomic_load_explicit(&exhaust_tpg_live_contexts, memory_order_relaxed) != 0) {
            atomic_fetch_add_explicit(&exhaust_tpg_dropped_hits, 1, memory_order_relaxed);
        }
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
    return atomic_load_explicit(&exhaust_tpg_edge_count, memory_order_relaxed);
}

struct exhaust_tpg_context *exhaust_tpg_create(void) {
    size_t edge_count = atomic_load_explicit(&exhaust_tpg_edge_count, memory_order_relaxed);
    if (edge_count == 0) {
        return NULL;
    }
    struct exhaust_tpg_context *context = calloc(1, sizeof(struct exhaust_tpg_context));
    if (context == NULL) {
        return NULL;
    }
    // Capacity is a snapshot: an image loaded after this point extends the global edge count, and its edges fall past `capacity` and are dropped by the hook. Growing the arrays mid-run would invalidate the hit indices an attempt is already accumulating.
    context->capacity = edge_count + 1;
    context->hits = calloc(context->capacity, sizeof(uint8_t));
    context->covered = calloc(context->capacity, sizeof(uint32_t));
    context->comparisons = calloc(1, sizeof(struct exhaust_cmp_ring));
    if (context->hits == NULL || context->covered == NULL || context->comparisons == NULL) {
        free(context->hits);
        free(context->covered);
        free(context->comparisons);
        free(context);
        return NULL;
    }
    atomic_fetch_add_explicit(&exhaust_tpg_live_contexts, 1, memory_order_relaxed);
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
    // The destroying thread is the run's lane (the source is a local of the run), so its hosting ends here.
    exhaust_tpg_thread_owned = 0;
    atomic_fetch_sub_explicit(&exhaust_tpg_live_contexts, 1, memory_order_relaxed);
    free(context->hits);
    free(context->covered);
    free(context->comparisons);
    free(context);
}

void exhaust_tpg_adopt_thread(void) {
    exhaust_tpg_thread_owned = 1;
}

void exhaust_tpg_bind(struct exhaust_tpg_context *context) {
    exhaust_tpg_current = context;
    if (context != NULL) {
        exhaust_tpg_thread_owned = 1;
    }
}

size_t exhaust_tpg_dropped_hit_count(void) {
    return atomic_load_explicit(&exhaust_tpg_dropped_hits, memory_order_relaxed);
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

const uint8_t *exhaust_tpg_hits(struct exhaust_tpg_context *context) {
    return context == NULL ? NULL : context->hits;
}

_Bool exhaust_tpg_is_bound(struct exhaust_tpg_context *context) {
    return context != NULL && exhaust_tpg_current == context;
}

// MARK: - Per-Context Comparison Harvest

void exhaust_tpg_cmp_set_enabled(struct exhaust_tpg_context *context, int enabled) {
    if (context != NULL) {
        context->comparisons->enabled = enabled;
    }
}

void exhaust_tpg_cmp_reset(struct exhaust_tpg_context *context) {
    if (context != NULL) {
        context->comparisons->cursor = 0;
    }
}

size_t exhaust_tpg_cmp_record_count(struct exhaust_tpg_context *context) {
    return context == NULL ? 0 : exhaust_cmp_ring_count(context->comparisons);
}

const uint64_t *exhaust_tpg_cmp_records(struct exhaust_tpg_context *context) {
    return context == NULL ? NULL : context->comparisons->buffer;
}

#ifdef DEBUG
void exhaust_tpg_reset_registry_for_testing(void) {
    atomic_store_explicit(&exhaust_tpg_edge_count, 0, memory_order_relaxed);
    exhaust_tpg_current = NULL;
    exhaust_tpg_thread_owned = 0;
    atomic_store_explicit(&exhaust_tpg_dropped_hits, 0, memory_order_relaxed);
}
#endif
