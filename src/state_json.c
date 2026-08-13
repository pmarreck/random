#include "state_json.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define STATE_JSON_MAX_DEPTH 64
#define STATE_JSON_MAX_OBJECT_MEMBERS 32
#define STATE_JSON_MAX_ARRAY_ITEMS 1024

typedef struct parser {
	const unsigned char *text;
	size_t length;
	size_t index;
	size_t depth;
	char *error;
	size_t error_capacity;
} parser;

static bool valid_utf8_bytes(const unsigned char *text, size_t length)
{
	for (size_t index = 0; index < length;) {
		unsigned char first = text[index++];
		if (first < 0x80) continue;
		size_t continuation;
		unsigned char second_min = 0x80, second_max = 0xbf;
		if (first >= 0xc2 && first <= 0xdf) continuation = 1;
		else if (first == 0xe0) { continuation = 2; second_min = 0xa0; }
		else if ((first >= 0xe1 && first <= 0xec) || (first >= 0xee && first <= 0xef))
			continuation = 2;
		else if (first == 0xed) { continuation = 2; second_max = 0x9f; }
		else if (first == 0xf0) { continuation = 3; second_min = 0x90; }
		else if (first >= 0xf1 && first <= 0xf3) continuation = 3;
		else if (first == 0xf4) { continuation = 3; second_max = 0x8f; }
		else return false;
		if (index >= length || text[index] < second_min || text[index] > second_max)
			return false;
		for (size_t offset = 1; offset < continuation; ++offset) {
			if (index + offset >= length || text[index + offset] < 0x80 ||
				text[index + offset] > 0xbf) return false;
		}
		index += continuation;
	}
	return true;
}

bool state_json_valid_utf8(const char *value)
{
	return value != NULL && valid_utf8_bytes((const unsigned char *)value, strlen(value));
}

static void fail(parser *p, const char *message)
{
	if (p->error_capacity > 0 && p->error[0] == '\0') {
		snprintf(p->error, p->error_capacity, "%s", message);
	}
}

static void space(parser *p)
{
	while (p->index < p->length &&
		(p->text[p->index] == ' ' || p->text[p->index] == '\t' ||
		p->text[p->index] == '\r' || p->text[p->index] == '\n')) p->index++;
}

static bool consume(parser *p, unsigned char byte)
{
	if (p->index < p->length && p->text[p->index] == byte) {
		p->index++;
		return true;
	}
	return false;
}

static int hex_digit(unsigned char byte)
{
	if (byte >= '0' && byte <= '9') return byte - '0';
	if (byte >= 'a' && byte <= 'f') return byte - 'a' + 10;
	if (byte >= 'A' && byte <= 'F') return byte - 'A' + 10;
	return -1;
}

static bool append_byte(char **buffer, size_t *length, size_t *capacity, unsigned char byte)
{
	if (*length + 1 >= *capacity) {
		size_t next = *capacity == 0 ? 32 : *capacity * 2;
		char *grown = realloc(*buffer, next);
		if (grown == NULL) return false;
		*buffer = grown;
		*capacity = next;
	}
	(*buffer)[(*length)++] = (char)byte;
	return true;
}

static bool append_utf8(char **buffer, size_t *length, size_t *capacity, uint32_t scalar)
{
	if (scalar <= 0x7f) return append_byte(buffer, length, capacity, (unsigned char)scalar);
	if (scalar <= 0x7ff) {
		return append_byte(buffer, length, capacity, 0xc0 | (unsigned char)(scalar >> 6)) &&
			append_byte(buffer, length, capacity, 0x80 | (unsigned char)(scalar & 0x3f));
	}
	if (scalar <= 0xffff) {
		return append_byte(buffer, length, capacity, 0xe0 | (unsigned char)(scalar >> 12)) &&
			append_byte(buffer, length, capacity, 0x80 | (unsigned char)((scalar >> 6) & 0x3f)) &&
			append_byte(buffer, length, capacity, 0x80 | (unsigned char)(scalar & 0x3f));
	}
	return append_byte(buffer, length, capacity, 0xf0 | (unsigned char)(scalar >> 18)) &&
		append_byte(buffer, length, capacity, 0x80 | (unsigned char)((scalar >> 12) & 0x3f)) &&
		append_byte(buffer, length, capacity, 0x80 | (unsigned char)((scalar >> 6) & 0x3f)) &&
		append_byte(buffer, length, capacity, 0x80 | (unsigned char)(scalar & 0x3f));
}

static bool hex_quad(parser *p, uint32_t *out)
{
	if (p->length - p->index < 4) return false;
	uint32_t value = 0;
	for (size_t i = 0; i < 4; ++i) {
		int digit = hex_digit(p->text[p->index++]);
		if (digit < 0) return false;
		value = (value << 4) | (uint32_t)digit;
	}
	*out = value;
	return true;
}

