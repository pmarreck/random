#ifndef RANDOMZ_H
#define RANDOMZ_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RANDOMZ_VERSION "0.3.0"
#define RANDOMZ_DRBG_KEY_BYTES 32
#define RANDOMZ_MAX_EXACT_POSITION UINT64_C(9007199254740992)
#define RANDOMZ_FIXED_STRING_BYTES 4096
#define RANDOMZ_CURVE_MAX_SAMPLES 4096

typedef enum randomz_status {
	RANDOMZ_OK = 0,
	RANDOMZ_INVALID_ARGUMENT = 1,
	RANDOMZ_ENTROPY_ERROR = 2,
	RANDOMZ_POSITION_OVERFLOW = 3,
	RANDOMZ_BUFFER_TOO_SMALL = 4,
	RANDOMZ_NUMERIC_ERROR = 5
} randomz_status;

typedef struct randomz_fixed {
	/* Canonical value: m * 2^(e-62). Nonzero |m| is in [2^62,2^63);
	 * zero is exactly {0,0}. Construct with parse/from_int, not literals. */
	int64_t m;
	int32_t e;
} randomz_fixed;

typedef enum randomz_distribution {
	RANDOMZ_DISTRIBUTION_NORMAL = 1,
	RANDOMZ_DISTRIBUTION_EXPONENTIAL = 2,
	RANDOMZ_DISTRIBUTION_POISSON = 3,
	RANDOMZ_DISTRIBUTION_LOG_NORMAL = 4,
	RANDOMZ_DISTRIBUTION_BETA = 5
} randomz_distribution;

/* Caller-owned, trivially serializable, and sensitive when secretly seeded.
 * A state is not thread-safe; copying or forking clones its future stream. */
typedef struct randomz_drbg {
	uint8_t key[RANDOMZ_DRBG_KEY_BYTES];
	uint64_t position;
} randomz_drbg;

/* Return RANDOMZ_OK after filling exactly count bytes. Known randomz_status
 * failures are preserved by samplers; unknown nonzero values map to
 * RANDOMZ_ENTROPY_ERROR. */
typedef int (*randomz_fill_fn)(void *context, uint8_t *out, size_t count);

/* BLAKE3 KDF(seed_material) -> keyed empty-message XOF at byte position zero. */
int randomz_drbg_init(randomz_drbg *state,
	const uint8_t seed_material[RANDOMZ_DRBG_KEY_BYTES]);
int randomz_drbg_set_state(randomz_drbg *state,
	const uint8_t key[RANDOMZ_DRBG_KEY_BYTES], uint64_t position);
int randomz_drbg_get_state(const randomz_drbg *state,
	uint8_t key[RANDOMZ_DRBG_KEY_BYTES], uint64_t *position);
/* Reposition an initialized DRBG without exposing or replacing its derived key. */
int randomz_drbg_seek(randomz_drbg *state, uint64_t position);
int randomz_drbg_fill(randomz_drbg *state, uint8_t *out, size_t count);
int randomz_drbg_u32(randomz_drbg *state, uint32_t *out);
int randomz_drbg_u64(randomz_drbg *state, uint64_t *out);
void randomz_drbg_zeroize(randomz_drbg *state);

/* Optional small-draw acceleration. Storage is caller-owned and sensitive.
 * Treat fields as private: use buffered setters, not the unbuffered setters
 * on state. Serialize only get_state's key/position; cached bytes are derived.
 * A copied context clones the future stream. Zeroize the whole context. */
typedef struct randomz_buffered_drbg {
	randomz_drbg state;
	uint8_t cache[1024];
	uint64_t cache_start;
	uint64_t cache_len;
} randomz_buffered_drbg;
int randomz_buffered_drbg_init(randomz_buffered_drbg *state,
	const uint8_t seed_material[RANDOMZ_DRBG_KEY_BYTES]);
int randomz_buffered_drbg_set_state(randomz_buffered_drbg *state,
	const uint8_t key[RANDOMZ_DRBG_KEY_BYTES], uint64_t position);
int randomz_buffered_drbg_get_state(const randomz_buffered_drbg *state,
	uint8_t key[RANDOMZ_DRBG_KEY_BYTES], uint64_t *position);
int randomz_buffered_drbg_seek(randomz_buffered_drbg *state, uint64_t position);
int randomz_buffered_drbg_fill(randomz_buffered_drbg *state, uint8_t *out, size_t count);
void randomz_buffered_drbg_zeroize(randomz_buffered_drbg *state);

/* Pure samplers. The callback is the only byte source and must fill exactly. */
int randomz_range(randomz_fill_fn fill, void *context,
	int64_t start, int64_t end, int64_t *out);
int randomz_uniform(randomz_fill_fn fill, void *context, randomz_fixed *out);
int randomz_normal_int(randomz_fill_fn fill, void *context,
	int64_t start, int64_t end, int64_t *out);
int randomz_normal(randomz_fill_fn fill, void *context,
	randomz_fixed mean, randomz_fixed stddev, randomz_fixed *out);
int randomz_exponential(randomz_fill_fn fill, void *context,
	randomz_fixed rate, randomz_fixed *out);
int randomz_poisson(randomz_fill_fn fill, void *context,
	randomz_fixed lambda, int64_t *out);
int randomz_log_normal(randomz_fill_fn fill, void *context,
	randomz_fixed mean, randomz_fixed stddev, randomz_fixed *out);
int randomz_beta(randomz_fill_fn fill, void *context,
	randomz_fixed alpha, randomz_fixed beta, randomz_fixed *out);

/* Pure, entropy-free distribution curves for visualization. `first` and
 * `second` are mean/stddev (normal and log-normal), rate/zero
 * (exponential), lambda/zero (Poisson), or alpha/beta (beta). Heights are
 * normalized to [0,65535]. Continuous curves write `capacity` samples;
 * Poisson writes one sample per integer when that fits, otherwise a
 * capacity-wide compressed curve. The caller supplies all storage. */
int randomz_distribution_curve(randomz_distribution distribution,
	randomz_fixed first, randomz_fixed second,
	uint16_t *heights, size_t capacity, size_t *written,
	randomz_fixed *x_min, randomz_fixed *x_max);

/* Total public conversions for the internal integer-only numeric format. */
randomz_fixed randomz_fixed_from_int(int64_t value);
int randomz_fixed_to_int_trunc(randomz_fixed value, int64_t *out);
int randomz_fixed_to_int_round(randomz_fixed value, int64_t *out);
int randomz_fixed_parse(const char *text, size_t length, randomz_fixed *out);
int randomz_fixed_parse_int_safe(const char *text, size_t length, int64_t *out);
/* Writes an unterminated byte span and its length; capacity excludes no
 * implicit NUL. Callers that need a C string reserve and append one byte. */
int randomz_fixed_format(randomz_fixed value, size_t decimal_places,
	char *out, size_t capacity, size_t *written);

#ifdef __cplusplus
}
#endif

#endif
