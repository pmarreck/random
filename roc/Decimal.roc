import Fixed
import Count
import Geometric

# CLI-facing decimal codecs, preserving the existing integer-only evaluation
# order and 18-place truncation. No IEEE floats or locale-sensitive parsing.
Decimal :: [].{
	parse : Str -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
	parse = |text| parse_decimal(text.to_utf8(), Bool.False)

	parse_bytes : List(U8) -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
	parse_bytes = |bytes| parse_decimal(bytes, Bool.False)

	integer : Str -> Try(I64, [Invalid])
	integer = |text| integer_bytes(text.to_utf8())

	integer_bytes : List(U8) -> Try(I64, [Invalid])
	integer_bytes = |bytes| signed_integer(trim_ascii(bytes), 9007199254740992)

	render : Fixed, U64 -> Try(Str, [Invalid, Numeric, DivisionByZero])
	render = |value, places| {
		if !value.is_valid() or places > 18 return Err(Invalid)
		(m, e) = value.parts()
		if m == 0 {
			return Ok(if places == 0 "0" else "0.".concat(Str.repeat("0", places)))
		}
		positive = if m < 0 value.neg() else value
		(am, _) = positive.parts()
		shift = e.to_i64() - 62
		(integer_text, fraction) = if shift >= 0 {
			# Same conservative guard as the existing formatter, before work.
			if shift > 1981 return Err(Numeric)
			var $mantissa = am.to_u64_wrap()
			var $bytes = []
			while $mantissa != 0 {
				$bytes = $bytes.append($mantissa.to_u8_wrap())
				$mantissa = $mantissa.shr_wrap(8)
			}
			bits = shift.to_u64_wrap()
			integer_count = Count.from_bytes($bytes).append_low_bits(List.repeat(0.U8, (bits + 7).div_by(8)), bits)?
			(integer_count.to_decimal(), Fixed.zero)
		} else {
			amount = -shift
			integer_value = if amount > 62 0 else am.div_trunc_by(I64.shl_wrap(1, amount.to_u8_wrap()))
			(integer_value.to_str(), positive.sub(Fixed.from_int(integer_value))?)
		}
		var $fraction = fraction
		var $digits = []
		var $text = integer_text
		for _index in 0..<places {
			$fraction = $fraction.mul(Fixed.from_int(10))?
			digit = $fraction.to_int_trunc()
			if digit < 0 or digit > 9 return Err(Numeric)
			$digits = $digits.append(digit.to_str())
			$fraction = $fraction.sub(Fixed.from_int(digit))?
		}
		if places > 0 {
			$text = $text.concat(".").concat(Str.join_with($digits, ""))
		}
		Ok(if m < 0 "-".concat($text) else $text)
	}

	probability : Str -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
	probability = |text| probability_bytes(text.to_utf8())

	probability_bytes : List(U8) -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
	probability_bytes = |input| {
		value = match input {
			[50, 94, .. as rest] => {
				exponent = signed_integer(rest, 1000000)?
				if exponent > 0 return Err(Invalid)
				Fixed.power_of_two(exponent.to_i32_wrap())
			}
			_ => {
				var $exponent_index = Missing
				var $index = 0.U64
				for byte in input {
					if byte == 101 or byte == 69 {
						match $exponent_index {
							Ready(_) => return Err(Invalid)
							Missing => {
								$exponent_index = Ready($index)
							}
						}
					}
					$index = $index + 1
				}
				match $exponent_index {
					Missing => parse_decimal(input, Bool.True)?
					Ready(index) => {
						mantissa_bytes = input.take_first(index)
						if mantissa_bytes.is_empty() return Err(Invalid)
						for byte in mantissa_bytes {
							if !is_digit(byte) and byte != 46 return Err(Invalid)
						}
						mantissa = parse_decimal(mantissa_bytes, Bool.True)?
						exponent = signed_integer(input.drop_first(index + 1), 1000000)?
						var $remaining = if exponent < 0 -exponent else exponent
						var $factor = Fixed.from_int(10)
						var $multiplier = Fixed.from_int(1)
						while $remaining > 0 {
							if $remaining.rem_by(2) != 0 {
								$multiplier = $multiplier.mul($factor)?
							}
							$remaining = $remaining.div_trunc_by(2)
							if $remaining > 0 {
								$factor = $factor.mul($factor)?
							}
						}
						if exponent < 0 mantissa.div($multiplier)? else mantissa.mul($multiplier)?
					}
				}
			}
		}
		_ = Geometric.new(value)?
		Ok(value)
	}
}

