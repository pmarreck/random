#ifndef RANDOMB_H
#define RANDOMB_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#if defined(__GNUC__)
#define RANDOMB_API __attribute__((visibility("default")))
#else
#define RANDOMB_API
#endif
#define RANDOMB_VERSION "0.4.0"
enum {
	RANDOMB_OK = 0, RANDOMB_INVALID_ARGUMENT = 1, RANDOMB_ENTROPY_ERROR = 2,
	RANDOMB_POSITION_OVERFLOW = 3, RANDOMB_BUFFER_TOO_SMALL = 4, RANDOMB_NUMERIC_ERROR = 5
};
/* Integer-only m * 2^(e-62), canonical zero 0/0; otherwise 2^62 <= |m| < 2^63. */
typedef struct { int64_t m; int32_t e; } randomb_fixed;
/* Caller-owned key and next byte cursor; do not concurrently mutate one state. */
typedef struct { uint8_t key[32]; uint64_t position; } randomb_drbg;
/* Fill exactly count bytes. Statuses 1..5 propagate; other errors become 2.
 * The evaluator lock is released before calling user I/O, including callbacks
 * that reenter this library. Actual source consumption survives failures. */
typedef int (*randomb_fill_fn)(void *, uint8_t *, size_t);
RANDOMB_API int randomb_drbg_init(randomb_drbg *, const uint8_t *);
RANDOMB_API int randomb_drbg_set_state(randomb_drbg *, const uint8_t *, uint64_t);
RANDOMB_API int randomb_drbg_get_state(const randomb_drbg *, uint8_t *, uint64_t *);
RANDOMB_API int randomb_drbg_seek(randomb_drbg *, uint64_t);
RANDOMB_API int randomb_drbg_fill(randomb_drbg *, uint8_t *, size_t);
RANDOMB_API int randomb_drbg_u32(randomb_drbg *, uint32_t *);
RANDOMB_API int randomb_drbg_u64(randomb_drbg *, uint64_t *);
/* Wipes the caller's state, not temporary copies in the experimental runtime. */
RANDOMB_API void randomb_drbg_zeroize(randomb_drbg *);
RANDOMB_API int randomb_uniform(randomb_fill_fn, void *, randomb_fixed *);
RANDOMB_API int randomb_normal(randomb_fill_fn, void *, randomb_fixed, randomb_fixed, randomb_fixed *);
RANDOMB_API int randomb_exponential(randomb_fill_fn, void *, randomb_fixed, randomb_fixed *);
RANDOMB_API int randomb_poisson(randomb_fill_fn, void *, randomb_fixed, int64_t *);
RANDOMB_API int randomb_log_normal(randomb_fill_fn, void *, randomb_fixed, randomb_fixed, randomb_fixed *);
RANDOMB_API int randomb_beta(randomb_fill_fn, void *, randomb_fixed, randomb_fixed, randomb_fixed *);
RANDOMB_API int randomb_range(randomb_fill_fn, void *, int64_t, int64_t, int64_t *);
RANDOMB_API int randomb_normal_int(randomb_fill_fn, void *, int64_t, int64_t, int64_t *);
/* Failures before success, canonical arbitrary-width unsigned BLIP v1.2.
 * Capacity limits encoded bytes, not the integer or total rejection work.
 * Invalid parameters/pointers leave written untouched; admitted failures set
 * it to zero. Callers must provide nonoverlapping output/state buffers. */
RANDOMB_API int randomb_geometric(randomb_fill_fn, void *, randomb_fixed, uint8_t *, size_t, size_t *);
/* Exact radix 10/16 formatting without NUL termination. Scratch is a compatible
 * capacity-admission argument; Bend owns its conversion workspace. Decimal
 * conversion is width-dependent and may be quadratic. */
RANDOMB_API int randomb_count_format(const uint8_t *, size_t, uint8_t, uint32_t *, size_t, char *, size_t, size_t *);
RANDOMB_API randomb_fixed randomb_fixed_from_int(int64_t);
RANDOMB_API int randomb_fixed_to_int_trunc(randomb_fixed, int64_t *);
RANDOMB_API int randomb_fixed_to_int_round(randomb_fixed, int64_t *);
RANDOMB_API int randomb_fixed_parse(const char *, size_t, randomb_fixed *);
RANDOMB_API int randomb_geometric_probability_parse(const char *, size_t, randomb_fixed *);
RANDOMB_API int randomb_fixed_parse_int_safe(const char *, size_t, int64_t *);
/* Exact deterministic truncation to 0..18 places, without NUL termination. */
RANDOMB_API int randomb_fixed_format(randomb_fixed, size_t, char *, size_t, size_t *);
/* Canonical model heights in 0..65535, independent of terminal/image encoding. */
RANDOMB_API int randomb_distribution_curve(int, randomb_fixed, randomb_fixed, uint16_t *, size_t, size_t *, randomb_fixed *, randomb_fixed *);
/* AUTO=0, SCALAR=1 and SIMD=2 use the same portable scalar Bend plan.
 * No prefetch; only completed prefix slots are written on source failure. */
RANDOMB_API int randomb_normal_int_batch(randomb_fill_fn, void *, int64_t, int64_t, int64_t *, size_t, size_t *, int);
/* Optional reason: 0 success, 1 invalid weight, 2 oversized total,
 * 3 zero total, 4 empty table. Indices are zero-based. */
RANDOMB_API int randomb_weighted_total(const int64_t *, size_t, int64_t *, uint8_t *);
RANDOMB_API int randomb_weight_add(int64_t, int64_t, int64_t *);
RANDOMB_API int randomb_weighted_index(randomb_fill_fn, void *, const int64_t *, size_t, int64_t *, uint8_t *);
RANDOMB_API int randomb_shuffle_indices(randomb_fill_fn, void *, int64_t *, size_t, size_t *);
/* Runtime allocation high-water pages, NOT a count of all live allocations.
 * Completed fixed-size calls should reuse pages after the relevant warmup. */
RANDOMB_API int randomb_debug_heap_pages(uint64_t *);
#ifdef __cplusplus
}
#endif
#endif
