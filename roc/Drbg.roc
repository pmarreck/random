import Blake3
import Fixed

# Pure, caller-owned keyed-XOF state. Entropy sourcing belongs to an interpreter
# at the I/O edge; there are no files, clocks, globals or implicit seeds here.
Drbg :: { key : List(U8), position : U64 }.{
	new : List(U8) -> Try(Drbg, [Invalid])
	new = |seed| {
		if seed.len() != 32 {
			Err(Invalid)
		} else {
			key = Blake3.derive_key("random drbg 2026-08-04 v1".to_utf8(), seed)?
			Ok({ key, position: 0 })
		}
	}

	restore : List(U8), U64 -> Try(Drbg, [Invalid])
	restore = |key, cursor| {
		if key.len() != 32 or cursor > limit Err(Invalid)
		else Ok({ key, position: cursor })
	}

	state : Drbg -> (List(U8), U64)
	state = |rng| (rng.key, rng.position)

	position : Drbg -> U64
	position = |rng| rng.position

	seek : Drbg, U64 -> Try(Drbg, [Invalid])
	seek = |rng, cursor| if cursor > limit Err(Invalid) else Ok({ ..rng, position: cursor })

	is_eq : Drbg, Drbg -> Bool
	is_eq = |a, b| a.key == b.key and a.position == b.position

	bytes : Drbg, U64 -> Try((List(U8), Drbg), [Invalid])
	bytes = |rng, count| {
		if rng.position > limit or count > limit - rng.position {
			Err(Invalid)
		} else {
			output = Blake3.keyed_xof(rng.key, rng.position, count)?
			Ok((output, { ..rng, position: rng.position + count }))
		}
	}

	u32 : Drbg -> Try((U32, Drbg), [Invalid])
	u32 = |rng| {
		(output, next) = rng.bytes(4)?
		Ok((big_endian(output).to_u32_wrap(), next))
	}

	u64 : Drbg -> Try((U64, Drbg), [Invalid])
	u64 = |rng| {
		(output, next) = rng.bytes(8)?
		Ok((big_endian(output), next))
	}

	uniform : Drbg -> Try((Fixed, Drbg), [Invalid, Numeric, DivisionByZero])
	uniform = |rng| {
		(value, next) = rng.u32()?
		fraction = Fixed.from_int(value.to_i64()).div(Fixed.from_int(4294967296))?
		Ok((fraction, next))
	}

	range : Drbg, I64, I64 -> Try((I64, Drbg), [Invalid])
	range = |rng, first, last| {
		if first < -9007199254740992 or first > 9007199254740992 or
			last < -9007199254740992 or last > 9007199254740992 or last < first {
			Err(Invalid)
		} else {
			width = last.to_i128() - first.to_i128() + 1
			if width > 9007199254740992 {
				Err(Invalid)
			} else if width == 1 {
				Ok((first, rng))
			} else {
				span = width.to_u64_wrap()
				var $state = rng
				if span <= 4294967296 {
					bound = 4294967296.U64 - (4294967296.U64).rem_by(span)
					var $done = Bool.False
					var $value = first
					while !$done {
						(draw, next) = $state.u32()?
						$state = next
						if draw.to_u64() < bound {
							$value = first + draw.to_u64().rem_by(span).to_i64_wrap()
							$done = Bool.True
						}
					}
					Ok(($value, $state))
				} else {
					remainder = U64.minus_wrap(0, span).rem_by(span)
					bound = U64.minus_wrap(0, remainder)
					var $done = Bool.False
					var $value = first
					while !$done {
						(draw, next) = $state.u64()?
						$state = next
						if remainder == 0 or draw < bound {
							$value = first + draw.rem_by(span).to_i64_wrap()
							$done = Bool.True
						}
					}
					Ok(($value, $state))
				}
			}
		}
	}
}

limit : U64
limit = 9007199254740992

big_endian : List(U8) -> U64
big_endian = |bytes| {
	var $value = 0.U64
	for byte in bytes {
		$value = $value.shl_wrap(8).bitwise_or(byte.to_u64())
	}
	$value
}
