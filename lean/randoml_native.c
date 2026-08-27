#define _GNU_SOURCE

#include <lean/lean.h>

#include "entropy_backend.h"

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if RANDOMZ_ENTROPY_BACKEND_BCRYPT
#include <windows.h>
#include <bcrypt.h>
#else
#if RANDOMZ_ENTROPY_BACKEND_GETRANDOM
#include <sys/random.h>
#endif
#include <unistd.h>
#endif

typedef struct randoml_source {
	FILE *file;
	bool explicit_file;
	bool no_wait;
	char error[256];
} randoml_source;

static lean_external_class *randoml_source_class;

static void source_finalize(void *data)
{
	randoml_source *source = data;
	if (source == NULL)
		return;
	if (source->file != NULL)
		fclose(source->file);
	memset(source, 0, sizeof(*source));
	free(source);
}

static void source_foreach(void *data, b_lean_obj_arg function)
{
	(void)data;
	(void)function;
}

void randoml_initialize_native(void)
{
	if (randoml_source_class == NULL)
		randoml_source_class = lean_register_external_class(source_finalize, source_foreach);
}

static lean_object *io_error(const char *message)
{
	return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(message)));
}

static int source_file_fill(randoml_source *source, uint8_t *out, size_t count)
{
	size_t offset = 0;
	while (offset < count) {
		size_t got = fread(out + offset, 1, count - offset, source->file);
		if (got == 0) {
			if (ferror(source->file))
				snprintf(source->error, sizeof(source->error),
					"source read failed: %s", strerror(errno));
			else
				snprintf(source->error, sizeof(source->error),
					"source reached EOF before %zu bytes were read", count);
			return 1;
		}
		offset += got;
	}
	return 0;
}

#if RANDOMZ_ENTROPY_BACKEND_GETRANDOM || RANDOMZ_ENTROPY_BACKEND_GETENTROPY
static int source_device_fallback(randoml_source *source, uint8_t *out, size_t count)
{
	if (source->file == NULL)
		source->file = fopen("/dev/urandom", "rb");
	if (source->file == NULL) {
		snprintf(source->error, sizeof(source->error),
			"fallback /dev/urandom could not be opened: %s", strerror(errno));
		return 1;
	}
	return source_file_fill(source, out, count);
}
#endif

static int source_fill(randoml_source *source, uint8_t *out, size_t count)
{
	if (source->explicit_file)
		return source_file_fill(source, out, count);
	if (count == 0)
		return 0;

#if RANDOMZ_ENTROPY_BACKEND_BCRYPT
	size_t offset = 0;
	while (offset < count) {
		size_t remaining = count - offset;
		ULONG part = remaining > UINT32_MAX ? UINT32_MAX : (ULONG)remaining;
		NTSTATUS status = BCryptGenRandom(NULL, out + offset, part,
			BCRYPT_USE_SYSTEM_PREFERRED_RNG);
		if (status != 0) {
			snprintf(source->error, sizeof(source->error),
				"BCryptGenRandom failed with status %ld", (long)status);
			return 1;
		}
		offset += part;
	}
	return 0;
#elif RANDOMZ_ENTROPY_BACKEND_ARC4RANDOM
	arc4random_buf(out, count);
	return 0;
#elif RANDOMZ_ENTROPY_BACKEND_GETRANDOM
	size_t offset = 0;
	while (offset < count) {
		ssize_t got = getrandom(out + offset, count - offset,
			source->no_wait ? GRND_NONBLOCK : 0);
		if (got > 0) {
			offset += (size_t)got;
			continue;
		}
		if (got == 0) {
			snprintf(source->error, sizeof(source->error), "getrandom returned zero bytes");
			return 1;
		}
		if (errno == EINTR)
			continue;
		if (errno == ENOSYS) {
			if (source->no_wait) {
				snprintf(source->error, sizeof(source->error),
					"getrandom is unavailable and --no-wait was requested");
				return 1;
			}
			return source_device_fallback(source, out + offset, count - offset);
		}
		if (source->no_wait && errno == EAGAIN) {
			snprintf(source->error, sizeof(source->error),
				"pool is not initialized and --no-wait was requested");
			return 1;
		}
		snprintf(source->error, sizeof(source->error),
			"getrandom failed: %s", strerror(errno));
		return 1;
	}
	return 0;
#elif RANDOMZ_ENTROPY_BACKEND_GETENTROPY
	size_t offset = 0;
	while (offset < count) {
		size_t part = count - offset;
		if (part > 256)
			part = 256;
		if (getentropy(out + offset, part) == 0) {
			offset += part;
			continue;
		}
		if (errno == EINTR)
			continue;
		if (errno == ENOSYS)
			return source_device_fallback(source, out + offset, count - offset);
		snprintf(source->error, sizeof(source->error),
			"getentropy failed: %s", strerror(errno));
		return 1;
	}
	return 0;
#else
#error "unhandled randoml entropy backend"
#endif
}

