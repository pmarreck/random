# Independent single-block BLAKE3 subset used by the DRBG. This deliberately
# does not claim general multi-block/tree hashing; public lengths are checked.
Blake3 :: [].{
	hash32 : List(U8) -> Try(List(U8), [Invalid])
	hash32 = |bytes| hash(bytes, iv, 0)

	derive_key : List(U8), List(U8) -> Try(List(U8), [Invalid])
	derive_key = |context, material| {
		context_key = hash(context, iv, 32)?
		hash(material, key_words(context_key)?, 64)
	}

	keyed_xof : List(U8), U64, U64 -> Try(List(U8), [Invalid])
	keyed_xof = |key, position, count| {
		limit = 9007199254740992.U64
		if key.len() != 32 or position > limit or count > limit - position or count > 1048576 {
			Err(Invalid)
		} else {
			words = key_words(key)?
			block = List.repeat(0.U32, 16)
			var $result = List.with_capacity(count)
			var $position = position
			var $remaining = count
			while $remaining > 0 {
				output = compress(words, block, $position.div_by(64), 0, 27)?
				bytes = words_to_bytes(output)
				offset = $position.rem_by(64)
				n = if $remaining < 64 - offset $remaining else 64 - offset
				$result = $result.concat(bytes.sublist({ start: offset, len: n }))
				$position = $position + n
				$remaining = $remaining - n
			}
			Ok($result)
		}
	}
}

iv : List(U32)
iv = [1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635, 1541459225]

permutation : List(U64)
permutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

word : List(U32), U64 -> Try(U32, [Invalid])
word = |words, index| match words.get(index) {
	Ok(value) => Ok(value)
	Err(OutOfBounds) => Err(Invalid)
}

set_word : List(U32), U64, U32 -> Try(List(U32), [Invalid])
set_word = |words, index, value| match words.set(index, value) {
	Ok(updated) => Ok(updated)
	Err(OutOfBounds) => Err(Invalid)
}

rotate : U32, U8 -> U32
rotate = |value, count| value.shr_wrap(count).bitwise_or(value.shl_wrap(32 - count))

mix : List(U32), U64, U64, U64, U64, U32, U32 -> Try(List(U32), [Invalid])
mix = |state, a, b, c, d, x, y| {
	a0 = word(state, a)?.plus_wrap(word(state, b)?).plus_wrap(x)
	d0 = rotate(word(state, d)?.bitwise_xor(a0), 16)
	c0 = word(state, c)?.plus_wrap(d0)
	b0 = rotate(word(state, b)?.bitwise_xor(c0), 12)
	a1 = a0.plus_wrap(b0).plus_wrap(y)
	d1 = rotate(d0.bitwise_xor(a1), 8)
	c1 = c0.plus_wrap(d1)
	b1 = rotate(b0.bitwise_xor(c1), 7)
	set_word(set_word(set_word(set_word(state, a, a1)?, b, b1)?, c, c1)?, d, d1)
}

round : List(U32), List(U32) -> Try(List(U32), [Invalid])
round = |state, message| {
	s0 = mix(state, 0, 4, 8, 12, word(message, 0)?, word(message, 1)?)?
	s1 = mix(s0, 1, 5, 9, 13, word(message, 2)?, word(message, 3)?)?
	s2 = mix(s1, 2, 6, 10, 14, word(message, 4)?, word(message, 5)?)?
	s3 = mix(s2, 3, 7, 11, 15, word(message, 6)?, word(message, 7)?)?
	s4 = mix(s3, 0, 5, 10, 15, word(message, 8)?, word(message, 9)?)?
	s5 = mix(s4, 1, 6, 11, 12, word(message, 10)?, word(message, 11)?)?
	s6 = mix(s5, 2, 7, 8, 13, word(message, 12)?, word(message, 13)?)?
	mix(s6, 3, 4, 9, 14, word(message, 14)?, word(message, 15)?)
}

compress : List(U32), List(U32), U64, U32, U32 -> Try(List(U32), [Invalid])
compress = |cv, block, counter, length, flags| {
	var $state = cv.concat(iv.take_first(4)).concat([
		counter.to_u32_wrap(),
		counter.shr_wrap(32).to_u32_wrap(),
		length,
		flags,
	])
	var $message = block
	for _iteration in 0..<7 {
		$state = round($state, $message)?
		var $permuted = List.with_capacity(16)
		for index in permutation {
			$permuted = $permuted.append(word($message, index)?)
		}
		$message = $permuted
	}
	var $output = List.with_capacity(16)
	for index in 0..<8 {
		$output = $output.append(word($state, index)?.bitwise_xor(word($state, index + 8)?))
	}
	for index in 0..<8 {
		$output = $output.append(word($state, index + 8)?.bitwise_xor(word(cv, index)?))
	}
	Ok($output)
}

word_at : List(U8), U64 -> Try(U32, [Invalid])
word_at = |bytes, offset| {
	var $value = 0.U32
	for i in 0..<4 {
		byte = match bytes.get(offset + i) {
			Ok(value) => value
			Err(OutOfBounds) => return Err(Invalid)
		}
		$value = $value.bitwise_or(byte.to_u32().shl_wrap((8 * i).to_u8_wrap()))
	}
	Ok($value)
}

key_words : List(U8) -> Try(List(U32), [Invalid])
key_words = |bytes| {
	if bytes.len() != 32 {
		Err(Invalid)
	} else {
		var $words = List.with_capacity(8)
		for index in 0..<8 {
			$words = $words.append(word_at(bytes, index * 4)?)
		}
		Ok($words)
	}
}

words_to_bytes : List(U32) -> List(U8)
words_to_bytes = |words| {
	var $bytes = List.with_capacity(words.len() * 4)
	for value in words {
		for shift in 0..<4 {
			$bytes = $bytes.append(value.shr_wrap((shift * 8).to_u8_wrap()).to_u8_wrap())
		}
	}
	$bytes
}

hash : List(U8), List(U32), U32 -> Try(List(U8), [Invalid])
hash = |bytes, key, flags| {
	if bytes.len() > 64 or key.len() != 8 {
		Err(Invalid)
	} else {
		padded = bytes.concat(List.repeat(0.U8, 64 - bytes.len()))
		var $block = List.with_capacity(16)
		for index in 0..<16 {
			$block = $block.append(word_at(padded, index * 4)?)
		}
		output = compress(key, $block, 0, bytes.len().to_u32_wrap(), flags.bitwise_or(11))?
		Ok(words_to_bytes(output).take_first(32))
	}
}
