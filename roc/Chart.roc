import Fixed
import Geometric

# Canonical chart geometry: integer relative heights, exact axis bounds and
# a stem-rendering hint. Terminal, pixels and encodings live elsewhere.
Chart :: { heights : List(U16), x_min : Fixed, x_max : Fixed, discrete : Bool }.{
	Kind := [Normal, Exponential, Poisson, Geometric, LogNormal, Beta]

	heights : Chart -> List(U16)
	heights = |model| model.heights

	bounds : Chart -> (Fixed, Fixed)
	bounds = |model| (model.x_min, model.x_max)

	discrete : Chart -> Bool
	# True for uncompressed Poisson stems, not a classification of the law;
	# the shared view draws geometric and compressed Poisson samples as lines.
	discrete = |model| model.discrete

	is_eq : Chart, Chart -> Bool
	is_eq = |a, b| a.heights == b.heights and a.x_min.is_eq(b.x_min) and
		a.x_max.is_eq(b.x_max) and a.discrete == b.discrete

	sample : Kind, Fixed, Fixed, U64 -> Try(Chart, [Invalid, Numeric, DivisionByZero])
	sample = |kind, first, second, capacity| {
		if !first.is_valid() or !second.is_valid() or capacity < 2 or capacity > 4096 {
			return Err(Invalid)
		}
		match kind {
			Normal => {
				check_parameter(first, -1000000, 1000000, Bool.False)?
				check_parameter(second, -1000000, 1000000, Bool.True)?
				normal(first, second, capacity)
			}
			Exponential => {
				if !second.is_zero() return Err(Invalid)
				check_parameter(first, -1000000, 1000000, Bool.True)?
				exponential(first, capacity)
			}
			Poisson => {
				if !second.is_zero() return Err(Invalid)
				check_parameter(first, -1000000, 19, Bool.True)?
				poisson(first, capacity)
			}
			Geometric => {
				if !second.is_zero() return Err(Invalid)
				_ = Geometric.new(first)?
				geometric(first, capacity)
			}
			LogNormal => {
				check_parameter(first, -1000000, 27, Bool.False)?
				check_parameter(second, -1000000, 23, Bool.True)?
				log_normal(first, second, capacity)
			}
			Beta => {
				check_parameter(first, -20, 20, Bool.True)?
				check_parameter(second, -20, 20, Bool.True)?
				beta(first, second, capacity)
			}
		}
	}
}

one : Fixed
one = Fixed.from_int(1)

two : Fixed
two = Fixed.from_int(2)

six : Fixed
six = Fixed.from_int(6)

check_parameter : Fixed, I32, I32, Bool -> Try({}, [Invalid, Numeric])
check_parameter = |value, minimum, maximum, positive| {
	(m, e) = value.parts()
	if positive and m <= 0 Err(Invalid)
	else if m != 0 and (e < minimum or e > maximum) Err(Numeric)
	else Ok({})
}

fraction : U64, U64 -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
fraction = |index, denominator| Fixed.from_int(index.to_i64_wrap()).div(Fixed.from_int(denominator.to_i64_wrap()))

height : Fixed -> Try(U16, [Invalid, Numeric])
height = |value| {
	(m, _) = value.parts()
	if m <= 0 Ok(0)
	else if value.compare(one) >= 0 Ok(65535)
		else {
			integer = value.mul(Fixed.from_int(65535))?.to_int_trunc()
			Ok(if integer <= 0 0 else if integer >= 65535 65535 else integer.to_u16_wrap())
		}
}

relative : Fixed, Fixed -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
relative = |score, maximum| {
	difference = score.sub(maximum)?
	(m, _) = difference.parts()
	if m >= 0 Ok(one)
	else if difference.compare(Fixed.from_int(-64)) < 0 Ok(Fixed.zero)
	else difference.exp()
}

normal : Fixed, Fixed, U64 -> Try(Chart, [Invalid, Numeric, DivisionByZero])
normal = |mean, stddev, count| {
	four = Fixed.from_int(4)
	spread = four.mul(stddev)?
	var $heights = []
	for index in 0..<count {
		z = Fixed.from_int(8).mul(fraction(index, count - 1)?)?.sub(four)?
		score = z.mul(z)?.div(two)?.neg()
		$heights = $heights.append(height(score.exp()?)?)
	}
	Ok({ heights: $heights, x_min: mean.sub(spread)?, x_max: mean.add(spread)?, discrete: Bool.False })
}

exponential : Fixed, U64 -> Try(Chart, [Invalid, Numeric, DivisionByZero])
exponential = |rate, count| {
	var $heights = []
	for index in 0..<count {
		score = six.mul(fraction(index, count - 1)?)?.neg()
		$heights = $heights.append(height(score.exp()?)?)
	}
	Ok({ heights: $heights, x_min: Fixed.zero, x_max: six.div(rate)?, discrete: Bool.False })
}

