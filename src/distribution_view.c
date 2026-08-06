#include "distribution_view.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VIEW_WIDTH 336
#define VIEW_HEIGHT 144
/* Lua's canvas is one-indexed; these are the equivalent zero-indexed pixels. */
#define VIEW_LEFT 17
#define VIEW_RIGHT (VIEW_WIDTH - 10)
#define VIEW_TOP 7
#define VIEW_BOTTOM (VIEW_HEIGHT - 19)
#define BRAILLE_WIDTH 96
#define BRAILLE_HEIGHT 32
#define MAX_HEIGHT UINT16_MAX

typedef struct curve {
	uint16_t heights[VIEW_RIGHT - VIEW_LEFT + 1];
	size_t count;
	randomz_fixed x_min;
	randomz_fixed x_max;
	bool discrete;
} curve;

static const uint8_t palette[4][3] = {
	{12, 16, 24},
	{37, 50, 71},
	{28, 93, 103},
	{100, 213, 210},
};

static int make_curve(randomz_distribution distribution, randomz_fixed first,
	randomz_fixed second, uint16_t *heights, size_t capacity, size_t *count,
	bool *discrete)
{
	randomz_fixed x_min;
	randomz_fixed x_max;
	int status = randomz_distribution_curve(distribution, first, second,
		heights, capacity, count, &x_min, &x_max);
	if (status != RANDOMZ_OK) return status;
	*discrete = false;
	if (distribution == RANDOMZ_DISTRIBUTION_POISSON) {
		int64_t minimum;
		int64_t maximum;
		if (randomz_fixed_to_int_trunc(x_min, &minimum) != RANDOMZ_OK ||
			randomz_fixed_to_int_trunc(x_max, &maximum) != RANDOMZ_OK) {
			return RANDOMZ_NUMERIC_ERROR;
		}
		*discrete = maximum - minimum + 1 <= (int64_t)capacity;
	}
	return RANDOMZ_OK;
}

static size_t canvas_index(size_t x, size_t y, size_t width)
{
	return y * width + x;
}

static void set_pixel(uint8_t *canvas, size_t width, size_t height,
	int x, int y, uint8_t color)
{
	if (x >= 0 && y >= 0 && (size_t)x < width && (size_t)y < height) {
		canvas[canvas_index((size_t)x, (size_t)y, width)] = color;
	}
}

static void draw_line(uint8_t *canvas, size_t width, size_t height,
	int x0, int y0, int x1, int y1, uint8_t color)
{
	int dx = abs(x1 - x0);
	int sx = x0 < x1 ? 1 : -1;
	int dy = -abs(y1 - y0);
	int sy = y0 < y1 ? 1 : -1;
	int error = dx + dy;
	for (;;) {
		set_pixel(canvas, width, height, x0, y0, color);
		if (x0 == x1 && y0 == y1) break;
		int twice = 2 * error;
		if (twice >= dy) { error += dy; x0 += sx; }
		if (twice <= dx) { error += dx; y0 += sy; }
	}
}

static int map_x(size_t index, size_t count, int left, int right)
{
	uint64_t denominator = count - 1;
	uint64_t numerator = (uint64_t)index * (uint64_t)(right - left) + denominator / 2;
	return left + (int)(numerator / denominator);
}

static int map_y(uint16_t value, int top, int bottom)
{
	uint64_t numerator = (uint64_t)value * (uint64_t)(bottom - top) + MAX_HEIGHT / 2;
	return bottom - (int)(numerator / MAX_HEIGHT);
}