static char *parse_string(parser *p)
{
	if (!consume(p, '"')) { fail(p, "expected JSON string"); return NULL; }
	char *buffer = NULL;
	size_t length = 0, capacity = 0;
	while (p->index < p->length) {
		unsigned char byte = p->text[p->index++];
		if (byte == '"') {
			if (!append_byte(&buffer, &length, &capacity, 0)) goto allocation;
			return buffer;
		}
		if (byte < 0x20) { fail(p, "unescaped control byte in JSON string"); goto invalid; }
		if (byte != '\\') {
			if (!append_byte(&buffer, &length, &capacity, byte)) goto allocation;
			continue;
		}
		if (p->index >= p->length) { fail(p, "incomplete JSON escape"); goto invalid; }
		byte = p->text[p->index++];
		unsigned char decoded = 0;
		bool simple = true;
		switch (byte) {
		case '"': case '\\': case '/': decoded = byte; break;
		case 'b': decoded = 8; break;
		case 'f': decoded = 12; break;
		case 'n': decoded = '\n'; break;
		case 'r': decoded = '\r'; break;
		case 't': decoded = '\t'; break;
		case 'u': simple = false; break;
		default: fail(p, "invalid JSON escape"); goto invalid;
		}
		if (simple) {
			if (!append_byte(&buffer, &length, &capacity, decoded)) goto allocation;
			continue;
		}
		uint32_t scalar;
		if (!hex_quad(p, &scalar)) { fail(p, "invalid JSON Unicode escape"); goto invalid; }
		if (scalar >= 0xd800 && scalar <= 0xdbff) {
			if (!consume(p, '\\') || !consume(p, 'u')) {
				fail(p, "unpaired JSON high surrogate"); goto invalid;
			}
			uint32_t low;
			if (!hex_quad(p, &low) || low < 0xdc00 || low > 0xdfff) {
				fail(p, "invalid JSON low surrogate"); goto invalid;
			}
			scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
		} else if (scalar >= 0xdc00 && scalar <= 0xdfff) {
			fail(p, "unpaired JSON low surrogate"); goto invalid;
		}
		if (scalar == 0) { fail(p, "NUL is not supported in state strings"); goto invalid; }
		if (!append_utf8(&buffer, &length, &capacity, scalar)) goto allocation;
	}
	fail(p, "unterminated JSON string");
	goto invalid;
allocation:
	fail(p, "could not allocate JSON string");
invalid:
	free(buffer);
	return NULL;
}

static state_json_value *parse_value(parser *p);

void state_json_free(state_json_value *value)
{
	if (value == NULL) return;
	free(value->text);
	for (size_t i = 0; i < value->item_count; ++i) state_json_free(value->items[i]);
	free(value->items);
	for (size_t i = 0; i < value->member_count; ++i) {
		free(value->members[i].key);
		state_json_free(value->members[i].value);
	}
	free(value->members);
	free(value);
}

static state_json_value *new_value(parser *p, state_json_kind kind)
{
	state_json_value *value = calloc(1, sizeof(*value));
	if (value == NULL) fail(p, "could not allocate JSON value");
	else value->kind = kind;
	return value;
}

static state_json_value *parse_object(parser *p)
{
	state_json_value *value = new_value(p, STATE_JSON_OBJECT);
	if (value == NULL) return NULL;
	p->index++;
	space(p);
	if (consume(p, '}')) return value;
	while (true) {
		if (value->member_count >= STATE_JSON_MAX_OBJECT_MEMBERS) {
			fail(p, "state JSON object exceeds 32 members"); goto invalid;
		}
		char *key = parse_string(p);
		if (key == NULL) goto invalid;
		for (size_t i = 0; i < value->member_count; ++i) if (strcmp(key, value->members[i].key) == 0) {
			free(key); fail(p, "duplicate JSON object key"); goto invalid;
		}
		space(p);
		if (!consume(p, ':')) { free(key); fail(p, "expected colon after JSON key"); goto invalid; }
		state_json_value *member_value = parse_value(p);
		if (member_value == NULL) { free(key); goto invalid; }
		state_json_member *grown = realloc(value->members,
			(value->member_count + 1) * sizeof(*grown));
		if (grown == NULL) {
			free(key); state_json_free(member_value); fail(p, "could not allocate JSON object"); goto invalid;
		}
		value->members = grown;
		value->members[value->member_count++] = (state_json_member){key, member_value};
		space(p);
		if (consume(p, '}')) return value;
		if (!consume(p, ',')) { fail(p, "expected comma or closing brace"); goto invalid; }
		space(p);
	}
invalid:
	state_json_free(value);
	return NULL;
}

static state_json_value *parse_array(parser *p)
{
	state_json_value *value = new_value(p, STATE_JSON_ARRAY);
	if (value == NULL) return NULL;
	p->index++;
	space(p);
	if (consume(p, ']')) return value;
	while (true) {
		if (value->item_count >= STATE_JSON_MAX_ARRAY_ITEMS) {
			fail(p, "state JSON array exceeds 1024 items"); goto invalid;
		}
		state_json_value *item = parse_value(p);
		if (item == NULL) goto invalid;
		state_json_value **grown = realloc(value->items,
			(value->item_count + 1) * sizeof(*grown));
		if (grown == NULL) {
			state_json_free(item); fail(p, "could not allocate JSON array"); goto invalid;
		}
		value->items = grown;
		value->items[value->item_count++] = item;
		space(p);
		if (consume(p, ']')) return value;
		if (!consume(p, ',')) { fail(p, "expected comma or closing bracket"); goto invalid; }
		space(p);
	}
invalid:
	state_json_free(value);
	return NULL;
}