poisson : Fixed, U64 -> Try(Chart, [Invalid, Numeric, DivisionByZero])
poisson = |lambda, capacity| {
	mode = lambda.to_int_trunc()
	radius = six.mul(lambda.sqrt()?)?.to_int_trunc() + 1
	minimum = if mode < radius 0 else mode - radius
	maximum = mode + radius
	integer_count = (maximum - minimum + 1).to_u64_wrap()
	count = if integer_count < capacity integer_count else capacity
	var $probability = one
	var $current = mode
	while $current > minimum {
		$probability = $probability.mul(Fixed.from_int($current).div(lambda)?)?
		$current = $current - 1
	}
	span = (maximum - minimum).to_u64_wrap()
	denominator = count - 1
	var $heights = []
	for index in 0..<count {
		numerator = index * span + denominator.div_by(2)
		target = minimum + numerator.div_by(denominator).to_i64_wrap()
		while $current < target {
			$current = $current + 1
			$probability = $probability.mul(lambda.div(Fixed.from_int($current))?)?
		}
		$heights = $heights.append(height($probability)?)
	}
	Ok({ heights: $heights, x_min: Fixed.from_int(minimum), x_max: Fixed.from_int(maximum), discrete: integer_count <= capacity })
}

geometric : Fixed, U64 -> Try(Chart, [Invalid, Numeric, DivisionByZero])
geometric = |p, count| {
	maximum = six.div(p)?
	(_, pe) = p.parts()
	certain = p.is_eq(one)
	log_survival = if certain {
		Fixed.zero
	} else if pe < -4 {
		# Eight log1p terms preserve tiny probabilities without 1-p cancellation.
		var $power = p
		var $sum = p
		for n in 2..=8 {
			$power = $power.mul(p)?
			$sum = $sum.add($power.div(Fixed.from_int(n))?)?
		}
		$sum.neg()
	} else {
		one.sub(p)?.ln()?
	}
	var $heights = []
	for index in 0..<count {
		x = maximum.mul(fraction(index, count - 1)?)?
		(xm, xe) = x.parts()
		k = if xe < 0 Fixed.zero else if xe < 62 {
			Fixed.from_int(xm.shr_wrap((62 - xe).to_u8_wrap()))
		} else x
		value = if certain {
			if k.is_zero() 65535.U16 else 0.U16
		} else height(log_survival.mul(k)?.exp()?)?
		$heights = $heights.append(value)
	}
	Ok({ heights: $heights, x_min: Fixed.zero, x_max: maximum, discrete: Bool.False })
}

log_normal_score : Fixed, Fixed, U64, U64 -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
log_normal_score = |sigma_squared, scaled, index, denominator| {
	x = scaled.mul(fraction(index, denominator)?)?
	shifted = x.ln()?.add(sigma_squared)?
	Ok(shifted.mul(shifted)?.div(two.mul(sigma_squared)?)?.neg())
}

log_normal : Fixed, Fixed, U64 -> Try(Chart, [Invalid, Numeric, DivisionByZero])
log_normal = |mean, stddev, count| {
	unbounded = stddev.mul(Fixed.from_int(13))?.div(Fixed.from_int(8))?
	twenty = Fixed.from_int(20)
	span = if unbounded.compare(twenty) < 0 unbounded else twenty
	scaled = span.exp()?
	sigma_squared = stddev.mul(stddev)?
	var $scores = []
	for index in 1..<count {
		$scores = $scores.append(log_normal_score(sigma_squared, scaled, index, count - 1)?)
	}
	maximum = maximum_score($scores)?
	var $heights = [0.U16]
	for score in $scores {
		$heights = $heights.append(height(relative(score, maximum)?)?)
	}
	Ok({ heights: $heights, x_min: Fixed.zero, x_max: mean.add(span)?.exp()?, discrete: Bool.False })
}

beta_score : Fixed, Fixed, U64, U64 -> Try(Fixed, [Invalid, Numeric, DivisionByZero])
beta_score = |alpha_minus_one, beta_minus_one, index, count| {
	x = fraction(2 * index + 1, 2 * count)?
	first = alpha_minus_one.mul(x.ln()?)?
	second = beta_minus_one.mul(one.sub(x)?.ln()?)?
	first.add(second)
}

maximum_score : List(Fixed) -> Try(Fixed, [Numeric])
maximum_score = |scores| {
	var $maximum = match scores.first() {
		Ok(value) => value
		Err(_) => return Err(Numeric)
	}
	for score in scores {
		if score.compare($maximum) > 0 {
			$maximum = score
		}
	}
	Ok($maximum)
}

beta : Fixed, Fixed, U64 -> Try(Chart, [Invalid, Numeric, DivisionByZero])
beta = |alpha, beta_shape, count| {
	a = alpha.sub(one)?
	b = beta_shape.sub(one)?
	var $scores = []
	for index in 0..<count {
		$scores = $scores.append(beta_score(a, b, index, count)?)
	}
	maximum = maximum_score($scores)?
	var $heights = []
	for score in $scores {
		$heights = $heights.append(height(relative(score, maximum)?)?)
	}
	Ok({ heights: $heights, x_min: Fixed.zero, x_max: one, discrete: Bool.False })
}