static int make_canvas(randomz_distribution distribution, randomz_fixed first,
	randomz_fixed second, uint8_t **out)
{
	uint8_t *canvas = calloc(VIEW_WIDTH * VIEW_HEIGHT, 1);
	if (canvas == NULL) return -1;
	for (int division = 1; division <= 3; ++division) {
		int y = VIEW_TOP + ((VIEW_BOTTOM - VIEW_TOP) * division + 2) / 4;
		draw_line(canvas, VIEW_WIDTH, VIEW_HEIGHT,
			VIEW_LEFT, y, VIEW_RIGHT, y, 1);
	}
	for (int division = 1; division <= 5; ++division) {
		int x = VIEW_LEFT + ((VIEW_RIGHT - VIEW_LEFT) * division + 3) / 6;
		draw_line(canvas, VIEW_WIDTH, VIEW_HEIGHT,
			x, VIEW_TOP, x, VIEW_BOTTOM, 1);
	}
	draw_line(canvas, VIEW_WIDTH, VIEW_HEIGHT,
		VIEW_LEFT, VIEW_TOP, VIEW_LEFT, VIEW_BOTTOM, 3);
	draw_line(canvas, VIEW_WIDTH, VIEW_HEIGHT,
		VIEW_LEFT, VIEW_BOTTOM, VIEW_RIGHT, VIEW_BOTTOM, 3);

	curve sampled;
	int status = make_curve(distribution, first, second, sampled.heights,
		sizeof(sampled.heights) / sizeof(sampled.heights[0]),
		&sampled.count, &sampled.discrete);
	if (status != RANDOMZ_OK) { free(canvas); return status; }
	if (sampled.discrete) {
		for (size_t i = 0; i < sampled.count; ++i) {
			int x = map_x(i, sampled.count, VIEW_LEFT, VIEW_RIGHT);
			int y = map_y(sampled.heights[i], VIEW_TOP, VIEW_BOTTOM);
			draw_line(canvas, VIEW_WIDTH, VIEW_HEIGHT,
				x, VIEW_BOTTOM - 1, x, y, 3);
			for (int oy = -2; oy <= 2; ++oy) {
				for (int ox = -2; ox <= 2; ++ox) {
					if (ox * ox + oy * oy <= 4) {
						set_pixel(canvas, VIEW_WIDTH, VIEW_HEIGHT, x + ox, y + oy, 3);
					}
				}
			}
		}
	} else {
		int previous_x = 0;
		int previous_y = 0;
		bool previous = false;
		for (size_t i = 0; i < sampled.count; ++i) {
			int x = map_x(i, sampled.count, VIEW_LEFT, VIEW_RIGHT);
			int y = map_y(sampled.heights[i], VIEW_TOP, VIEW_BOTTOM);
			for (int fill_y = y + 1; fill_y < VIEW_BOTTOM; ++fill_y) {
				set_pixel(canvas, VIEW_WIDTH, VIEW_HEIGHT, x, fill_y, 2);
			}
			if (previous) draw_line(canvas, VIEW_WIDTH, VIEW_HEIGHT,
				previous_x, previous_y, x, y, 3);
			previous_x = x;
			previous_y = y;
			previous = true;
		}
	}
	*out = canvas;
	return RANDOMZ_OK;
}

static char *canvas_base64(const uint8_t *canvas, size_t *length)
{
	static const char alphabet[] =
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	size_t raw_length = VIEW_WIDTH * VIEW_HEIGHT * 3;
	uint8_t *raw = malloc(raw_length);
	if (raw == NULL) return NULL;
	for (size_t i = 0; i < VIEW_WIDTH * VIEW_HEIGHT; ++i) {
		const uint8_t *rgb = palette[canvas[i]];
		raw[i * 3] = rgb[0];
		raw[i * 3 + 1] = rgb[1];
		raw[i * 3 + 2] = rgb[2];
	}
	size_t encoded_length = ((raw_length + 2) / 3) * 4;
	char *encoded = malloc(encoded_length + 1);
	if (encoded == NULL) { free(raw); return NULL; }
	size_t target = 0;
	for (size_t i = 0; i < raw_length; i += 3) {
		uint32_t a = raw[i];
		uint32_t b = i + 1 < raw_length ? raw[i + 1] : 0;
		uint32_t c = i + 2 < raw_length ? raw[i + 2] : 0;
		uint32_t value = (a << 16) | (b << 8) | c;
		encoded[target++] = alphabet[(value >> 18) & 63];
		encoded[target++] = alphabet[(value >> 12) & 63];
		encoded[target++] = i + 1 < raw_length ? alphabet[(value >> 6) & 63] : '=';
		encoded[target++] = i + 2 < raw_length ? alphabet[value & 63] : '=';
	}
	encoded[target] = '\0';
	free(raw);
	*length = target;
	return encoded;
}

