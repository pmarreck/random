/* Owned C ABI adapter for the pinned generated Bend runtime. No RNG, sampler,
 * fixed-point arithmetic, numeric formatting or acceptance policy lives here. */
#ifndef RANDOMB_GENERATED_C
#define RANDOMB_GENERATED_C "randomb.generated.c"
#endif
#define main randomb_unused_runtime_main
#include RANDOMB_GENERATED_C
#undef main
#include "../include/randomb.h"
#include <limits.h>

_Static_assert(BANGS == 0, "parallel Bend graphs need a different host adapter");
_Static_assert(sizeof(size_t) <= sizeof(uint64_t), "unsupported size_t width");

static pthread_mutex_t rb_gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t rb_once = PTHREAD_ONCE_INIT;
static int rb_init_status = RANDOMB_NUMERIC_ERROR;
static void *rb_stack;
static const size_t rb_stack_bytes = ((size_t)1 << 31) + 16384;

static void rb_require(bool condition) {
	if (!condition) {
		fputs("{\"error\":\"internal Bend ABI invariant failed\"}\n", stderr);
		abort();
	}
}
static void rb_lock(void) { rb_require(pthread_mutex_lock(&rb_gate) == 0); }
static void rb_unlock(void) { rb_require(pthread_mutex_unlock(&rb_gate) == 0); }

