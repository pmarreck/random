#include "roc_platform_abi.h"
#include "../../include/randomroc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* These memory/ABI guards stay active in optimized builds (including NDEBUG).
 * They do not substitute for recoverable domain checks in the Roc core. */
static void require(int condition) {
	if (!condition) abort();
}

typedef struct Allocation {
	void *raw;
	size_t length;
	size_t alignment;
} Allocation;
static _Thread_local size_t live;

void *roc_alloc(size_t length, size_t alignment) {
	if (!alignment || (alignment & (alignment - 1))) abort();
	if (alignment < _Alignof(Allocation)) alignment = _Alignof(Allocation);
	if (alignment > SIZE_MAX - sizeof(Allocation) - 32 ||
		length > SIZE_MAX - sizeof(Allocation) - 32 - alignment) abort();
	uint8_t *raw = malloc(length + sizeof(Allocation) + 32 + alignment);
	if (!raw) abort();
	uintptr_t address = ((uintptr_t)raw + sizeof(Allocation) + 16 + alignment - 1) & ~(alignment - 1);
	uint8_t *user = (uint8_t *)address;
	Allocation *header = (Allocation *)(user - 16 - sizeof(Allocation));
	*header = (Allocation){raw, length, alignment};
	memset(user - 16, 0xa5, 16);
	memset(user + length, 0xa5, 16);
	live++;
	return user;
}

void roc_dealloc(void *ptr, size_t alignment) {
	if (!ptr) return;
	uint8_t *user = ptr;
	Allocation header = *(Allocation *)(user - 16 - sizeof(Allocation));
	if (alignment < _Alignof(Allocation)) alignment = _Alignof(Allocation);
	require(header.alignment == alignment);
	for (size_t i = 0; i < 16; i++) {
		require(user[i + header.length] == 0xa5 && user[(ptrdiff_t)i - 16] == 0xa5);
	}
	require(live > 0);
	live--;
	volatile uint8_t *wipe = user;
	for (size_t i = 0; i < header.length; i++) wipe[i] = 0;
	free(header.raw);
}

void *roc_realloc(void *ptr, size_t length, size_t alignment) {
	if (!ptr) return roc_alloc(length, alignment);
	Allocation header = *(Allocation *)((uint8_t *)ptr - 16 - sizeof(Allocation));
	void *fresh = roc_alloc(length, alignment);
	memcpy(fresh, ptr, length < header.length ? length : header.length);
	roc_dealloc(ptr, alignment);
	return fresh;
}

void roc_dbg(const uint8_t *bytes, size_t count) { fwrite(bytes, 1, count, stderr); }
void roc_expect_failed(const uint8_t *bytes, size_t count) { fwrite(bytes, 1, count, stderr); abort(); }
void roc_crashed(const uint8_t *bytes, size_t count) { fwrite(bytes, 1, count, stderr); abort(); }

typedef struct Context {
	randomroc_fill_fn fill;
	void *source;
	randomroc_fixed *numeric;
	int64_t *integer;
	uint8_t *output;
	size_t capacity;
	size_t *written;
	const uint8_t *input;
	size_t input_length;
	randomroc_drbg *state;
	uint32_t *u32;
	uint64_t *u64;
	uint16_t *heights;
	randomroc_fixed *x_min;
	randomroc_fixed *x_max;
	int64_t *integers;
	const int64_t *weights;
	size_t weight_count;
	uint8_t *reason;
	uint8_t source_error;
} Context;
static _Thread_local Context *current;

RocList randomroc_host_source(uint64_t count) {
	Context *context = current;
	require(context && context->fill && count <= 1048576);
	RocList list = randomroc_owned_bytes(count);
	require(list.length == count);
	int status = context->fill(context->source, list.elements, list.length);
	context->source_error = status == 0 ? 0 : (status >= 1 && status <= 5 ? (uint8_t)status : 2);
	return list;
}

uint8_t randomroc_host_status(void) {
	require(current != NULL);
	return current->source_error;
}

void randomroc_host_numeric(int64_t m, int32_t e) {
	require(current && current->numeric);
	*current->numeric = (randomroc_fixed){m, e};
}

void randomroc_host_integer(int64_t value) {
	require(current && current->integer);
	*current->integer = value;
}

void randomroc_host_begin(void) {
	require(current && current->written);
	*current->written = 0;
}

RocList randomroc_host_output(RocList bytes) {
	require(current && current->output && current->written && bytes.length <= current->capacity);
	memcpy(current->output, bytes.elements, bytes.length);
	*current->written = bytes.length;
	return bytes;
}