static state_json_value *parse_number(parser *p)
{
	size_t start = p->index;
	if (consume(p, '-') && (p->index >= p->length ||
		p->text[p->index] < '0' || p->text[p->index] > '9')) {
		fail(p, "malformed JSON number"); return NULL;
	}
	if (consume(p, '0')) {
		if (p->index < p->length && p->text[p->index] >= '0' && p->text[p->index] <= '9') {
			fail(p, "leading zero in JSON number"); return NULL;
		}
	} else {
		size_t digits = p->index;
		while (p->index < p->length && p->text[p->index] >= '0' &&
			p->text[p->index] <= '9') p->index++;
		if (p->index == digits) { fail(p, "malformed JSON number"); return NULL; }
	}
	state_json_value *value = new_value(p, STATE_JSON_NUMBER);
	if (value == NULL) return NULL;
	size_t length = p->index - start;
	value->text = malloc(length + 1);
	if (value->text == NULL) { state_json_free(value); fail(p, "could not allocate JSON number"); return NULL; }
	memcpy(value->text, p->text + start, length);
	value->text[length] = '\0';
	return value;
}

static state_json_value *parse_value(parser *p)
{
	space(p);
	if (p->index >= p->length) { fail(p, "missing JSON value"); return NULL; }
	unsigned char first = p->text[p->index];
	if (first == '{' || first == '[') {
		if (p->depth >= STATE_JSON_MAX_DEPTH) {
			fail(p, "state JSON nesting exceeds 64 levels"); return NULL;
		}
		p->depth++;
		state_json_value *value = first == '{' ? parse_object(p) : parse_array(p);
		p->depth--;
		return value;
	}
	if (first == '"') {
		state_json_value *value = new_value(p, STATE_JSON_STRING);
		if (value == NULL) return NULL;
		value->text = parse_string(p);
		if (value->text == NULL) { state_json_free(value); return NULL; }
		return value;
	}
	if (first == '-' || (first >= '0' && first <= '9')) return parse_number(p);
	for (size_t i = 0; i < 2; ++i) {
		const char *literal = i == 0 ? "true" : "false";
		size_t length = strlen(literal);
		if (p->length - p->index >= length &&
			memcmp(p->text + p->index, literal, length) == 0) {
			p->index += length;
			state_json_value *value = new_value(p, STATE_JSON_BOOL);
			if (value != NULL) value->boolean = i == 0;
			return value;
		}
	}
	fail(p, "unsupported or malformed JSON value");
	return NULL;
}

int state_json_parse(const char *text, state_json_value **out,
	char *error, size_t error_capacity)
{
	if (text == NULL || out == NULL) return 1;
	if (error_capacity > 0) error[0] = '\0';
	size_t length = strlen(text);
	if (!valid_utf8_bytes((const unsigned char *)text, length)) {
		if (error_capacity > 0) snprintf(error, error_capacity, "%s", "state JSON is not valid UTF-8");
		return 1;
	}
	parser p = {(const unsigned char *)text, length, 0, 0, error, error_capacity};
	state_json_value *value = parse_value(&p);
	if (value == NULL) return 1;
	space(&p);
	if (p.index != p.length) {
		state_json_free(value);
		fail(&p, "trailing data after JSON state");
		return 1;
	}
	*out = value;
	return 0;
}

const state_json_value *state_json_get(const state_json_value *object,
	const char *key)
{
	if (object == NULL || object->kind != STATE_JSON_OBJECT) return NULL;
	for (size_t i = 0; i < object->member_count; ++i) {
		if (strcmp(object->members[i].key, key) == 0) return object->members[i].value;
	}
	return NULL;
}

int state_json_write_string(FILE *stream, const char *value)
{
	bool utf8 = state_json_valid_utf8(value);
	if (fputc('"', stream) == EOF) return 1;
	for (const unsigned char *p = (const unsigned char *)value; *p != 0; ++p) {
		const char *escape = NULL;
		switch (*p) {
		case '"': escape = "\\\""; break;
		case '\\': escape = "\\\\"; break;
		case '\b': escape = "\\b"; break;
		case '\f': escape = "\\f"; break;
		case '\n': escape = "\\n"; break;
		case '\r': escape = "\\r"; break;
		case '\t': escape = "\\t"; break;
		default: break;
		}
		if (escape != NULL) {
			if (fputs(escape, stream) == EOF) return 1;
		} else if (*p < 0x20 || (*p >= 0x80 && !utf8)) {
			if (fprintf(stream, "\\u%04x", *p) < 0) return 1;
		} else if (fputc(*p, stream) == EOF) return 1;
	}
	return fputc('"', stream) == EOF;
}
