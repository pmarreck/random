#!/usr/bin/env luajit

-- Generate the embedded chart tables consumed by all four CLIs.
-- The plots are documentation, not RNG output, so host floating point is fine;
-- keeping one generator is what makes all four frontends byte-identical.

local bit = require("bit")

local script = (arg and arg[0]) or "tools/generate_distribution_charts.lua"
local tools_dir = script:match("^(.*)/[^/]+$") or "."
local root = tools_dir .. "/.."

local WIDTH, HEIGHT = 336, 144
local LEFT, RIGHT, TOP, BOTTOM = 18, WIDTH - 9, 8, HEIGHT - 18
local BRAILLE_WIDTH, BRAILLE_HEIGHT = 96, 32

local charts = {
	{
		key = "normal",
		title = "Normal (Gaussian)",
		parameters = "Reference shape: mu=0, sigma=1; integer output is rescaled to [start,end].",
		axis = "Horizontal axis: value; vertical axis: relative probability density.",
		xmin = -4, xmax = 4,
		value = function(x) return math.exp(-0.5 * x * x) end,
	},
	{
		key = "exponential",
		title = "Exponential",
		parameters = "Default shape: rate=1; --rate reshapes the horizontal scale.",
		axis = "Horizontal axis: value; vertical axis: relative probability density.",
		xmin = 0, xmax = 6,
		value = function(x) return math.exp(-x) end,
	},
	{
		key = "poisson",
		title = "Poisson",
		parameters = "Default shape: lambda=1; --lambda or --mean sets lambda.",
		axis = "Horizontal axis: integer value; vertical axis: probability mass.",
		xmin = 0, xmax = 8,
		discrete = true,
	},
	{
		key = "log_normal",
		title = "Log-normal",
		parameters = "Default shape: mu=0, sigma=1 in log space.",
		axis = "Horizontal axis: value; vertical axis: relative probability density.",
		xmin = 0, xmax = 5,
		value = function(x)
			if x <= 0 then return 0 end
			local lx = math.log(x)
			return math.exp(-0.5 * lx * lx) / x
		end,
	},
	{
		key = "beta",
		title = "Beta",
		parameters = "Default shape: alpha=2, beta=2; --alpha and --beta[=B] reshape it.",
		axis = "Horizontal axis: value from 0 to 1; vertical axis: relative probability density.",
		xmin = 0, xmax = 1,
		value = function(x) return 6 * x * (1 - x) end,
	},
}

local function u32be(value)
	return string.char(
		bit.band(bit.rshift(value, 24), 0xff),
		bit.band(bit.rshift(value, 16), 0xff),
		bit.band(bit.rshift(value, 8), 0xff),
		bit.band(value, 0xff))
end

local function crc32(data)
	local crc = bit.tobit(0xffffffff)
	for i = 1, #data do
		crc = bit.bxor(crc, data:byte(i))
		for _ = 1, 8 do
			if bit.band(crc, 1) ~= 0 then
				crc = bit.bxor(bit.rshift(crc, 1), 0xedb88320)
			else
				crc = bit.rshift(crc, 1)
			end
		end
	end
	return bit.bnot(crc)
end

local function adler32(data)
	local a, b = 1, 0
	for i = 1, #data do
		a = (a + data:byte(i)) % 65521
		b = (b + a) % 65521
	end
	return b * 65536 + a
end

