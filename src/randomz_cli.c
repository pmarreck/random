#define _GNU_SOURCE

#include "randomz.h"
#include "distribution_view.h"

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#include <bcrypt.h>
#include <fcntl.h>
#include <io.h>
#include <process.h>
#elif defined(__linux__)
#include <sys/random.h>
#include <sys/wait.h>
#include <unistd.h>
#elif defined(__APPLE__)
#include <sys/random.h>
#include <sys/wait.h>
#include <unistd.h>
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

#define MAX_EXACT_INTEGER INT64_C(9007199254740992)
#define STREAM_CHUNK 65536

typedef enum distribution {
	DIST_UNIFORM,
	DIST_NORMAL,
	DIST_EXPONENTIAL,
	DIST_POISSON,
	DIST_LOG_NORMAL,
	DIST_BETA
} distribution;

typedef enum chart_renderer {
	CHART_UTF8,
	CHART_KITTY,
	CHART_SIXEL
} chart_renderer;

typedef enum terminal_kind {
	TERMINAL_UNKNOWN,
	TERMINAL_KITTY,
	TERMINAL_WEZTERM
} terminal_kind;

#include "distribution_charts.inc"

typedef struct options {
	bool deterministic;
	bool force_true_random;
	distribution dist;
	int dist_count;
	bool binary_output;
	bool hex_output;
	bool base64_output;
	bool choose;
	bool shuffle;
	bool weighted;
	bool no_wait;
	bool chart_renderer_flag;
	bool view;
	bool generation_option_seen;
	const char *delimiter;
	const char *random_source;
	bool count_set;
	int64_t count;
	bool seed_set;
	uint8_t seed[32];
	bool start_set;
	bool end_set;
	int64_t start;
	int64_t end;
	bool mean_set;
	bool stddev_set;
	bool rate_set;
	bool lambda_set;
	bool alpha_set;
	bool beta_set;
	randomz_fixed mean;
	randomz_fixed stddev;
	randomz_fixed rate;
	randomz_fixed lambda;
	randomz_fixed alpha;
	randomz_fixed beta;
	const char *mean_text;
	const char *stddev_text;
	const char *rate_text;
	const char *lambda_text;
	const char *alpha_text;
	const char *beta_text;
} options;

typedef struct entropy_source {
	FILE *file;
	bool explicit_file;
	bool no_wait;
	char error[256];
} entropy_source;

typedef struct rng_source {
	randomz_fill_fn fill;
	void *context;
} rng_source;

typedef struct generated_value {
	bool is_fixed;
	int64_t integer;
	randomz_fixed fixed;
} generated_value;

typedef struct item_list {
	char **items;
	size_t count;
	char *storage;
} item_list;

static const char *program_name = "randomz";
static const char *program_path = "randomz";
static entropy_source *active_entropy;

static void print_error(const char *message)
{
	fprintf(stderr, "Error: %s\n", message);
}

static int parse_fixed_arg(const char *text, randomz_fixed *out)
{
	return randomz_fixed_parse(text, strlen(text), out);
}

static int parse_safe_int(const char *text, int64_t *out)
{
	return randomz_fixed_parse_int_safe(text, strlen(text), out);
}

static int parse_range_part(const char *text, size_t length, int64_t *out)
{
	if (length == 0) return RANDOMZ_INVALID_ARGUMENT;
	return randomz_fixed_parse_int_safe(text, length, out);
}

static int parse_range_literal(const char *text, int64_t *start, int64_t *end,
	bool *exclusive)
{
	const char *separator = strstr(text, "...");
	size_t separator_length = 3;
	*exclusive = separator != NULL;
	if (separator == NULL) {
		separator = strstr(text, "..");
		separator_length = 2;
	}
	if (separator == NULL) {
		const char *search = text + ((*text == '+' || *text == '-') ? 1 : 0);
		separator = strchr(search, '-');
		separator_length = 1;
		*exclusive = false;
	}
	if (separator == NULL) return RANDOMZ_INVALID_ARGUMENT;
	size_t first_length = (size_t)(separator - text);
	const char *last = separator + separator_length;
	if (parse_range_part(text, first_length, start) != RANDOMZ_OK ||
		parse_range_part(last, strlen(last), end) != RANDOMZ_OK)
		return RANDOMZ_INVALID_ARGUMENT;
	return RANDOMZ_OK;
}

static const char *base_name(const char *path)
{
	const char *slash = strrchr(path, '/');
	const char *backslash = strrchr(path, '\\');
	const char *last = slash;
	if (backslash != NULL && (last == NULL || backslash > last)) last = backslash;
	return last == NULL ? path : last + 1;
}

static bool normal_invocation(const char *name)
{
	size_t length = strlen(name);
	if (length > 4 && name[length - 4] == '.' &&
		(name[length - 3] == 'e' || name[length - 3] == 'E') &&
		(name[length - 2] == 'x' || name[length - 2] == 'X') &&
		(name[length - 1] == 'e' || name[length - 1] == 'E')) length -= 4;
	return (length == 7 && strncmp(name, "nrandom", length) == 0) ||
		(length == 8 && strncmp(name, "nrandomz", length) == 0);
}

static bool deterministic_invocation(const char *name)
{
	size_t length = strlen(name);
	if (length > 4 && name[length - 4] == '.' &&
		(name[length - 3] == 'e' || name[length - 3] == 'E') &&
		(name[length - 2] == 'x' || name[length - 2] == 'X') &&
		(name[length - 1] == 'e' || name[length - 1] == 'E')) length -= 4;
	return (length == 7 && strncmp(name, "drandom", length) == 0) ||
		(length == 8 && strncmp(name, "drandomz", length) == 0);
}

static const char *platform_name(void)
{
#if defined(_WIN32)
	return "Windows";
#elif defined(__APPLE__)
	return "OSX";
#elif defined(__linux__)
	return "Linux";
#else
	return "Unknown";
#endif
}

static const char *architecture_name(void)
{
#if defined(__aarch64__) || defined(_M_ARM64)
	return "arm64";
#elif defined(__x86_64__) || defined(_M_X64)
	return "x64";
#elif defined(__i386__) || defined(_M_IX86)
	return "x86";
#else
	return "unknown";
#endif
}

static void print_about(void)
{
	const char *description;
	if (normal_invocation(program_name)) {
		description = "Normally distributed random integer between bounds via Box-Muller sampling";
	} else if (deterministic_invocation(program_name)) {
		description = "Deterministic BLAKE3 keyed-XOF generator with reproducible integer seeds";
	} else {
		description = "Unified random number generator: multiple distributions, stdin ops, output formats";
	}
	printf("%s v%s (%s/%s): %s\n", program_name, RANDOMZ_VERSION,
		platform_name(), architecture_name(), description);
}

static bool equals_case_insensitive(const char *left, const char *right)
{
	if (left == NULL || right == NULL) return false;
	while (*left != '\0' && *right != '\0') {
		if (tolower((unsigned char)*left) != tolower((unsigned char)*right)) return false;
		left++;
		right++;
	}
	return *left == '\0' && *right == '\0';
}

static terminal_kind terminal_program_kind(const char *value)
{
	if (equals_case_insensitive(value, "WezTerm")) return TERMINAL_WEZTERM;
	if (equals_case_insensitive(value, "ghostty") ||
		equals_case_insensitive(value, "kitty")) return TERMINAL_KITTY;
	return TERMINAL_UNKNOWN;
}

static bool environment_present(const char *name)
{
	const char *value = getenv(name);
	return value != NULL && *value != '\0';
}

static terminal_kind detected_terminal_kind(void)
{
	const char *term = getenv("TERM");
	if (environment_present("WEZTERM_PANE") || environment_present("WEZTERM_EXECUTABLE"))
		return TERMINAL_WEZTERM;
	if ((term != NULL && strcmp(term, "xterm-kitty") == 0) ||
		environment_present("KITTY_WINDOW_ID") || environment_present("GHOSTTY_RESOURCES_DIR"))
		return TERMINAL_KITTY;
	terminal_kind direct = terminal_program_kind(getenv("TERM_PROGRAM"));
	if (direct != TERMINAL_UNKNOWN) return direct;
	return TERMINAL_UNKNOWN;
}

