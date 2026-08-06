-- Runtime distribution-curve rasterizer for `random --view`.
--
-- Curve math uses the same integer-only soft-float kernel as the samplers.
-- The Zig core independently implements this contract for the C CLI; exact
-- CLI differential tests make either implementation an oracle for the other.

local fx = require("fixed")

local M = {}

local WIDTH, HEIGHT = 336, 144
local LEFT, RIGHT, TOP, BOTTOM = 18, WIDTH - 9, 8, HEIGHT - 18
local BRAILLE_WIDTH, BRAILLE_HEIGHT = 96, 32
local MAX_HEIGHT = 65535

M.width, M.height = WIDTH, HEIGHT

local function fixed(value)
	local m, e = fx.from_int(value)
	return { m, e }
end

local ZERO, ONE, TWO = fixed(0), fixed(1), fixed(2)
local FOUR, SIX, EIGHT = fixed(4), fixed(6), fixed(8)
local THIRTEEN, TWENTY, NEGATIVE_SIXTY_FOUR =
	fixed(13), fixed(20), fixed(-64)
local MAX_HEIGHT_FIXED = fixed(MAX_HEIGHT)

local function mul(left, right)
	local m, e = fx.mul(left[1], left[2], right[1], right[2])
	return { m, e }
end

local function div(left, right)
	local m, e = fx.div(left[1], left[2], right[1], right[2])
	return { m, e }
end

local function add(left, right)
	local m, e = fx.add(left[1], left[2], right[1], right[2])
	return { m, e }
end

local function sub(left, right)
	local m, e = fx.sub(left[1], left[2], right[1], right[2])
	return { m, e }
end

local function neg(value)
	local m, e = fx.neg(value[1], value[2])
	return { m, e }
end

local function exp(value)
	local m, e = fx.exp(value[1], value[2])
	return { m, e }
end

local function ln(value)
	local m, e = fx.ln(value[1], value[2])
	return { m, e }
end

local function sqrt(value)
	local m, e = fx.sqrt(value[1], value[2])
	return { m, e }
end

local function cmp(left, right)
	return fx.cmp(left[1], left[2], right[1], right[2])
end

local function fraction(index, denominator)
	return div(fixed(index), fixed(denominator))
end

local function height(relative)
	if relative[1] <= 0 then return 0 end
	if cmp(relative, ONE) >= 0 then return MAX_HEIGHT end
	local value = fx.to_int_trunc(unpack(mul(relative, MAX_HEIGHT_FIXED)))
	if value <= 0 then return 0 end
	if value >= MAX_HEIGHT then return MAX_HEIGHT end
	return value
end

local function relative(score, maximum)
	local difference = sub(score, maximum)
	if difference[1] >= 0 then return ONE end
	if cmp(difference, NEGATIVE_SIXTY_FOUR) < 0 then return ZERO end
	return exp(difference)
end

local function normal_curve(mean, stddev, capacity)
	local heights = {}
	local spread = mul(FOUR, stddev)
	for i = 0, capacity - 1 do
		local z = sub(mul(EIGHT, fraction(i, capacity - 1)), FOUR)
		local score = neg(div(mul(z, z), TWO))
		heights[i + 1] = height(exp(score))
	end
	return heights, capacity, sub(mean, spread), add(mean, spread), false
end

local function exponential_curve(rate, capacity)
	local heights = {}
	for i = 0, capacity - 1 do
		local score = neg(mul(SIX, fraction(i, capacity - 1)))
		heights[i + 1] = height(exp(score))
	end
	return heights, capacity, ZERO, div(SIX, rate), false
end

