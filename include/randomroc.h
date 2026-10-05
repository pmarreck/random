#ifndef RANDOMROC_H
#define RANDOMROC_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RANDOMROC_VERSION "0.3.0"
#if defined(__GNUC__)
#define RANDOMROC_API __attribute__((visibility("default")))
#else
#define RANDOMROC_API
#endif
#define RANDOMROC_MAX_EXACT_POSITION UINT64_C(9007199254740992)
#define RANDOMROC_MAX_EXACT_INTEGER INT64_C(9007199254740992)
#define RANDOMROC_MAX_FRACTION_DIGITS 18
typedef enum randomroc_status {
	RANDOMROC_OK = 0, RANDOMROC_INVALID_ARGUMENT = 1,
	RANDOMROC_ENTROPY_ERROR = 2, RANDOMROC_POSITION_OVERFLOW = 3,
	RANDOMROC_BUFFER_TOO_SMALL = 4, RANDOMROC_NUMERIC_ERROR = 5
} randomroc_status;
typedef enum randomroc_distribution {
	RANDOMROC_DISTRIBUTION_NORMAL = 1, RANDOMROC_DISTRIBUTION_EXPONENTIAL = 2,
	RANDOMROC_DISTRIBUTION_POISSON = 3, RANDOMROC_DISTRIBUTION_LOG_NORMAL = 4,
	RANDOMROC_DISTRIBUTION_BETA = 5, RANDOMROC_DISTRIBUTION_GEOMETRIC = 6
} randomroc_distribution;

/* Integer-only canonical value m * 2^(e-62), with zero represented by 0/0.
 * All nonzero magnitudes are in [2^62, 2^63). Fields are not IEEE floats. */
typedef struct { int64_t m; int32_t e; } randomroc_fixed;
/* Caller-owned key and next byte position. Use setters rather than editing
 * fields; never share mutable state between threads without synchronization. */
typedef struct { uint8_t key[32]; uint64_t position; } randomroc_drbg;
/* Fill exactly count bytes. Known statuses 1..5 propagate; other failures
 * become ENTROPY_ERROR. Actual source consumption is retained on errors.
 * Synchronous reentrant calls use separate host contexts on the same thread. */
typedef int (*randomroc_fill_fn)(void *, uint8_t *, size_t);
RANDOMROC_API int randomroc_uniform(randomroc_fill_fn, void *, randomroc_fixed *);
RANDOMROC_API int randomroc_normal(randomroc_fill_fn, void *, randomroc_fixed, randomroc_fixed, randomroc_fixed *);
RANDOMROC_API int randomroc_exponential(randomroc_fill_fn, void *, randomroc_fixed, randomroc_fixed *);
RANDOMROC_API int randomroc_poisson(randomroc_fill_fn, void *, randomroc_fixed, int64_t *);
RANDOMROC_API int randomroc_log_normal(randomroc_fill_fn, void *, randomroc_fixed, randomroc_fixed, randomroc_fixed *);
RANDOMROC_API int randomroc_beta(randomroc_fill_fn, void *, randomroc_fixed, randomroc_fixed, randomroc_fixed *);
RANDOMROC_API int randomroc_range(randomroc_fill_fn, void *, int64_t, int64_t, int64_t *);
RANDOMROC_API int randomroc_normal_int(randomroc_fill_fn, void *, int64_t, int64_t, int64_t *);
/* Failures before success, canonical arbitrary-width unsigned BLIP v1.2.
 * Capacity limits bytes, not integer width or total rejection work. A late
 * capacity error retains prior source consumption. No count is narrowed. */
RANDOMROC_API int randomroc_geometric(randomroc_fill_fn, void *, randomroc_fixed, uint8_t *, size_t, size_t *);
/* Radix 10 or 16, exact text without NUL termination. Scratch is a compatible
 * capacity-admission parameter, not a no-allocation guarantee: the Roc core
 * owns its conversion workspace and may leave the supplied scratch untouched.
 * Decimal conversion is width-dependent and potentially quadratic. */
RANDOMROC_API int randomroc_count_format(const uint8_t *, size_t, uint8_t, uint32_t *, size_t, char *, size_t, size_t *);
RANDOMROC_API randomroc_fixed randomroc_fixed_from_int(int64_t);
RANDOMROC_API int randomroc_fixed_to_int_trunc(randomroc_fixed, int64_t *);
RANDOMROC_API int randomroc_fixed_to_int_round(randomroc_fixed, int64_t *);
RANDOMROC_API int randomroc_fixed_parse(const char *, size_t, randomroc_fixed *);
RANDOMROC_API int randomroc_geometric_probability_parse(const char *, size_t, randomroc_fixed *);
RANDOMROC_API int randomroc_fixed_parse_int_safe(const char *, size_t, int64_t *);
/* Truncates to 0..18 fractional places. Text is not NUL-terminated. */
RANDOMROC_API int randomroc_fixed_format(randomroc_fixed, size_t, char *, size_t, size_t *);
RANDOMROC_API int randomroc_drbg_init(randomroc_drbg *, const uint8_t *);
RANDOMROC_API int randomroc_drbg_set_state(randomroc_drbg *, const uint8_t *, uint64_t);
RANDOMROC_API int randomroc_drbg_get_state(const randomroc_drbg *, uint8_t *, uint64_t *);
RANDOMROC_API int randomroc_drbg_seek(randomroc_drbg *, uint64_t);
RANDOMROC_API int randomroc_drbg_fill(randomroc_drbg *, uint8_t *, size_t);
RANDOMROC_API int randomroc_drbg_u32(randomroc_drbg *, uint32_t *);
RANDOMROC_API int randomroc_drbg_u64(randomroc_drbg *, uint64_t *);
RANDOMROC_API void randomroc_drbg_zeroize(randomroc_drbg *);
RANDOMROC_API int randomroc_distribution_curve(int, randomroc_fixed, randomroc_fixed, uint16_t *, size_t, size_t *, randomroc_fixed *, randomroc_fixed *);
/* Mode 0 (AUTO) and 1 (SCALAR) currently use identical scalar Roc plans.
 * Constant auxiliary batch storage; no prefetch. On a callback failure,
 * written counts only the complete prefix; untouched tail slots stay intact. */
RANDOMROC_API int randomroc_normal_int_batch(randomroc_fill_fn, void *, int64_t, int64_t, int64_t *, size_t, size_t *, int);
/* Optional reason: 0 success, 1 invalid weight, 2 oversized total,
 * 3 zero total, 4 empty table. Indexes are zero-based. */
RANDOMROC_API int randomroc_weighted_total(const int64_t *, size_t, int64_t *, uint8_t *);
RANDOMROC_API int randomroc_weight_add(int64_t, int64_t, int64_t *);
RANDOMROC_API int randomroc_weighted_index(randomroc_fill_fn, void *, const int64_t *, size_t, int64_t *, uint8_t *);
/* Fisher-Yates index permutation. Byte spans and rendering belong to callers.
 * Auxiliary storage is O(count); count 0/1 consumes no entropy. */
RANDOMROC_API int randomroc_shuffle_indices(randomroc_fill_fn, void *, int64_t *, size_t, size_t *);
/* Diagnostics: thread-local live Roc allocations; completed calls release
 * owned temporary lists. Allocation failure follows Roc's fail-stop policy. */
RANDOMROC_API size_t randomroc_debug_live(void);
#ifdef __cplusplus
}
#endif
#endif