static bool stdout_is_tty(void)
{
#if defined(_WIN32)
	return _isatty(_fileno(stdout)) == 1;
#else
	return isatty(fileno(stdout)) == 1;
#endif
}

static bool chart_renderer_for_help(int argc, char **argv, chart_renderer *out)
{
	bool flag_seen = false;
	for (int i = 1; i < argc; ++i) {
		if (strcmp(argv[i], "--kitty") == 0) { *out = CHART_KITTY; flag_seen = true; }
		else if (strcmp(argv[i], "--sixel") == 0) { *out = CHART_SIXEL; flag_seen = true; }
		else if (strcmp(argv[i], "--utf8") == 0 ||
			strcmp(argv[i], "--utf8-graphics") == 0) {
			*out = CHART_UTF8; flag_seen = true;
		}
	}
	if (flag_seen) return true;
	const char *requested = getenv("RANDOMZ_CHART_TYPE");
	if (requested != NULL && *requested != '\0') {
		if (equals_case_insensitive(requested, "utf8")) *out = CHART_UTF8;
		else if (equals_case_insensitive(requested, "kitty")) *out = CHART_KITTY;
		else if (equals_case_insensitive(requested, "sixel")) *out = CHART_SIXEL;
		else {
			print_error("RANDOMZ_CHART_TYPE must be utf8, kitty, or sixel");
			return false;
		}
		return true;
	}
	if (!stdout_is_tty()) { *out = CHART_UTF8; return true; }
	/* Image placements are not reliably attached to tmux scrollback. Explicit
	 * flags still bypass this automatic, conservative fallback. */
	if (environment_present("TMUX")) { *out = CHART_UTF8; return true; }
	terminal_kind terminal = detected_terminal_kind();
	if (terminal == TERMINAL_WEZTERM) {
		*out = CHART_SIXEL;
	} else if (terminal == TERMINAL_KITTY) {
		*out = CHART_KITTY;
	} else {
		*out = CHART_UTF8;
	}
	return true;
}

static const distribution_chart *chart_for_distribution(distribution dist)
{
	for (size_t i = 0; i < sizeof(distribution_charts) / sizeof(distribution_charts[0]); ++i) {
		if (distribution_charts[i].dist == dist) return &distribution_charts[i];
	}
	return NULL;
}

static void write_kitty_sequence(const char *control, const char *payload, size_t length,
	bool tmux)
{
	if (tmux) fputs("\033Ptmux;\033\033_G", stdout);
	else fputs("\033_G", stdout);
	fputs(control, stdout);
	fputc(';', stdout);
	(void)fwrite(payload, 1, length, stdout);
	if (tmux) fputs("\033\033\\\033\\", stdout);
	else fputs("\033\\", stdout);
}

static void print_distribution_help(distribution dist, chart_renderer renderer)
{
	const distribution_chart *chart = chart_for_distribution(dist);
	if (chart == NULL) return;
	printf("\nDistribution: %s\n%s\n\n", chart->title, chart->parameters);
	if (renderer == CHART_KITTY) {
		size_t length = strlen(chart->png_base64);
		bool tmux = environment_present("TMUX");
		for (size_t offset = 0; offset < length; offset += 4096) {
			size_t count = length - offset > 4096 ? 4096 : length - offset;
			bool final = offset + count == length;
			char control[64];
			if (offset == 0) {
				(void)snprintf(control, sizeof(control),
					"a=T,f=100,t=d,c=56,r=12,C=1,q=2,m=%d", final ? 0 : 1);
			} else {
				(void)snprintf(control, sizeof(control), "m=%d", final ? 0 : 1);
			}
			write_kitty_sequence(control, chart->png_base64 + offset, count, tmux);
		}
		for (int row = 0; row < 12; ++row) fputs("\r\n", stdout);
	} else if (renderer == CHART_SIXEL) {
		/* tmux 3.4+ parses Sixel DCS natively when built with Sixel support. */
		fputs("\033" "7\033P0;1;0q", stdout);
		fputs(chart->sixel_data, stdout);
		fputs("\033\\\033" "8", stdout);
		for (int row = 0; row < 12; ++row) fputs("\r\n", stdout);
	} else {
		fputs(chart->fallback, stdout);
	}
	puts(chart->axis);
}

static void print_help(distribution dist, chart_renderer renderer)
{
	printf("Usage: %s [options] [M-N|M..N|M...N]\n", program_name);
	printf("       echo 'items' | %s --choose\n", program_name);
	printf("       echo 'items' | %s --shuffle\n", program_name);
	puts("");
	puts("Unified random number generator with multiple modes and distributions.");
	puts("");
	puts("Distributions (mutually exclusive):");
	puts("  (default)           Uniform distribution");
	puts("  -n, --normalized    Normal (Gaussian) via Box-Muller");
	puts("      --exponential   Exponential distribution (use --rate)");
	puts("      --poisson       Poisson distribution (use --lambda or --mean)");
	puts("      --log-normal    Log-normal distribution");
	puts("      --beta[=B]      Beta distribution; optional B replaces default beta 2");
	puts("");
	puts("Stdin operations:");
	puts("      --choose        Pick one random item from stdin");
	puts("      --shuffle       Shuffle all items from stdin");
	puts("      --weighted      Pick from weighted stdin (format: value:weight)");
	puts("");
	puts("Options:");
	puts("  -a, --about         Show a short description");
	puts("  -b, --binaryoutput  Output binary bytes");
	puts("  -c, --count N       Output N numbers (default: 1, or 1024 with -b)");
	puts("  -d, --deterministic Use the deterministic BLAKE3 keyed XOF");
	puts("      --true-random   Force OS/source entropy; ignore DRANDOMZ_SEED");
	puts("      --delimiter S   Set delimiter for output/input (default: newline)");
	puts("  -h, --help          Show this help message");
	puts("      --hex           Output as hexadecimal");
	puts("      --base64        Output as base64 (for binary)");
	puts("      --seed N|0xHEX  Set unsigned 256-bit integer seed (implies -d)");
	puts("      --random-source PATH  Read entropy from PATH instead of the OS");
	puts("      --no-wait       Fail rather than wait for Linux getrandom initialization");
	puts("      --kitty         Force Kitty graphics for a distribution help chart");
	puts("      --sixel         Force Sixel graphics for a distribution help chart");
	puts("      --utf8           Force the UTF-8 Braille distribution chart");
	puts("      --utf8-graphics  Long alias for --utf8");
	puts("      --view          Show only the selected distribution with supplied parameters");
	puts("      --mean M        Set mean for normal/log-normal; Poisson lambda alias");
	puts("      --stddev S      Set stddev for normal/log-normal");
	puts("      --rate R        Set exponential rate");
	puts("      --lambda L      Set Poisson lambda (clearer alias for --mean)");
	puts("      --alpha A       Set alpha for beta distribution");
	puts("      --test          Run the test suite");
	puts("");
	puts("Symlink behavior:");
	puts("  'nrandomz' -> implies --normalized");
	puts("  'drandomz' -> implies --deterministic");
	puts("");
	puts("Environment variables:");
	puts("  DRANDOMZ_SEED     Unsigned decimal or 0x-prefixed seed (implies -d)");
	puts("  RANDOMZ_CHART_TYPE  utf8, kitty, or sixel; command-line flags override it");
	puts("");
	puts("Deterministic mode never persists state. Every invocation starts at");
	puts("stream position zero. Without an explicit seed it obtains 32 bytes");
	puts("from the entropy source and prints the replayable seed to stderr.");
	print_distribution_help(dist, renderer);
}

