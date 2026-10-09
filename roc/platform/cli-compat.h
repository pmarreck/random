#ifndef RANDOMROC_CLI_COMPAT_H
#define RANDOMROC_CLI_COMPAT_H
#include "../../include/randomroc.h"
#define RANDOM_CLI_ROC 1
#define RANDOM_CLI_NAME "randomroc"
#define RANDOM_CLI_KIND "roc"
#define RANDOM_CLI_NORMAL_NAME "nrandomroc"
#define RANDOM_CLI_DETERMINISTIC_NAME "drandomroc"
#define RANDOM_CLI_SEED_ENV "DRANDOMROC_SEED"
#define RANDOM_CLI_SEED_HELP "  DRANDOMROC_SEED   "
/* Internal frontend binding: this backend deliberately uses the plain Roc
 * DRBG. It is not a public buffered API or a claim of caching acceleration. */
#define RANDOMZ_H
#define RANDOMZ_VERSION RANDOMROC_VERSION
#define RANDOMZ_DRBG_KEY_BYTES 32
#define RANDOMZ_MAX_EXACT_POSITION UINT64_C(9007199254740992)
#define RANDOMZ_MAX_EXACT_INTEGER INT64_C(9007199254740992)
#define RANDOMZ_FIXED_STRING_BYTES 4096
#define RANDOMZ_CURVE_MAX_SAMPLES 4096
typedef randomroc_fixed randomz_fixed;
typedef randomroc_drbg randomz_drbg;
typedef randomroc_fill_fn randomz_fill_fn;
typedef int randomz_distribution;
typedef int randomz_batch_mode;
enum {
	RANDOMZ_OK = 0, RANDOMZ_INVALID_ARGUMENT = 1,
	RANDOMZ_ENTROPY_ERROR = 2, RANDOMZ_POSITION_OVERFLOW = 3,
	RANDOMZ_BUFFER_TOO_SMALL = 4, RANDOMZ_NUMERIC_ERROR = 5,
	RANDOMZ_DISTRIBUTION_NORMAL = 1, RANDOMZ_DISTRIBUTION_EXPONENTIAL = 2,
	RANDOMZ_DISTRIBUTION_POISSON = 3, RANDOMZ_DISTRIBUTION_LOG_NORMAL = 4,
	RANDOMZ_DISTRIBUTION_BETA = 5, RANDOMZ_DISTRIBUTION_GEOMETRIC = 6,
	RANDOMZ_BATCH_AUTO = 0, RANDOMZ_BATCH_SCALAR = 1, RANDOMZ_BATCH_SIMD = 2
};
#define randomz_uniform randomroc_uniform
#define randomz_normal randomroc_normal
#define randomz_exponential randomroc_exponential
#define randomz_poisson randomroc_poisson
#define randomz_log_normal randomroc_log_normal
#define randomz_beta randomroc_beta
#define randomz_range randomroc_range
#define randomz_normal_int randomroc_normal_int
#define randomz_geometric randomroc_geometric
#define randomz_count_format randomroc_count_format
#define randomz_fixed_from_int randomroc_fixed_from_int
#define randomz_fixed_to_int_trunc randomroc_fixed_to_int_trunc
#define randomz_fixed_to_int_round randomroc_fixed_to_int_round
#define randomz_fixed_parse randomroc_fixed_parse
#define randomz_geometric_probability_parse randomroc_geometric_probability_parse
#define randomz_fixed_parse_int_safe randomroc_fixed_parse_int_safe
#define randomz_fixed_format randomroc_fixed_format
#define randomz_drbg_init randomroc_drbg_init
#define randomz_drbg_set_state randomroc_drbg_set_state
#define randomz_drbg_get_state randomroc_drbg_get_state
#define randomz_drbg_seek randomroc_drbg_seek
#define randomz_drbg_fill randomroc_drbg_fill
#define randomz_drbg_u32 randomroc_drbg_u32
#define randomz_drbg_u64 randomroc_drbg_u64
#define randomz_drbg_zeroize randomroc_drbg_zeroize
#define randomz_distribution_curve randomroc_distribution_curve
#define randomz_normal_int_batch randomroc_normal_int_batch
typedef struct { randomroc_drbg state; } randomz_buffered_drbg;
static inline int randomz_buffered_drbg_init(randomz_buffered_drbg *state, const uint8_t *seed)
{
	return randomroc_drbg_init(&state->state, seed);
}
static inline int randomz_buffered_drbg_seek(randomz_buffered_drbg *state, uint64_t position)
{
	return randomroc_drbg_seek(&state->state, position);
}
static inline int randomz_buffered_drbg_fill(randomz_buffered_drbg *state, uint8_t *out, size_t count)
{
	return randomroc_drbg_fill(&state->state, out, count);
}
static inline void randomz_buffered_drbg_zeroize(randomz_buffered_drbg *state)
{
	randomroc_drbg_zeroize(&state->state);
}
#endif
