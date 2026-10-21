#ifndef RANDOMB_CLI_COMPAT_H
#define RANDOMB_CLI_COMPAT_H
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../include/randomb.h"
#define RANDOM_CLI_CORE_SELECTION 1
#define random_cli_shuffle_indices randomb_shuffle_indices
#define random_cli_weight_add randomb_weight_add
#define random_cli_weighted_total randomb_weighted_total
#define random_cli_weighted_index randomb_weighted_index
#define RANDOM_CLI_NAME "randomb"
#define RANDOM_CLI_KIND "bend"
#define RANDOM_CLI_NORMAL_NAME "nrandomb"
#define RANDOM_CLI_DETERMINISTIC_NAME "drandomb"
#define RANDOM_CLI_SEED_ENV "DRANDOMB_SEED"
#define RANDOM_CLI_SEED_HELP "  DRANDOMB_SEED     "
#define RANDOMZ_H
#define RANDOMZ_VERSION RANDOMB_VERSION
#define RANDOMZ_DRBG_KEY_BYTES 32
#define RANDOMZ_MAX_EXACT_POSITION UINT64_C(9007199254740992)
#define RANDOMZ_MAX_EXACT_INTEGER INT64_C(9007199254740992)
#define RANDOMZ_FIXED_STRING_BYTES 4096
#define RANDOMZ_CURVE_MAX_SAMPLES 4096
typedef randomb_fixed randomz_fixed;
typedef randomb_drbg randomz_drbg;
typedef randomb_fill_fn randomz_fill_fn;
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
#define randomz_uniform randomb_uniform
#define randomz_normal randomb_normal
#define randomz_exponential randomb_exponential
#define randomz_poisson randomb_poisson
#define randomz_log_normal randomb_log_normal
#define randomz_beta randomb_beta
#define randomz_range randomb_range
#define randomz_normal_int randomb_normal_int
#define randomz_geometric randomb_geometric
#define randomz_count_format randomb_count_format
#define randomz_fixed_from_int randomb_fixed_from_int
#define randomz_fixed_to_int_trunc randomb_fixed_to_int_trunc
#define randomz_fixed_to_int_round randomb_fixed_to_int_round
#define randomz_fixed_parse randomb_fixed_parse
#define randomz_geometric_probability_parse randomb_geometric_probability_parse
#define randomz_fixed_parse_int_safe randomb_fixed_parse_int_safe
#define randomz_fixed_format randomb_fixed_format
#define randomz_drbg_init randomb_drbg_init
#define randomz_drbg_set_state randomb_drbg_set_state
#define randomz_drbg_get_state randomb_drbg_get_state
#define randomz_drbg_seek randomb_drbg_seek
#define randomz_drbg_fill randomb_drbg_fill
#define randomz_drbg_u32 randomb_drbg_u32
#define randomz_drbg_u64 randomb_drbg_u64
#define randomz_drbg_zeroize randomb_drbg_zeroize
#define randomz_distribution_curve randomb_distribution_curve
#define randomz_normal_int_batch randomb_normal_int_batch
/* Internal frontend binding to the plain Bend state, not a buffered API or
 * a claim of caching acceleration. Caller-visible position stays logical. */
typedef struct { randomb_drbg state; } randomz_buffered_drbg;
static inline int randomz_buffered_drbg_init(randomz_buffered_drbg *state, const uint8_t *seed)
{
	return randomb_drbg_init(&state->state, seed);
}
static inline int randomz_buffered_drbg_seek(randomz_buffered_drbg *state, uint64_t position)
{
	return randomb_drbg_seek(&state->state, position);
}
static inline int randomz_buffered_drbg_fill(randomz_buffered_drbg *state, uint8_t *out, size_t count)
{
	return randomb_drbg_fill(&state->state, out, count);
}
static inline int randomz_buffered_drbg_get_state(const randomz_buffered_drbg *state, uint8_t *key, uint64_t *position)
{
	return randomb_drbg_get_state(&state->state, key, position);
}
static inline void randomz_buffered_drbg_zeroize(randomz_buffered_drbg *state)
{
	randomb_drbg_zeroize(&state->state);
}
#endif
