-- Small dependency-free JSON codec for random's continuation-state protocol.
-- The decoder accepts ordinary JSON whitespace, object-key reordering, and
-- standard string escapes. Duplicate object keys are rejected so a state has
-- only one interpretation in every frontend.
local M = {}
local object_metatable = {}
local array_metatable = {}
local MAX_DEPTH = 64
local MAX_OBJECT_MEMBERS = 32
local MAX_ARRAY_ITEMS = 1024

local function valid_utf8(value)
	local index = 1
	while index <= #value do
		local first = value:byte(index)
		if first < 0x80 then
			index = index + 1
		else
			local count, second_min, second_max
			if first >= 0xc2 and first <= 0xdf then
				count, second_min, second_max = 1, 0x80, 0xbf
			elseif first == 0xe0 then
				count, second_min, second_max = 2, 0xa0, 0xbf
			elseif first >= 0xe1 and first <= 0xec or first >= 0xee and first <= 0xef then
				count, second_min, second_max = 2, 0x80, 0xbf
			elseif first == 0xed then
				count, second_min, second_max = 2, 0x80, 0x9f
			elseif first == 0xf0 then
				count, second_min, second_max = 3, 0x90, 0xbf
			elseif first >= 0xf1 and first <= 0xf3 then
				count, second_min, second_max = 3, 0x80, 0xbf
			elseif first == 0xf4 then
				count, second_min, second_max = 3, 0x80, 0x8f
			else
				return false
			end
			local second = value:byte(index + 1)
			if second == nil or second < second_min or second > second_max then return false end
			for offset = 2, count do
				local byte = value:byte(index + offset)
				if byte == nil or byte < 0x80 or byte > 0xbf then return false end
			end
			index = index + count + 1
		end
	end
	return true
end

M.valid_utf8 = valid_utf8

function M.is_object(value)
	return type(value) == 'table' and getmetatable(value) == object_metatable
end

function M.is_array(value)
	return type(value) == 'table' and getmetatable(value) == array_metatable
end

local function utf8(codepoint)
	if codepoint <= 0x7f then
		return string.char(codepoint)
	elseif codepoint <= 0x7ff then
		return string.char(0xc0 + math.floor(codepoint / 0x40),
			0x80 + codepoint % 0x40)
	elseif codepoint <= 0xffff then
		return string.char(0xe0 + math.floor(codepoint / 0x1000),
			0x80 + math.floor(codepoint / 0x40) % 0x40,
			0x80 + codepoint % 0x40)
	end
	return string.char(0xf0 + math.floor(codepoint / 0x40000),
		0x80 + math.floor(codepoint / 0x1000) % 0x40,
		0x80 + math.floor(codepoint / 0x40) % 0x40,
		0x80 + codepoint % 0x40)
end