RocList randomroc_host_input(void) {
	require(current && current->input);
	RocList bytes = randomroc_owned_bytes(current->input_length);
	if (bytes.length) memcpy(bytes.elements, current->input, bytes.length);
	return bytes;
}

RocList randomroc_host_state(RocList key, uint64_t position) {
	require(current && current->state && key.length == 32);
	memcpy(current->state->key, key.elements, key.length);
	current->state->position = position;
	return key;
}

RocList randomroc_host_chunk(RocList bytes, uint64_t offset) {
	require(current && current->output && offset <= current->capacity && bytes.length <= current->capacity - offset);
	memcpy(current->output + offset, bytes.elements, bytes.length);
	return bytes;
}

void randomroc_host_u32(uint32_t value) {
	require(current && current->u32);
	*current->u32 = value;
}

void randomroc_host_u64(uint64_t value) {
	require(current && current->u64);
	*current->u64 = value;
}

void randomroc_host_count(uint64_t count) {
	require(current && current->written);
	*current->written = count;
}

RocList randomroc_host_curve(RocList heights, int64_t lm, int32_t le, int64_t hm, int32_t he) {
	require(current && current->heights && current->x_min && current->x_max && current->written);
	require(heights.length <= current->capacity);
	memcpy(current->heights, heights.elements, heights.length * sizeof(uint16_t));
	*current->written = heights.length;
	*current->x_min = (randomroc_fixed){lm, le};
	*current->x_max = (randomroc_fixed){hm, he};
	return heights;
}

void randomroc_host_item(int64_t value, uint64_t index, uint64_t completed) {
	require(current && current->integers && current->written && index < current->capacity);
	current->integers[index] = value;
	*current->written = completed;
}

RocList randomroc_host_weights(void) {
	require(current && current->weights && current->weight_count <= SIZE_MAX / sizeof(int64_t));
	RocList list = randomroc_owned_i64(current->weight_count);
	if (list.length) memcpy(list.elements, current->weights, list.length * sizeof(int64_t));
	return list;
}

void randomroc_host_reason(uint8_t reason) {
	require(current != NULL);
	if (current->reason) *current->reason = reason;
}

RocList randomroc_host_permutation(RocList indices) {
	require(current && current->written && indices.length == current->capacity);
	if (indices.length) {
		require(current->integers && indices.length <= SIZE_MAX / sizeof(int64_t));
		memcpy(current->integers, indices.elements, indices.length * sizeof(int64_t));
	}
	*current->written = indices.length;
	return indices;
}

static int call(Context *context, uint8_t op, randomroc_fixed a,
	randomroc_fixed b, int64_t first, int64_t last) {
	Context *previous = current;
	current = context;
	int status = randomroc_run(op, a.m, a.e, b.m, b.e, first, last, context->capacity);
	current = previous;
	return context->source_error ? context->source_error : status;
}

static int numeric_call(randomroc_fill_fn fill, void *source, uint8_t op,
	randomroc_fixed a, randomroc_fixed b, randomroc_fixed *out) {
	if (!fill || !out) return 1;
	Context context = {.fill = fill, .source = source, .numeric = out};
	return call(&context, op, a, b, 0, 0);
}

static int integer_call(randomroc_fill_fn fill, void *source, uint8_t op,
	randomroc_fixed a, int64_t first, int64_t last, int64_t *out) {
	if (!fill || !out) return 1;
	Context context = {.fill = fill, .source = source, .integer = out};
	return call(&context, op, a, (randomroc_fixed){0, 0}, first, last);
}