lean_object *randoml_source_open(b_lean_obj_arg path, uint8_t no_wait)
{
	randoml_source *source = calloc(1, sizeof(*source));
	if (source == NULL)
		return io_error("entropy source allocation failed");
	source->no_wait = no_wait != 0;
	size_t length = lean_sarray_size(path);
	if (length > 0) {
		char *name = malloc(length + 1);
		if (name == NULL) {
			free(source);
			return io_error("entropy path allocation failed");
		}
		memcpy(name, lean_sarray_cptr(path), length);
		name[length] = '\0';
		source->file = fopen(name, "rb");
		source->explicit_file = true;
		if (source->file == NULL) {
			snprintf(source->error, sizeof(source->error),
				"entropy source could not be opened: %s: %s", name, strerror(errno));
			free(name);
			lean_object *result = io_error(source->error);
			free(source);
			return result;
		}
		free(name);
	}
#if !RANDOMZ_ENTROPY_BACKEND_GETRANDOM
	if (source->no_wait && !source->explicit_file) {
		free(source);
		return io_error("--no-wait is supported only by a getrandom backend");
	}
#endif
	return lean_io_result_mk_ok(lean_alloc_external(randoml_source_class, source));
}

lean_object *randoml_source_fill(b_lean_obj_arg handle, size_t count)
{
	randoml_source *source = lean_get_external_data((lean_object *)handle);
	lean_object *bytes = lean_alloc_sarray(1, count, count);
	if (source_fill(source, lean_sarray_cptr(bytes), count) != 0) {
		lean_dec_ref(bytes);
		return io_error(source->error[0] == '\0' ? "entropy source failed" : source->error);
	}
	return lean_io_result_mk_ok(bytes);
}

lean_object *randoml_base64(b_lean_obj_arg input)
{
	static const uint8_t alphabet[] =
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	size_t input_size = lean_sarray_size(input);
	if (input_size > (SIZE_MAX - 2) / 3)
		return lean_alloc_sarray(1, 0, 0);
	size_t output_size = ((input_size + 2) / 3) * 4;
	lean_object *output = lean_alloc_sarray(1, output_size, output_size);
	const uint8_t *source = lean_sarray_cptr(input);
	uint8_t *target = lean_sarray_cptr(output);
	size_t input_offset = 0;
	size_t output_offset = 0;
	while (input_offset < input_size) {
		size_t remaining = input_size - input_offset;
		uint32_t a = source[input_offset++];
		uint32_t b = remaining > 1 ? source[input_offset++] : 0;
		uint32_t c = remaining > 2 ? source[input_offset++] : 0;
		uint32_t value = (a << 16) | (b << 8) | c;
		target[output_offset++] = alphabet[(value >> 18) & 63];
		target[output_offset++] = alphabet[(value >> 12) & 63];
		target[output_offset++] = remaining > 1 ? alphabet[(value >> 6) & 63] : '=';
		target[output_offset++] = remaining > 2 ? alphabet[value & 63] : '=';
	}
	return output;
}

lean_object *randoml_platform_name(void)
{
#if defined(_WIN32)
	return lean_mk_string("Windows");
#elif defined(__APPLE__)
	return lean_mk_string("OSX");
#elif defined(__linux__)
	return lean_mk_string("Linux");
#elif defined(__FreeBSD__)
	return lean_mk_string("FreeBSD");
#elif defined(__NetBSD__)
	return lean_mk_string("NetBSD");
#elif defined(__OpenBSD__)
	return lean_mk_string("OpenBSD");
#elif defined(__DragonFly__)
	return lean_mk_string("DragonFlyBSD");
#elif defined(__illumos__)
	return lean_mk_string("illumos");
#elif defined(__sun)
	return lean_mk_string("Solaris");
#else
	return lean_mk_string("Unknown");
#endif
}

lean_object *randoml_architecture_name(void)
{
#if defined(__aarch64__) || defined(_M_ARM64)
	return lean_mk_string("arm64");
#elif defined(__x86_64__) || defined(_M_X64)
	return lean_mk_string("x64");
#elif defined(__i386__) || defined(_M_IX86)
	return lean_mk_string("x86");
#else
	return lean_mk_string("unknown");
#endif
}