local function poisson_curve(lambda, capacity)
	local mode = fx.to_int_trunc(lambda[1], lambda[2])
	local radius = fx.to_int_trunc(unpack(mul(SIX, sqrt(lambda)))) + 1
	local minimum = math.max(0, mode - radius)
	local maximum = mode + radius
	local integer_count = maximum - minimum + 1
	local count = math.min(integer_count, capacity)
	local probability = ONE
	local current = mode
	while current > minimum do
		probability = mul(probability, div(fixed(current), lambda))
		current = current - 1
	end
	local heights = {}
	local x_span = maximum - minimum
	local denominator = count - 1
	for i = 0, count - 1 do
		local target = minimum + math.floor((i * x_span + math.floor(denominator / 2)) /
			denominator)
		while current < target do
			current = current + 1
			probability = mul(probability, div(lambda, fixed(current)))
		end
		heights[i + 1] = height(probability)
	end
	return heights, count, fixed(minimum), fixed(maximum), integer_count <= capacity
end

local function log_normal_score(sigma_squared, x_max_scaled, index, denominator)
	local x = mul(x_max_scaled, fraction(index, denominator))
	local shifted = add(ln(x), sigma_squared)
	return neg(div(mul(shifted, shifted), mul(TWO, sigma_squared)))
end

local function log_normal_curve(mean, stddev, capacity)
	local span = div(mul(stddev, THIRTEEN), EIGHT)
	if cmp(span, TWENTY) > 0 then span = TWENTY end
	local x_max_scaled = exp(span)
	local sigma_squared = mul(stddev, stddev)
	local maximum = log_normal_score(sigma_squared, x_max_scaled, 1, capacity - 1)
	for i = 2, capacity - 1 do
		local score = log_normal_score(sigma_squared, x_max_scaled, i, capacity - 1)
		if cmp(score, maximum) > 0 then maximum = score end
	end
	local heights = { 0 }
	for i = 1, capacity - 1 do
		heights[i + 1] = height(relative(
			log_normal_score(sigma_squared, x_max_scaled, i, capacity - 1), maximum))
	end
	return heights, capacity, ZERO, exp(add(mean, span)), false
end

local function beta_score(alpha_minus_one, beta_minus_one, index, count)
	local x = div(fixed(index * 2 + 1), fixed(count * 2))
	local one_minus_x = sub(ONE, x)
	return add(mul(alpha_minus_one, ln(x)), mul(beta_minus_one, ln(one_minus_x)))
end

local function beta_curve(alpha, beta_parameter, capacity)
	local alpha_minus_one = sub(alpha, ONE)
	local beta_minus_one = sub(beta_parameter, ONE)
	local maximum = beta_score(alpha_minus_one, beta_minus_one, 0, capacity)
	for i = 1, capacity - 1 do
		local score = beta_score(alpha_minus_one, beta_minus_one, i, capacity)
		if cmp(score, maximum) > 0 then maximum = score end
	end
	local heights = {}
	for i = 0, capacity - 1 do
		heights[i + 1] = height(relative(
			beta_score(alpha_minus_one, beta_minus_one, i, capacity), maximum))
	end
	return heights, capacity, ZERO, ONE, false
end

function M.curve(key, first, second, capacity)
	assert(capacity >= 2 and capacity <= 4096, "distribution view capacity out of range")
	if key == "normal" then return normal_curve(first, second, capacity) end
	if key == "exponential" then return exponential_curve(first, capacity) end
	if key == "poisson" then return poisson_curve(first, capacity) end
	if key == "log_normal" then return log_normal_curve(first, second, capacity) end
	if key == "beta" then return beta_curve(first, second, capacity) end
	error("unknown distribution view: " .. tostring(key))
end

local function new_canvas(width, canvas_height)
	local canvas = {}
	for y = 1, canvas_height do
		local row = {}
		for x = 1, width do row[x] = 0 end
		canvas[y] = row
	end
	return canvas
end

local function line(canvas, x0, y0, x1, y1, color)
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

local function map_x(index, count, left, right)
	return left + math.floor((index * (right - left) + math.floor((count - 1) / 2)) /
		(count - 1))
end

local function map_y(value, top, bottom)
	return bottom - math.floor((value * (bottom - top) + math.floor(MAX_HEIGHT / 2)) /
		MAX_HEIGHT)
end

