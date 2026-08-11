use crate::{ByteSource, Error, Fixed, MAX_EXACT_POSITION};

/// Draw an unbiased integer from the inclusive range `start..=end`.
pub fn range(source: &mut impl ByteSource, start: i64, end: i64) -> Result<i64, Error> {
	if start > end {
		return Err(Error::InvalidArgument);
	}
	let span_i128 = i128::from(end) - i128::from(start) + 1;
	if span_i128 <= 0 || span_i128 > i128::from(MAX_EXACT_POSITION) {
		return Err(Error::InvalidArgument);
	}
	let span = u64::try_from(span_i128).map_err(|_| Error::InvalidArgument)?;
	if span <= 1 {
		return Ok(start);
	}
	if span <= 0x1_0000_0000 {
		let universe = 0x1_0000_0000_u64;
		let bound = universe - universe % span;
		loop {
			let draw = u64::from(source.u32_be()?);
			if draw < bound {
				return Ok(start + i64::try_from(draw % span).map_err(|_| Error::Numeric)?);
			}
		}
	}
	let remainder = span.wrapping_neg() % span;
	let exact_divides = remainder == 0;
	let bound = remainder.wrapping_neg();
	loop {
		let draw = source.u64_be()?;
		if exact_divides || draw < bound {
			return Ok(start + i64::try_from(draw % span).map_err(|_| Error::Numeric)?);
		}
	}
}

/// Draw one of the 2^32 evenly spaced fixed values in `[0, 1)`.
pub fn uniform(source: &mut impl ByteSource) -> Result<Fixed, Error> {
	Fixed::from_i64(i64::from(source.u32_be()?)).div(Fixed::from_i64(0x1_0000_0000))
}

fn nonzero_uniform(source: &mut impl ByteSource) -> Result<Fixed, Error> {
	let value = uniform(source)?;
	if value.is_zero() {
		Fixed::from_i64(1).div(Fixed::from_i64(0x1_0000_0000))
	} else {
		Ok(value)
	}
}

/// Draw a normal variate using the integer-only Box–Muller kernel.
pub fn normal(source: &mut impl ByteSource, mean: Fixed, stddev: Fixed) -> Result<Fixed, Error> {
	if !mean.is_valid() || !stddev.is_valid() || stddev.m() <= 0 {
		return Err(Error::InvalidArgument);
	}
	if !mean.exponent_in(-1_000_000, 1_000_000) || !stddev.exponent_in(-1_000_000, 1_000_000) {
		return Err(Error::Numeric);
	}
	let u1 = nonzero_uniform(source)?;
	let u2 = uniform(source)?;
	let radius = Fixed::from_i64(-2).mul(u1.ln()?)?.sqrt()?;
	let z = radius.mul(u2.cos_turns()?)?;
	mean.add(z.mul(stddev)?)
}

/// Draw a range-scaled normal integer, rejecting tails outside `start..=end`.
pub fn normal_int(source: &mut impl ByteSource, start: i64, end: i64) -> Result<i64, Error> {
	if start > end {
		return Err(Error::InvalidArgument);
	}
	let width = i128::from(end) - i128::from(start);
	let width = i64::try_from(width).map_err(|_| Error::InvalidArgument)?;
	let sixth = Fixed::from_i64(width).div(Fixed::from_i64(6))?;
	let half = Fixed::from_i64(width).div(Fixed::from_i64(2))?;
	let million = Fixed::from_i64(1_000_000);
	loop {
		let u1 = Fixed::from_i64(range(source, 1, 1_000_000)?).div(million)?;
		let u2 = Fixed::from_i64(range(source, 1, 1_000_000)?).div(million)?;
		let radius = Fixed::from_i64(-2).mul(u1.ln()?)?.sqrt()?;
		let z = radius.mul(u2.cos_turns()?)?;
		let value = z.mul(sixth)?.add(half)?.add(Fixed::from_i64(start))?;
		let rounded = value.round_to_i64()?;
		if rounded >= start && rounded <= end {
			return Ok(rounded);
		}
	}
}

/// Draw an exponential variate with strictly positive `rate`.
pub fn exponential(source: &mut impl ByteSource, rate: Fixed) -> Result<Fixed, Error> {
	if !rate.is_valid() || rate.m() <= 0 {
		return Err(Error::InvalidArgument);
	}
	if !rate.exponent_in(-1_000_000, 1_000_000) {
		return Err(Error::Numeric);
	}
	nonzero_uniform(source)?.ln()?.neg().div(rate)
}

