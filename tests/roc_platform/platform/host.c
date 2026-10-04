#include "roc_platform_abi.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
	assert(header.alignment == alignment);
	for (size_t i = 0; i < 16; i++) {
		assert(user[i + header.length] == 0xa5 && user[(ptrdiff_t)i - 16] == 0xa5);
	}
	assert(live > 0);
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
	const uint8_t *input;
	size_t input_count;
	uint8_t *output;
	size_t output_count;
	int64_t *m;
	int32_t *e;
	uint64_t *next;
} Context;
static _Thread_local Context *current;

RocList roc_probe_input(uint64_t count) {
	assert(current && count == current->input_count);
	RocList list = roc_probe_bytes(count);
	assert(list.length == count);
	if (count) memcpy(list.elements, current->input, count);
	return list;
}

RocList roc_probe_output(RocList list) {
	assert(current && list.length == current->output_count);
	if (list.length) memcpy(current->output, list.elements, list.length);
	return list;
}

void roc_probe_numeric(int64_t m, int32_t e, uint64_t next) {
	assert(current && current->m && current->e);
	*current->m = m;
	*current->e = e;
	if (current->next) *current->next = next;
}

static int run(Context *context, uint8_t op, int64_t m, int32_t e, uint64_t position, uint64_t count) {
	Context *previous = current;
	current = context;
	int status = roc_probe_run(op, m, e, position, count);
	current = previous;
	return status;
}

int roc_probe_fixed(int64_t m, int32_t e, int64_t *answer_m, int32_t *answer_e) {
	Context context = {.m = answer_m, .e = answer_e};
	return run(&context, 0, m, e, 0, 0);
}

int roc_probe_init(const uint8_t seed[32], uint8_t key[32]) {
	Context context = {.input = seed, .input_count = 32, .output = key, .output_count = 32};
	return run(&context, 1, 0, 0, 0, 0);
}

int roc_probe_fill(const uint8_t key[32], uint64_t position, uint8_t *out, size_t count) {
	Context context = {.input = key, .input_count = 32, .output = out, .output_count = count};
	return run(&context, 2, 0, 0, position, count);
}

int roc_probe_normal(const uint8_t key[32], uint64_t position, int64_t *m, int32_t *e, uint64_t *next) {
	Context context = {.input = key, .input_count = 32, .m = m, .e = e, .next = next};
	return run(&context, 3, 0, 0, position, 0);
}

size_t roc_probe_live(void) { return live; }