static distribution help_distribution_from_args(int argc, char **argv)
{
	distribution selected = normal_invocation(program_name) ? DIST_NORMAL : DIST_UNIFORM;
	for (int i = 1; i < argc; ++i) {
		distribution candidate = DIST_UNIFORM;
		if (strcmp(argv[i], "--normalized") == 0 || strcmp(argv[i], "-n") == 0) {
			candidate = DIST_NORMAL;
		} else if (strcmp(argv[i], "--exponential") == 0) {
			candidate = DIST_EXPONENTIAL;
		} else if (strcmp(argv[i], "--poisson") == 0) {
			candidate = DIST_POISSON;
		} else if (strcmp(argv[i], "--log-normal") == 0) {
			candidate = DIST_LOG_NORMAL;
		} else if (strcmp(argv[i], "--beta") == 0 ||
			strncmp(argv[i], "--beta=", 7) == 0) {
			candidate = DIST_BETA;
		}
		if (candidate == DIST_UNIFORM) continue;
		if (selected != DIST_UNIFORM && selected != candidate) return DIST_UNIFORM;
		selected = candidate;
	}
	return selected;
}

static bool test_file_exists(const char *path)
{
	FILE *file = fopen(path, "rb");
	if (file == NULL) return false;
	fclose(file);
	return true;
}

static char *relative_test_path(const char *suffix)
{
	const char *slash = strrchr(program_path, '/');
	const char *backslash = strrchr(program_path, '\\');
	const char *last = slash;
	if (backslash != NULL && (last == NULL || backslash > last)) last = backslash;
	if (last == NULL) return NULL;
	size_t directory_length = (size_t)(last - program_path);
	size_t needed = directory_length + strlen(suffix) + 1;
	char *candidate = malloc(needed);
	if (candidate == NULL) return NULL;
	memcpy(candidate, program_path, directory_length);
	memcpy(candidate + directory_length, suffix, strlen(suffix) + 1);
	return candidate;
}

static int run_test_suite(void)
{
	const char *depth = getenv("RANDOM_TEST_DEPTH");
	if (depth != NULL && strcmp(depth, "1") == 0) return 0;
	const char *path = getenv("RANDOM_TEST_FILE");
	char *owned_path = NULL;
	if (path == NULL || *path == '\0') {
		const char *suffixes[] = { "/../tests/random_test", "/../../tests/random_test" };
		for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); ++i) {
			owned_path = relative_test_path(suffixes[i]);
			if (owned_path != NULL && test_file_exists(owned_path)) {
				path = owned_path;
				break;
			}
			free(owned_path);
			owned_path = NULL;
		}
		if (path == NULL || *path == '\0') path = "tests/random_test";
	}
	if (!test_file_exists(path)) {
		fprintf(stderr, "Error: test file not found: %s\n", path);
		free(owned_path);
		return 1;
	}
#if defined(_WIN32)
	_putenv_s("FAST", "1");
	_putenv_s("RANDOM_TEST_DEPTH", "0");
	_putenv_s("RANDOM_TEST_CLI", program_path);
	intptr_t status = _spawnlp(_P_WAIT, "bash", "bash", path, NULL);
	free(owned_path);
	if (status == -1) print_error("could not run test suite (bash is required on Windows)");
	return status == 0 ? 0 : 1;
#else
	pid_t child = fork();
	if (child == 0) {
		(void)setenv("FAST", "1", 1);
		(void)setenv("RANDOM_TEST_DEPTH", "0", 1);
		(void)setenv("RANDOM_TEST_CLI", program_path, 1);
		execl(path, path, (char *)NULL);
		_exit(127);
	}
	if (child < 0) {
		print_error("could not start test suite");
		free(owned_path);
		return 1;
	}
	int status = 0;
	while (waitpid(child, &status, 0) < 0) {
		if (errno == EINTR) continue;
		print_error("could not wait for test suite");
		free(owned_path);
		return 1;
	}
	free(owned_path);
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
#endif
}