static void write_kitty_sequence(const char *control, const char *payload,
	size_t length, bool tmux)
{
	if (tmux) fputs("\033Ptmux;\033\033_G", stdout);
	else fputs("\033_G", stdout);
	fputs(control, stdout);
	fputc(';', stdout);
	(void)fwrite(payload, 1, length, stdout);
	if (tmux) fputs("\033\033\\\033\\", stdout);
	else fputs("\033\\", stdout);
}

static int render_kitty(const uint8_t *canvas)
{
	size_t length = 0;
	char *encoded = canvas_base64(canvas, &length);
	if (encoded == NULL) return -1;
	bool tmux = getenv("TMUX") != NULL && *getenv("TMUX") != '\0';
	for (size_t offset = 0; offset < length; offset += 4096) {
		size_t count = length - offset > 4096 ? 4096 : length - offset;
		bool final = offset + count == length;
		char control[96];
		if (offset == 0) {
			(void)snprintf(control, sizeof(control),
				"a=T,f=24,s=%d,v=%d,c=56,r=12,C=1,q=2,m=%d",
				VIEW_WIDTH, VIEW_HEIGHT, final ? 0 : 1);
		} else {
			(void)snprintf(control, sizeof(control), "m=%d", final ? 0 : 1);
		}
		write_kitty_sequence(control, encoded + offset, count, tmux);
	}
	free(encoded);
	for (int row = 0; row < 12; ++row) fputs("\r\n", stdout);
	return ferror(stdout) ? -1 : RANDOMZ_OK;
}

static void write_sixel_run(unsigned mask, size_t count)
{
	int pixel = 63 + (int)mask;
	if (count >= 4) fprintf(stdout, "!%zu%c", count, pixel);
	else for (size_t i = 0; i < count; ++i) fputc(pixel, stdout);
}

static int render_sixel(const uint8_t *canvas)
{
	fputs("\033" "7\033P0;1;0q\"1;1;336;144", stdout);
	for (size_t color = 0; color < 4; ++color) {
		int red = (palette[color][0] * 100 + 127) / 255;
		int green = (palette[color][1] * 100 + 127) / 255;
		int blue = (palette[color][2] * 100 + 127) / 255;
		fprintf(stdout, "#%zu;2;%d;%d;%d", color, red, green, blue);
	}
	for (size_t band_y = 0; band_y < VIEW_HEIGHT; band_y += 6) {
		for (uint8_t color = 0; color < 4; ++color) {
			fprintf(stdout, "#%u", color);
			unsigned previous = 0;
			size_t run_length = 0;
			for (size_t x = 0; x < VIEW_WIDTH; ++x) {
				unsigned mask = 0;
				for (unsigned bit = 0; bit < 6; ++bit) {
					size_t y = band_y + bit;
					if (y < VIEW_HEIGHT && canvas[canvas_index(x, y, VIEW_WIDTH)] == color) {
						mask |= 1U << bit;
					}
				}
				if (run_length == 0) { previous = mask; run_length = 1; }
				else if (mask == previous) run_length++;
				else {
					write_sixel_run(previous, run_length);
					previous = mask;
					run_length = 1;
				}
			}
			write_sixel_run(previous, run_length);
			if (color < 3) fputc('$', stdout);
			else if (band_y + 6 < VIEW_HEIGHT) fputc('-', stdout);
		}
	}
	fputs("\033\\\033" "8", stdout);
	for (int row = 0; row < 12; ++row) fputs("\r\n", stdout);
	return ferror(stdout) ? -1 : RANDOMZ_OK;
}

