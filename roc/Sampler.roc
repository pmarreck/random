import Fixed
import Draw

# One pure byte-request program per algorithm, shared by deterministic and
# entropy interpreters. All parameter checks happen before requesting bytes.
Sampler :: [].{
	uniform : () -> Draw(Fixed)
	uniform = || Draw.read(4).and_then(
		|bytes| {
			value = big_endian(bytes)
			Draw.from_try(Fixed.from_int(value.to_i64_wrap()).div(Fixed.from_int(4294967296)))
		},
	)

	range : I64, I64 -> Draw(I64)
	range = |first, last| {
		if first < -9007199254740992 or first > 9007199254740992 or
			last < -9007199254740992 or last > 9007199254740992 or last < first {
			Draw.fail(Invalid)
		} else {
			span = last.to_i128() - first.to_i128() + 1
			if span > 9007199254740992 Draw.fail(Invalid)
			else if span == 1 Draw.succeed(first)
			else range_loop(first, span.to_u64_wrap())
		}
	}

	normal : Fixed, Fixed -> Draw(Fixed)
	normal = |mean, stddev| {
		match parameters(mean, stddev, -1000000, 1000000, -1000000, 1000000, Bool.False, Bool.True) {
			Err(problem) => Draw.fail(problem)
			Ok(_) => {
				uniform().and_then(|u1| uniform().and_then(|u2|
					Draw.from_try(normal_value(mean, stddev, u1, u2))))
			}
		}
	}

	normal_int : I64, I64 -> Draw(I64)
	normal_int = |first, last| {
		if first < -9007199254740992 or first > 9007199254740992 or
			last < -9007199254740992 or last > 9007199254740992 or last < first or
				last.to_i128() - first.to_i128() >= 9007199254740992 {
			Draw.fail(Invalid)
		} else {
			normal_int_loop(first, last)
		}
	}

	exponential : Fixed -> Draw(Fixed)
	exponential = |rate| {
		match parameters(rate, Fixed.zero, -1000000, 1000000, 0, 0, Bool.True, Bool.False) {
			Err(problem) => Draw.fail(problem)
			Ok(_) => uniform().and_then(|u| Draw.from_try(exponential_value(rate, u)))
		}
	}

	poisson : Fixed -> Draw(I64)
	poisson = |lambda| {
		match parameters(lambda, Fixed.zero, -1000000, 19, 0, 0, Bool.True, Bool.False) {
			Err(problem) => Draw.fail(problem)
			Ok(_) => poisson_loop(lambda, Fixed.zero, 0)
		}
	}

	log_normal : Fixed, Fixed -> Draw(Fixed)
	log_normal = |mean, stddev| {
		match parameters(mean, stddev, -1000000, 27, -1000000, 23, Bool.False, Bool.True) {
			Err(problem) => Draw.fail(problem)
			Ok(_) => normal(mean, stddev).and_then(|value| Draw.from_try(value.exp()))
		}
	}

	# Gamma is already needed internally by beta; CLI exposure is a separate
	# planned feature and is not implied by this library method.
	gamma : Fixed -> Draw(Fixed)
	gamma = |alpha| {
		match parameters(alpha, Fixed.zero, -20, 20, 0, 0, Bool.True, Bool.False) {
			Err(problem) => Draw.fail(problem)
			Ok(_) => if alpha.compare(one) < 0 {
				uniform().and_then(
					|u| {
						match one.add(alpha) {
							Err(problem) => Draw.fail(problem)
							Ok(larger) => gamma(larger).and_then(|value|
								Draw.from_try(gamma_small(alpha, value, nonzero(u))))
						}
					},
				)
			} else {
				match gamma_parameters(alpha) {
					Ok((d, c)) => gamma_loop(d, c)
					Err(problem) => Draw.fail(problem)
				}
			}
		}
	}

	beta : Fixed, Fixed -> Draw(Fixed)
	beta = |alpha, beta_shape| {
		match parameters(alpha, beta_shape, -20, 20, -20, 20, Bool.True, Bool.True) {
			Err(problem) => Draw.fail(problem)
			Ok(_) => gamma(alpha).and_then(|x| gamma(beta_shape).and_then(|y|
				Draw.from_try(beta_value(x, y))))
		}
	}
}

one : Fixed
one = Fixed.from_int(1)

parameters : Fixed, Fixed, I32, I32, I32, I32, Bool, Bool -> Try({}, [Invalid, Numeric])
parameters = |a, b, low_a, high_a, low_b, high_b, positive_a, positive_b| {
	(am, ae) = a.parts()
	(bm, be) = b.parts()
	if !a.is_valid() or !b.is_valid() or (positive_a and am <= 0) or (positive_b and bm <= 0) {
		Err(Invalid)
	} else if (am != 0 and (ae < low_a or ae > high_a)) or
		(bm != 0 and (be < low_b or be > high_b)) {
		Err(Numeric)
	} else Ok({})
}

nonzero : Fixed -> Fixed
nonzero = |value| {
	if value.is_zero() Fixed.power_of_two(-32)
	else value
}

big_endian : List(U8) -> U64
big_endian = |bytes| {
	var $value = 0.U64
	for byte in bytes {
		$value = $value.shl_wrap(8).bitwise_or(byte.to_u64())
	}
	$value
}