static int hex_value(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static bool parse_seed(const char *text, uint8_t out[32])
{
	size_t length = strlen(text);
	if (length == 0) return false;
	memset(out, 0, 32);

	if (length >= 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
		const char *digits = text + 2;
		size_t count = length - 2;
		if (count == 0 || count > 64) return false;
		for (size_t i = 0; i < count; ++i) if (hex_value(digits[i]) < 0) return false;
		size_t byte_index = 32 - (count + 1) / 2;
		size_t digit_index = 0;
		if ((count & 1) != 0) {
			out[byte_index++] = (uint8_t)hex_value(digits[digit_index++]);
		}
		while (digit_index < count) {
			out[byte_index++] = (uint8_t)((hex_value(digits[digit_index]) << 4) |
				hex_value(digits[digit_index + 1]));
			digit_index += 2;
		}
		return true;
	}

	for (size_t i = 0; i < length; ++i) if (text[i] < '0' || text[i] > '9') return false;
	for (size_t i = 0; i < length; ++i) {
		unsigned carry = (unsigned)(text[i] - '0');
		for (size_t j = 32; j-- > 0;) {
			unsigned value = (unsigned)out[j] * 10U + carry;
			out[j] = (uint8_t)(value & 0xffU);
			carry = value >> 8;
		}
		if (carry != 0) return false;
	}
	return true;
}

static void select_distribution(options *opts, distribution value)
{
	if (opts->dist_count > 0 && opts->dist == value) return;
	opts->dist = value;
	opts->dist_count++;
}

static int require_next(int argc, char **argv, int *index, const char *message,
	const char **value)
{
	(*index)++;
	if (*index >= argc) {
		print_error(message);
		return 1;
	}
	*value = argv[*index];
	return 0;
}

static const char *attached_option_value(const char *argument, const char *name)
{
	size_t length = strlen(name);
	return strncmp(argument, name, length) == 0 && argument[length] == '='
		? argument + length + 1 : NULL;
}

static int parse_arguments(int argc, char **argv, options *opts)
{
	memset(opts, 0, sizeof(*opts));
	opts->dist = DIST_UNIFORM;
	opts->delimiter = "\n";
	opts->deterministic = deterministic_invocation(program_name);
	if (normal_invocation(program_name)) select_distribution(opts, DIST_NORMAL);

	const char *range_literal = NULL;
	int positional_count = 0;
	for (int i = 1; i < argc; ++i) {
		const char *arg = argv[i];
		const char *value;
		if (strcmp(arg, "--about") == 0 || strcmp(arg, "-a") == 0) {
			print_about();
			exit(0);
		} else if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
			distribution help_dist = help_distribution_from_args(argc, argv);
			chart_renderer renderer = CHART_UTF8;
			if (help_dist != DIST_UNIFORM &&
				!chart_renderer_for_help(argc, argv, &renderer)) return 1;
			print_help(help_dist, renderer);
			exit(0);
		} else if (strcmp(arg, "--test") == 0) {
			exit(run_test_suite());
		} else if (strcmp(arg, "--deterministic") == 0 || strcmp(arg, "-d") == 0) {
			opts->deterministic = true;
			opts->generation_option_seen = true;
		} else if (strcmp(arg, "--true-random") == 0) {
			opts->force_true_random = true;
			opts->generation_option_seen = true;
		} else if (strcmp(arg, "--normalized") == 0 || strcmp(arg, "-n") == 0) {
			select_distribution(opts, DIST_NORMAL);
		} else if (strcmp(arg, "--exponential") == 0) {
			select_distribution(opts, DIST_EXPONENTIAL);
		} else if (strcmp(arg, "--poisson") == 0) {
			select_distribution(opts, DIST_POISSON);
		} else if (strcmp(arg, "--log-normal") == 0) {
			select_distribution(opts, DIST_LOG_NORMAL);
		} else if (strcmp(arg, "--beta") == 0 ||
			attached_option_value(arg, "--beta") != NULL) {
			select_distribution(opts, DIST_BETA);
			value = attached_option_value(arg, "--beta");
			if (value != NULL && *value == '\0') {
				print_error("--beta value must be a number");
				return 1;
			}
			if (value == NULL && i + 1 < argc) {
				randomz_fixed candidate_fixed;
				int64_t range_start, range_end;
				bool range_exclusive;
				const char *candidate = argv[i + 1];
				bool numeric = parse_fixed_arg(candidate, &candidate_fixed) == RANDOMZ_OK;
				bool range = parse_range_literal(candidate, &range_start, &range_end,
					&range_exclusive) == RANDOMZ_OK;
				if (numeric || (candidate[0] != '-' && !range)) value = argv[++i];
			}
			if (value != NULL) {
				if (parse_fixed_arg(value, &opts->beta) != RANDOMZ_OK) {
					print_error("--beta value must be a number");
					return 1;
				}
				if (opts->beta.m <= 0) {
					print_error("--beta parameter must be positive");
					return 1;
				}
				opts->beta_set = true;
				opts->beta_text = value;
			}
		} else if (strcmp(arg, "--binaryoutput") == 0 || strcmp(arg, "-b") == 0) {
			opts->binary_output = true;
			opts->generation_option_seen = true;
		} else if (strcmp(arg, "--hex") == 0) {
			opts->hex_output = true;
			opts->generation_option_seen = true;
		} else if (strcmp(arg, "--base64") == 0) {
			opts->base64_output = true;
			opts->generation_option_seen = true;
		} else if (strcmp(arg, "--choose") == 0) {
			opts->choose = true;
			opts->generation_option_seen = true;
		} else if (strcmp(arg, "--shuffle") == 0) {
			opts->shuffle = true;
			opts->generation_option_seen = true;
		} else if (strcmp(arg, "--weighted") == 0) {
			opts->weighted = true;
			opts->generation_option_seen = true;
		} else if (strcmp(arg, "--no-wait") == 0) {
			opts->no_wait = true;
			opts->generation_option_seen = true;
		} else if (strcmp(arg, "--view") == 0) {
			opts->view = true;
		} else if (strcmp(arg, "--kitty") == 0 || strcmp(arg, "--sixel") == 0 ||
			strcmp(arg, "--utf8") == 0 || strcmp(arg, "--utf8-graphics") == 0) {
			opts->chart_renderer_flag = true;
		} else if (strncmp(arg, "--random-source=", 16) == 0) {
			opts->generation_option_seen = true;
			opts->random_source = arg + 16;
			if (*opts->random_source == '\0') {
				print_error("--random-source requires a path");
				return 1;
			}
		} else if (strcmp(arg, "--random-source") == 0) {
			opts->generation_option_seen = true;
			if (require_next(argc, argv, &i, "--random-source requires a path", &value)) return 1;
			if (*value == '\0') {
				print_error("--random-source requires a path");
				return 1;
			}
			opts->random_source = value;
		} else if (strcmp(arg, "--delimiter") == 0 || strcmp(arg, "--delim") == 0) {
			opts->generation_option_seen = true;
			if (require_next(argc, argv, &i, "--delimiter requires a value", &value)) return 1;
			if (*value == '\0') {
				print_error("--delimiter must not be empty");
				return 1;
			}
			opts->delimiter = value;
		} else if (strcmp(arg, "--count") == 0 || strcmp(arg, "-c") == 0) {
			opts->generation_option_seen = true;
			if (require_next(argc, argv, &i, "--count requires a number", &value)) return 1;
			if (parse_safe_int(value, &opts->count) != RANDOMZ_OK || opts->count < 0) {
				print_error("--count must be a nonnegative whole number no larger than 2^53");
				return 1;
			}
			opts->count_set = true;
		} else if (strcmp(arg, "--seed") == 0) {
			opts->generation_option_seen = true;
			if (require_next(argc, argv, &i, "--seed requires a value", &value)) return 1;
			if (!parse_seed(value, opts->seed)) {
				fprintf(stderr, "Error: --seed must be an unsigned decimal or 0x-prefixed "
					"hexadecimal integer smaller than 2^256, got: %s\n", value);
				return 1;
			}
			opts->seed_set = true;
			opts->deterministic = true;
		} else if (strcmp(arg, "--mean") == 0 ||
			attached_option_value(arg, "--mean") != NULL) {
			value = attached_option_value(arg, "--mean");
			if (value == NULL && require_next(argc, argv, &i,
				"--mean requires a number", &value)) return 1;
			if (*value == '\0') { print_error("--mean requires a number"); return 1; }
			if (parse_fixed_arg(value, &opts->mean) != RANDOMZ_OK) {
				print_error("--mean value must be a number");
				return 1;
			}
			opts->mean_set = true;
			opts->mean_text = value;
		} else if (strcmp(arg, "--stddev") == 0 ||
			attached_option_value(arg, "--stddev") != NULL) {
			value = attached_option_value(arg, "--stddev");
			if (value == NULL && require_next(argc, argv, &i,
				"--stddev requires a number", &value)) return 1;
			if (*value == '\0') { print_error("--stddev requires a number"); return 1; }
			if (parse_fixed_arg(value, &opts->stddev) != RANDOMZ_OK) {
				print_error("--stddev value must be a number");
				return 1;
			}
			if (opts->stddev.m <= 0) {
				print_error("--stddev must be positive");
				return 1;
			}
			opts->stddev_set = true;
			opts->stddev_text = value;
		} else if (strcmp(arg, "--rate") == 0 ||
			attached_option_value(arg, "--rate") != NULL) {
			value = attached_option_value(arg, "--rate");
			if (value == NULL && require_next(argc, argv, &i,
				"--rate requires a number", &value)) return 1;
			if (*value == '\0') { print_error("--rate requires a number"); return 1; }
			if (parse_fixed_arg(value, &opts->rate) != RANDOMZ_OK) {
				print_error("--rate value must be a number");
				return 1;
			}
			if (opts->rate.m <= 0) {
				print_error("--rate must be positive");
				return 1;
			}
			opts->rate_set = true;
			opts->rate_text = value;
		} else if (strcmp(arg, "--lambda") == 0 ||
			attached_option_value(arg, "--lambda") != NULL) {
			value = attached_option_value(arg, "--lambda");
			if (value == NULL && require_next(argc, argv, &i,
				"--lambda requires a number", &value)) return 1;
			if (*value == '\0') { print_error("--lambda requires a number"); return 1; }
			if (parse_fixed_arg(value, &opts->lambda) != RANDOMZ_OK) {
				print_error("--lambda value must be a number");
				return 1;
			}
			if (opts->lambda.m <= 0) {
				print_error("--lambda must be positive");
				return 1;
			}
			opts->lambda_set = true;
			opts->lambda_text = value;
		} else if (strcmp(arg, "--alpha") == 0 ||
			attached_option_value(arg, "--alpha") != NULL) {
			value = attached_option_value(arg, "--alpha");
			if (value == NULL && require_next(argc, argv, &i,
				"--alpha requires a number", &value)) return 1;
			if (*value == '\0') { print_error("--alpha requires a number"); return 1; }
			if (parse_fixed_arg(value, &opts->alpha) != RANDOMZ_OK) {
				print_error("--alpha value must be a number");
				return 1;
			}
			if (opts->alpha.m <= 0) {
				print_error("--alpha must be positive");
				return 1;
			}
			opts->alpha_set = true;
			opts->alpha_text = value;
		} else {
			if (strncmp(arg, "--", 2) == 0) {
				fprintf(stderr, "Error: unknown option: %s\n", arg);
				return 1;
			}
			if (positional_count == 0) range_literal = arg;
			positional_count++;
		}
	}

	if (opts->view && positional_count > 0) {
		print_error("--view does not accept a range");
		return 1;
	}
	if (positional_count > 1) {
		print_error("expected at most one range (M-N, M..N, or M...N)");
		return 1;
	}
	if (positional_count > 0 && !(opts->dist == DIST_UNIFORM || opts->dist == DIST_NORMAL)) {
		print_error("ranges do not apply to the selected distribution");
		return 1;
	}
	if (positional_count > 0 && opts->dist == DIST_NORMAL &&
		(opts->mean_set || opts->stddev_set)) {
		print_error("a range cannot be combined with custom normal parameters");
		return 1;
	}
	if (range_literal != NULL) {
		bool exclusive;
		if (parse_range_literal(range_literal, &opts->start, &opts->end,
			&exclusive) != RANDOMZ_OK) {
			print_error("range must be M-N, M..N, or M...N using whole numbers no larger than 2^53 in magnitude");
			return 1;
		}
		if (exclusive) {
			if (opts->start >= opts->end) {
				print_error("an end-exclusive range must have M < N");
				return 1;
			}
			opts->end--;
		}
		opts->start_set = true;
		opts->end_set = true;
	}

	if (opts->dist_count > 1) {
		print_error("only one distribution type can be specified");
		return 1;
	}
	if (opts->chart_renderer_flag && !opts->view) {
		print_error("--kitty, --sixel, --utf8, and --utf8-graphics require --help or --view");
		return 1;
	}
	if (opts->view && opts->dist_count != 1) {
		print_error("--view requires exactly one alternate distribution");
		return 1;
	}
	if (opts->view && opts->generation_option_seen) {
		print_error("--view cannot be combined with generation, stdin, range, or output options");
		return 1;
	}
	int stdin_modes = (opts->choose ? 1 : 0) + (opts->shuffle ? 1 : 0) +
		(opts->weighted ? 1 : 0);
	if (stdin_modes > 1) {
		print_error("only one stdin operation can be specified");
		return 1;
	}
	if (opts->base64_output && !opts->binary_output) {
		print_error("--base64 requires --binaryoutput");
		return 1;
	}
	if (opts->hex_output && opts->base64_output) {
		print_error("--hex and --base64 are mutually exclusive");
		return 1;
	}
	if (opts->mean_set && !(opts->dist == DIST_NORMAL || opts->dist == DIST_POISSON ||
		opts->dist == DIST_LOG_NORMAL)) {
		print_error("--mean is not used by the selected distribution");
		return 1;
	}
	if (opts->stddev_set && !(opts->dist == DIST_NORMAL || opts->dist == DIST_LOG_NORMAL)) {
		print_error("--stddev is not used by the selected distribution");
		return 1;
	}
	if (opts->rate_set && opts->dist != DIST_EXPONENTIAL) {
		print_error("--rate requires --exponential");
		return 1;
	}
	if (opts->lambda_set && opts->dist != DIST_POISSON) {
		print_error("--lambda requires --poisson");
		return 1;
	}
	if (opts->dist == DIST_POISSON && opts->lambda_set && opts->mean_set) {
		print_error("--lambda and --mean are aliases; specify only one");
		return 1;
	}
	if (opts->alpha_set && opts->dist != DIST_BETA) {
		print_error("--alpha requires --beta");
		return 1;
	}
	if (opts->force_true_random && opts->deterministic) {
		print_error("--true-random cannot be combined with --deterministic, --seed, or drandomz");
		return 1;
	}
	if (opts->dist == DIST_POISSON && opts->mean_set && opts->mean.m <= 0) {
		print_error("--mean must be positive for --poisson (it is the rate parameter)");
		return 1;
	}
	const char *env_seed = getenv("DRANDOMZ_SEED");
	if (!opts->force_true_random && !opts->deterministic && env_seed != NULL && *env_seed != '\0') {
		opts->deterministic = true;
	}
	return 0;
}