local function png_chunk(kind, data)
	return u32be(#data) .. kind .. data .. u32be(crc32(kind .. data))
end

local function zlib_store(data)
	local out = { string.char(0x78, 0x01) }
	local offset = 1
	while offset <= #data do
		local count = math.min(65535, #data - offset + 1)
		local final = offset + count - 1 == #data and 1 or 0
		local complement = 0xffff - count
		out[#out + 1] = string.char(final, bit.band(count, 0xff),
			bit.rshift(count, 8), bit.band(complement, 0xff),
			bit.rshift(complement, 8))
		out[#out + 1] = data:sub(offset, offset + count - 1)
		offset = offset + count
	end
	out[#out + 1] = u32be(adler32(data))
	return table.concat(out)
end

local function new_canvas(width, height)
	local canvas = {}
	for y = 1, height do
		local row = {}
		for x = 1, width do row[x] = 0 end
		canvas[y] = row
	end
	return canvas
end

local function line(canvas, x0, y0, x1, y1, color)
	x0, y0, x1, y1 = math.floor(x0 + 0.5), math.floor(y0 + 0.5),
		math.floor(x1 + 0.5), math.floor(y1 + 0.5)
	local dx, sx = math.abs(x1 - x0), x0 < x1 and 1 or -1
	local dy, sy = -math.abs(y1 - y0), y0 < y1 and 1 or -1
	local err = dx + dy
	while true do
		if canvas[y0] and canvas[y0][x0] then canvas[y0][x0] = color end
		if x0 == x1 and y0 == y1 then break end
		local twice = 2 * err
		if twice >= dy then err = err + dy; x0 = x0 + sx end
		if twice <= dx then err = err + dx; y0 = y0 + sy end
	end
end

local function samples(chart, count)
	local points = {}
	if chart.discrete then
		local probability = math.exp(-1)
		for k = 0, 8 do
			points[#points + 1] = { x = k, y = probability }
			probability = probability / (k + 1)
		end
	else
		for i = 0, count - 1 do
			local fraction = i / (count - 1)
			local x = chart.xmin + (chart.xmax - chart.xmin) * fraction
			points[#points + 1] = { x = x, y = chart.value(x) }
		end
	end
	local ymax = 0
	for _, point in ipairs(points) do ymax = math.max(ymax, point.y) end
	return points, ymax * 1.08
end

local function map_point(chart, point, ymax, left, right, top, bottom)
	local x = left + (point.x - chart.xmin) / (chart.xmax - chart.xmin) * (right - left)
	local y = bottom - point.y / ymax * (bottom - top)
	return x, y
end

local function make_canvas(chart)
	local canvas = new_canvas(WIDTH, HEIGHT)
	for division = 1, 3 do
		local y = TOP + (BOTTOM - TOP) * division / 4
		line(canvas, LEFT, y, RIGHT, y, 1)
	end
	for division = 1, 5 do
		local x = LEFT + (RIGHT - LEFT) * division / 6
		line(canvas, x, TOP, x, BOTTOM, 1)
	end
	line(canvas, LEFT, TOP, LEFT, BOTTOM, 3)
	line(canvas, LEFT, BOTTOM, RIGHT, BOTTOM, 3)

	local points, ymax = samples(chart, RIGHT - LEFT + 1)
	if chart.discrete then
		for _, point in ipairs(points) do
			local x, y = map_point(chart, point, ymax, LEFT, RIGHT, TOP, BOTTOM)
			line(canvas, x, BOTTOM - 1, x, y, 3)
			for oy = -2, 2 do
				for ox = -2, 2 do
					if ox * ox + oy * oy <= 4 and canvas[math.floor(y + oy)] then
						canvas[math.floor(y + oy)][math.floor(x + ox)] = 3
					end
				end
			end
		end
	else
		local previous_x, previous_y
		for _, point in ipairs(points) do
			local x, y = map_point(chart, point, ymax, LEFT, RIGHT, TOP, BOTTOM)
			local xi, yi = math.floor(x + 0.5), math.floor(y + 0.5)
			for fill_y = yi + 1, BOTTOM - 1 do canvas[fill_y][xi] = 2 end
			if previous_x then line(canvas, previous_x, previous_y, x, y, 3) end
			previous_x, previous_y = x, y
		end
	end

	return canvas
end

local function make_png(canvas)
	local scanlines = {}
	for y = 1, HEIGHT do
		local packed = { string.char(0) }
		for x = 1, WIDTH, 4 do
			local byte = canvas[y][x] * 64 + canvas[y][x + 1] * 16 +
				canvas[y][x + 2] * 4 + canvas[y][x + 3]
			packed[#packed + 1] = string.char(byte)
		end
		scanlines[#scanlines + 1] = table.concat(packed)
	end
	local signature = "\137PNG\r\n\26\n"
	local ihdr = u32be(WIDTH) .. u32be(HEIGHT) .. string.char(2, 3, 0, 0, 0)
	local palette = string.char(
		12, 16, 24,
		37, 50, 71,
		28, 93, 103,
		100, 213, 210)
	return signature .. png_chunk("IHDR", ihdr) .. png_chunk("PLTE", palette) ..
		png_chunk("IDAT", zlib_store(table.concat(scanlines))) .. png_chunk("IEND", "")
end

local function sixel_run(mask, count)
	local pixel = string.char(63 + mask)
	if count >= 4 then return "!" .. count .. pixel end
	return pixel:rep(count)
end

-- Encode the same four-colour canvas directly as SIXEL. The DCS framing is
-- deliberately added by each frontend so the generated table remains plain
-- ASCII and the renderer can save/restore the cursor around it. Every colour
-- paints a complete six-pixel band; unset bits are transparent, while colour
-- zero explicitly supplies the chart background.
local function make_sixel(canvas)
	local palette = {
		{ 12, 16, 24 },
		{ 37, 50, 71 },
		{ 28, 93, 103 },
		{ 100, 213, 210 },
	}
	local out = { ('"1;1;%d;%d'):format(WIDTH, HEIGHT) }
	for index, rgb in ipairs(palette) do
		local function percent(value) return math.floor(value * 100 / 255 + 0.5) end
		out[#out + 1] = ("#%d;2;%d;%d;%d"):format(index - 1,
			percent(rgb[1]), percent(rgb[2]), percent(rgb[3]))
	end
	for band_y = 1, HEIGHT, 6 do
		for color = 0, #palette - 1 do
			out[#out + 1] = "#" .. color
			local previous, run_length
			for x = 1, WIDTH do
				local mask = 0
				for bit_index = 0, 5 do
					local row = canvas[band_y + bit_index]
					if row and row[x] == color then mask = mask + 2 ^ bit_index end
				end
				if previous == nil then
					previous, run_length = mask, 1
				elseif mask == previous then
					run_length = run_length + 1
				else
					out[#out + 1] = sixel_run(previous, run_length)
					previous, run_length = mask, 1
				end
			end
			out[#out + 1] = sixel_run(previous, run_length)
			out[#out + 1] = color == #palette - 1 and
				(band_y + 5 < HEIGHT and "-" or "") or "$"
		end
	end
	return table.concat(out)
end

local base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		b, c = b or 0, c or 0
		local value = a * 65536 + b * 256 + c
		out[#out + 1] = base64_alphabet:sub(math.floor(value / 262144) % 64 + 1,
			math.floor(value / 262144) % 64 + 1)
		out[#out + 1] = base64_alphabet:sub(math.floor(value / 4096) % 64 + 1,
			math.floor(value / 4096) % 64 + 1)
		out[#out + 1] = i + 1 <= #data and base64_alphabet:sub(math.floor(value / 64) % 64 + 1,
			math.floor(value / 64) % 64 + 1) or "="
		out[#out + 1] = i + 2 <= #data and base64_alphabet:sub(value % 64 + 1,
			value % 64 + 1) or "="
	end
	return table.concat(out)
end

local function utf8_char(codepoint)
	if codepoint < 0x80 then return string.char(codepoint) end
	if codepoint < 0x800 then
		return string.char(0xc0 + math.floor(codepoint / 64), 0x80 + codepoint % 64)
	end
	return string.char(0xe0 + math.floor(codepoint / 4096),
		0x80 + math.floor(codepoint / 64) % 64, 0x80 + codepoint % 64)
end

local function make_braille(chart)
	local dots = new_canvas(BRAILLE_WIDTH, BRAILLE_HEIGHT)
	local points, ymax = samples(chart, BRAILLE_WIDTH)
	local function mark_line(x0, y0, x1, y1)
		line(dots, x0, y0, x1, y1, 1)
	end
	mark_line(1, 1, 1, BRAILLE_HEIGHT)
	mark_line(1, BRAILLE_HEIGHT, BRAILLE_WIDTH, BRAILLE_HEIGHT)
	if chart.discrete then
		for _, point in ipairs(points) do
			local x, y = map_point(chart, point, ymax, 1, BRAILLE_WIDTH, 1, BRAILLE_HEIGHT)
			mark_line(x, BRAILLE_HEIGHT - 1, x, y)
		end
	else
		local previous_x, previous_y
		for _, point in ipairs(points) do
			local x, y = map_point(chart, point, ymax, 1, BRAILLE_WIDTH, 1, BRAILLE_HEIGHT)
			if previous_x then mark_line(previous_x, previous_y, x, y) end
			previous_x, previous_y = x, y
		end
	end

	local dot_masks = {
		{ 1, 2, 4, 64 },
		{ 8, 16, 32, 128 },
	}
	local rows = {}
	for cell_y = 0, BRAILLE_HEIGHT / 4 - 1 do
		local row = {}
		for cell_x = 0, BRAILLE_WIDTH / 2 - 1 do
			local mask = 0
			for dx = 0, 1 do
				for dy = 0, 3 do
					if dots[cell_y * 4 + dy + 1][cell_x * 2 + dx + 1] ~= 0 then
						mask = mask + dot_masks[dx + 1][dy + 1]
					end
				end
			end
			row[#row + 1] = utf8_char(0x2800 + mask)
		end
		rows[#rows + 1] = table.concat(row)
	end
	return table.concat(rows, "\n") .. "\n"
end

local function lua_quote(value)
	return string.format("%q", value)
end

local function c_quote(value)
	value = value:gsub("\\", "\\\\"):gsub('"', '\\"')
	value = value:gsub("\r", "\\r"):gsub("\n", "\\n")
	return '"' .. value .. '"'
end

local function wrapped_literal(value, indent, quote)
	local lines = {}
	for offset = 1, #value, 96 do
		lines[#lines + 1] = indent .. quote(value:sub(offset, offset + 95))
	end
	return table.concat(lines, "\n")
end

for _, chart in ipairs(charts) do
	local canvas = make_canvas(chart)
	chart.png_base64 = base64(make_png(canvas))
	chart.sixel_data = make_sixel(canvas)
	chart.fallback = make_braille(chart)
end

local function lua_source()
	local out = {
		"-- Generated by tools/generate_distribution_charts.lua; do not edit.",
		"return {",
	}
	for _, chart in ipairs(charts) do
		out[#out + 1] = "\t[" .. lua_quote(chart.key) .. "] = {"
		out[#out + 1] = "\t\ttitle = " .. lua_quote(chart.title) .. ","
		out[#out + 1] = "\t\tparameters = " .. lua_quote(chart.parameters) .. ","
		out[#out + 1] = "\t\taxis = " .. lua_quote(chart.axis) .. ","
		out[#out + 1] = "\t\tpng_base64 ="
		local literal = wrapped_literal(chart.png_base64, "\t\t\t", lua_quote)
		literal = literal:gsub("\n", " ..\n", select(2, literal:gsub("\n", "")))
		out[#out + 1] = literal .. ","
		out[#out + 1] = "\t\tsixel_data ="
		local sixel_literal = wrapped_literal(chart.sixel_data, "\t\t\t", lua_quote)
		sixel_literal = sixel_literal:gsub("\n", " ..\n", select(2, sixel_literal:gsub("\n", "")))
		out[#out + 1] = sixel_literal .. ","
		out[#out + 1] = "\t\tfallback = " .. lua_quote(chart.fallback) .. ","
		out[#out + 1] = "\t},"
	end
	out[#out + 1] = "}"
	out[#out + 1] = ""
	return table.concat(out, "\n")
end

local function c_source()
	local out = {
		"/* Generated by tools/generate_distribution_charts.lua; do not edit. */",
		"typedef struct distribution_chart {",
		"\tdistribution dist;",
		"\tconst char *title;",
		"\tconst char *parameters;",
		"\tconst char *axis;",
		"\tconst char *png_base64;",
		"\tconst char *sixel_data;",
		"\tconst char *fallback;",
		"} distribution_chart;",
		"",
		"static const distribution_chart distribution_charts[] = {",
	}
	local enum_name = {
		normal = "DIST_NORMAL", exponential = "DIST_EXPONENTIAL",
		poisson = "DIST_POISSON", log_normal = "DIST_LOG_NORMAL", beta = "DIST_BETA",
	}
	for _, chart in ipairs(charts) do
		out[#out + 1] = "\t{"
		out[#out + 1] = "\t\t" .. enum_name[chart.key] .. ","
		out[#out + 1] = "\t\t" .. c_quote(chart.title) .. ","
		out[#out + 1] = "\t\t" .. c_quote(chart.parameters) .. ","
		out[#out + 1] = "\t\t" .. c_quote(chart.axis) .. ","
		out[#out + 1] = wrapped_literal(chart.png_base64, "\t\t", c_quote) .. ","
		out[#out + 1] = wrapped_literal(chart.sixel_data, "\t\t", c_quote) .. ","
		out[#out + 1] = "\t\t" .. c_quote(chart.fallback)
		out[#out + 1] = "\t},"
	end
	out[#out + 1] = "};"
	out[#out + 1] = ""
	return table.concat(out, "\n")
end

local function rust_concat(value, indent)
	local literals = wrapped_literal(value, indent .. "\t", c_quote)
	local lines = { "concat!(" }
	for literal in literals:gmatch("[^\n]+") do
		lines[#lines + 1] = literal .. ","
	end
	lines[#lines + 1] = indent .. ")"
	return table.concat(lines, "\n")
end

local function rust_source()
	local out = {
		"// Generated by tools/generate_distribution_charts.lua; do not edit.",
		"#[rustfmt::skip]",
		"pub static EMBEDDED_CHARTS: &[EmbeddedChart] = &[",
	}
	for _, chart in ipairs(charts) do
		out[#out + 1] = "\tEmbeddedChart {"
		out[#out + 1] = "\t\tkey: " .. c_quote(chart.key) .. ","
		out[#out + 1] = "\t\ttitle: " .. c_quote(chart.title) .. ","
		out[#out + 1] = "\t\tparameters: " .. c_quote(chart.parameters) .. ","
		out[#out + 1] = "\t\taxis: " .. c_quote(chart.axis) .. ","
		out[#out + 1] = "\t\tpng_base64: " .. rust_concat(chart.png_base64, "\t\t") .. ","
		out[#out + 1] = "\t\tsixel_data: " .. rust_concat(chart.sixel_data, "\t\t") .. ","
		out[#out + 1] = "\t\tfallback: " .. c_quote(chart.fallback) .. ","
		out[#out + 1] = "\t},"
	end
	out[#out + 1] = "];"
	out[#out + 1] = ""
	return table.concat(out, "\n")
end

local function lean_concat(value, indent)
	local literals = {}
	for offset = 1, #value, 96 do
		literals[#literals + 1] = indent .. c_quote(value:sub(offset, offset + 95))
	end
	return table.concat(literals, " ++\n")
end

local function lean_source()
	local out = {
		"-- Generated by tools/generate_distribution_charts.lua; do not edit.",
		"namespace Randoml.GeneratedCharts",
		"",
		"structure EmbeddedChart where",
		"  title : String",
		"  parameters : String",
		"  axis : String",
		"  pngBase64 : String",
		"  sixelData : String",
		"  fallback : String",
		"deriving BEq, Repr",
		"",
		"def get? (key : String) : Option EmbeddedChart :=",
		"  match key with",
	}
	for _, chart in ipairs(charts) do
		out[#out + 1] = "  | " .. c_quote(chart.key) .. " => some {"
		out[#out + 1] = "      title := " .. c_quote(chart.title)
		out[#out + 1] = "      parameters := " .. c_quote(chart.parameters)
		out[#out + 1] = "      axis := " .. c_quote(chart.axis)
		out[#out + 1] = "      pngBase64 :=\n" .. lean_concat(chart.png_base64, "        ")
		out[#out + 1] = "      sixelData :=\n" .. lean_concat(chart.sixel_data, "        ")
		out[#out + 1] = "      fallback := " .. c_quote(chart.fallback) .. " }"
	end
	out[#out + 1] = "  | _ => none"
	out[#out + 1] = ""
	out[#out + 1] = "end Randoml.GeneratedCharts"
	out[#out + 1] = ""
	return table.concat(out, "\n")
end

local outputs = {
	{ path = root .. "/lib/distribution_charts.lua", content = lua_source() },
	{ path = root .. "/src/distribution_charts.inc", content = c_source() },
	{ path = root .. "/rust/randomr-cli/src/generated_charts.rs", content = rust_source() },
	{ path = root .. "/lean/Randoml/GeneratedCharts.lean", content = lean_source() },
}

local checking = arg and arg[1] == "--check"
for _, output in ipairs(outputs) do
	if checking then
		local file = io.open(output.path, "rb")
		local existing = file and file:read("*a") or nil
		if file then file:close() end
		if existing ~= output.content then
			io.stderr:write(output.path .. " is stale; rerun " .. script .. "\n")
			os.exit(1)
		end
	else
		local file, err = io.open(output.path, "wb")
		if not file then error(err) end
		assert(file:write(output.content))
		assert(file:close())
	end
end
