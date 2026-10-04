-- Exact nonnegative integers as canonical little-endian magnitude bytes.
-- This is an unsigned BLIP payload, not signed two's-complement blip_mp data.
-- All intermediate Lua numbers stay below 2^53; no integer value is converted
-- wholesale to binary64. Importing this pure module performs no I/O.
local M = {}
local floor = math.floor

-- Trim redundant high zeros; the empty magnitude is the unique internal zero.
function M.from_bytes(bytes)
	assert(type(bytes) == "string", "count magnitude must be a byte string")
	local length = #bytes
	while length > 0 and bytes:byte(length) == 0 do length = length - 1 end
	return bytes:sub(1, length)
end

-- Multiply a magnitude by a small positive integer and add a small carry.
-- Decimal parsing and bit reconstruction need only multipliers ten and two.
local function multiply_add(bytes, multiplier, carry)
	local result = {}
	for index = 1, #bytes do
		local value = bytes:byte(index) * multiplier + carry
		result[index] = string.char(value % 256)
		carry = floor(value / 256)
	end
	while carry > 0 do
		result[#result + 1] = string.char(carry % 256)
		carry = floor(carry / 256)
	end
	return M.from_bytes(table.concat(result))
end

-- Parse decimal digits without passing the full value through tonumber.
function M.from_decimal(text)
	assert(type(text) == "string" and text:match("^%d+$"),
		"count must contain only unsigned decimal digits")
	local value = ""
	for index = 1, #text do value = multiply_add(value, 10, text:byte(index) - 48) end
	return value
end

-- Reconstruct a geometric block: two times the block count plus its low bit.
function M.double_add(bytes, bit)
	assert(bit == 0 or bit == 1, "count reconstruction bit must be zero or one")
	return multiply_add(M.from_bytes(bytes), 2, bit)
end

-- Increment remains exact at byte carries and beyond every native word width.
function M.increment(bytes)
	return multiply_add(M.from_bytes(bytes), 1, 1)
end

-- Shift once and insert independently sampled low bits, avoiding repeated
-- whole-magnitude copies for probabilities with very large negative exponents.
function M.append_low_bits(bytes, low, bits)
	bytes = M.from_bytes(bytes)
	assert(type(bits) == "number" and bits >= 0 and bits == floor(bits),
		"low-bit count must be a nonnegative integer")
	assert(type(low) == "string" and #low == floor((bits + 7) / 8),
		"low-bit byte span has the wrong length")
	if bits == 0 then return bytes end
	local whole, remaining = floor(bits / 8), bits % 8
	local scale = ({1, 2, 4, 8, 16, 32, 64, 128})[remaining + 1]
	local result = {}
	for index = 1, whole do result[index] = low:byte(index) end
	if remaining ~= 0 then result[whole + 1] = low:byte(whole + 1) % scale end
	local carry = 0
	for index = 1, #bytes do
		local destination = whole + index
		local value = bytes:byte(index) * scale + carry + (result[destination] or 0)
		result[destination] = value % 256
		carry = floor(value / 256)
	end
	if carry > 0 then result[whole + #bytes + 1] = carry end
	for index = 1, #result do result[index] = string.char(result[index]) end
	return M.from_bytes(table.concat(result))
end

-- Convert with base-10^9 scratch digits. The largest intermediate is below
-- 256*10^9, so every addition, multiplication and remainder is exact in Lua.
function M.to_decimal(bytes)
	bytes = M.from_bytes(bytes)
	if #bytes == 0 then return "0" end
	local digits = {0}
	for index = #bytes, 1, -1 do
		local carry = bytes:byte(index)
		for digit = 1, #digits do
			local value = digits[digit] * 256 + carry
			digits[digit] = value % 1000000000
			carry = floor(value / 1000000000)
		end
		if carry > 0 then digits[#digits + 1] = carry end
	end
	local text = {string.format("%d", digits[#digits])}
	for index = #digits - 1, 1, -1 do text[#text + 1] = string.format("%09d", digits[index]) end
	return table.concat(text)
end

-- Numeric hexadecimal text is distinct from the BLIP envelope's hex bytes.
function M.to_hex(bytes)
	bytes = M.from_bytes(bytes)
	if #bytes == 0 then return "0" end
	local text = {string.format("%x", bytes:byte(#bytes))}
	for index = #bytes - 1, 1, -1 do text[#text + 1] = string.format("%02x", bytes:byte(index)) end
	return table.concat(text)
end

-- Canonical unsigned BLIP v1.2: immediate 0..127, otherwise the shortest
-- little-endian payload, five inline length bits and seven-bit continuation.
function M.to_blip(bytes)
	bytes = M.from_bytes(bytes)
	local length = #bytes
	if length == 0 then return "\0" end
	if length == 1 and bytes:byte(1) < 128 then return bytes end
	if length < 32 then return string.char(128 + length) .. bytes end
	local prefix = {string.char(160 + length % 32)}
	length = floor(length / 32)
	repeat
		local next_length = floor(length / 128)
		prefix[#prefix + 1] = string.char(length % 128 + (next_length > 0 and 128 or 0))
		length = next_length
	until length == 0
	return table.concat(prefix) .. bytes
end

return M
