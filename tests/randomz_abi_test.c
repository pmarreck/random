#include "randomz.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

_Static_assert(RANDOMZ_OK == 0, "status ABI drift");
_Static_assert(RANDOMZ_NUMERIC_ERROR == 5, "status ABI drift");
_Static_assert(RANDOMZ_DISTRIBUTION_NORMAL == 1, "distribution ABI drift");
_Static_assert(RANDOMZ_DISTRIBUTION_BETA == 5, "distribution ABI drift");
_Static_assert(sizeof(randomz_fixed) == 16, "randomz_fixed ABI drift");
_Static_assert(offsetof(randomz_fixed, m) == 0, "randomz_fixed.m ABI drift");
_Static_assert(offsetof(randomz_fixed, e) == 8, "randomz_fixed.e ABI drift");
_Static_assert(sizeof(randomz_drbg) == 40, "randomz_drbg ABI drift");
_Static_assert(offsetof(randomz_drbg, position) == 32, "randomz_drbg.position ABI drift");

#define CHECK(condition) do { \
	if (!(condition)) { \
		fprintf(stderr, "randomz ABI check failed at line %d: %s\n", __LINE__, #condition); \
		return 1; \
	} \
} while (0)

static int drbg_fill(void *context, uint8_t *out, size_t count)
{
	return randomz_drbg_fill((randomz_drbg *)context, out, count);
}

static int failed_fill(void *context, uint8_t *out, size_t count)
{
	(void)context;
	(void)out;
	(void)count;
	return 42;
}