static void rb_initialize(void) {
	/* pool_stack() installs process-wide signal handlers. An embeddable library
	 * must not replace its caller's handlers; reserve only its private stack. */
	rb_stack = mmap(NULL, rb_stack_bytes, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
	if (rb_stack == MAP_FAILED) { rb_stack = NULL; return; }
	if (mprotect((char *)rb_stack + ((size_t)1 << 31), 16384, PROT_NONE)) {
		munmap(rb_stack, rb_stack_bytes); rb_stack = NULL; return;
	}
	corpus_setup(false, 1, 0);
	io_stk = rb_stack;
	rb_require(fid_arity(MAIN_FID) == 0 && fid_arity(FID_CLO_APPLY) == 2);
	rb_require(cid_arity(CID_TOUCH) == 2);
	rb_require(pthread_atfork(rb_lock, rb_unlock, rb_unlock) == 0);
	rb_init_status = RANDOMB_OK;
}

static int rb_begin(void) {
	if (pthread_once(&rb_once, rb_initialize)) return RANDOMB_NUMERIC_ERROR;
	if (rb_init_status) return rb_init_status;
	rb_lock();
	return RANDOMB_OK;
}

static Env rb_env(void) { return (Env){CORPUS, ALC[0]}; }

/* Mirror the pinned runtime's own node ownership/sealing protocol. Wire
 * variants keep a boxed sum at the boundary, independent of data flattening. */
static Term rb_node(u32 cid, const Term *fields, u32 count) {
	Env e = rb_env();
	rb_require(cid_arity(cid) == count);
	if (!count) return term_pak(cid, 0);
	u64 loc = heap_alloc(e, cls_fit(count));
	for (u32 i = 0; i < count; i++) e.mem[loc + i] = io_seal(e, fields[i], cid);
	return term_ctr(cid, loc);
}

static u32 rb_take(Term value, Term *fields, size_t capacity) {
	Env e = rb_env();
	u32 cid = (u32)term_aux(value), count = cid_arity(cid);
	rb_require(count <= capacity);
	if (term_tag(value) == TAG_PAK) {
		rb_require(count <= 1);
		if (count) fields[0] = term_loc(value);
	} else {
		spare_free(e, cls_fit(count), ctr_take(e, value, count, fields));
	}
	return cid;
}

static size_t rb_list_length(Term list, uint32_t maximum) {
	Env e = rb_env();
	size_t length = 0;
	while (term_aux(list) == CID_CON) {
		u64 loc = term_peek(e.mem, list);
		rb_require(e.mem[loc] <= maximum && length < SIZE_MAX);
		length++;
		list = e.mem[loc + 1];
	}
	rb_require(term_aux(list) == CID_NIL);
	return length;
}
static size_t rb_byte_length(Term list) { return rb_list_length(list, 255); }

static int rb_copy_bytes(Term list, uint8_t *out, size_t capacity, size_t *written) {
	Env e = rb_env();
	size_t length = rb_byte_length(list);
	if (length > capacity) { term_drop(e, list); return RANDOMB_BUFFER_TOO_SMALL; }
	rb_require(out || !length);
	for (size_t i = 0; i < length; i++) {
		Term fields[2];
		rb_require(rb_take(list, fields, 2) == CID_CON);
		out[i] = (uint8_t)fields[0];
		list = fields[1];
	}
	term_drop(e, list);
	*written = length;
	return RANDOMB_OK;
}

typedef struct rb_reply {
	u32 kind;
	uint8_t key[32];
	uint64_t position;
	uint64_t integer;
	uint64_t index, completed, remaining;
	uint32_t reason;
	randomb_fixed number;
	randomb_fixed minimum, maximum;
	uint16_t *heights;
	int64_t *integers;
	uint8_t *output;
	size_t capacity;
	size_t written;
	Term prepared[5]; /* Owned opaque core data, transferred into the next call. */
} rb_reply;

static uint64_t rb_u64(Term hi, Term lo) {
	return (uint64_t)(uint32_t)hi << 32 | (uint32_t)lo;
}

static randomb_fixed rb_fixed(Term hi, Term lo, Term e) {
	randomb_fixed value;
	uint64_t m = rb_u64(hi, lo);
	uint32_t exponent = (uint32_t)e;
	memcpy(&value.m, &m, sizeof m);
	memcpy(&value.e, &exponent, sizeof exponent);
	return value;
}

static int rb_response(Term value, rb_reply *reply) {
	Term f[16];
	reply->kind = rb_take(value, f, 16);
	size_t key_length = 0;
	switch (reply->kind) {
	case CID_ACKNOWLEDGED: return RANDOMB_OK;
	case CID_GEOMETRICREADY:
		memcpy(reply->prepared, f, 5 * sizeof(Term)); return RANDOMB_OK;
	case CID_COUNTREADY:
		reply->prepared[0] = f[0]; return RANDOMB_OK;
	case CID_STATEOUT:
		rb_require(rb_byte_length(f[0]) == 32);
		rb_require(rb_copy_bytes(f[0], reply->key, 32, &key_length) == 0 && key_length == 32);
		reply->position = rb_u64(f[1], f[2]);
		return RANDOMB_OK;
	case CID_POSITIONOUT:
		reply->position = rb_u64(f[0], f[1]); return RANDOMB_OK;
	case CID_BYTESOUT:
		reply->position = rb_u64(f[1], f[2]);
		return rb_copy_bytes(f[0], reply->output, reply->capacity, &reply->written);
	case CID_NUMBEROUT: {
		reply->number = rb_fixed(f[0], f[1], f[2]);
		return RANDOMB_OK;
	}
	case CID_INTEGEROUT:
		reply->integer = rb_u64(f[0], f[1]); return RANDOMB_OK;
	case CID_WORDOUT:
		reply->integer = rb_u64(f[0], f[1]);
		reply->position = rb_u64(f[2], f[3]); return RANDOMB_OK;
	case CID_TEXTOUT: {
		u64 length = 0;
		char *text = io_cstr(rb_env(), f[0], &length);
		if (length > reply->capacity) { free(text); return RANDOMB_BUFFER_TOO_SMALL; }
		rb_require(reply->output || !length);
		if (length) memcpy(reply->output, text, (size_t)length);
		reply->written = (size_t)length;
		free(text);
		return RANDOMB_OK;
	}
	case CID_CURVEOUT: {
		Term list = f[0];
		size_t length = rb_list_length(list, UINT16_MAX);
		if (length > reply->capacity) { term_drop(rb_env(), list); return RANDOMB_BUFFER_TOO_SMALL; }
		rb_require(reply->heights || !length);
		for (size_t i = 0; i < length; i++) {
			Term item[2];
			rb_require(rb_take(list, item, 2) == CID_CON);
			reply->heights[i] = (uint16_t)item[0];
			list = item[1];
		}
		term_drop(rb_env(), list);
		reply->written = length;
		reply->minimum = rb_fixed(f[1], f[2], f[3]);
		reply->maximum = rb_fixed(f[4], f[5], f[6]);
		return RANDOMB_OK;
	}
	case CID_BATCHREADY:
		reply->remaining = rb_u64(f[0], f[1]);
		reply->completed = rb_u64(f[2], f[3]);
		return RANDOMB_OK;
	case CID_BATCHEND: return RANDOMB_OK;
	case CID_BATCHITEM:
		reply->index = rb_u64(f[0], f[1]);
		reply->integer = rb_u64(f[2], f[3]);
		reply->remaining = rb_u64(f[4], f[5]);
		reply->completed = rb_u64(f[6], f[7]);
		return RANDOMB_OK;
	case CID_SELECTIONFAILURE:
		reply->reason = (u32)f[0];
		return RANDOMB_INVALID_ARGUMENT;
	case CID_INDICESOUT: {
		Term list = f[0];
		size_t length = 0;
		for (Term cursor = list; term_aux(cursor) == CID_CON;) {
			u64 loc = term_peek(rb_env().mem, cursor);
			rb_require(length < SIZE_MAX);
			length++; cursor = rb_env().mem[loc + 1];
		}
		if (length > reply->capacity) { term_drop(rb_env(), list); return RANDOMB_BUFFER_TOO_SMALL; }
		rb_require(reply->integers || !length);
		for (size_t i = 0; i < length; i++) {
			Term pair[2], wide[2];
			rb_require(rb_take(list, pair, 2) == CID_CON);
			rb_require(rb_take(pair[0], wide, 2) == CID_CORE_WIDE);
			uint64_t value = rb_u64(wide[0], wide[1]);
			memcpy(reply->integers + i, &value, sizeof value);
			list = pair[1];
		}
		rb_require(term_aux(list) == CID_NIL);
		term_drop(rb_env(), list);
		reply->written = length;
		return RANDOMB_OK;
	}
	default:
		rb_require(false); return RANDOMB_NUMERIC_ERROR;
	}
}

/* Enters and leaves with rb_gate held. No caller callback runs under it.
 * Continuations own heap references while another call uses the evaluator. */
static int rb_call(Term request, randomb_fill_fn fill, void *source, rb_reply *reply) {
	Env e = rb_env();
	/* Evaluate only the pure IO construction, never the process IO loop. Its
	 * single touch payload carries a fresh boxed numerical entry closure. */
	u64 task = task_node(e, MAIN_FID, TERM_HOLE, 0, 0);
	Term main_function = corpus_eval(CORPUS, term_tsk(MAIN_FID, task));
	task = task_node(e, FID_CLO_APPLY, TERM_HOLE, 0, 0);
	e.mem[task] = main_function;
	e.mem[task + 1] = term_clo(FID_IO_EMIT, 0);
	Term bootstrap = corpus_eval(CORPUS, term_tsk(FID_CLO_APPLY, task));
	Term root_fields[2];
	rb_require(rb_take(bootstrap, root_fields, 2) == CID_TOUCH);
	Term entry = root_fields[0];
	term_drop(e, root_fields[1]);
	task = task_node(e, FID_CLO_APPLY, TERM_HOLE, 0, 0);
	e.mem[task] = entry;
	e.mem[task + 1] = request;
	Term step = corpus_eval(CORPUS, term_tsk(FID_CLO_APPLY, task));
	for (;;) {
		Term fields[16];
		u32 tag = rb_take(step, fields, 16);
		if (tag == CID_DRAW_FINISHED) return rb_response(fields[0], reply);
		if (tag == CID_DRAW_REJECTED) {
			u32 code = (u32)fields[0];
			return code >= 1 && code <= 5 ? (int)code : RANDOMB_NUMERIC_ERROR;
		}
		rb_require(tag == CID_DRAW_REQUEST && fields[0] <= UINT32_MAX);
		size_t count = (u32)fields[0];
		Term continuation = fields[1];
		rb_unlock();
		uint8_t *buffer = malloc(count ? count : 1);
		int status = buffer && fill ? fill(source, buffer, count) : RANDOMB_ENTROPY_ERROR;
		rb_lock();
		if (status) {
			free(buffer);
			term_drop(e, continuation);
			return status >= 1 && status <= 5 ? status : RANDOMB_ENTROPY_ERROR;
		}
		Term bytes = io_list(e, (const char *)buffer, count);
		free(buffer);
		task = task_node(e, FID_CLO_APPLY, TERM_HOLE, 0, 0);
		e.mem[task] = continuation;
		e.mem[task + 1] = bytes;
		step = corpus_eval(CORPUS, term_tsk(FID_CLO_APPLY, task));
	}
}

static Term rb_bytes(const uint8_t *bytes, size_t count) {
	return io_list(rb_env(), (const char *)bytes, count);
}
static int rb_plain(u32 cid, const Term *fields, u32 count, rb_reply *reply) {
	return rb_call(rb_node(cid, fields, count), NULL, NULL, reply);
}

int randomb_drbg_init(randomb_drbg *state, const uint8_t *seed) {
	if (!state || !seed) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	Term fields[] = {rb_bytes(seed, 32)};
	rb_reply reply = {0};
	status = rb_plain(CID_NEWSEED, fields, 1, &reply);
	if (!status) {
		rb_require(reply.kind == CID_STATEOUT);
		memcpy(state->key, reply.key, 32); state->position = reply.position;
	}
	rb_unlock(); return status;
}

int randomb_drbg_set_state(randomb_drbg *state, const uint8_t *key, uint64_t position) {
	if (!state || !key) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	Term fields[] = {rb_bytes(key, 32), position >> 32, (uint32_t)position};
	rb_reply reply = {0};
	status = rb_plain(CID_RESTORE, fields, 3, &reply);
	if (!status) {
		rb_require(reply.kind == CID_STATEOUT);
		memmove(state->key, reply.key, 32); state->position = reply.position;
	}
	rb_unlock(); return status;
}

int randomb_drbg_get_state(const randomb_drbg *state, uint8_t *key, uint64_t *position) {
	if (!state || !key || !position) return RANDOMB_INVALID_ARGUMENT;
	randomb_drbg copy;
	int status = randomb_drbg_set_state(&copy, state->key, state->position);
	if (!status) { memmove(key, copy.key, 32); *position = copy.position; }
	return status;
}

int randomb_drbg_seek(randomb_drbg *state, uint64_t position) {
	if (!state) return RANDOMB_INVALID_ARGUMENT;
	return randomb_drbg_set_state(state, state->key, position);
}

int randomb_drbg_fill(randomb_drbg *state, uint8_t *output, size_t count) {
	if (!state || (!output && count)) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	Term preflight[] = {rb_bytes(state->key, 32), state->position >> 32, (uint32_t)state->position,
		(uint64_t)count >> 32, (uint32_t)count};
	rb_reply reply = {0};
	status = rb_plain(CID_PREFLIGHT, preflight, 5, &reply);
	if (status) { rb_unlock(); return status; }
	rb_require(reply.kind == CID_POSITIONOUT);
	/* Chunking is output transport. The Bend core preflights the entire byte
	 * cursor before any output write; each chunk supplies its own next cursor. */
	size_t done = 0;
	while (done < count) {
		size_t chunk = count - done < 65536 ? count - done : 65536;
		Term fields[] = {rb_bytes(state->key, 32), state->position >> 32,
			(uint32_t)state->position, (uint32_t)chunk};
		reply = (rb_reply){.output = output + done, .capacity = chunk};
		status = rb_plain(CID_FILL, fields, 4, &reply);
		if (status) break;
		rb_require(reply.kind == CID_BYTESOUT && reply.written == chunk);
		state->position = reply.position;
		done += chunk;
	}
	rb_unlock(); return status;
}

static int rb_word(randomb_drbg *state, uint32_t width, uint64_t *value) {
	if (!state || !value) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	Term fields[] = {rb_bytes(state->key, 32), state->position >> 32, (uint32_t)state->position, width};
	rb_reply reply = {0};
	status = rb_plain(CID_READWORD, fields, 4, &reply);
	if (!status) {
		rb_require(reply.kind == CID_WORDOUT);
		*value = reply.integer; state->position = reply.position;
	}
	rb_unlock(); return status;
}
int randomb_drbg_u32(randomb_drbg *state, uint32_t *out) {
	if (!out) return RANDOMB_INVALID_ARGUMENT;
	uint64_t value;
	int status = rb_word(state, 4, &value);
	if (!status) *out = (uint32_t)value;
	return status;
}
int randomb_drbg_u64(randomb_drbg *state, uint64_t *out) { return rb_word(state, 8, out); }
void randomb_drbg_zeroize(randomb_drbg *state) {
	if (state) {
		volatile uint8_t *bytes = (volatile uint8_t *)state;
		for (size_t i = 0; i < sizeof *state; i++) bytes[i] = 0;
	}
}

static int rb_numeric(randomb_fill_fn fill, void *source, u32 op, randomb_fixed a, randomb_fixed b,
	randomb_fixed *number, int64_t *integer) {
	if (!fill || (!number && !integer)) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	uint64_t am = (uint64_t)a.m, bm = (uint64_t)b.m;
	Term fields[] = {op, am >> 32, (uint32_t)am, (uint32_t)a.e, bm >> 32, (uint32_t)bm, (uint32_t)b.e};
	rb_reply reply = {0};
	status = rb_call(rb_node(CID_NUMERICMETHOD, fields, 7), fill, source, &reply);
	if (!status) {
		if (number) { rb_require(reply.kind == CID_NUMBEROUT); *number = reply.number; }
		else { rb_require(reply.kind == CID_INTEGEROUT); memcpy(integer, &reply.integer, sizeof *integer); }
	}
	rb_unlock(); return status;
}
int randomb_uniform(randomb_fill_fn fill, void *source, randomb_fixed *out) {
	return rb_numeric(fill, source, 0, (randomb_fixed){0}, (randomb_fixed){0}, out, NULL);
}
int randomb_normal(randomb_fill_fn fill, void *source, randomb_fixed a, randomb_fixed b, randomb_fixed *out) {
	return rb_numeric(fill, source, 1, a, b, out, NULL);
}
int randomb_exponential(randomb_fill_fn fill, void *source, randomb_fixed a, randomb_fixed *out) {
	return rb_numeric(fill, source, 2, a, (randomb_fixed){0}, out, NULL);
}
int randomb_poisson(randomb_fill_fn fill, void *source, randomb_fixed a, int64_t *out) {
	return rb_numeric(fill, source, 3, a, (randomb_fixed){0}, NULL, out);
}
int randomb_log_normal(randomb_fill_fn fill, void *source, randomb_fixed a, randomb_fixed b, randomb_fixed *out) {
	return rb_numeric(fill, source, 4, a, b, out, NULL);
}
int randomb_beta(randomb_fill_fn fill, void *source, randomb_fixed a, randomb_fixed b, randomb_fixed *out) {
	return rb_numeric(fill, source, 5, a, b, out, NULL);
}

static int rb_integer(randomb_fill_fn fill, void *source, u32 op, int64_t first, int64_t last, int64_t *out) {
	if (!fill || !out) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	uint64_t a = (uint64_t)first, b = (uint64_t)last;
	Term fields[] = {op, a >> 32, (uint32_t)a, b >> 32, (uint32_t)b};
	rb_reply reply = {0};
	status = rb_call(rb_node(CID_INTEGERMETHOD, fields, 5), fill, source, &reply);
	if (!status) { rb_require(reply.kind == CID_INTEGEROUT); memcpy(out, &reply.integer, sizeof *out); }
	rb_unlock(); return status;
}
int randomb_range(randomb_fill_fn fill, void *source, int64_t first, int64_t last, int64_t *out) {
	return rb_integer(fill, source, 0, first, last, out);
}
int randomb_normal_int(randomb_fill_fn fill, void *source, int64_t first, int64_t last, int64_t *out) {
	return rb_integer(fill, source, 1, first, last, out);
}

int randomb_geometric(randomb_fill_fn fill, void *source, randomb_fixed p, uint8_t *out, size_t capacity, size_t *written) {
	if (!written || !fill || !out) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	uint64_t m = (uint64_t)p.m;
	Term input[] = {m >> 32, (uint32_t)m, (uint32_t)p.e};
	rb_reply reply = {.output = out, .capacity = capacity};
	status = rb_plain(CID_GEOMETRICPREPARE, input, 3, &reply);
	if (!status) {
		rb_require(reply.kind == CID_GEOMETRICREADY);
		/* Admission and preparation are pure Bend. Only now may output metadata
		 * change. Transfer, rather than recompute, the admitted opaque model. */
		*written = 0;
		Term fields[] = {reply.prepared[0], reply.prepared[1], reply.prepared[2],
			reply.prepared[3], reply.prepared[4], (uint64_t)capacity >> 32, (uint32_t)capacity};
		status = rb_call(rb_node(CID_GEOMETRICSAMPLE, fields, 7), fill, source, &reply);
		if (!status) { rb_require(reply.kind == CID_BYTESOUT); *written = reply.written; }
	}
	rb_unlock(); return status;
}

int randomb_count_format(const uint8_t *input, size_t length, uint8_t radix,
	uint32_t *scratch, size_t scratch_capacity, char *out, size_t capacity, size_t *written) {
	if (!written || !input || !scratch || !out) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	Term encoded[] = {rb_bytes(input, length), radix};
	rb_reply reply = {.output = (uint8_t *)out, .capacity = capacity};
	status = rb_plain(CID_COUNTPREPARE, encoded, 2, &reply);
	if (!status) {
		rb_require(reply.kind == CID_COUNTREADY);
		*written = 0;
		Term fields[] = {reply.prepared[0], radix, (uint64_t)scratch_capacity >> 32,
			(uint32_t)scratch_capacity, (uint64_t)capacity >> 32, (uint32_t)capacity};
		status = rb_plain(CID_COUNTFORMAT, fields, 6, &reply);
		if (!status) { rb_require(reply.kind == CID_TEXTOUT); *written = reply.written; }
	}
	rb_unlock(); return status;
}

static int rb_convert(u32 operation, randomb_fixed value, rb_reply *reply) {
	int status = rb_begin(); if (status) return status;
	uint64_t m = (uint64_t)value.m;
	Term fields[] = {operation, m >> 32, (uint32_t)m, (uint32_t)value.e};
	status = rb_plain(CID_CONVERT, fields, 4, reply);
	rb_unlock(); return status;
}
randomb_fixed randomb_fixed_from_int(int64_t value) {
	rb_reply reply = {0};
	/* This total numerical conversion has no status slot in the shared ABI.
	 * Runtime initialization/allocation failure follows Bend's fail-stop policy. */
	rb_require(rb_convert(0, (randomb_fixed){value, 0}, &reply) == RANDOMB_OK);
	rb_require(reply.kind == CID_NUMBEROUT);
	return reply.number;
}
static int rb_convert_integer(u32 operation, randomb_fixed value, int64_t *out) {
	if (!out) return RANDOMB_INVALID_ARGUMENT;
	rb_reply reply = {0};
	int status = rb_convert(operation, value, &reply);
	if (!status) { rb_require(reply.kind == CID_INTEGEROUT); memcpy(out, &reply.integer, sizeof *out); }
	return status;
}
int randomb_fixed_to_int_trunc(randomb_fixed value, int64_t *out) { return rb_convert_integer(1, value, out); }
int randomb_fixed_to_int_round(randomb_fixed value, int64_t *out) { return rb_convert_integer(2, value, out); }

static int rb_parse(u32 operation, const char *text, size_t length, randomb_fixed *number, int64_t *integer) {
	if (!text || (!number && !integer)) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	Term fields[] = {operation, rb_bytes((const uint8_t *)text, length)};
	rb_reply reply = {0};
	status = rb_plain(CID_PARSE, fields, 2, &reply);
	if (!status) {
		if (number) { rb_require(reply.kind == CID_NUMBEROUT); *number = reply.number; }
		else { rb_require(reply.kind == CID_INTEGEROUT); memcpy(integer, &reply.integer, sizeof *integer); }
	}
	rb_unlock(); return status;
}
int randomb_fixed_parse(const char *text, size_t length, randomb_fixed *out) { return rb_parse(0, text, length, out, NULL); }
int randomb_geometric_probability_parse(const char *text, size_t length, randomb_fixed *out) { return rb_parse(1, text, length, out, NULL); }
int randomb_fixed_parse_int_safe(const char *text, size_t length, int64_t *out) { return rb_parse(2, text, length, NULL, out); }

int randomb_fixed_format(randomb_fixed value, size_t places, char *out, size_t capacity, size_t *written) {
	if (!written) return RANDOMB_INVALID_ARGUMENT;
	if (!out) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	uint64_t m = (uint64_t)value.m;
	Term fields[] = {m >> 32, (uint32_t)m, (uint32_t)value.e, (uint64_t)places >> 32,
		(uint32_t)places, (uint64_t)capacity >> 32, (uint32_t)capacity};
	rb_reply reply = {.output = (uint8_t *)out, .capacity = capacity};
	status = rb_plain(CID_FORMAT, fields, 7, &reply);
	if (!status) { rb_require(reply.kind == CID_TEXTOUT); *written = reply.written; }
	rb_unlock(); return status;
}

int randomb_distribution_curve(int kind, randomb_fixed a, randomb_fixed b, uint16_t *heights,
	size_t capacity, size_t *written, randomb_fixed *minimum, randomb_fixed *maximum) {
	if (!heights || !written || !minimum || !maximum) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	uint64_t am = (uint64_t)a.m, bm = (uint64_t)b.m;
	Term fields[] = {0, (uint32_t)kind, am >> 32, (uint32_t)am, (uint32_t)a.e,
		bm >> 32, (uint32_t)bm, (uint32_t)b.e, (uint64_t)capacity >> 32, (uint32_t)capacity};
	rb_reply reply = {.heights = heights, .capacity = capacity};
	/* The core's admission response defines whether the caller's count is
	 * initialized. Domain/numeric errors then preserve this admitted count. */
	status = rb_plain(CID_CURVE, fields, 10, &reply);
	if (!status) {
		rb_require(reply.kind == CID_INTEGEROUT && reply.integer <= SIZE_MAX);
		*written = (size_t)reply.integer;
		fields[0] = 1;
		status = rb_plain(CID_CURVE, fields, 10, &reply);
		if (!status) {
			rb_require(reply.kind == CID_CURVEOUT);
			*written = reply.written; *minimum = reply.minimum; *maximum = reply.maximum;
		}
	}
	rb_unlock(); return status;
}

int randomb_normal_int_batch(randomb_fill_fn fill, void *source, int64_t first, int64_t last,
	int64_t *out, size_t count, size_t *written, int mode) {
	if (!written) return RANDOMB_INVALID_ARGUMENT;
	*written = 0;
	if (!fill || (!out && count) || count > SIZE_MAX / sizeof *out) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	uint64_t a = (uint64_t)first, b = (uint64_t)last;
	Term start[] = {a >> 32, (uint32_t)a, b >> 32, (uint32_t)b,
		(uint64_t)count >> 32, (uint32_t)count, (uint32_t)mode};
	rb_reply reply = {0};
	status = rb_plain(CID_BATCHSTART, start, 7, &reply);
	if (!status) rb_require(reply.kind == CID_BATCHREADY);
	while (!status) {
		Term next[] = {a >> 32, (uint32_t)a, b >> 32, (uint32_t)b,
			reply.remaining >> 32, (uint32_t)reply.remaining, reply.completed >> 32, (uint32_t)reply.completed};
		status = rb_call(rb_node(CID_BATCHNEXT, next, 8), fill, source, &reply);
		if (status || reply.kind == CID_BATCHEND) break;
		rb_require(reply.kind == CID_BATCHITEM && reply.index < count && reply.completed <= count);
		memcpy(out + (size_t)reply.index, &reply.integer, sizeof *out);
		*written = (size_t)reply.completed;
	}
	rb_unlock(); return status;
}

static Term rb_weights(const int64_t *weights, size_t count) {
	Term list = term_pak(CID_NIL, 0);
	for (size_t i = count; i > 0; i--) {
		uint64_t value = (uint64_t)weights[i - 1];
		Term wide[] = {value >> 32, (uint32_t)value};
		Term pair[] = {rb_node(CID_CORE_WIDE, wide, 2), list};
		list = rb_node(CID_CON, pair, 2);
	}
	return list;
}
static int rb_weighted(u32 operation, randomb_fill_fn fill, void *source, const int64_t *weights,
	size_t count, int64_t *out, uint8_t *reason) {
	if (!weights || !out || count > SIZE_MAX / sizeof *weights) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	Term fields[] = {operation, rb_weights(weights, count)};
	rb_reply reply = {0};
	status = rb_call(rb_node(CID_WEIGHTS, fields, 2), fill, source, &reply);
	if (reason) *reason = (uint8_t)reply.reason;
	if (!status) { rb_require(reply.kind == CID_INTEGEROUT); memcpy(out, &reply.integer, sizeof *out); }
	rb_unlock(); return status;
}
int randomb_weighted_total(const int64_t *weights, size_t count, int64_t *out, uint8_t *reason) {
	return rb_weighted(0, NULL, NULL, weights, count, out, reason);
}
int randomb_weighted_index(randomb_fill_fn fill, void *source, const int64_t *weights,
	size_t count, int64_t *out, uint8_t *reason) {
	if (!fill) return RANDOMB_INVALID_ARGUMENT;
	return rb_weighted(1, fill, source, weights, count, out, reason);
}
int randomb_weight_add(int64_t total, int64_t weight, int64_t *out) {
	if (!out) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	uint64_t a = (uint64_t)total, b = (uint64_t)weight;
	Term fields[] = {a >> 32, (uint32_t)a, b >> 32, (uint32_t)b};
	rb_reply reply = {0};
	status = rb_plain(CID_WEIGHTADD, fields, 4, &reply);
	if (!status) { rb_require(reply.kind == CID_INTEGEROUT); memcpy(out, &reply.integer, sizeof *out); }
	rb_unlock(); return status;
}
int randomb_shuffle_indices(randomb_fill_fn fill, void *source, int64_t *out, size_t count, size_t *written) {
	if (!written) return RANDOMB_INVALID_ARGUMENT;
	*written = 0;
	if (!fill || (!out && count) || count > SIZE_MAX / sizeof *out) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	Term fields[] = {(uint64_t)count >> 32, (uint32_t)count};
	rb_reply reply = {.integers = out, .capacity = count};
	status = rb_call(rb_node(CID_SHUFFLE, fields, 2), fill, source, &reply);
	if (!status) { rb_require(reply.kind == CID_INDICESOUT); *written = reply.written; }
	rb_unlock(); return status;
}

int randomb_debug_heap_pages(uint64_t *out) {
	if (!out) return RANDOMB_INVALID_ARGUMENT;
	int status = rb_begin(); if (status) return status;
	*out = a32_load(a32_at(CORPUS, H_BUMP));
	rb_unlock(); return RANDOMB_OK;
}

static void __attribute__((destructor)) rb_finalize(void) {
	if (rb_init_status != RANDOMB_OK) return;
	rb_lock();
	munmap(CORPUS, corpus_size);
	munmap(rb_stack, rb_stack_bytes);
	CORPUS = NULL; io_stk = NULL; rb_stack = NULL;
	rb_unlock();
}
