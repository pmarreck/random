import Codec

# Exact unsigned arbitrary-width counts, canonical little-endian magnitudes.
# Empty bytes is the unique internal zero; binary output is unsigned BLIP v1.2.
Count :: { magnitude : List(U8) }.{
	zero : Count
	zero = { magnitude: [] }

	from_bytes : List(U8) -> Count
	from_bytes = |bytes| {
		var $trimmed = []
		var $started = Bool.False
		for byte in bytes.rev() {
			if byte != 0 or $started {
				$trimmed = $trimmed.append(byte)
				$started = Bool.True
			}
		}
		{ magnitude: $trimmed.rev() }
	}

	bytes : Count -> List(U8)
	bytes = |value| value.magnitude

	is_eq : Count, Count -> Bool
	is_eq = |a, b| a.magnitude == b.magnitude

	from_decimal : Str -> Try(Count, [Invalid])
	from_decimal = |text| {
		input = text.to_utf8()
		if input.is_empty() {
			Err(Invalid)
		} else {
			var $value = zero
			for byte in input {
				if byte < 48 or byte > 57 return Err(Invalid)
				$value = multiply_add($value, 10, (byte - 48).to_u16())
			}
			Ok($value)
		}
	}

	increment : Count -> Count
	increment = |value| multiply_add(value, 1, 1)

	double_add : Count, U8 -> Try(Count, [Invalid])
	double_add = |value, bit| {
		if bit > 1 Err(Invalid) else Ok(multiply_add(value, 2, bit.to_u16()))
	}

	append_low_bits : Count, List(U8), U64 -> Try(Count, [Invalid])
	append_low_bits = |value, low, bits| {
		if bits > 1000000 or low.len() != (bits + 7).div_by(8) {
			Err(Invalid)
		} else if bits == 0 {
			Ok(value)
		} else {
			whole = bits.div_by(8)
			remaining = bits.rem_by(8)
			scale = U16.shl_wrap(1, remaining.to_u8_wrap())
			var $output = low.take_first(whole)
			var $carry = if remaining == 0 0 else {
				partial = match low.get(whole) {
					Ok(byte) => byte
					Err(OutOfBounds) => return Err(Invalid)
				}
				partial.to_u16().rem_by(scale)
			}
			for byte in value.magnitude {
				combined = byte.to_u16() * scale + $carry
				$output = $output.append(combined.to_u8_wrap())
				$carry = combined.shr_wrap(8)
			}
			if $carry > 0 {
				$output = $output.append($carry.to_u8_wrap())
			}
			Ok(from_bytes($output))
		}
	}

	to_blip : Count -> List(U8)
	to_blip = |value| match value.magnitude {
		[] => [0]
		[byte] => if byte < 128 [byte] else [129, byte]
		_ => blip_envelope(value.magnitude)
	}

	# Decode exactly one shortest unsigned BLIP, never a native-width count.
	# The length prefix is bounded by U64; the magnitude itself is not narrowed.
	from_blip : List(U8) -> Try(Count, [Invalid])
	from_blip = |input| {
		first = match input.first() {
			Ok(byte) => byte
			Err(_) => return Err(Invalid)
		}
		if first < 128 {
			if input.len() != 1 return Err(Invalid)
			return Ok(from_bytes(input))
		}
		if first >= 192 return Err(Invalid)
		var $length = first.bitwise_and(31).to_u64()
		var $header = 1.U64
		if first.bitwise_and(32) != 0 {
			var $shift = 5.U8
			while Bool.True {
				if $shift >= 64 return Err(Invalid)
				byte = match input.get($header) {
					Ok(value) => value
					Err(_) => return Err(Invalid)
				}
				$header = $header + 1
				low = byte.bitwise_and(127).to_u64()
				if low > U64.shr_wrap(18446744073709551615, $shift) return Err(Invalid)
				$length = $length.bitwise_or(low.shl_wrap($shift))
				if byte.bitwise_and(128) == 0 {
					if low == 0 return Err(Invalid)
					break
				}
				$shift = $shift + 7
			}
		}
		if $length == 0 or $length != input.len() - $header return Err(Invalid)
		magnitude = input.drop_first($header)
		last = match magnitude.last() {
			Ok(byte) => byte
			Err(_) => return Err(Invalid)
		}
		if last == 0 or ($length == 1 and last < 128) return Err(Invalid)
		Ok({ magnitude: magnitude })
	}

	# Numeric hexadecimal digits, without a BLIP envelope or 0x prefix.
	to_hex : Count -> Str
	to_hex = |value| {
		if value.magnitude.is_empty() {
			"0"
		} else {
			text = Codec.hex(value.magnitude.rev())
			first = value.magnitude.last() ?? 0
			if first < 16 text.drop_prefix("0") else text
		}
	}

	to_decimal : Count -> Str
	to_decimal = |value| {
		if value.magnitude.is_empty() {
			"0"
		} else {
			var $digits = [0.U64]
			for byte in value.magnitude.rev() {
				var $carry = byte.to_u64()
				var $updated = List.with_capacity($digits.len() + 1)
				for group in $digits {
					combined = group * 256 + $carry
					$updated = $updated.append(combined.rem_by(1000000000))
					$carry = combined.div_by(1000000000)
				}
				if $carry > 0 {
					$updated = $updated.append($carry)
				}
				$digits = $updated
			}
			var $text = ""
			var $first = Bool.True
			for group in $digits.rev() {
				part = group.to_str()
				if $first {
					$text = part
					$first = Bool.False
				} else {
					$text = $text.concat(Str.repeat("0", 9 - part.to_utf8().len())).concat(part)
				}
			}
			$text
		}
	}
}

multiply_add : Count, U16, U16 -> Count
multiply_add = |value, multiplier, carry| {
	var $output = List.with_capacity(value.bytes().len() + 1)
	var $carry = carry
	for byte in value.bytes() {
		combined = byte.to_u16() * multiplier + $carry
		$output = $output.append(combined.to_u8_wrap())
		$carry = combined.shr_wrap(8)
	}
	while $carry > 0 {
		$output = $output.append($carry.to_u8_wrap())
		$carry = $carry.shr_wrap(8)
	}
	Count.from_bytes($output)
}

blip_envelope : List(U8) -> List(U8)
blip_envelope = |bytes| {
	length = bytes.len()
	if length < 32 {
		[128 + length.to_u8_wrap()].concat(bytes)
	} else {
		var $prefix = [160 + length.rem_by(32).to_u8_wrap()]
		var $remaining = length.div_by(32)
		while $remaining > 0 {
			next = $remaining.div_by(128)
			continuation = $remaining.rem_by(128).to_u8_wrap() + (if next != 0 128 else 0)
			$prefix = $prefix.append(continuation)
			$remaining = next
		}
		$prefix.concat(bytes)
	}
}