static void write_utf8(uint32_t codepoint)
{
	if (codepoint < 0x80) {
		fputc((int)codepoint, stdout);
	} else if (codepoint < 0x800) {
		fputc((int)(0xc0 | (codepoint >> 6)), stdout);
		fputc((int)(0x80 | (codepoint & 0x3f)), stdout);
	} else {
		fputc((int)(0xe0 | (codepoint >> 12)), stdout);
		fputc((int)(0x80 | ((codepoint >> 6) & 0x3f)), stdout);
		fputc((int)(0x80 | (codepoint & 0x3f)), stdout);
	}
}

static int render_braille(randomz_distribution distribution,
	randomz_fixed first, randomz_fixed second)
{
	uint8_t dots[BRAILLE_WIDTH * BRAILLE_HEIGHT] = {0};
	draw_line(dots, BRAILLE_WIDTH, BRAILLE_HEIGHT,
		0, 0, 0, BRAILLE_HEIGHT - 1, 1);
	draw_line(dots, BRAILLE_WIDTH, BRAILLE_HEIGHT,
		0, BRAILLE_HEIGHT - 1, BRAILLE_WIDTH - 1, BRAILLE_HEIGHT - 1, 1);
	uint16_t heights[BRAILLE_WIDTH];
	size_t count = 0;
	bool discrete = false;
	int status = make_curve(distribution, first, second, heights,
		BRAILLE_WIDTH, &count, &discrete);
	if (status != RANDOMZ_OK) return status;
	if (discrete) {
		for (size_t i = 0; i < count; ++i) {
			int x = map_x(i, count, 0, BRAILLE_WIDTH - 1);
			int y = map_y(heights[i], 0, BRAILLE_HEIGHT - 1);
			draw_line(dots, BRAILLE_WIDTH, BRAILLE_HEIGHT,
				x, BRAILLE_HEIGHT - 2, x, y, 1);
		}
	} else {
		int previous_x = 0;
		int previous_y = 0;
		bool previous = false;
		for (size_t i = 0; i < count; ++i) {
			int x = map_x(i, count, 0, BRAILLE_WIDTH - 1);
			int y = map_y(heights[i], 0, BRAILLE_HEIGHT - 1);
			if (previous) draw_line(dots, BRAILLE_WIDTH, BRAILLE_HEIGHT,
				previous_x, previous_y, x, y, 1);
			previous_x = x;
			previous_y = y;
			previous = true;
		}
	}
	static const unsigned masks[2][4] = {
		{1, 2, 4, 64},
		{8, 16, 32, 128},
	};
	for (size_t cell_y = 0; cell_y < BRAILLE_HEIGHT / 4; ++cell_y) {
		for (size_t cell_x = 0; cell_x < BRAILLE_WIDTH / 2; ++cell_x) {
			unsigned mask = 0;
			for (size_t dx = 0; dx < 2; ++dx) {
				for (size_t dy = 0; dy < 4; ++dy) {
					size_t x = cell_x * 2 + dx;
					size_t y = cell_y * 4 + dy;
					if (dots[canvas_index(x, y, BRAILLE_WIDTH)] != 0) mask += masks[dx][dy];
				}
			}
			write_utf8(0x2800 + mask);
		}
		fputc('\n', stdout);
	}
	return ferror(stdout) ? -1 : RANDOMZ_OK;
}

int distribution_view_render(randomz_distribution distribution,
	randomz_fixed first, randomz_fixed second, distribution_view_output output)
{
	if (output == DISTRIBUTION_VIEW_UTF8) {
		return render_braille(distribution, first, second);
	}
	uint8_t *canvas = NULL;
	int status = make_canvas(distribution, first, second, &canvas);
	if (status != RANDOMZ_OK) return status;
	status = output == DISTRIBUTION_VIEW_KITTY ? render_kitty(canvas) : render_sixel(canvas);
	free(canvas);
	return status;
}