/// Draw a Poisson variate with strictly positive `lambda`.
pub fn poisson(source: &mut impl ByteSource, lambda: Fixed) -> Result<i64, Error> {
	if !lambda.is_valid() || lambda.m() <= 0 {
		return Err(Error::InvalidArgument);
	}
	if !lambda.exponent_in(-1_000_000, 19) {
		return Err(Error::Numeric);
	}
	let mut sum = Fixed::ZERO;
	let mut count = 0_i64;
	loop {
		sum = sum.add(nonzero_uniform(source)?.ln()?.neg())?;
		if sum.cmp_value(lambda).is_gt() {
			return Ok(count);
		}
		count = count.checked_add(1).ok_or(Error::Numeric)?;
	}
}

/// Draw a log-normal variate with positive `stddev`.
pub fn log_normal(
	source: &mut impl ByteSource,
	mean: Fixed,
	stddev: Fixed,
) -> Result<Fixed, Error> {
	if !mean.is_valid() || !stddev.is_valid() || stddev.m() <= 0 {
		return Err(Error::InvalidArgument);
	}
	if !mean.exponent_in(-1_000_000, 27) || !stddev.exponent_in(-1_000_000, 23) {
		return Err(Error::Numeric);
	}
	let value = normal(source, mean, stddev)?;
	if !value.is_zero() && value.e() > 28 {
		return Err(Error::Numeric);
	}
	value.exp()
}

fn gamma(source: &mut impl ByteSource, alpha: Fixed) -> Result<Fixed, Error> {
	let one = Fixed::from_i64(1);
	if alpha.m() <= 0 {
		return Err(Error::InvalidArgument);
	}
	if alpha.cmp_value(one).is_lt() {
		let u = nonzero_uniform(source)?;
		let g = gamma(source, one.add(alpha)?)?;
		return g.mul(u.pow(one.div(alpha)?)?);
	}
	let third = one.div(Fixed::from_i64(3))?;
	let d = alpha.sub(third)?;
	let scale = one.div(Fixed::from_i64(9).mul(d)?.sqrt()?)?;
	let coefficient = Fixed::from_ratio(331, 10_000)?;
	loop {
		let (x, v) = loop {
			let x = normal(source, Fixed::ZERO, one)?;
			let v = one.add(scale.mul(x)?)?;
			if v.m() > 0 {
				break (x, v);
			}
		};
		let v3 = v.mul(v)?.mul(v)?;
		let u = uniform(source)?;
		let x2 = x.mul(x)?;
		let x4 = x2.mul(x2)?;
		let quick = one.sub(coefficient.mul(x4)?)?;
		if u.cmp_value(quick).is_lt() {
			return d.mul(v3);
		}
		if !u.is_zero() {
			let lhs = u.ln()?;
			let half_x2 = Fixed::from_ratio(1, 2)?.mul(x2)?;
			let correction = one.sub(v3)?.add(v3.ln()?)?;
			let rhs = half_x2.add(d.mul(correction)?)?;
			if lhs.cmp_value(rhs).is_lt() {
				return d.mul(v3);
			}
		}
	}
}

/// Draw a beta variate with strictly positive `alpha` and beta parameter.
pub fn beta(
	source: &mut impl ByteSource,
	alpha: Fixed,
	beta_parameter: Fixed,
) -> Result<Fixed, Error> {
	if !alpha.is_valid() || !beta_parameter.is_valid() || alpha.m() <= 0 || beta_parameter.m() <= 0
	{
		return Err(Error::InvalidArgument);
	}
	if !alpha.exponent_in(-20, 20) || !beta_parameter.exponent_in(-20, 20) {
		return Err(Error::Numeric);
	}
	let x = gamma(source, alpha)?;
	let y = gamma(source, beta_parameter)?;
	x.div(x.add(y)?)
}

#[cfg(test)]
mod tests {
	use super::*;
	use alloc::vec::Vec;

	struct ScriptedSource {
		bytes: Vec<u8>,
		cursor: usize,
		requests: Vec<usize>,
		failure: Option<Error>,
	}

	impl ScriptedSource {
		fn new(bytes: &[u8]) -> Self {
			Self {
				bytes: bytes.to_vec(),
				cursor: 0,
				requests: Vec::new(),
				failure: None,
			}
		}

