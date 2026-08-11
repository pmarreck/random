use alloc::vec;
use alloc::vec::Vec;
use core::cmp::Ordering;

use crate::{Error, Fixed};

const MAX_SAMPLES: usize = 4096;
const HEIGHT_MAX: i64 = u16::MAX as i64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
/// Alternate distribution supported by the deterministic core.
#[non_exhaustive]
pub enum Distribution {
	/// Normal (Gaussian) density.
	Normal,
	/// Exponential density.
	Exponential,
	/// Poisson probability mass.
	Poisson,
	/// Log-normal density.
	LogNormal,
	/// Beta density.
	Beta,
}

#[derive(Clone, Debug, Eq, PartialEq)]
/// Integer-normalized samples suitable for frontend chart rendering.
pub struct Curve {
	/// Relative heights in the inclusive range `0..=u16::MAX`.
	pub heights: Vec<u16>,
	/// Left endpoint represented by the first height.
	pub x_min: Fixed,
	/// Right endpoint represented by the last height.
	pub x_max: Fixed,
}

impl Curve {
	/// Sample a normalized curve at `count` evenly spaced positions.
	///
	/// `first` and `second` are distribution-specific parameters in the same
	/// order as the matching sampler. `count` must be in `2..=4096`.
	pub fn sample(
		distribution: Distribution,
		first: Fixed,
		second: Fixed,
		count: usize,
	) -> Result<Self, Error> {
		if !first.is_valid() || !second.is_valid() || !(2..=MAX_SAMPLES).contains(&count) {
			return Err(Error::InvalidArgument);
		}
		match distribution {
			Distribution::Normal => normal_curve(first, second, count),
			Distribution::Exponential => {
				require_positive(first, -1_000_000, 1_000_000)?;
				if !second.is_zero() {
					return Err(Error::InvalidArgument);
				}
				exponential_curve(first, count)
			}
			Distribution::Poisson => {
				require_positive(first, -1_000_000, 19)?;
				if !second.is_zero() {
					return Err(Error::InvalidArgument);
				}
				poisson_curve(first, count)
			}
			Distribution::LogNormal => log_normal_curve(first, second, count),
			Distribution::Beta => beta_curve(first, second, count),
		}
	}
}

fn require_positive(value: Fixed, minimum: i32, maximum: i32) -> Result<(), Error> {
	if value.m() <= 0 {
		Err(Error::InvalidArgument)
	} else if !value.exponent_in(minimum, maximum) {
		Err(Error::Numeric)
	} else {
		Ok(())
	}
}

fn fraction(index: usize, denominator: usize) -> Result<Fixed, Error> {
	Fixed::from_i64(index as i64).div(Fixed::from_i64(denominator as i64))
}

fn height(relative: Fixed) -> Result<u16, Error> {
	if relative.m() <= 0 {
		return Ok(0);
	}
	if relative.cmp_value(Fixed::from_i64(1)) != Ordering::Less {
		return Ok(u16::MAX);
	}
	let value = relative.mul(Fixed::from_i64(HEIGHT_MAX))?.to_i64_trunc();
	Ok(value.clamp(0, HEIGHT_MAX) as u16)
}

fn relative(score: Fixed, maximum: Fixed) -> Result<Fixed, Error> {
	let difference = score.sub(maximum)?;
	if difference.m() >= 0 {
		return Ok(Fixed::from_i64(1));
	}
	if difference.cmp_value(Fixed::from_i64(-64)) == Ordering::Less {
		return Ok(Fixed::ZERO);
	}
	difference.exp()
}

fn normal_curve(mean: Fixed, stddev: Fixed, count: usize) -> Result<Curve, Error> {
	require_positive(stddev, -1_000_000, 1_000_000)?;
	if !mean.exponent_in(-1_000_000, 1_000_000) {
		return Err(Error::Numeric);
	}
	let four = Fixed::from_i64(4);
	let eight = Fixed::from_i64(8);
	let two = Fixed::from_i64(2);
	let spread = four.mul(stddev)?;
	let mut heights = vec![0; count];
	for (index, item) in heights.iter_mut().enumerate() {
		let z = eight.mul(fraction(index, count - 1)?)?.sub(four)?;
		let score = z.mul(z)?.div(two)?.neg();
		*item = height(score.exp()?)?;
	}
	Ok(Curve {
		heights,
		x_min: mean.sub(spread)?,
		x_max: mean.add(spread)?,
	})
}

fn exponential_curve(rate: Fixed, count: usize) -> Result<Curve, Error> {
	let six = Fixed::from_i64(6);
	let mut heights = vec![0; count];
	for (index, item) in heights.iter_mut().enumerate() {
		let score = six.mul(fraction(index, count - 1)?)?.neg();
		*item = height(score.exp()?)?;
	}
	Ok(Curve {
		heights,
		x_min: Fixed::ZERO,
		x_max: six.div(rate)?,
	})
}