range_loop : I64, U64 -> Draw(I64)
range_loop = |first, span| {
	if span <= 4294967296 {
		bound = 4294967296.U64 - (4294967296.U64).rem_by(span)
		Draw.read(4).and_then(
			|bytes| {
				value = big_endian(bytes)
				if value < bound Draw.succeed(first + value.rem_by(span).to_i64_wrap())
				else range_loop(first, span)
			},
		)
	} else {
		remainder = U64.minus_wrap(0, span).rem_by(span)
		bound = U64.minus_wrap(0, remainder)
		Draw.read(8).and_then(
			|bytes| {
				value = big_endian(bytes)
				if remainder == 0 or value < bound Draw.succeed(first + value.rem_by(span).to_i64_wrap())
				else range_loop(first, span)
			},
		)
	}
}

normal_value : Fixed, Fixed, Fixed, Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
normal_value = |mean, stddev, u1, u2| {
	logarithm = nonzero(u1).ln()?
	radial = Fixed.from_int(-2).mul(logarithm)?.sqrt()?
	cosine = u2.cos_turns()?
	standard = radial.mul(cosine)?
	mean.add(standard.mul(stddev)?)
}

normal_int_value : I64, I64, I64, I64 -> Try(I64, [Invalid, Numeric, DivisionByZero])
normal_int_value = |first, last, n1, n2| {
	million = Fixed.from_int(1000000)
	u1 = Fixed.from_int(n1).div(million)?
	u2 = Fixed.from_int(n2).div(million)?
	standard = normal_value(Fixed.zero, one, u1, u2)?
	width = Fixed.from_int(last - first)
	sixth = width.div(Fixed.from_int(6))?
	half = width.div(Fixed.from_int(2))?
	standard.mul(sixth)?.add(half)?.add(Fixed.from_int(first))?.round_to_int()
}

normal_int_loop : I64, I64 -> Draw(I64)
normal_int_loop = |first, last| {
	Sampler.range(1, 1000000).and_then(
		|n1| Sampler.range(1, 1000000).and_then(
			|n2| {
				match normal_int_value(first, last, n1, n2) {
					Err(problem) => Draw.fail(problem)
					Ok(value) => if value >= first and value <= last Draw.succeed(value)
					else normal_int_loop(first, last)
				}
			},
		),
	)
}

exponential_value : Fixed, Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
exponential_value = |rate, u| nonzero(u).ln()?.neg().div(rate)

poisson_loop : Fixed, Fixed, I64 -> Draw(I64)
poisson_loop = |lambda, sum, count| {
	Sampler.uniform().and_then(
		|u| {
			match poisson_sum(sum, u) {
				Err(problem) => Draw.fail(problem)
				Ok(total) => if total.compare(lambda) > 0 Draw.succeed(count)
				else if count >= 9007199254740992 Draw.fail(Numeric)
				else poisson_loop(lambda, total, count + 1)
			}
		},
	)
}

poisson_sum : Fixed, Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
poisson_sum = |sum, u| sum.add(nonzero(u).ln()?.neg())

gamma_parameters : Fixed -> Try((Fixed, Fixed), [Invalid, Numeric, DivisionByZero])
gamma_parameters = |alpha| {
	third = one.div(Fixed.from_int(3))?
	d = alpha.sub(third)?
	c = one.div(Fixed.from_int(9).mul(d)?.sqrt()?)?
	Ok((d, c))
}

gamma_small : Fixed, Fixed, Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
gamma_small = |alpha, value, u| {
	inverse = one.div(alpha)?
	value.mul(u.pow(inverse)?)
}

beta_value : Fixed, Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
beta_value = |x, y| x.div(x.add(y)?)

gamma_loop : Fixed, Fixed -> Draw(Fixed)
gamma_loop = |d, c| {
	Sampler.normal(Fixed.zero, one).and_then(
		|x| {
			match gamma_v(c, x) {
				Err(problem) => Draw.fail(problem)
				Ok(v) => if v.compare(Fixed.zero) <= 0 {
					gamma_loop(d, c)
				} else {
					Sampler.uniform().and_then(
						|u| {
							match gamma_accept(d, x, v, u) {
								Err(problem) => Draw.fail(problem)
								Ok(Accept(value)) => Draw.succeed(value)
								Ok(Retry) => gamma_loop(d, c)
							}
						},
					)
				}
			}
		},
	)
}

gamma_v : Fixed, Fixed -> Try(Fixed, [Invalid, Numeric])
gamma_v = |c, x| one.add(c.mul(x)?)

gamma_accept : Fixed, Fixed, Fixed, Fixed -> Try([Accept(Fixed), Retry], [Invalid, Numeric, DivisionByZero])
gamma_accept = |d, x, v, u| {
	v3 = v.mul(v)?.mul(v)?
	x2 = x.mul(x)?
	x4 = x2.mul(x2)?
	c0331 = Fixed.from_parts(4884697830718289267, -5)?
	bound = one.sub(c0331.mul(x4)?)?
	if u.compare(bound) < 0 {
		Ok(Accept(d.mul(v3)?))
	} else if u.is_zero() {
		Ok(Retry)
	} else {
		lu = u.ln()?
		lv = v3.ln()?
		half = Fixed.from_parts(4611686018427387904, -1)?
		t2 = one.sub(v3)?.add(lv)?
		right = half.mul(x2)?.add(d.mul(t2)?)?
		if lu.compare(right) < 0 Ok(Accept(d.mul(v3)?)) else Ok(Retry)
	}
}