		fn failing(error: Error) -> Self {
			Self {
				bytes: Vec::new(),
				cursor: 0,
				requests: Vec::new(),
				failure: Some(error),
			}
		}
	}

	impl ByteSource for ScriptedSource {
		fn fill_exact(&mut self, out: &mut [u8]) -> Result<(), Error> {
			self.requests.push(out.len());
			if let Some(error) = self.failure {
				return Err(error);
			}
			let end = self.cursor.checked_add(out.len()).ok_or(Error::Entropy)?;
			let bytes = self.bytes.get(self.cursor..end).ok_or(Error::Entropy)?;
			out.copy_from_slice(bytes);
			self.cursor = end;
			Ok(())
		}
	}

	#[test]
	fn range_boundaries_and_rejection_consumption_are_explicit() {
		let mut empty = ScriptedSource::new(&[]);
		assert_eq!(range(&mut empty, 7, 7), Ok(7));
		assert!(empty.requests.is_empty());
		assert_eq!(range(&mut empty, 8, 7), Err(Error::InvalidArgument));

		let mut narrow = ScriptedSource::new(&[0xff, 0xff, 0xff, 0xff, 0, 0, 0, 5]);
		assert_eq!(range(&mut narrow, 10, 12), Ok(12));
		assert_eq!(narrow.requests, [4, 4]);

		let mut wide = ScriptedSource::new(&[0; 8]);
		assert_eq!(range(&mut wide, 0, 4_294_967_296), Ok(0));
		assert_eq!(wide.requests, [8]);
	}

	#[test]
	fn byte_source_errors_and_invalid_domains_remain_typed() {
		let one = Fixed::from_i64(1);
		let zero = Fixed::ZERO;
		let mut failing = ScriptedSource::failing(Error::Entropy);
		assert_eq!(uniform(&mut failing), Err(Error::Entropy));
		assert_eq!(failing.requests, [4]);

		let mut untouched = ScriptedSource::new(&[]);
		assert_eq!(
			normal(&mut untouched, zero, zero),
			Err(Error::InvalidArgument)
		);
		assert_eq!(
			normal_int(&mut untouched, 2, 1),
			Err(Error::InvalidArgument)
		);
		assert_eq!(
			exponential(&mut untouched, zero),
			Err(Error::InvalidArgument)
		);
		assert_eq!(poisson(&mut untouched, zero), Err(Error::InvalidArgument));
		assert_eq!(
			log_normal(&mut untouched, zero, zero),
			Err(Error::InvalidArgument)
		);
		assert_eq!(beta(&mut untouched, zero, one), Err(Error::InvalidArgument));
		assert!(untouched.requests.is_empty());
	}

	#[test]
	fn sampler_vectors_pin_rust_api_outputs_and_consumption() {
		let mut seed = [0_u8; 32];
		seed[31] = 42;
		let one = Fixed::from_i64(1);
		let two = Fixed::from_i64(2);

		let mut source = crate::Drbg::new(&seed);
		assert_eq!(
			uniform(&mut source).unwrap().parts(),
			(7_629_065_784_144_166_912, -2)
		);
		assert_eq!(source.position(), 4);
		let mut source = crate::Drbg::new(&seed);
		assert_eq!(
			normal(&mut source, Fixed::ZERO, one).unwrap().parts(),
			(-6_261_580_692_471_259_166, -2)
		);
		assert_eq!(source.position(), 8);
		let mut source = crate::Drbg::new(&seed);
		assert_eq!(normal_int(&mut source, -17, 981), Ok(339));
		assert_eq!(source.position(), 8);
		let mut source = crate::Drbg::new(&seed);
		assert_eq!(
			exponential(&mut source, one).unwrap().parts(),
			(8_143_522_549_336_293_876, -1)
		);
		assert_eq!(source.position(), 4);
		let mut source = crate::Drbg::new(&seed);
		assert_eq!(poisson(&mut source, Fixed::from_i64(5)), Ok(5));
		assert_eq!(source.position(), 24);
		let mut source = crate::Drbg::new(&seed);
		assert_eq!(
			log_normal(&mut source, Fixed::ZERO, one).unwrap().parts(),
			(6_568_593_509_554_243_022, -1)
		);
		assert_eq!(source.position(), 8);
		let mut source = crate::Drbg::new(&seed);
		assert_eq!(
			beta(&mut source, two, two).unwrap().parts(),
			(5_240_771_193_768_987_065, -1)
		);
		assert_eq!(source.position(), 24);
	}
}
