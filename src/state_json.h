#ifndef RANDOMZ_STATE_JSON_H
#define RANDOMZ_STATE_JSON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

typedef enum state_json_kind {
	STATE_JSON_STRING,
	STATE_JSON_NUMBER,
	STATE_JSON_BOOL,
	STATE_JSON_ARRAY,
	STATE_JSON_OBJECT
} state_json_kind;

typedef struct state_json_value state_json_value;

typedef struct state_json_member {
	char *key;
	state_json_value *value;
} state_json_member;

struct state_json_value {
	state_json_kind kind;
	char *text;
	bool boolean;
	state_json_value **items;
	size_t item_count;
	state_json_member *members;
	size_t member_count;
};

int state_json_parse(const char *text, state_json_value **out,
	char *error, size_t error_capacity);
bool state_json_valid_utf8(const char *value);
const state_json_value *state_json_get(const state_json_value *object,
	const char *key);
void state_json_free(state_json_value *value);
int state_json_write_string(FILE *stream, const char *value);

#endif
