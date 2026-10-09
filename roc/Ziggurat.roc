import Fixed
import Draw
import ZigguratTables

# Pure byte-request program: no ambient entropy, spare cache or host floats.
Ziggurat :: [].{
	normal : () -> Draw(Fixed)
	normal = || word().and_then(
		|header| {
			index = header.bitwise_and(255)
			negative = header.bitwise_and(256) != 0
			coordinate = header.shr_wrap(9)
			match rectangle(index, coordinate) {
				Err(problem) => Draw.fail(problem)
				Ok((x, low, k)) => if coordinate < k Draw.succeed(signed(negative, x))
				else if index == 0 tail(negative)
				else word().and_then(
					|vertical| {
						match wedge(index, x, low, vertical.shr_wrap(9)) {
							Err(problem) => Draw.fail(problem)
							Ok(accepted) => if accepted Draw.succeed(signed(negative, x))
							else normal()
						}
					},
				)
			}
		},
	)
}

word : () -> Draw(U64)
word = || Draw.read(8).and_then(
	|bytes| {
		var $value = 0.U64
		for byte in bytes {
			$value = $value.shl_wrap(8).bitwise_or(byte.to_u64())
		}
		Draw.succeed($value)
	},
)

unit : U64 -> Try(Fixed, [Invalid, Numeric])
unit = |n| Fixed.from_int(n.to_i64_wrap()).mul(Fixed.power_of_two(-55))

signed : Bool, Fixed -> Fixed
signed = |negative, x| if negative x.neg() else x

strip : U64 -> Try((Fixed, Fixed, U64), [Invalid])
strip = |index| {
	match ZigguratTables.strips.get(index) {
		Err(OutOfBounds) => Err(Invalid)
		Ok((xm, xe, ym, ye, k)) => Ok((Fixed.from_parts(xm, xe)?, Fixed.from_parts(ym, ye)?, k))
	}
}

rectangle : U64, U64 -> Try((Fixed, Fixed, U64), [Invalid, Numeric])
rectangle = |index, coordinate| {
	(x, y, k) = strip(index)?
	Ok((unit(coordinate)?.mul(x)?, y, k))
}

wedge : U64, Fixed, Fixed, U64 -> Try(Bool, [Invalid, Numeric, DivisionByZero])
wedge = |index, x, low, coordinate| {
	upper = if index == 255 Fixed.from_int(1) else strip(index + 1)?.1
	y = low.add(unit(coordinate)?.mul(upper.sub(low)?)?)?
	square = x.mul(x)?.neg()
	(m, e) = square.parts()
	exponent = if m == 0 square else Fixed.from_parts(m, e - 1)?
	Ok(y.compare(exponent.exp()?) < 0)
}

tail_value : U64, U64 -> Try((Fixed, Bool), [Invalid, Numeric, DivisionByZero])
tail_value = |first, second| {
	(r, _, _) = strip(1)?
	t = unit(first.shr_wrap(9) + 1)?.ln()?.neg().div(r)?
	y = unit(second.shr_wrap(9) + 1)?.ln()?.neg()
	Ok((r.add(t)?, y.add(y)?.compare(t.mul(t)?) >= 0))
}

# Tail retries retain the selected sign; failed wedges instead reselect above.
tail : Bool -> Draw(Fixed)
tail = |negative| word().and_then(
	|first| word().and_then(
		|second| {
			match tail_value(first, second) {
				Err(problem) => Draw.fail(problem)
				Ok((value, accepted)) => if accepted Draw.succeed(signed(negative, value))
				else tail(negative)
			}
		},
	),
)
