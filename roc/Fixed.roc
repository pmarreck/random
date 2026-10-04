# Integer-only software numbers: m * 2^(e-62), canonical |m| in [2^62,2^63).
Fixed :: { m : I64, e : I32 }.{
	zero : Fixed
	zero = { m: 0, e: 0 }

	power_of_two : I32 -> Fixed
	power_of_two = |exponent| { m: 4611686018427387904, e: exponent }

	from_parts : I64, I32 -> Try(Fixed, [Invalid])
	from_parts = |m, e| {
		value : Fixed
		value = { m, e }
		if valid(value) Ok(value) else Err(Invalid)
	}

	from_int : I64 -> Fixed
	from_int = |value| {
		if value == 0 {
			zero
		} else {
			parts = normalize_parts(value.to_i128(), 62)
			# An i64 normalizes to an exponent between zero and 63.
			{ m: parts.0, e: parts.1.to_i32_wrap() }
		}
	}

	parts : Fixed -> (I64, I32)
	parts = |value| (value.m, value.e)

	is_valid : Fixed -> Bool
	is_valid = valid

	is_zero : Fixed -> Bool
	is_zero = |value| value.m == 0

	is_eq : Fixed, Fixed -> Bool
	is_eq = |a, b| a.m == b.m and a.e == b.e

	neg : Fixed -> Fixed
	neg = |value| if value.m == 0 zero else { m: -value.m, e: value.e }

	add : Fixed, Fixed -> Try(Fixed, [Invalid, Numeric])
	add = |a, b| {
		if !valid(a) or !valid(b) {
			Err(Invalid)
		} else if a.m == 0 {
			Ok(b)
		} else if b.m == 0 {
			Ok(a)
		} else {
			(x, y) = if a.e < b.e (b, a) else (a, b)
			distance = x.e.to_i64() - y.e.to_i64()
			if distance >= 63 {
				Ok(x)
			} else {
				divisor = I64.shl_wrap(1, distance.to_u8_wrap())
				shifted = y.m.div_trunc_by(divisor)
				if shifted == 0 {
					Ok(x)
				} else if (x.m < 0) == (shifted < 0) {
					normalize((x.m.div_trunc_by(2) + shifted.div_trunc_by(2)).to_i128(), x.e.to_i64() + 1)
				} else {
					normalize((x.m + shifted).to_i128(), x.e.to_i64())
				}
			}
		}
	}

	sub : Fixed, Fixed -> Try(Fixed, [Invalid, Numeric])
	sub = |a, b| add(a, neg(b))

	mul : Fixed, Fixed -> Try(Fixed, [Invalid, Numeric])
	mul = |a, b| {
		if !valid(a) or !valid(b) {
			Err(Invalid)
		} else if a.m == 0 or b.m == 0 {
			Ok(zero)
		} else {
			product = magnitude(a.m) * magnitude(b.m)
			(shift, exponent) = if product >= U128.shl_wrap(1, 125) {
				(63, a.e.to_i64() + b.e.to_i64() + 1)
			} else {
				(62, a.e.to_i64() + b.e.to_i64())
			}
			mantissa = product.shr_wrap(shift).to_i128_wrap()
			normalize(if (a.m < 0) != (b.m < 0) -mantissa else mantissa, exponent)
		}
	}

	div : Fixed, Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
	div = |a, b| {
		if !valid(a) or !valid(b) {
			Err(Invalid)
		} else if b.m == 0 {
			Err(DivisionByZero)
		} else if a.m == 0 {
			Ok(zero)
		} else {
			quotient = magnitude(a.m).shl_wrap(62).div_by(magnitude(b.m)).to_i128_wrap()
			normalize(if (a.m < 0) != (b.m < 0) -quotient else quotient, a.e.to_i64() - b.e.to_i64())
		}
	}

	to_int_trunc : Fixed -> I64
	to_int_trunc = |value| {
		if value.m == 0 {
			0
		} else if value.e >= 62 {
			if value.m < 0 -9007199254740992 else 9007199254740992
		} else if value.e < 0 {
			0
		} else {
			amount = 62 - value.e
			quotient = value.m.div_trunc_by(I64.shl_wrap(1, amount.to_u8_wrap()))
			if quotient > 9007199254740992 9007199254740992
			else if quotient < -9007199254740992 -9007199254740992
			else quotient
		}
	}

	compare : Fixed, Fixed -> I64
	compare = |a, b| {
		sa = sign(a.m)
		sb = sign(b.m)
		if sa != sb {
			if sa < sb -1 else 1
		} else if sa == 0 {
			0
		} else if a.e != b.e {
			(if a.e < b.e -1 else 1) * sa
		} else if a.m == b.m {
			0
		} else if a.m < b.m {
			-1
		} else {
			1
		}
	}

	frac : Fixed -> Try(Fixed, [Invalid, Numeric])
	frac = |value| {
		integer = to_int_trunc(value)
		if integer == 0 Ok(value) else sub(value, from_int(integer))
	}

	round_to_int : Fixed -> Try(I64, [Invalid, Numeric])
	round_to_int = |value| {
		half : Fixed
		half = { m: 4611686018427387904, e: -1 }
		adjusted = if value.m < 0 sub(value, half)? else add(value, half)?
		Ok(to_int_trunc(adjusted))
	}

	ln : Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
	ln = |value| {
		if value.m <= 0 or !valid(value) {
			Err(Invalid)
		} else {
			fraction : Fixed
			fraction = { m: value.m, e: 0 }
			one = from_int(1)
			t = sub(fraction, one)?.div(add(fraction, one)?)?
			t2 = mul(t, t)?
			var $term = t
			var $accumulator = t
			for n in 1..=20 {
				$term = mul($term, t2)?
				reciprocal = div(one, from_int(2 * n + 1))?
				$accumulator = add($accumulator, mul($term, reciprocal)?)?
			}
			logarithm = add($accumulator, $accumulator)?
			if value.e == 0 Ok(logarithm)
			else add(logarithm, mul(ln2, from_int(value.e.to_i64()))?)
		}
	}

	exp : Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
	exp = |value| {
		if value.m == 0 {
			Ok(from_int(1))
		} else {
			candidate = div(value, ln2)?.to_int_trunc()
			(k, remainder) = correct_exp(value, candidate, 3)?
			one = from_int(1)
			var $accumulator = one
			var $power = one
			var $factorial = one
			var $n = 1.I64
			var $done = Bool.False
			while $n <= 16 and !$done {
				$factorial = mul($factorial, from_int($n))?
				reciprocal = div(one, $factorial)?
				$power = mul($power, remainder)?
				contribution = mul($power, reciprocal)?
				if contribution.m == 0 {
					$done = Bool.True
				} else {
					$accumulator = add($accumulator, contribution)?
				}
				$n = $n + 1
			}
			normalize($accumulator.m.to_i128(), $accumulator.e.to_i64() + k)
		}
	}

	cos_turns : Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
	cos_turns = |value| {
		if value.m == 0 {
			Ok(from_int(1))
		} else {
			fraction = frac(value)?
			wrapped = if fraction.m < 0 add(fraction, from_int(1))? else fraction
			quadrant_value = mul(wrapped, from_int(4))?
			quadrant = to_int_trunc(quadrant_value)
			within = sub(quadrant_value, from_int(quadrant))?
			angle = mul(within, pi_over_two)?
			if quadrant == 0 cos_radians(angle)
			else if quadrant == 1 Ok(sin_radians(angle)?.neg())
			else if quadrant == 2 Ok(cos_radians(angle)?.neg())
			else sin_radians(angle)
		}
	}

	sqrt : Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
	sqrt = |value| {
		if value.m < 0 or !valid(value) {
			Err(Invalid)
		} else if value.m == 0 {
			Ok(zero)
		} else {
			(mantissa, exponent) = if value.e.rem_by(2) != 0 {
				(value.m.div_trunc_by(2), value.e.to_i64() + 1)
			} else {
				(value.m, value.e.to_i64())
			}
			var $estimate = 4294967296.U64
			var $n = 0.U64
			var $done = Bool.False
			while $n < 40 and !$done {
				next = ($estimate + mantissa.to_u64_wrap().div_by($estimate)).div_by(2)
				$done = next == $estimate
				$estimate = next
				$n = $n + 1
			}
			var $result = normalize($estimate.to_i128(), exponent.div_trunc_by(2) + 31)?
			for _n in 0..<3 {
				sum = add($result, div(value, $result)?)?
				$result = normalize(sum.m.to_i128(), sum.e.to_i64() - 1)?
			}
			Ok($result)
		}
	}

	pow : Fixed, Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
	pow = |base, exponent| {
		if base.m <= 0 Err(Invalid) else mul(exponent, ln(base)?)?.exp()
	}
}