static int entropy_open(entropy_source *source, const char *path, bool no_wait)
{
	memset(source, 0, sizeof(*source));
	source->no_wait = no_wait;
	if (path != NULL) {
		source->file = fopen(path, "rb");
		source->explicit_file = true;
		if (source->file == NULL) {
			snprintf(source->error, sizeof(source->error),
				"source could not be opened: %s", strerror(errno));
			return 1;
		}
	}
#if !defined(__linux__)
	if (no_wait && path == NULL) {
		snprintf(source->error, sizeof(source->error),
			"--no-wait is supported only by Linux getrandom");
		return 1;
	}
#endif
	return 0;
}

static int entropy_file_fill(entropy_source *source, uint8_t *out, size_t count)
{
	size_t offset = 0;
	while (offset < count) {
		size_t got = fread(out + offset, 1, count - offset, source->file);
		if (got == 0) {
			if (ferror(source->file)) {
				snprintf(source->error, sizeof(source->error),
					"source read failed: %s", strerror(errno));
			} else {
				snprintf(source->error, sizeof(source->error),
					"source reached EOF before %zu bytes were read", count);
			}
			return 1;
		}
		offset += got;
	}
	return 0;
}

#if !defined(_WIN32)
static int entropy_device_fallback(entropy_source *source, uint8_t *out, size_t count)
{
	if (source->file == NULL) source->file = fopen("/dev/urandom", "rb");
	if (source->file == NULL) {
		snprintf(source->error, sizeof(source->error),
			"fallback /dev/urandom could not be opened: %s", strerror(errno));
		return 1;
	}
	return entropy_file_fill(source, out, count);
}
#endif

static int entropy_fill(void *context, uint8_t *out, size_t count)
{
	entropy_source *source = context;
	if (source->explicit_file) return entropy_file_fill(source, out, count);
	if (count == 0) return 0;

#if defined(_WIN32)
	NTSTATUS status = BCryptGenRandom(NULL, out, (ULONG)count,
		BCRYPT_USE_SYSTEM_PREFERRED_RNG);
	if (status != 0) {
		snprintf(source->error, sizeof(source->error),
			"BCryptGenRandom failed with status %ld", (long)status);
		return 1;
	}
	return 0;
#elif defined(__linux__)
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
		if (errno == EINTR) continue;
		if (errno == ENOSYS) return entropy_device_fallback(source, out + offset, count - offset);
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
#else
	size_t offset = 0;
	while (offset < count) {
		size_t part = count - offset;
		if (part > 256) part = 256;
		if (getentropy(out + offset, part) == 0) {
			offset += part;
			continue;
		}
		if (errno == EINTR) continue;
		if (errno == ENOSYS) return entropy_device_fallback(source, out + offset, count - offset);
		snprintf(source->error, sizeof(source->error),
			"getentropy failed: %s", strerror(errno));
		return 1;
	}
	return 0;
#endif
}

static int drbg_fill_callback(void *context, uint8_t *out, size_t count)
{
	return randomz_drbg_fill(context, out, count);
}

static int entropy_rng_fill(void *context, uint8_t *out, size_t count)
{
	return entropy_fill(context, out, count) == 0 ? RANDOMZ_OK : RANDOMZ_ENTROPY_ERROR;
}

static int rng_failure(int status)
{
	if (status == RANDOMZ_ENTROPY_ERROR && active_entropy != NULL) {
		fprintf(stderr, "Error: entropy %s\n",
			active_entropy->error[0] == '\0' ? "source failed" : active_entropy->error);
	} else {
		fprintf(stderr, "Error: RNG core failed with status %d\n", status);
	}
	return 1;
}

static int rng_range(rng_source *source, int64_t start, int64_t end, int64_t *out)
{
	int status = randomz_range(source->fill, source->context, start, end, out);
	return status;
}

static randomz_fixed fixed_integer(int64_t value)
{
	return randomz_fixed_from_int(value);
}

