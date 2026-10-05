#include "randomroc.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Internal allocator calls are exercised only by this archive boundary test. */
extern void *roc_alloc(size_t, size_t);
extern void roc_dealloc(void *, size_t);

static int fill(void *state, uint8_t *out, size_t count)
{
	return randomroc_drbg_fill(state, out, count);
}

static void *thread_probe(void *unused)
{
	(void)unused;
	uint8_t seed[32] = {0};
	seed[31] = 42;
	randomroc_drbg state;
	if (randomroc_drbg_init(&state, seed)) return (void *)(uintptr_t)1;
	for (size_t i = 0; i < 100; ++i) {
		randomroc_fixed value = {0, 0};
		if (randomroc_drbg_seek(&state, 0) ||
			randomroc_uniform(fill, &state, &value) ||
			value.m != INT64_C(7629065784144166912) || value.e != -2 ||
			state.position != 4 || randomroc_debug_live() != 0)
			return (void *)(uintptr_t)2;
	}
	randomroc_drbg_zeroize(&state);
	return NULL;
}

int main(int argc, char **argv)
{
	if (argc > 1 && strcmp(argv[1], "guard") == 0) {
		uint8_t *bytes = roc_alloc(1, 8);
		bytes[1] = 0; /* Deliberately corrupt the allocation's trailing guard. */
		roc_dealloc(bytes, 8);
		return 9; /* An optimized-away guard must not look like a passing test. */
	}
	uint8_t expected[] = {
		0x69, 0xdf, 0xe2, 0xe9, 0xb5, 0x79, 0xcf, 0x6d,
		0xfe, 0x3d, 0x71, 0xb1, 0x10, 0x24, 0xdb, 0x6e
	};
	if (argc > 1 && strcmp(argv[1], "bad-vector") == 0) expected[0] ^= 1;
	uint8_t seed[32] = {0}, bytes[sizeof(expected)];
	randomroc_drbg state;
	seed[31] = 42;
	if (randomroc_drbg_init(&state, seed) ||
		randomroc_drbg_fill(&state, bytes, sizeof(bytes)) ||
		memcmp(bytes, expected, sizeof(bytes)) || state.position != 16 ||
		randomroc_debug_live() != 0) return 1;
	randomroc_drbg_zeroize(&state);
	for (size_t i = 0; i < sizeof(state); ++i)
		if (((const uint8_t *)&state)[i] != 0) return 2;
	pthread_t threads[4];
	for (size_t i = 0; i < 4; ++i)
		if (pthread_create(&threads[i], NULL, thread_probe, NULL)) return 3;
	for (size_t i = 0; i < 4; ++i) {
		void *result = NULL;
		if (pthread_join(threads[i], &result) || result != NULL) return 4;
	}
	puts("Roc archive: frozen bytes, zeroization, reentrant callbacks and four-thread isolation passed.");
	return 0;
}
