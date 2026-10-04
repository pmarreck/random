# Pure byte/seed codecs. No IEEE-754 or JSON numeric conversion is involved.
Codec :: [].{
	hex : List(U8) -> Str
	hex = |bytes| {
		var $result = Str.with_capacity(bytes.len() * 2)
		for byte in bytes {
			$result = $result.concat(digit(byte.shr_wrap(4))).concat(digit(byte.bitwise_and(15)))
		}
		$result
	}

	unhex : Str -> Try(List(U8), [Invalid])
	unhex = |text| {
		bytes = text.to_utf8()
		if bytes.len().rem_by(2) != 0 {
			Err(Invalid)
		} else {
			var $output = List.with_capacity(bytes.len().div_by(2))
			var $high = 0.U8
			var $first = Bool.True
			for byte in bytes {
				nibble = decode_digit(byte)?
				if $first {
					$high = nibble
				} else {
					$output = $output.append($high * 16 + nibble)
				}
				$first = !$first
			}
			Ok($output)
		}
	}

	seed : Str -> Try(List(U8), [Invalid])
	seed = |text| {
		bytes = text.to_utf8()
		(hexadecimal, digits) = if text.starts_with("0x") or text.starts_with("0X") {
			(Bool.True, bytes.drop_first(2))
		} else {
			(Bool.False, bytes)
		}
		if digits.is_empty() or (hexadecimal and digits.len() > 64) {
			Err(Invalid)
		} else {
			base = if hexadecimal 16.U16 else 10.U16
			var $magnitude = List.repeat(0.U8, 32)
			for byte in digits {
				n = if hexadecimal decode_digit(byte)?
				else if byte >= 48 and byte <= 57 byte - 48
				else return Err(Invalid)
				var $carry = n.to_u16()
				for i in 0..<32 {
					index = 31 - i
					old = match $magnitude.get(index) {
						Ok(value) => value
						Err(OutOfBounds) => return Err(Invalid)
					}
					product = old.to_u16() * base + $carry
					$magnitude = match $magnitude.set(index, product.to_u8_wrap()) {
						Ok(value) => value
						Err(OutOfBounds) => return Err(Invalid)
					}
					$carry = product.shr_wrap(8)
				}
				if $carry != 0 return Err(Invalid)
			}
			Ok($magnitude)
		}
	}
}

digit : U8 -> Str
digit = |n| {
	if n < 10 n.to_str()
	else if n == 10 "a"
	else if n == 11 "b"
	else if n == 12 "c"
	else if n == 13 "d"
	else if n == 14 "e"
	else "f"
}

decode_digit : U8 -> Try(U8, [Invalid])
decode_digit = |byte| {
	if byte >= 48 and byte <= 57 Ok(byte - 48)
	else if byte >= 65 and byte <= 70 Ok(byte - 55)
	else if byte >= 97 and byte <= 102 Ok(byte - 87)
	else Err(Invalid)
}