static int generate_value(const options *opts, rng_source *source,
	int64_t start, int64_t end, generated_value *value)
{
	int status;
	value->is_fixed = false;
	switch (opts->dist) {
	case DIST_EXPONENTIAL:
		value->is_fixed = true;
		return randomz_exponential(source->fill, source->context,
			opts->rate_set ? opts->rate : fixed_integer(1), &value->fixed);
	case DIST_POISSON:
		return randomz_poisson(source->fill, source->context,
			opts->lambda_set ? opts->lambda :
			(opts->mean_set ? opts->mean : fixed_integer(1)), &value->integer);
	case DIST_LOG_NORMAL:
		value->is_fixed = true;
		return randomz_log_normal(source->fill, source->context,
			opts->mean_set ? opts->mean : fixed_integer(0),
			opts->stddev_set ? opts->stddev : fixed_integer(1), &value->fixed);
	case DIST_BETA:
		value->is_fixed = true;
		return randomz_beta(source->fill, source->context,
			opts->alpha_set ? opts->alpha : fixed_integer(2),
			opts->beta_set ? opts->beta : fixed_integer(2), &value->fixed);
	case DIST_NORMAL:
		if (opts->mean_set || opts->stddev_set) {
			randomz_fixed output;
			status = randomz_normal(source->fill, source->context,
				opts->mean_set ? opts->mean : fixed_integer(0),
				opts->stddev_set ? opts->stddev : fixed_integer(1), &output);
			if (status != RANDOMZ_OK) return status;
			return randomz_fixed_to_int_round(output, &value->integer);
		}
		return randomz_normal_int(source->fill, source->context, start, end,
			&value->integer);
	case DIST_UNIFORM:
	default:
		return rng_range(source, start, end, &value->integer);
	}
}

static char *trim_in_place(char *text)
{
	while (*text != '\0' && isspace((unsigned char)*text)) text++;
	char *end = text + strlen(text);
	while (end > text && isspace((unsigned char)end[-1])) end--;
	*end = '\0';
	return text;
}

static char *read_stdin_all(void)
{
	size_t length = 0;
	size_t capacity = 4096;
	char *buffer = malloc(capacity + 1);
	if (buffer == NULL) return NULL;
	while (true) {
		if (length == capacity) {
			if (capacity > SIZE_MAX / 2) { free(buffer); return NULL; }
			capacity *= 2;
			char *grown = realloc(buffer, capacity + 1);
			if (grown == NULL) { free(buffer); return NULL; }
			buffer = grown;
		}
		size_t got = fread(buffer + length, 1, capacity - length, stdin);
		length += got;
		if (got == 0) break;
	}
	if (ferror(stdin)) { free(buffer); return NULL; }
	buffer[length] = '\0';
	return buffer;
}

static bool delimiter_contains(const char *delimiter, char c)
{
	return strchr(delimiter, c) != NULL;
}

static item_list read_items(const char *delimiter)
{
	item_list list = {0};
	list.storage = read_stdin_all();
	if (list.storage == NULL) return list;
	char *content = trim_in_place(list.storage);
	if (*content == '\0') return list;

	size_t capacity = 16;
	list.items = malloc(capacity * sizeof(*list.items));
	if (list.items == NULL) {
		free(list.storage);
		list.storage = NULL;
		return list;
	}
	char *cursor = content;
	while (*cursor != '\0') {
		while (*cursor != '\0' && (strcmp(delimiter, "\n") == 0
				? *cursor == '\n' : delimiter_contains(delimiter, *cursor))) cursor++;
		if (*cursor == '\0') break;
		char *start = cursor;
		while (*cursor != '\0' && !(strcmp(delimiter, "\n") == 0
				? *cursor == '\n' : delimiter_contains(delimiter, *cursor))) cursor++;
		if (*cursor != '\0') {
			if (strcmp(delimiter, "\n") == 0 && cursor > start && cursor[-1] == '\r')
				cursor[-1] = '\0';
			*cursor++ = '\0';
		} else if (strcmp(delimiter, "\n") == 0 && cursor > start && cursor[-1] == '\r') {
			cursor[-1] = '\0';
		}
		if (strcmp(delimiter, "\n") != 0) start = trim_in_place(start);
		if (*start == '\0') continue;
		if (list.count == capacity) {
			capacity *= 2;
			char **grown = realloc(list.items, capacity * sizeof(*list.items));
			if (grown == NULL) {
				free(list.items);
				free(list.storage);
				list.items = NULL;
				list.storage = NULL;
				list.count = 0;
				return list;
			}
			list.items = grown;
		}
		list.items[list.count++] = start;
	}
	return list;
}

static void free_items(item_list *list)
{
	free(list->items);
	free(list->storage);
}

static int handle_stdin_operation(const options *opts, rng_source *source)
{
	item_list list = read_items(opts->delimiter);
	if (list.storage == NULL || (list.count > 0 && list.items == NULL)) {
		free_items(&list);
		print_error("could not read stdin");
		return 1;
	}
	if (list.count == 0) {
		free_items(&list);
		if (opts->choose) print_error("no items to choose from");
		else if (opts->shuffle) print_error("no items to shuffle");
		else print_error("no items for weighted selection");
		return 1;
	}

	int status = RANDOMZ_OK;
	if (opts->choose) {
		int64_t index;
		status = rng_range(source, 1, (int64_t)list.count, &index);
		if (status == RANDOMZ_OK) puts(list.items[index - 1]);
	} else if (opts->shuffle) {
		for (size_t i = list.count; i > 1 && status == RANDOMZ_OK; --i) {
			int64_t index;
			status = rng_range(source, 1, (int64_t)i, &index);
			if (status == RANDOMZ_OK) {
				char *temporary = list.items[i - 1];
				list.items[i - 1] = list.items[index - 1];
				list.items[index - 1] = temporary;
			}
		}
		if (status == RANDOMZ_OK) for (size_t i = 0; i < list.count; ++i) puts(list.items[i]);
	} else {
		int64_t *weights = calloc(list.count, sizeof(*weights));
		int64_t total = 0;
		if (weights == NULL) status = RANDOMZ_BUFFER_TOO_SMALL;
		for (size_t i = 0; i < list.count && status == RANDOMZ_OK; ++i) {
			char *colon = strrchr(list.items[i], ':');
			if (colon == NULL || colon == list.items[i] || colon[1] == '\0') {
				fprintf(stderr, "Error: weighted item must be in format 'value:weight', got: %s\n", list.items[i]);
				status = RANDOMZ_INVALID_ARGUMENT;
				break;
			}
			for (char *p = colon + 1; *p != '\0'; ++p) if (!isdigit((unsigned char)*p)) {
				status = RANDOMZ_INVALID_ARGUMENT;
				break;
			}
			if (status != RANDOMZ_OK) {
				fprintf(stderr, "Error: weighted item must be in format 'value:weight', got: %s\n", list.items[i]);
				break;
			}
			if (parse_safe_int(colon + 1, &weights[i]) != RANDOMZ_OK) {
				fprintf(stderr, "Error: weighted item weight is out of range (must be a whole number no larger than 2^53): %s\n", list.items[i]);
				status = RANDOMZ_INVALID_ARGUMENT;
				break;
			}
			if (weights[i] > MAX_EXACT_INTEGER - total) {
				print_error("total weighted-item weight must be no larger than 2^53");
				status = RANDOMZ_INVALID_ARGUMENT;
				break;
			}
			total += weights[i];
			*colon = '\0';
		}
		if (status == RANDOMZ_OK && total == 0) {
			print_error("total weighted-item weight must be positive");
			status = RANDOMZ_INVALID_ARGUMENT;
		}
		if (status == RANDOMZ_OK) {
			int64_t pick;
			status = rng_range(source, 1, total, &pick);
			int64_t cumulative = 0;
			for (size_t i = 0; i < list.count && status == RANDOMZ_OK; ++i) {
				cumulative += weights[i];
				if (pick <= cumulative) { puts(list.items[i]); break; }
			}
		}
		free(weights);
	}
	free_items(&list);
	if (status == RANDOMZ_OK) {
		if (fflush(stdout) == EOF || ferror(stdout)) {
			print_error("stdout write failed");
			return 1;
		}
		return 0;
	}
	if (status == RANDOMZ_INVALID_ARGUMENT) return 1;
	return rng_failure(status);
}