fn poisson_curve(lambda: Fixed, capacity: usize) -> Result<Curve, Error> {
	let mode = lambda.to_i64_trunc();
	let radius = Fixed::from_i64(6)
		.mul(lambda.sqrt()?)?
		.to_i64_trunc()
		.checked_add(1)
		.ok_or(Error::Numeric)?;
	let minimum = 0.max(mode.checked_sub(radius).ok_or(Error::Numeric)?);
	let maximum = mode.checked_add(radius).ok_or(Error::Numeric)?;
	let integer_count = usize::try_from(maximum - minimum + 1).map_err(|_| Error::Numeric)?;
	let count = integer_count.min(capacity);
	if count < 2 {
		return Err(Error::Numeric);
	}
	let mut probability = Fixed::from_i64(1);
	let mut current = mode;
	while current > minimum {
		probability = probability.mul(Fixed::from_i64(current).div(lambda)?)?;
		current -= 1;
	}
	let span = u64::try_from(maximum - minimum).map_err(|_| Error::Numeric)?;
	let denominator = (count - 1) as u64;
	let mut heights = vec![0; count];
	for (index, item) in heights.iter_mut().enumerate() {
		let numerator = (index as u64)
			.checked_mul(span)
			.and_then(|value| value.checked_add(denominator / 2))
			.ok_or(Error::Numeric)?;
		let target =
			minimum + i64::try_from(numerator / denominator).map_err(|_| Error::Numeric)?;
		while current < target {
			current += 1;
			probability = probability.mul(lambda.div(Fixed::from_i64(current))?)?;
		}
		*item = height(probability)?;
	}
	Ok(Curve {
		heights,
		x_min: Fixed::from_i64(minimum),
		x_max: Fixed::from_i64(maximum),
	})
}

fn log_normal_score(
	sigma_squared: Fixed,
	x_max_scaled: Fixed,
	index: usize,
	denominator: usize,
) -> Result<Fixed, Error> {
	let x = x_max_scaled.mul(fraction(index, denominator)?)?;
	let shifted = x.ln()?.add(sigma_squared)?;
	shifted
		.mul(shifted)?
		.div(Fixed::from_i64(2).mul(sigma_squared)?)
		.map(Fixed::neg)
}

fn log_normal_curve(mean: Fixed, stddev: Fixed, count: usize) -> Result<Curve, Error> {
	require_positive(stddev, -1_000_000, 23)?;
	if !mean.exponent_in(-1_000_000, 27) {
		return Err(Error::Numeric);
	}
	let span_unbounded = stddev.mul(Fixed::from_i64(13))?.div(Fixed::from_i64(8))?;
	let twenty = Fixed::from_i64(20);
	let span = if span_unbounded.cmp_value(twenty) == Ordering::Less {
		span_unbounded
	} else {
		twenty
	};
	let x_max_scaled = span.exp()?;
	let sigma_squared = stddev.mul(stddev)?;
	let mut maximum = log_normal_score(sigma_squared, x_max_scaled, 1, count - 1)?;
	for index in 2..count {
		let score = log_normal_score(sigma_squared, x_max_scaled, index, count - 1)?;
		if score.cmp_value(maximum) == Ordering::Greater {
			maximum = score;
		}
	}
	let mut heights = vec![0; count];
	for (index, item) in heights.iter_mut().enumerate().skip(1) {
		let score = log_normal_score(sigma_squared, x_max_scaled, index, count - 1)?;
		*item = height(relative(score, maximum)?)?;
	}
	Ok(Curve {
		heights,
		x_min: Fixed::ZERO,
		x_max: mean.add(span)?.exp()?,
	})
}

fn beta_score(
	alpha_minus_one: Fixed,
	beta_minus_one: Fixed,
	index: usize,
	count: usize,
) -> Result<Fixed, Error> {
	let numerator = Fixed::from_i64((index * 2 + 1) as i64);
	let denominator = Fixed::from_i64((count * 2) as i64);
	let x = numerator.div(denominator)?;
	let one_minus_x = Fixed::from_i64(1).sub(x)?;
	alpha_minus_one
		.mul(x.ln()?)?
		.add(beta_minus_one.mul(one_minus_x.ln()?)?)
}

fn beta_curve(alpha: Fixed, beta: Fixed, count: usize) -> Result<Curve, Error> {
	require_positive(alpha, -20, 20)?;
	require_positive(beta, -20, 20)?;
	let alpha_minus_one = alpha.sub(Fixed::from_i64(1))?;
	let beta_minus_one = beta.sub(Fixed::from_i64(1))?;
	let mut maximum = beta_score(alpha_minus_one, beta_minus_one, 0, count)?;
	for index in 1..count {
		let score = beta_score(alpha_minus_one, beta_minus_one, index, count)?;
		if score.cmp_value(maximum) == Ordering::Greater {
			maximum = score;
		}
	}
	let mut heights = Vec::with_capacity(count);
	for index in 0..count {
		let score = beta_score(alpha_minus_one, beta_minus_one, index, count)?;
		heights.push(height(relative(score, maximum)?)?);
	}
	Ok(Curve {
		heights,
		x_min: Fixed::ZERO,
		x_max: Fixed::from_i64(1),
	})
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn normal_curve_has_frozen_symmetric_endpoints() {
		let curve =
			Curve::sample(Distribution::Normal, Fixed::ZERO, Fixed::from_i64(1), 64).unwrap();
		assert_eq!(curve.x_min, Fixed::from_i64(-4));
		assert_eq!(curve.x_max, Fixed::from_i64(4));
		assert_eq!(curve.heights.first(), curve.heights.last());
		assert_eq!(curve.heights.len(), 64);
	}

	#[test]
	fn curve_input_domains_are_typed() {
		assert_eq!(
			Curve::sample(Distribution::Beta, Fixed::ZERO, Fixed::from_i64(1), 64),
			Err(Error::InvalidArgument)
		);
		assert_eq!(
			Curve::sample(
				Distribution::Exponential,
				Fixed::from_i64(1),
				Fixed::ZERO,
				1,
			),
			Err(Error::InvalidArgument)
		);
	}
}