ln2 : Fixed
ln2 = { m: 6393154322601327829, e: -1 }

pi_over_two : Fixed
pi_over_two = { m: 7244019458077122842, e: 0 }

correct_exp : Fixed, I64, U64 -> Try((I64, Fixed), [Invalid, Numeric, DivisionByZero])
correct_exp = |value, candidate, remaining| {
	remainder = value.sub(ln2.mul(Fixed.from_int(candidate))?)?
	half_ln2 : Fixed
	half_ln2 = { m: ln2.m, e: ln2.e - 1 }
	if remainder.compare(half_ln2) > 0 {
		if remaining == 0 Err(Numeric) else correct_exp(value, candidate + 1, remaining - 1)
	} else if remainder.compare(half_ln2.neg()) < 0 {
		if remaining == 0 Err(Numeric) else correct_exp(value, candidate - 1, remaining - 1)
	} else {
		Ok((candidate, remainder))
	}
}

cos_radians : Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
cos_radians = |angle| {
	squared = angle.mul(angle)?
	var $term = Fixed.from_int(1)
	var $accumulator = $term
	for n in 1..=14 {
		reciprocal = Fixed.from_int(1).div(Fixed.from_int((2 * n - 1) * (2 * n)))?
		$term = $term.mul(squared)?.mul(reciprocal)?.neg()
		$accumulator = $accumulator.add($term)?
	}
	Ok($accumulator)
}