static int format_fixed(randomz_fixed value, size_t places, char *buffer, size_t capacity)
{
	size_t written = 0;
	int status = randomz_fixed_format(value, places, buffer, capacity - 1, &written);
	if (status != RANDOMZ_OK) return status;
	buffer[written] = '\0';
	return RANDOMZ_OK;
}

static int value_byte(const generated_value *value, uint8_t *out)
{
	int64_t integer = value->integer;
	if (value->is_fixed) {
		int status = randomz_fixed_to_int_trunc(value->fixed, &integer);
		if (status != RANDOMZ_OK) return status;
	}
	int64_t reduced = integer % 256;
	if (reduced < 0) reduced += 256;
	*out = (uint8_t)reduced;
	return RANDOMZ_OK;
}

typedef int (*byte_producer)(void *context, uint8_t *out, size_t count);

typedef struct sampled_binary {
	const options *opts;
	rng_source *source;
	int64_t start;
	int64_t end;
} sampled_binary;

static int sampled_binary_fill(void *context, uint8_t *out, size_t count)
{
	sampled_binary *sampled = context;
	for (size_t i = 0; i < count; ++i) {
		generated_value value;
		int status = generate_value(sampled->opts, sampled->source,
			sampled->start, sampled->end, &value);
		if (status != RANDOMZ_OK) return status;
		status = value_byte(&value, &out[i]);
		if (status != RANDOMZ_OK) return status;
	}
	return RANDOMZ_OK;
}

static int direct_binary_fill(void *context, uint8_t *out, size_t count)
{
	rng_source *source = context;
	return source->fill(source->context, out, count) == 0 ? RANDOMZ_OK : RANDOMZ_ENTROPY_ERROR;
}

static const char base64_alphabet[] =
	"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static int emit_binary(byte_producer producer, void *context, uint64_t count,
	bool hex_output, bool base64_output)
{
	uint8_t *buffer = malloc(STREAM_CHUNK + 3);
	if (buffer == NULL) { print_error("could not allocate output buffer"); return 1; }
	uint64_t remaining = count;
	uint8_t carry[3];
	size_t carry_count = 0;
	int result = 0;
	while (remaining > 0) {
		size_t chunk = remaining > STREAM_CHUNK ? STREAM_CHUNK : (size_t)remaining;
		int status = producer(context, buffer, chunk);
		if (status != RANDOMZ_OK) { result = rng_failure(status); break; }
		remaining -= chunk;
		if (base64_output) {
			size_t i = 0;
			if (carry_count > 0) {
				while (carry_count < 3 && i < chunk) carry[carry_count++] = buffer[i++];
				if (carry_count == 3) {
					uint32_t word = ((uint32_t)carry[0] << 16) |
						((uint32_t)carry[1] << 8) | carry[2];
					putchar(base64_alphabet[(word >> 18) & 63]);
					putchar(base64_alphabet[(word >> 12) & 63]);
					putchar(base64_alphabet[(word >> 6) & 63]);
					putchar(base64_alphabet[word & 63]);
					carry_count = 0;
				}
			}
			for (; i + 3 <= chunk; i += 3) {
				uint32_t word = ((uint32_t)buffer[i] << 16) |
					((uint32_t)buffer[i + 1] << 8) | buffer[i + 2];
				putchar(base64_alphabet[(word >> 18) & 63]);
				putchar(base64_alphabet[(word >> 12) & 63]);
				putchar(base64_alphabet[(word >> 6) & 63]);
				putchar(base64_alphabet[word & 63]);
			}
			while (i < chunk) carry[carry_count++] = buffer[i++];
		} else if (hex_output) {
			static const char hex[] = "0123456789abcdef";
			for (size_t i = 0; i < chunk; ++i) {
				putchar(hex[buffer[i] >> 4]);
				putchar(hex[buffer[i] & 15]);
			}
		} else if (fwrite(buffer, 1, chunk, stdout) != chunk) {
			print_error("stdout write failed");
			result = 1;
			break;
		}
	}
	if (result == 0 && base64_output) {
		if (carry_count == 1) {
			uint32_t word = (uint32_t)carry[0] << 16;
			putchar(base64_alphabet[(word >> 18) & 63]);
			putchar(base64_alphabet[(word >> 12) & 63]);
			putchar('='); putchar('=');
		} else if (carry_count == 2) {
			uint32_t word = ((uint32_t)carry[0] << 16) | ((uint32_t)carry[1] << 8);
			putchar(base64_alphabet[(word >> 18) & 63]);
			putchar(base64_alphabet[(word >> 12) & 63]);
			putchar(base64_alphabet[(word >> 6) & 63]);
			putchar('=');
		}
		putchar('\n');
	} else if (result == 0 && hex_output) {
		putchar('\n');
	}
	free(buffer);
	if (result == 0 && (fflush(stdout) == EOF || ferror(stdout))) {
		print_error("stdout write failed");
		result = 1;
	}
	return result;
}

static int emit_text(const options *opts, rng_source *source,
	int64_t start, int64_t end, uint64_t count)
{
	char formatted[RANDOMZ_FIXED_STRING_BYTES];
	for (uint64_t i = 0; i < count; ++i) {
		generated_value value;
		int status = generate_value(opts, source, start, end, &value);
		if (status != RANDOMZ_OK) return rng_failure(status);
		if (i > 0 && strcmp(opts->delimiter, "\n") != 0) fputs(opts->delimiter, stdout);
		if (opts->hex_output && !value.is_fixed) {
			printf("%" PRIx64, (uint64_t)value.integer);
		} else if (value.is_fixed) {
			status = format_fixed(value.fixed, 6, formatted, sizeof(formatted));
			if (status != RANDOMZ_OK) return rng_failure(status);
			fputs(formatted, stdout);
		} else {
			printf("%" PRId64, value.integer);
		}
		if (strcmp(opts->delimiter, "\n") == 0) putchar('\n');
	}
	if (strcmp(opts->delimiter, "\n") != 0) putchar('\n');
	if (fflush(stdout) == EOF || ferror(stdout)) {
		print_error("stdout write failed");
		return 1;
	}
	return 0;
}

static int print_seed(const uint8_t seed[32])
{
	static const char hex[] = "0123456789abcdef";
	fputs("(seed: 0x", stderr);
	for (size_t i = 0; i < 32; ++i) {
		fputc(hex[seed[i] >> 4], stderr);
		fputc(hex[seed[i] & 15], stderr);
	}
	fputs(")\n", stderr);
	if (fflush(stderr) == EOF || ferror(stderr)) return 1;
	return 0;
}

static randomz_distribution public_distribution(distribution dist)
{
	switch (dist) {
	case DIST_NORMAL: return RANDOMZ_DISTRIBUTION_NORMAL;
	case DIST_EXPONENTIAL: return RANDOMZ_DISTRIBUTION_EXPONENTIAL;
	case DIST_POISSON: return RANDOMZ_DISTRIBUTION_POISSON;
	case DIST_LOG_NORMAL: return RANDOMZ_DISTRIBUTION_LOG_NORMAL;
	case DIST_BETA: return RANDOMZ_DISTRIBUTION_BETA;
	case DIST_UNIFORM:
	default: return 0;
	}
}