local function make_canvas(key, first, second)
	local canvas = new_canvas(WIDTH, HEIGHT)
	for division = 1, 3 do
		local y = TOP + math.floor(((BOTTOM - TOP) * division + 2) / 4)
		line(canvas, LEFT, y, RIGHT, y, 1)
	end
	for division = 1, 5 do
		local x = LEFT + math.floor(((RIGHT - LEFT) * division + 3) / 6)
		line(canvas, x, TOP, x, BOTTOM, 1)
	end
	line(canvas, LEFT, TOP, LEFT, BOTTOM, 3)
	line(canvas, LEFT, BOTTOM, RIGHT, BOTTOM, 3)

	local heights, count, _, _, discrete = M.curve(key, first, second, RIGHT - LEFT + 1)
	if discrete then
		for i = 0, count - 1 do
			local x = map_x(i, count, LEFT, RIGHT)
			local y = map_y(heights[i + 1], TOP, BOTTOM)
			line(canvas, x, BOTTOM - 1, x, y, 3)
			for oy = -2, 2 do
				for ox = -2, 2 do
					if ox * ox + oy * oy <= 4 and canvas[y + oy] and canvas[y + oy][x + ox] then
						canvas[y + oy][x + ox] = 3
					end
				end
			end
		end
	else
		local previous_x, previous_y
		for i = 0, count - 1 do
			local x = map_x(i, count, LEFT, RIGHT)
			local y = map_y(heights[i + 1], TOP, BOTTOM)
			for fill_y = y + 1, BOTTOM - 1 do canvas[fill_y][x] = 2 end
			if previous_x then line(canvas, previous_x, previous_y, x, y, 3) end
			previous_x, previous_y = x, y
		end
	end
	return canvas
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

local palette = {
	{ 12, 16, 24 },
	{ 37, 50, 71 },
	{ 28, 93, 103 },
	{ 100, 213, 210 },
}

local function raw_rgb_base64(canvas)
	local rows = {}
	for y = 1, HEIGHT do
		local row = {}
		for x = 1, WIDTH do
			local rgb = palette[canvas[y][x] + 1]
			row[x] = string.char(rgb[1], rgb[2], rgb[3])
		end
		rows[y] = table.concat(row)
	end
	return base64(table.concat(rows))
end

local function sixel_run(mask, count)
	local pixel = string.char(63 + mask)
	if count >= 4 then return "!" .. count .. pixel end
	return pixel:rep(count)
end

local function make_sixel(canvas)
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

local function utf8_char(codepoint)
	if codepoint < 0x80 then return string.char(codepoint) end
	if codepoint < 0x800 then
		return string.char(0xc0 + math.floor(codepoint / 64), 0x80 + codepoint % 64)
	end
	return string.char(0xe0 + math.floor(codepoint / 4096),
		0x80 + math.floor(codepoint / 64) % 64, 0x80 + codepoint % 64)
end

local function make_braille(key, first, second)
	local dots = new_canvas(BRAILLE_WIDTH, BRAILLE_HEIGHT)
	line(dots, 1, 1, 1, BRAILLE_HEIGHT, 1)
	line(dots, 1, BRAILLE_HEIGHT, BRAILLE_WIDTH, BRAILLE_HEIGHT, 1)
	local heights, count, _, _, discrete = M.curve(key, first, second, BRAILLE_WIDTH)
	if discrete then
		for i = 0, count - 1 do
			local x = map_x(i, count, 1, BRAILLE_WIDTH)
			local y = map_y(heights[i + 1], 1, BRAILLE_HEIGHT)
			line(dots, x, BRAILLE_HEIGHT - 1, x, y, 1)
		end
	else
		local previous_x, previous_y
		for i = 0, count - 1 do
			local x = map_x(i, count, 1, BRAILLE_WIDTH)
			local y = map_y(heights[i + 1], 1, BRAILLE_HEIGHT)
			if previous_x then line(dots, previous_x, previous_y, x, y, 1) end
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

function M.render(key, first, second, renderer)
	if renderer == "utf8" then return make_braille(key, first, second) end
	local canvas = make_canvas(key, first, second)
	if renderer == "kitty" then return raw_rgb_base64(canvas) end
	if renderer == "sixel" then return make_sixel(canvas) end
	error("unknown chart renderer: " .. tostring(renderer))
end

return M