int randomroc_uniform(randomroc_fill_fn fill, void *source, randomroc_fixed *out) {
	return numeric_call(fill, source, 0, (randomroc_fixed){0, 0}, (randomroc_fixed){0, 0}, out);
}
int randomroc_normal(randomroc_fill_fn fill, void *source, randomroc_fixed mean,
	randomroc_fixed stddev, randomroc_fixed *out) {
	return numeric_call(fill, source, 1, mean, stddev, out);
}
int randomroc_exponential(randomroc_fill_fn fill, void *source, randomroc_fixed rate,
	randomroc_fixed *out) {
	return numeric_call(fill, source, 2, rate, (randomroc_fixed){0, 0}, out);
}
int randomroc_poisson(randomroc_fill_fn fill, void *source, randomroc_fixed lambda,
	int64_t *out) {
	return integer_call(fill, source, 3, lambda, 0, 0, out);
}
int randomroc_log_normal(randomroc_fill_fn fill, void *source, randomroc_fixed mean,
	randomroc_fixed stddev, randomroc_fixed *out) {
	return numeric_call(fill, source, 4, mean, stddev, out);
}
int randomroc_beta(randomroc_fill_fn fill, void *source, randomroc_fixed alpha,
	randomroc_fixed beta, randomroc_fixed *out) {
	return numeric_call(fill, source, 5, alpha, beta, out);
}
int randomroc_range(randomroc_fill_fn fill, void *source, int64_t first,
	int64_t last, int64_t *out) {
	return integer_call(fill, source, 6, (randomroc_fixed){0, 0}, first, last, out);
}
int randomroc_normal_int(randomroc_fill_fn fill, void *source, int64_t first,
	int64_t last, int64_t *out) {
	return integer_call(fill, source, 7, (randomroc_fixed){0, 0}, first, last, out);
}
int randomroc_geometric(randomroc_fill_fn fill, void *source, randomroc_fixed probability,
	uint8_t *out, size_t capacity, size_t *written) {
	if (!fill || !out || !written) return 1;
	Context context = {.fill = fill, .source = source, .output = out, .capacity = capacity, .written = written};
	return call(&context, 8, probability, (randomroc_fixed){0, 0}, 0, 0);
}
int randomroc_count_format(const uint8_t *input, size_t length, uint8_t radix,
	uint32_t *scratch, size_t scratch_capacity, char *out, size_t capacity, size_t *written) {
	if (!input || !scratch || !out || !written) return 1;
	Context context = {.input = input, .input_length = length, .output = (uint8_t *)out,
		.capacity = capacity, .written = written};
	uint64_t scratch_bits = scratch_capacity;
	int64_t scratch_arg;
	memcpy(&scratch_arg, &scratch_bits, sizeof(scratch_arg));
	return call(&context, 9, (randomroc_fixed){0, 0}, (randomroc_fixed){scratch_arg, 0}, radix, 0);
}

randomroc_fixed randomroc_fixed_from_int(int64_t value) {
	randomroc_fixed result;
	Context context = {.numeric = &result};
	int status = call(&context, 10, (randomroc_fixed){0, 0}, (randomroc_fixed){0, 0}, value, 0);
	require(status == 0);
	return result;
}

static int conversion_call(randomroc_fixed value, int64_t *out, uint8_t op) {
	if (!out) return 1;
	Context context = {.integer = out};
	return call(&context, op, value, (randomroc_fixed){0, 0}, 0, 0);
}
int randomroc_fixed_to_int_trunc(randomroc_fixed value, int64_t *out) {
	return conversion_call(value, out, 11);
}
int randomroc_fixed_to_int_round(randomroc_fixed value, int64_t *out) {
	return conversion_call(value, out, 12);
}

static int parse_call(const char *text, size_t length, randomroc_fixed *out, uint8_t op) {
	if (!text || !out) return 1;
	Context context = {.numeric = out, .input = (const uint8_t *)text, .input_length = length};
	return call(&context, op, (randomroc_fixed){0, 0}, (randomroc_fixed){0, 0}, 0, 0);
}
int randomroc_fixed_parse(const char *text, size_t length, randomroc_fixed *out) {
	return parse_call(text, length, out, 13);
}
int randomroc_geometric_probability_parse(const char *text, size_t length, randomroc_fixed *out) {
	return parse_call(text, length, out, 14);
}
int randomroc_fixed_parse_int_safe(const char *text, size_t length, int64_t *out) {
	if (!text || !out) return 1;
	Context context = {.integer = out, .input = (const uint8_t *)text, .input_length = length};
	return call(&context, 15, (randomroc_fixed){0, 0}, (randomroc_fixed){0, 0}, 0, 0);
}
int randomroc_fixed_format(randomroc_fixed value, size_t decimal_places,
	char *out, size_t capacity, size_t *written) {
	if (!out || !written) return 1;
	Context context = {.output = (uint8_t *)out, .capacity = capacity, .written = written};
	uint64_t places_bits = decimal_places;
	int64_t places_arg;
	memcpy(&places_arg, &places_bits, sizeof(places_arg));
	return call(&context, 16, value, (randomroc_fixed){0, 0}, places_arg, 0);
}

static int drbg_call(Context *context, uint8_t op, uint64_t position) {
	int64_t position_arg;
	memcpy(&position_arg, &position, sizeof(position_arg));
	return call(context, op, (randomroc_fixed){0, 0}, (randomroc_fixed){0, 0}, position_arg, 0);
}

int randomroc_drbg_init(randomroc_drbg *state, const uint8_t *seed) {
	if (!state || !seed) return 1;
	Context context = {.state = state, .input = seed, .input_length = 32};
	return drbg_call(&context, 18, 0);
}

