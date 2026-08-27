#include <lean/lean.h>

#include <stdint.h>
#include <string.h>

extern lean_object *initialize_randoml_Randoml_Cli(uint8_t builtin);
extern void lean_initialize_runtime_module(void);
extern lean_object *randoml_cli_run(lean_object *arguments);
extern void randoml_initialize_native(void);

static lean_object *raw_arguments(int argc, char **argv)
{
	lean_object *arguments = lean_mk_empty_array_with_capacity(lean_box((size_t)argc));
	for (int index = 0; index < argc; index++) {
		const unsigned char *source = (const unsigned char *)argv[index];
		size_t length = strlen(argv[index]);
		lean_object *bytes = lean_mk_empty_byte_array(lean_box(length));
		for (size_t offset = 0; offset < length; offset++)
			bytes = lean_byte_array_push(bytes, source[offset]);
		arguments = lean_array_push(arguments, bytes);
	}
	return arguments;
}

int main(int argc, char **argv)
{
	lean_initialize_runtime_module();
	randoml_initialize_native();
	lean_object *result = initialize_randoml_Randoml_Cli(1);
	lean_io_mark_end_initialization();
	if (lean_io_result_is_error(result)) {
		lean_io_result_show_error(result);
		lean_dec_ref(result);
		return 1;
	}
	lean_dec_ref(result);
	lean_init_task_manager();
	result = randoml_cli_run(raw_arguments(argc, argv));
	int status;
	if (lean_io_result_is_error(result)) {
		lean_io_result_show_error(result);
		status = 1;
	} else {
		status = (int)lean_unbox(lean_io_result_get_value(result));
	}
	lean_dec_ref(result);
	lean_finalize_task_manager();
	return status;
}
