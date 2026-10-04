import Fixed
import Draw
import Count

# Failures before success, with prepared portable Fixed recurrence thresholds.
# Arbitrary-width results retain every bit; no log approximation or u64 clamp.
Geometric :: { base : U64, levels : List(U64), tail_bits : U64, certain : Bool }.{
	new : Fixed -> Try(Geometric, [Invalid, Numeric, DivisionByZero])
	new = |probability| {
		(m, e) = probability.parts()
		one = Fixed.from_int(1)
		if !probability.is_valid() or m <= 0 or e < -1000000 or e > 0 or probability.compare(one) > 0 {
			Err(Invalid)
		} else if probability.compare(one) == 0 {
			Ok({ base: 0, levels: [], tail_bits: 0, certain: Bool.True })
		} else {
			tail_bits = if e < -62 (-62 - e).to_u64_wrap() else 0
			var $p = if e < -62 Fixed.from_parts(m, -62)? else probability
			var $levels = []
			half = Fixed.power_of_two(-1)
			two = Fixed.from_int(2)
			while $p.compare(half) < 0 {
				if $levels.len() >= 128 return Err(Numeric)
				bit = one.sub($p)?.div(two.sub($p)?)?
				$levels = $levels.append(threshold(bit)?)
				(pm, pe) = $p.parts()
				# Double the exponent exactly: same-sign Fixed.add loses odd bits.
				doubled = Fixed.from_parts(pm, pe + 1)?
				$p = doubled.sub($p.mul($p)?)?
			}
			Ok({ base: threshold($p)?, levels: $levels, tail_bits, certain: Bool.False })
		}
	}

	is_eq : Geometric, Geometric -> Bool
	is_eq = |a, b| a.base == b.base and a.levels == b.levels and
		a.tail_bits == b.tail_bits and a.certain == b.certain

	sample : Geometric -> Draw(Count)
	sample = |prepared| {
		if prepared.certain {
			Draw.succeed(Count.zero)
		} else {
			base_loop(prepared.base, Count.zero).and_then(|value|
				bit_loop(value, prepared.levels.rev(), prepared.tail_bits))
		}
	}
}

threshold : Fixed -> Try(U64, [Numeric])
threshold = |value| {
	(m, e) = value.parts()
	if m <= 0 or e < -2 or e > -1 Err(Numeric)
	else Ok(m.to_u64_wrap().shl_wrap((e + 2).to_u8_wrap()))
}

big_endian : List(U8) -> U64
big_endian = |bytes| {
	var $value = 0.U64
	for byte in bytes {
		$value = $value.shl_wrap(8).bitwise_or(byte.to_u64())
	}
	$value
}

base_loop : U64, Count -> Draw(Count)
base_loop = |base, value| Draw.read(8).and_then(
	|bytes| {
		if big_endian(bytes) < base Draw.succeed(value)
		else base_loop(base, value.increment())
	},
)

bit_loop : Count, List(U64), U64 -> Draw(Count)
bit_loop = |value, levels, tail_bits| match levels {
	[] => if tail_bits == 0 Draw.succeed(value)
	else Draw.read((tail_bits + 7).div_by(8)).and_then(|low|
		Draw.from_try(value.append_low_bits(low, tail_bits)))
	[bound, .. as remaining] => Draw.read(8).and_then(
		|bytes| {
			bit = if big_endian(bytes) < bound 1.U8 else 0.U8
			match value.double_add(bit) {
				Ok(reconstructed) => bit_loop(reconstructed, remaining, tail_bits)
				Err(problem) => Draw.fail(problem)
			}
		},
	)
}