int randomroc_drbg_set_state(randomroc_drbg *state, const uint8_t *key, uint64_t position) {
	if (!state || !key) return 1;
	Context context = {.state = state, .input = key, .input_length = 32};
	return drbg_call(&context, 19, position);
}

int randomroc_drbg_get_state(const randomroc_drbg *state, uint8_t *key, uint64_t *position) {
	if (!state || !key || !position) return 1;
	memmove(key, state->key, 32);
	*position = state->position;
	return 0;
}

int randomroc_drbg_seek(randomroc_drbg *state, uint64_t position) {
	if (!state) return 1;
	Context context = {.state = state, .input = state->key, .input_length = 32};
	return drbg_call(&context, 19, position);
}

int randomroc_drbg_fill(randomroc_drbg *state, uint8_t *out, size_t count) {
	if (!state || (!out && count)) return 1;
	Context context = {.state = state, .input = state->key, .input_length = 32,
		.output = out, .capacity = count};
	return drbg_call(&context, 20, state->position);
}

int randomroc_drbg_u32(randomroc_drbg *state, uint32_t *out) {
	if (!state || !out) return 1;
	Context context = {.state = state, .input = state->key, .input_length = 32, .u32 = out};
	return drbg_call(&context, 21, state->position);
}

int randomroc_drbg_u64(randomroc_drbg *state, uint64_t *out) {
	if (!state || !out) return 1;
	Context context = {.state = state, .input = state->key, .input_length = 32, .u64 = out};
	return drbg_call(&context, 22, state->position);
}

void randomroc_drbg_zeroize(randomroc_drbg *state) {
	if (!state) return;
	volatile uint8_t *bytes = (volatile uint8_t *)state;
	for (size_t i = 0; i < sizeof(*state); i++) bytes[i] = 0;
}

int randomroc_distribution_curve(int kind, randomroc_fixed a, randomroc_fixed b,
	uint16_t *heights, size_t capacity, size_t *written, randomroc_fixed *x_min, randomroc_fixed *x_max) {
	if (!heights || !written || !x_min || !x_max) return 1;
	Context context = {.heights = heights, .capacity = capacity, .written = written, .x_min = x_min, .x_max = x_max};
	return call(&context, 17, a, b, kind, 0);
}

int randomroc_normal_int_batch(randomroc_fill_fn fill, void *source,
	int64_t first, int64_t last, int64_t *out, size_t count, size_t *written, int mode) {
	if (!written) return 1;
	*written = 0;
	if (!fill || (!out && count)) return 1;
	Context context = {.fill = fill, .source = source, .integers = out, .capacity = count, .written = written};
	return call(&context, 23, (randomroc_fixed){mode, 0}, (randomroc_fixed){0, 0}, first, last);
}

int randomroc_weight_add(int64_t total, int64_t weight, int64_t *out) {
	if (!out) return 1;
	Context context = {.integer = out};
	return call(&context, 27, (randomroc_fixed){0, 0}, (randomroc_fixed){0, 0}, total, weight);
}

int randomroc_weighted_total(const int64_t *weights, size_t count, int64_t *total, uint8_t *reason) {
	if (!weights || !total || count > SIZE_MAX / sizeof(int64_t)) return 1;
	Context context = {.weights = weights, .weight_count = count, .integer = total, .reason = reason};
	return call(&context, 24, (randomroc_fixed){0, 0}, (randomroc_fixed){0, 0}, 0, 0);
}

int randomroc_weighted_index(randomroc_fill_fn fill, void *source, const int64_t *weights,
	size_t count, int64_t *index, uint8_t *reason) {
	if (!fill || !weights || !index || count > SIZE_MAX / sizeof(int64_t)) return 1;
	Context context = {.fill = fill, .source = source, .weights = weights, .weight_count = count,
		.integer = index, .reason = reason};
	return call(&context, 25, (randomroc_fixed){0, 0}, (randomroc_fixed){0, 0}, 0, 0);
}

int randomroc_shuffle_indices(randomroc_fill_fn fill, void *source, int64_t *indices,
	size_t count, size_t *written) {
	if (!written) return 1;
	*written = 0;
	if (!fill || (!indices && count) || count > SIZE_MAX / sizeof(int64_t)) return 1;
	Context context = {.fill = fill, .source = source, .integers = indices, .capacity = count, .written = written};
	return call(&context, 26, (randomroc_fixed){0, 0}, (randomroc_fixed){0, 0}, 0, 0);
}
size_t randomroc_debug_live(void) { return live; }