int main(void)
{
	static const uint8_t expected_prefix[8] = {
		0x69, 0xdf, 0xe2, 0xe9, 0xb5, 0x79, 0xcf, 0x6d,
	};
	static const uint8_t expected_second[8] = {
		0xfe, 0x3d, 0x71, 0xb1, 0x10, 0x24, 0xdb, 0x6e,
	};
	uint8_t seed[32] = {0};
	seed[31] = 42;
	randomz_drbg state;
	CHECK(randomz_drbg_init(&state, seed) == RANDOMZ_OK);
	uint8_t bytes[8];
	CHECK(randomz_drbg_fill(&state, bytes, sizeof(bytes)) == RANDOMZ_OK);
	CHECK(memcmp(bytes, expected_prefix, sizeof(bytes)) == 0);
	CHECK(state.position == 8);

	uint8_t key[32];
	uint64_t position = 0;
	CHECK(randomz_drbg_get_state(&state, key, &position) == RANDOMZ_OK);
	CHECK(position == 8);
	randomz_drbg resumed;
	CHECK(randomz_drbg_set_state(&resumed, key, position) == RANDOMZ_OK);
	CHECK(randomz_drbg_fill(&resumed, bytes, sizeof(bytes)) == RANDOMZ_OK);
	CHECK(resumed.position == 16);
	CHECK(randomz_drbg_set_state(&resumed, key, RANDOMZ_MAX_EXACT_POSITION + 1) ==
		RANDOMZ_POSITION_OVERFLOW);
	CHECK(randomz_drbg_seek(&state, 8) == RANDOMZ_OK);
	CHECK(randomz_drbg_fill(&state, bytes, sizeof(bytes)) == RANDOMZ_OK);
	CHECK(memcmp(bytes, expected_second, sizeof(bytes)) == 0);
	CHECK(randomz_drbg_seek(&state, RANDOMZ_MAX_EXACT_POSITION + 1) ==
		RANDOMZ_POSITION_OVERFLOW);
	CHECK(randomz_drbg_seek(NULL, 0) == RANDOMZ_INVALID_ARGUMENT);
	CHECK(randomz_drbg_fill(&resumed, NULL, 0) == RANDOMZ_OK);
	CHECK(randomz_drbg_init(NULL, seed) == RANDOMZ_INVALID_ARGUMENT);
	CHECK(randomz_drbg_get_state(&state, NULL, &position) == RANDOMZ_INVALID_ARGUMENT);

	CHECK(randomz_drbg_init(&state, seed) == RANDOMZ_OK);
	uint32_t u32 = 0;
	CHECK(randomz_drbg_u32(&state, &u32) == RANDOMZ_OK);
	CHECK(u32 == UINT32_C(0x69dfe2e9));
	CHECK(randomz_drbg_init(&state, seed) == RANDOMZ_OK);
	uint64_t u64 = 0;
	CHECK(randomz_drbg_u64(&state, &u64) == RANDOMZ_OK);
	CHECK(u64 == UINT64_C(0x69dfe2e9b579cf6d));
	randomz_drbg_zeroize(&state);
	for (size_t i = 0; i < sizeof(state.key); ++i) CHECK(state.key[i] == 0);
	CHECK(state.position == 0);
	CHECK(randomz_drbg_init(&state, seed) == RANDOMZ_OK);

	int64_t integer = 0;
	CHECK(randomz_range(drbg_fill, &state, -17, 981, &integer) == RANDOMZ_OK);
	CHECK(randomz_range(NULL, NULL, 0, 1, &integer) == RANDOMZ_INVALID_ARGUMENT);
	CHECK(randomz_range(failed_fill, NULL, 0, 1, &integer) == RANDOMZ_ENTROPY_ERROR);

	randomz_fixed zero = randomz_fixed_from_int(0);
	randomz_fixed one = randomz_fixed_from_int(1);
	randomz_fixed two = randomz_fixed_from_int(2);
	randomz_fixed three = randomz_fixed_from_int(3);
	randomz_fixed sampled;
	CHECK(randomz_fixed_to_int_trunc(two, &integer) == RANDOMZ_OK && integer == 2);
	CHECK(randomz_fixed_to_int_round(two, &integer) == RANDOMZ_OK && integer == 2);
	randomz_fixed invalid_fixed = {1, 0};
	CHECK(randomz_fixed_to_int_trunc(invalid_fixed, &integer) == RANDOMZ_INVALID_ARGUMENT);
	CHECK(randomz_fixed_to_int_round(two, NULL) == RANDOMZ_INVALID_ARGUMENT);

	randomz_fixed parsed;
	CHECK(randomz_fixed_parse("-7.25", 5, &parsed) == RANDOMZ_OK);
	CHECK(randomz_fixed_parse("no", 2, &parsed) == RANDOMZ_INVALID_ARGUMENT);
	CHECK(randomz_fixed_parse_int_safe("42", 2, &integer) == RANDOMZ_OK && integer == 42);
	char rendered[64];
	size_t written = 0;
	CHECK(randomz_fixed_format(two, 6, rendered, sizeof(rendered), &written) == RANDOMZ_OK);
	CHECK(written == 8 && memcmp(rendered, "2.000000", 8) == 0);
	CHECK(randomz_fixed_format(two, 6, rendered, 2, &written) == RANDOMZ_BUFFER_TOO_SMALL);
	uint16_t curve[64];
	size_t curve_count = 0;
	randomz_fixed x_min;
	randomz_fixed x_max;
	CHECK(randomz_distribution_curve(RANDOMZ_DISTRIBUTION_EXPONENTIAL,
		two, zero, curve, 64, &curve_count, &x_min, &x_max) == RANDOMZ_OK);
	CHECK(curve_count == 64 && curve[0] == UINT16_MAX && curve[63] < curve[0]);
	CHECK(randomz_fixed_to_int_trunc(x_min, &integer) == RANDOMZ_OK && integer == 0);
	CHECK(randomz_fixed_to_int_trunc(x_max, &integer) == RANDOMZ_OK && integer == 3);
	CHECK(randomz_distribution_curve(RANDOMZ_DISTRIBUTION_POISSON,
		one, zero, curve, 64, &curve_count, &x_min, &x_max) == RANDOMZ_OK);
	CHECK(curve_count == 9 && curve[0] == UINT16_MAX && curve[1] == UINT16_MAX);
	CHECK(randomz_distribution_curve(RANDOMZ_DISTRIBUTION_BETA,
		one, three, curve, 64, &curve_count, &x_min, &x_max) == RANDOMZ_OK);
	CHECK(curve_count == 64 && curve[0] > curve[63]);
	CHECK(randomz_distribution_curve(RANDOMZ_DISTRIBUTION_NORMAL,
		zero, one, curve, 1, &curve_count, &x_min, &x_max) == RANDOMZ_INVALID_ARGUMENT);
	randomz_fixed huge;
	CHECK(randomz_fixed_parse("1500000000", 10, &huge) == RANDOMZ_OK);
	CHECK(randomz_log_normal(drbg_fill, &state, huge, one, &sampled) == RANDOMZ_NUMERIC_ERROR);
	CHECK(randomz_log_normal(drbg_fill, &state, invalid_fixed, one, &sampled) ==
		RANDOMZ_INVALID_ARGUMENT);

	CHECK(randomz_drbg_init(&state, seed) == RANDOMZ_OK);
	CHECK(randomz_uniform(drbg_fill, &state, &sampled) == RANDOMZ_OK);
	CHECK(randomz_normal_int(drbg_fill, &state, -18, 0, &integer) == RANDOMZ_OK);
	CHECK(randomz_normal(drbg_fill, &state, zero, one, &sampled) == RANDOMZ_OK);
	CHECK(randomz_exponential(drbg_fill, &state, one, &sampled) == RANDOMZ_OK);
	CHECK(randomz_poisson(drbg_fill, &state, two, &integer) == RANDOMZ_OK);
	CHECK(randomz_log_normal(drbg_fill, &state, zero, one, &sampled) == RANDOMZ_OK);
	CHECK(randomz_beta(drbg_fill, &state, two, three, &sampled) == RANDOMZ_OK);
	CHECK(randomz_normal(drbg_fill, &state, zero, zero, &sampled) == RANDOMZ_INVALID_ARGUMENT);
	CHECK(randomz_uniform(failed_fill, NULL, &sampled) == RANDOMZ_ENTROPY_ERROR);

	puts("randomz C ABI conformance PASSED: layout + every public symbol");
	return 0;
}