is_digit : U8 -> Bool
is_digit = |byte| byte >= 48 and byte <= 57

is_space : U8 -> Bool
is_space = |byte| byte == 32 or (byte >= 9 and byte <= 13)

trim_ascii : List(U8) -> List(U8)
trim_ascii = |bytes| {
	var $front = bytes
	var $done = Bool.False
	while !$done {
		match $front {
			[byte, .. as rest] => {
				if is_space(byte) {
					$front = rest
				} else {
					$done = Bool.True
				}
			}
			[] => {
				$done = Bool.True
			}
		}
	}
	var $back = $front.rev()
	$done = Bool.False
	while !$done {
		match $back {
			[byte, .. as rest] => {
				if is_space(byte) {
					$back = rest
				} else {
					$done = Bool.True
				}
			}
			[] => {
				$done = Bool.True
			}
		}
	}
	$back.rev()
}

unsigned_digits : List(U8), I64 -> Try(I64, [Invalid])
unsigned_digits = |bytes, limit| {
	if bytes.is_empty() return Err(Invalid)
	var $value = 0.I64
	for byte in bytes {
		if !is_digit(byte) return Err(Invalid)
		digit = (byte - 48).to_i64()
		if $value > (limit - digit).div_trunc_by(10) return Err(Invalid)
		$value = $value * 10 + digit
	}
	Ok($value)
}

signed_integer : List(U8), I64 -> Try(I64, [Invalid])
signed_integer = |bytes, limit| match bytes {
	[45, .. as digits] => Ok(-unsigned_digits(digits, limit)?)
	[43, .. as digits] => unsigned_digits(digits, limit)
	_ => unsigned_digits(bytes, limit)
}

parse_decimal : List(U8), Bool -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
parse_decimal = |input, strict_cap| {
	(negative, bytes) = match trim_ascii(input) {
		[45, .. as rest] => (Bool.True, rest)
		[43, .. as rest] => (Bool.False, rest)
		other => (Bool.False, other)
	}
	var $remaining = bytes
	var $integers = []
	var $done = Bool.False
	while !$done {
		match $remaining {
			[byte, .. as rest] => if is_digit(byte) {
				$integers = $integers.append(byte)
				$remaining = rest
			} else {
				$done = Bool.True
			}
			[] => {
				$done = Bool.True
			}
		}
	}
	if strict_cap and $integers.len() > 2000 return Err(Invalid)
	integer_value = if $integers.is_empty() Fixed.zero else match unsigned_digits($integers, 9223372036854775807) {
		Ok(value) => Fixed.from_int(value)
		Err(Invalid) => {
			if $integers.len() > 2000 return Err(Invalid)
			var $value = Fixed.zero
			for byte in $integers {
				$value = $value.mul(Fixed.from_int(10))?.add(Fixed.from_int((byte - 48).to_i64()))?
			}
			$value
		}
	}
	var $fraction = 0.I64
	var $denominator = 1.I64
	var $fraction_digits = 0.U64
	match $remaining {
		[46, .. as rest] => {
			$remaining = rest
			for byte in rest {
				if !is_digit(byte) return Err(Invalid)
				if $fraction_digits < 18 {
					$fraction = $fraction * 10 + (byte - 48).to_i64()
					$denominator = $denominator * 10
					$fraction_digits = $fraction_digits + 1
				}
			}
			$remaining = []
		}
		_ => {}
	}
	if !$remaining.is_empty() or ($integers.is_empty() and $fraction_digits == 0) return Err(Invalid)
	value = if $fraction_digits == 0 integer_value else {
		fraction_value = Fixed.from_int($fraction).div(Fixed.from_int($denominator))?
		integer_value.add(fraction_value)?
	}
	Ok(if negative value.neg() else value)
}