static int print_distribution_view(int argc, char **argv, const options *opts)
{
	chart_renderer renderer = CHART_UTF8;
	if (!chart_renderer_for_help(argc, argv, &renderer)) return 1;
	randomz_fixed zero = fixed_integer(0);
	randomz_fixed one = fixed_integer(1);
	randomz_fixed two = fixed_integer(2);
	randomz_fixed first = zero;
	randomz_fixed second = zero;
	const char *title = NULL;
	const char *axis = NULL;
	switch (opts->dist) {
	case DIST_NORMAL:
		title = "Normal (Gaussian)";
		first = opts->mean_set ? opts->mean : zero;
		second = opts->stddev_set ? opts->stddev : one;
		axis = "Horizontal axis: mean +/- 4 standard deviations; vertical axis: relative probability density.";
		break;
	case DIST_EXPONENTIAL:
		title = "Exponential";
		first = opts->rate_set ? opts->rate : one;
		axis = "Horizontal axis: 0 to 6/rate; vertical axis: relative probability density.";
		break;
	case DIST_POISSON:
		title = "Poisson";
		first = opts->lambda_set ? opts->lambda :
			(opts->mean_set ? opts->mean : one);
		axis = "Horizontal axis: lambda +/- 6*sqrt(lambda), clipped at zero; vertical axis: probability mass.";
		break;
	case DIST_LOG_NORMAL:
		title = "Log-normal";
		first = opts->mean_set ? opts->mean : zero;
		second = opts->stddev_set ? opts->stddev : one;
		axis = "Horizontal axis: 0 to exp(mean + min(1.625*stddev, 20)); vertical axis: relative probability density.";
		break;
	case DIST_BETA:
		title = "Beta";
		first = opts->alpha_set ? opts->alpha : two;
		second = opts->beta_set ? opts->beta : two;
		axis = "Horizontal axis: value from 0 to 1; vertical axis: relative probability density.";
		break;
	case DIST_UNIFORM:
	default:
		print_error("--view requires exactly one alternate distribution");
		return 1;
	}

	printf("Distribution: %s\n", title);
	if (opts->dist == DIST_NORMAL || opts->dist == DIST_LOG_NORMAL) {
		printf("Parameters: mean=%s, stddev=%s.\n",
			opts->mean_text != NULL ? opts->mean_text : "0",
			opts->stddev_text != NULL ? opts->stddev_text : "1");
	} else if (opts->dist == DIST_EXPONENTIAL) {
		printf("Parameters: rate=%s.\n",
			opts->rate_text != NULL ? opts->rate_text : "1");
	} else if (opts->dist == DIST_POISSON) {
		const char *lambda_text = opts->lambda_text != NULL ? opts->lambda_text :
			(opts->mean_text != NULL ? opts->mean_text : "1");
		printf("Parameters: lambda=%s.\n", lambda_text);
	} else {
		printf("Parameters: alpha=%s, beta=%s.\n",
			opts->alpha_text != NULL ? opts->alpha_text : "2",
			opts->beta_text != NULL ? opts->beta_text : "2");
	}
	putchar('\n');
	distribution_view_output output = renderer == CHART_KITTY ? DISTRIBUTION_VIEW_KITTY :
		(renderer == CHART_SIXEL ? DISTRIBUTION_VIEW_SIXEL : DISTRIBUTION_VIEW_UTF8);
	int status = distribution_view_render(public_distribution(opts->dist),
		first, second, output);
	if (status != RANDOMZ_OK) {
		if (status < 0) print_error("could not render distribution chart");
		else fprintf(stderr, "Error: supplied distribution parameters cannot be charted (status %d)\n",
			status);
		return 1;
	}
	puts(axis);
	if (fflush(stdout) == EOF || ferror(stdout)) {
		print_error("stdout write failed");
		return 1;
	}
	return 0;
}

int main(int argc, char **argv)
{
#if defined(_WIN32)
	/* The Microsoft CRT otherwise rewrites LF bytes on stdout and treats
	 * stdin as text, corrupting the cross-platform-identical byte contract. */
	if (_setmode(_fileno(stdout), _O_BINARY) == -1 ||
		_setmode(_fileno(stdin), _O_BINARY) == -1) {
		print_error("could not put standard streams in binary mode");
		return 1;
	}
#endif
#if defined(RANDOMZ_DEBUG_BUILD)
	if (getenv("MUTE_DEBUG_STATUS") == NULL) {
		fputs("\033[33mrandomz: DEBUG build (use -Doptimize=ReleaseFast for shipped output)\033[0m\n", stderr);
	}
#endif
	program_path = argc > 0 ? argv[0] : "randomz";
	program_name = base_name(program_path);
	options opts;
	if (parse_arguments(argc, argv, &opts) != 0) return 1;
	if (opts.view) return print_distribution_view(argc, argv, &opts);

	entropy_source entropy = {0};
	randomz_drbg drbg;
	rng_source source;
	active_entropy = NULL;

	if (opts.deterministic) {
		uint8_t seed[32];
		if (opts.seed_set) {
			memcpy(seed, opts.seed, 32);
		} else {
			const char *env_seed = getenv("DRANDOMZ_SEED");
			if (env_seed != NULL && *env_seed != '\0') {
				if (!parse_seed(env_seed, seed)) {
					fprintf(stderr, "Error: DRANDOMZ_SEED must be an unsigned decimal or "
						"0x-prefixed hexadecimal integer smaller than 2^256, got: %s\n", env_seed);
					return 1;
				}
			} else {
				if (entropy_open(&entropy, opts.random_source, opts.no_wait) != 0) {
					fprintf(stderr, "Error: entropy %s\n", entropy.error);
					return 1;
				}
				active_entropy = &entropy;
				if (entropy_fill(&entropy, seed, 32) != 0) {
					fprintf(stderr, "Error: entropy %s\n", entropy.error);
					return 1;
				}
				if (print_seed(seed) != 0) {
					print_error("could not write the replay seed to stderr");
					return 1;
				}
			}
		}
		if (randomz_drbg_init(&drbg, seed) != RANDOMZ_OK) {
			print_error("could not initialize BLAKE3 DRBG");
			return 1;
		}
		source.fill = drbg_fill_callback;
		source.context = &drbg;
	} else {
		if (entropy_open(&entropy, opts.random_source, opts.no_wait) != 0) {
			fprintf(stderr, "Error: entropy %s\n", entropy.error);
			return 1;
		}
		active_entropy = &entropy;
		source.fill = entropy_rng_fill;
		source.context = &entropy;
	}

	if (opts.choose || opts.shuffle || opts.weighted) {
		return handle_stdin_operation(&opts, &source);
	}

	int64_t start;
	int64_t end;
	uint64_t count;
	bool show_defaults = false;
	if (opts.binary_output) {
		start = opts.start_set ? opts.start : 0;
		end = opts.end_set ? opts.end : 255;
		count = opts.count_set ? (uint64_t)opts.count : 1024;
		if (start < 0) { print_error("start value must be >= 0 for binary output"); return 1; }
		if (end > 255) { print_error("end value must be <= 255 for binary output"); return 1; }
	} else {
		bool range_scaled = (opts.dist == DIST_UNIFORM || opts.dist == DIST_NORMAL) &&
			!(opts.dist == DIST_NORMAL && (opts.mean_set || opts.stddev_set));
		if (!opts.start_set && !opts.end_set && range_scaled) {
			show_defaults = true;
		}
		start = opts.start_set ? opts.start : 0;
		end = opts.end_set ? opts.end : 99;
		count = opts.count_set ? (uint64_t)opts.count : 1;
	}

	if (opts.dist == DIST_UNIFORM || opts.dist == DIST_NORMAL) {
		if (start > end) { print_error("start value must be less than or equal to end value"); return 1; }
		uint64_t span = (uint64_t)end - (uint64_t)start;
		if (span >= UINT64_C(9007199254740992)) {
			print_error("an inclusive integer range may contain at most 2^53 values");
			return 1;
		}
	}
	if (show_defaults && !opts.binary_output) {
		fputs("(with the default range 0..99)\n", stderr);
	}

	int result;
	if (opts.binary_output) {
		bool direct = opts.dist == DIST_UNIFORM && start == 0 && end == 255;
		if (direct) {
			result = emit_binary(direct_binary_fill, &source, count,
				opts.hex_output, opts.base64_output);
		} else {
			sampled_binary sampled = {&opts, &source, start, end};
			result = emit_binary(sampled_binary_fill, &sampled, count,
				opts.hex_output, opts.base64_output);
		}
	} else {
		result = emit_text(&opts, &source, start, end, count);
	}
	if (entropy.file != NULL) fclose(entropy.file);
	return result;
}
