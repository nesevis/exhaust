#include "ExhaustTraceCmp.h"

// MARK: - Site-Keyed Operand Ring Buffer
//
// Each record carries the comparison's call-site address (the return address into the instrumented system under test), so the harvest can group operands by the comparison that produced them. Grouping matters because a shallow comparison in a cascade fires on every attempt and would otherwise flood a flat pool, drowning the constants of deeper comparisons that only fire once earlier ones match.
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
    if (exhaust_cmp_cursor >= EXHAUST_CMP_CAPACITY) {
        return;
    }
    size_t slot = exhaust_cmp_cursor * 3;
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
// The call-site key is __builtin_return_address(0) read in the hook itself (not the shared helper), so it is the address in the instrumented SUT immediately after the call — distinct per comparison site. Every width widens into the same u64 slots; the mutator filters injected values against each site's declared range regardless of the width the comparison used.

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