function M.quote(value)
	local out = {'"'}
	local value_is_utf8 = valid_utf8(value)
	for index = 1, #value do
		local byte = value:byte(index)
		if byte == 0x22 then out[#out + 1] = '\\"'
		elseif byte == 0x5c then out[#out + 1] = '\\\\'
		elseif byte == 0x08 then out[#out + 1] = '\\b'
		elseif byte == 0x0c then out[#out + 1] = '\\f'
		elseif byte == 0x0a then out[#out + 1] = '\\n'
		elseif byte == 0x0d then out[#out + 1] = '\\r'
		elseif byte == 0x09 then out[#out + 1] = '\\t'
		elseif byte < 0x20 or (byte >= 0x80 and not value_is_utf8) then
			out[#out + 1] = string.format('\\u%04x', byte)
		else out[#out + 1] = string.char(byte)
		end
	end
	out[#out + 1] = '"'
	return table.concat(out)
end

function M.decode(text)
	if type(text) ~= 'string' then return nil, 'state must be JSON text' end
	if not valid_utf8(text) then return nil, 'state JSON is not valid UTF-8' end
	local index, length = 1, #text
	local parse_value

	local function skip_space()
		while index <= length do
			local byte = text:byte(index)
			if byte ~= 0x20 and byte ~= 0x09 and byte ~= 0x0a and byte ~= 0x0d then break end
			index = index + 1
		end
	end

	local function parse_number()
		local start = index
		if text:byte(index) == 0x2d then
			index = index + 1
			local byte = text:byte(index)
			if byte == nil or byte < 0x30 or byte > 0x39 then
				return nil, 'malformed JSON number'
			end
		end
		if text:byte(index) == 0x30 then
			index = index + 1
			local byte = text:byte(index)
			if byte ~= nil and byte >= 0x30 and byte <= 0x39 then
				return nil, 'leading zero in JSON number'
			end
		else
			local digits = index
			while index <= length do
				local byte = text:byte(index)
				if byte < 0x30 or byte > 0x39 then break end
				index = index + 1
			end
			if index == digits then return nil, 'malformed JSON number' end
		end
		return tonumber(text:sub(start, index - 1))
	end

	local function parse_string()
		if text:sub(index, index) ~= '"' then return nil, 'expected JSON string' end
		index = index + 1
		local out = {}
		while index <= length do
			local byte = text:byte(index)
			if byte == 0x22 then
				index = index + 1
				return table.concat(out)
			elseif byte == 0x5c then
				index = index + 1
				local escape = text:sub(index, index)
				local simple = {['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t'}
				if simple[escape] then
					out[#out + 1] = simple[escape]
					index = index + 1
				elseif escape == 'u' then
					local digits = text:sub(index + 1, index + 4)
					if #digits ~= 4 or not digits:match('^[0-9a-fA-F]+$') then
						return nil, 'invalid JSON Unicode escape'
					end
					local codepoint = tonumber(digits, 16)
					index = index + 5
					if codepoint >= 0xd800 and codepoint <= 0xdbff then
						if text:sub(index, index + 1) ~= '\\u' then
							return nil, 'unpaired JSON high surrogate'
						end
						local low_digits = text:sub(index + 2, index + 5)
						if #low_digits ~= 4 or not low_digits:match('^[0-9a-fA-F]+$') then
							return nil, 'invalid JSON low surrogate'
						end
						local low = tonumber(low_digits, 16)
						if low < 0xdc00 or low > 0xdfff then return nil, 'invalid JSON low surrogate' end
						codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + low - 0xdc00
						index = index + 6
					elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
						return nil, 'unpaired JSON low surrogate'
					end
					if codepoint == 0 then return nil, 'NUL is not supported in state strings' end
					out[#out + 1] = utf8(codepoint)
				else
					return nil, 'invalid JSON escape'
				end
			elseif byte < 0x20 then
				return nil, 'unescaped control byte in JSON string'
			else
				out[#out + 1] = string.char(byte)
				index = index + 1
			end
		end
		return nil, 'unterminated JSON string'
	end

	local function parse_object(depth)
		index = index + 1
		skip_space()
		local object, seen, members = setmetatable({}, object_metatable), {}, 0
		if text:sub(index, index) == '}' then index = index + 1; return object end
		while true do
			if members >= MAX_OBJECT_MEMBERS then
				return nil, 'state JSON object exceeds 32 members'
			end
			local key, err = parse_string()
			if key == nil then return nil, err end
			if seen[key] then return nil, 'duplicate JSON object key: ' .. key end
			seen[key] = true
			members = members + 1
			skip_space()
			if text:sub(index, index) ~= ':' then return nil, 'expected colon after JSON key' end
			index = index + 1
			skip_space()
			local value
			value, err = parse_value(depth)
			if err then return nil, err end
			object[key] = value
			skip_space()
			local separator = text:sub(index, index)
			if separator == '}' then index = index + 1; return object end
			if separator ~= ',' then return nil, 'expected comma or closing brace' end
			index = index + 1
			skip_space()
		end
	end

	local function parse_array(depth)
		index = index + 1
		skip_space()
		local array = setmetatable({}, array_metatable)
		if text:sub(index, index) == ']' then index = index + 1; return array end
		while true do
			if #array >= MAX_ARRAY_ITEMS then
				return nil, 'state JSON array exceeds 1024 items'
			end
			local value, err = parse_value(depth)
			if err then return nil, err end
			array[#array + 1] = value
			skip_space()
			local separator = text:sub(index, index)
			if separator == ']' then index = index + 1; return array end
			if separator ~= ',' then return nil, 'expected comma or closing bracket' end
			index = index + 1
			skip_space()
		end
	end

	parse_value = function(depth)
		skip_space()
		local first = text:sub(index, index)
		if first == '"' then return parse_string() end
		if first == '{' or first == '[' then
			if depth >= MAX_DEPTH then return nil, 'state JSON nesting exceeds 64 levels' end
			if first == '{' then return parse_object(depth + 1) end
			return parse_array(depth + 1)
		end
		local byte = text:byte(index)
		if byte == 0x2d or (byte ~= nil and byte >= 0x30 and byte <= 0x39) then
			return parse_number()
		end
		if text:sub(index, index + 3) == 'true' then index = index + 4; return true end
		if text:sub(index, index + 4) == 'false' then index = index + 5; return false end
		return nil, 'unsupported or malformed JSON value'
	end

	local value, err = parse_value(0)
	if err then return nil, err end
	skip_space()
	if index <= length then return nil, 'trailing data after JSON state' end
	return value
end

return M