sin_radians : Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
sin_radians = |angle| {
	squared = angle.mul(angle)?
	var $term = angle
	var $accumulator = angle
	for n in 1..=14 {
		reciprocal = Fixed.from_int(1).div(Fixed.from_int((2 * n) * (2 * n + 1)))?
		$term = $term.mul(squared)?.mul(reciprocal)?.neg()
		$accumulator = $accumulator.add($term)?
	}
	Ok($accumulator)
}

magnitude : I64 -> U128
magnitude = |value| {
	wide = value.to_i128()
	(if wide < 0 -wide else wide).to_u128_wrap()
}

sign : I64 -> I64
sign = |value| if value == 0 0 else if value < 0 -1 else 1

valid : Fixed -> Bool
valid = |value| {
	if value.m == 0 {
		value.e == 0
	} else {
		mag = magnitude(value.m)
		mag >= 4611686018427387904 and mag < 9223372036854775808
	}
}

normalize_parts : I128, I64 -> (I64, I64)
normalize_parts = |mantissa, exponent| {
	if mantissa == 0 {
		(0, 0)
	} else {
		var $mag = (if mantissa < 0 -mantissa else mantissa).to_u128_wrap()
		var $exponent = exponent
		while $mag < 4611686018427387904 {
			$mag = $mag.shl_wrap(1)
			$exponent = $exponent - 1
		}
		while $mag >= 9223372036854775808 {
			$mag = $mag.shr_wrap(1)
			$exponent = $exponent + 1
		}
		m = $mag.to_i64_wrap()
		(if mantissa < 0 -m else m, $exponent)
	}
}

normalize : I128, I64 -> Try(Fixed, [Numeric])
normalize = |mantissa, exponent| {
	(m, e) = normalize_parts(mantissa, exponent)
	if e < -2147483648 or e > 2147483647 {
		Err(Numeric)
	} else {
		Ok({ m, e: e.to_i32_wrap() })
	}
}
