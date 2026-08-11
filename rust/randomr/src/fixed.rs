use core::cmp::Ordering;

use crate::{Error, MAX_EXACT_INTEGER};

const TWO62: u64 = 0x4000_0000_0000_0000;
const TWO61: u64 = 0x2000_0000_0000_0000;
const LN2: Fixed = Fixed {
	m: 6_393_154_322_601_327_829,
	e: -1,
};
const PI_2: Fixed = Fixed {
	m: 7_244_019_458_077_122_842,
	e: 0,
};
const ATANH_TERMS: usize = 20;
const EXP_TERMS: usize = 16;
const COS_TERMS: usize = 14;
const SQRT_REFINE: usize = 3;
const EXP_MAX_CORRECTIONS: usize = 3;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
/// Canonical signed integer-only software-float value `(mantissa, exponent)`.
pub struct Fixed {
	m: i64,
	e: i32,
}

// The named operations are deliberately fallible: unlike the standard
// arithmetic traits, they surface exponent overflow and invalid domains.
#[allow(clippy::should_implement_trait)]
impl Fixed {
	/// Canonical zero.
	pub const ZERO: Self = Self { m: 0, e: 0 };

	/// Construct an already-normalized canonical `(mantissa, exponent)` pair.
	pub fn from_parts(m: i64, e: i32) -> Result<Self, Error> {
		let value = norm(m, i64::from(e))?;
		if value.m == m && value.e == e {
			Ok(value)
		} else {
			Err(Error::InvalidArgument)
		}
	}

	#[must_use]
	/// Convert an integer exactly into the canonical representation.
	pub fn from_i64(value: i64) -> Self {
		if value == 0 {
			Self::ZERO
		} else {
			norm(value, 62).expect("an i64 always normalizes within i32 exponent range")
		}
	}

	/// Divide two integers through the deterministic fixed-point kernel.
	pub fn from_ratio(numerator: i64, denominator: i64) -> Result<Self, Error> {
		Self::from_i64(numerator).div(Self::from_i64(denominator))
	}

	#[must_use]
	/// Return the canonical mantissa.
	pub const fn m(self) -> i64 {
		self.m
	}

	#[must_use]
	/// Return the canonical binary exponent.
	pub const fn e(self) -> i32 {
		self.e
	}

	#[must_use]
	/// Return `(mantissa, exponent)` for serialization or exact comparison.
	pub const fn parts(self) -> (i64, i32) {
		(self.m, self.e)
	}

	#[must_use]
	/// Return whether this value is canonical zero.
	pub const fn is_zero(self) -> bool {
		self.m == 0
	}

	#[must_use]
	/// Return whether the representation satisfies all canonical invariants.
	pub fn is_valid(self) -> bool {
		if self.m == 0 {
			return self.e == 0;
		}
		let magnitude = magnitude(self.m);
		(TWO62..0x8000_0000_0000_0000).contains(&magnitude)
	}

	pub(crate) fn exponent_in(self, minimum: i32, maximum: i32) -> bool {
		self.is_valid() && (self.is_zero() || (self.e >= minimum && self.e <= maximum))
	}

	/// Multiply and normalize, returning [`Error::Numeric`] on overflow.
	pub fn mul(self, other: Self) -> Result<Self, Error> {
		if self.m == 0 || other.m == 0 {
			return Ok(Self::ZERO);
		}
		require_valid(self)?;
		require_valid(other)?;
		let negative = (self.m < 0) != (other.m < 0);
		let product = u128::from(magnitude(self.m)) * u128::from(magnitude(other.m));
		let high = (product >> 64) as u64;
		let low = product as u64;
		let mut exponent = i64::from(self.e) + i64::from(other.e);
		let mantissa = if high >= TWO61 {
			exponent += 1;
			high.wrapping_mul(2).wrapping_add(low >> 63)
		} else {
			high.wrapping_mul(4).wrapping_add(low >> 62)
		};
		let signed = if negative {
			(mantissa as i64).wrapping_neg()
		} else {
			mantissa as i64
		};
		norm(signed, exponent)
	}

	/// Add and normalize, returning [`Error::Numeric`] on overflow.
	pub fn add(self, other: Self) -> Result<Self, Error> {
		if self.m == 0 {
			require_valid(other)?;
			return Ok(other);
		}
		if other.m == 0 {
			require_valid(self)?;
			return Ok(self);
		}
		require_valid(self)?;
		require_valid(other)?;
		let (x, y) = if self.e < other.e {
			(other, self)
		} else {
			(self, other)
		};
		let distance = i64::from(x.e) - i64::from(y.e);
		if distance >= 63 {
			return Ok(x);
		}
		let shifted = y.m / (1_i64 << u32::try_from(distance).map_err(|_| Error::Numeric)?);
		if shifted == 0 {
			return Ok(x);
		}
		let (sum, exponent) = if (x.m < 0) == (shifted < 0) {
			(
				x.m / 2 + shifted / 2,
				i64::from(x.e).checked_add(1).ok_or(Error::Numeric)?,
			)
		} else {
			(x.m + shifted, i64::from(x.e))
		};
		norm(sum, exponent)
	}

	/// Subtract and normalize, returning [`Error::Numeric`] on overflow.
	pub fn sub(self, other: Self) -> Result<Self, Error> {
		self.add(other.neg())
	}

	#[must_use]
	/// Negate without changing the exponent.
	pub fn neg(self) -> Self {
		if self.m == 0 {
			Self::ZERO
		} else {
			Self {
				m: self.m.wrapping_neg(),
				e: self.e,
			}
		}
	}

	#[must_use]
	/// Compare numeric values rather than representation tuples.
	pub fn cmp_value(self, other: Self) -> Ordering {
		let s1 = self.m.signum();
		let s2 = other.m.signum();
		if s1 != s2 {
			return s1.cmp(&s2);
		}
		if s1 == 0 {
			return Ordering::Equal;
		}
		if self.e != other.e {
			let order = self.e.cmp(&other.e);
			return if s1 > 0 { order } else { order.reverse() };
		}
		self.m.cmp(&other.m)
	}

	/// Divide and normalize; a zero divisor is [`Error::InvalidArgument`].
	pub fn div(self, other: Self) -> Result<Self, Error> {
		if other.m == 0 {
			return Err(Error::InvalidArgument);
		}
		if self.m == 0 {
			return Ok(Self::ZERO);
		}
		require_valid(self)?;
		require_valid(other)?;
		let negative = (self.m < 0) != (other.m < 0);
		let magnitude = div_magnitude(magnitude(self.m), magnitude(other.m));
		let signed = if negative {
			(magnitude as i64).wrapping_neg()
		} else {
			magnitude as i64
		};
		norm(signed, i64::from(self.e) - i64::from(other.e))
	}

	#[must_use]
	/// Truncate toward zero and clamp to the exact integer contract.
	pub fn to_i64_trunc(self) -> i64 {
		if self.m == 0 {
			return 0;
		}
		let shift = i64::from(self.e) - 62;
		if shift >= 0 {
			return if self.m < 0 {
				-MAX_EXACT_INTEGER
			} else {
				MAX_EXACT_INTEGER
			};
		}
		let amount = -shift;
		if amount > 62 {
			return 0;
		}
		let quotient = self.m / (1_i64 << u32::try_from(amount).unwrap());
		quotient.clamp(-MAX_EXACT_INTEGER, MAX_EXACT_INTEGER)
	}

	/// Round to the nearest integer, with halves away from zero.
	pub fn round_to_i64(self) -> Result<i64, Error> {
		let half = Self::from_ratio(1, 2)?;
		Ok(if self.m < 0 {
			self.sub(half)?.to_i64_trunc()
		} else {
			self.add(half)?.to_i64_trunc()
		})
	}

	/// Return the signed fractional component after truncation toward zero.
	pub fn frac(self) -> Result<Self, Error> {
		let integer = self.to_i64_trunc();
		if integer == 0 {
			Ok(self)
		} else {
			self.sub(Self::from_i64(integer))
		}
	}

	/// Compute the natural logarithm with the pinned integer-only series.
	pub fn ln(self) -> Result<Self, Error> {
		if self.m <= 0 || !self.is_valid() {
			return Err(Error::InvalidArgument);
		}
		let k = self.e;
		let fraction = Self { m: self.m, e: 0 };
		let one = Self::from_i64(1);
		let t = fraction.sub(one)?.div(fraction.add(one)?)?;
		let t2 = t.mul(t)?;
		let mut term = t;
		let mut accumulator = t;
		for index in 0..ATANH_TERMS {
			term = term.mul(t2)?;
			let reciprocal = one.div(Self::from_i64((2 * (index + 1) + 1) as i64))?;
			accumulator = accumulator.add(term.mul(reciprocal)?)?;
		}
		let mut result = accumulator.add(accumulator)?;
		if k != 0 {
			result = result.add(LN2.mul(Self::from_i64(i64::from(k)))?)?;
		}
		Ok(result)
	}

	/// Compute `e^self` with the pinned integer-only series and correction bound.
	pub fn exp(self) -> Result<Self, Error> {
		if self.m == 0 {
			return Ok(Self::from_i64(1));
		}
		let half_ln2 = LN2.div(Self::from_i64(2))?;
		let mut k = self.div(LN2)?.to_i64_trunc();
		let mut remainder = reduce_remainder(self, k)?;
		let mut corrections = 0_usize;
		while remainder.cmp_value(half_ln2).is_gt() {
			k = k.checked_add(1).ok_or(Error::Numeric)?;
			remainder = reduce_remainder(self, k)?;
			corrections += 1;
			if corrections > EXP_MAX_CORRECTIONS {
				return Err(Error::Numeric);
			}
		}
		while remainder.cmp_value(half_ln2.neg()).is_lt() {
			k = k.checked_sub(1).ok_or(Error::Numeric)?;
			remainder = reduce_remainder(self, k)?;
			corrections += 1;
			if corrections > EXP_MAX_CORRECTIONS {
				return Err(Error::Numeric);
			}
		}
		let one = Self::from_i64(1);
		let mut accumulator = one;
		let mut power = one;
		let mut factorial = one;
		for index in 0..EXP_TERMS {
			factorial = factorial.mul(Self::from_i64((index + 1) as i64))?;
			let reciprocal = one.div(factorial)?;
			power = power.mul(remainder)?;
			let contribution = power.mul(reciprocal)?;
			if contribution.m == 0 {
				break;
			}
			accumulator = accumulator.add(contribution)?;
		}
		norm(accumulator.m, i64::from(accumulator.e) + k)
	}

	/// Compute cosine where one input unit is one full turn.
	pub fn cos_turns(self) -> Result<Self, Error> {
		if self.m == 0 {
			return Ok(Self::from_i64(1));
		}
		let mut fraction = self.frac()?;
		if fraction.m < 0 {
			fraction = fraction.add(Self::from_i64(1))?;
		}
		let quadrant_value = fraction.mul(Self::from_i64(4))?;
		let quadrant = quadrant_value.to_i64_trunc();
		let within = quadrant_value.sub(Self::from_i64(quadrant))?;
		let angle = within.mul(PI_2)?;
		match quadrant {
			0 => cos_radians(angle),
			1 => Ok(sin_radians(angle)?.neg()),
			2 => Ok(cos_radians(angle)?.neg()),
			_ => sin_radians(angle),
		}
	}

	/// Compute the nonnegative square root with fixed refinement count.
	pub fn sqrt(self) -> Result<Self, Error> {
		if self.m < 0 || !self.is_valid() {
			return Err(Error::InvalidArgument);
		}
		if self.m == 0 {
			return Ok(Self::ZERO);
		}
		let mut mantissa = self.m;
		let mut exponent = i64::from(self.e);
		if exponent % 2 != 0 {
			mantissa /= 2;
			exponent += 1;
		}
		let unsigned = mantissa as u64;
		let mut estimate = 0x1_0000_0000_u64;
		for _ in 0..40 {
			let next = (estimate + unsigned / estimate) / 2;
			if next == estimate {
				break;
			}
			estimate = next;
		}
		let mut result = norm(estimate as i64, exponent / 2 + 31)?;
		for _ in 0..SQRT_REFINE {
			let sum = result.add(self.div(result)?)?;
			result = norm(sum.m, i64::from(sum.e) - 1)?;
		}
		Ok(result)
	}

	/// Raise a positive base to a fixed-point exponent.
	pub fn pow(self, exponent: Self) -> Result<Self, Error> {
		if self.m <= 0 {
			return Err(Error::InvalidArgument);
		}
		exponent.mul(self.ln()?)?.exp()
	}
}

fn require_valid(value: Fixed) -> Result<(), Error> {
	if value.is_valid() {
		Ok(())
	} else {
		Err(Error::Numeric)
	}
}

fn magnitude(value: i64) -> u64 {
	if value < 0 {
		value.wrapping_neg() as u64
	} else {
		value as u64
	}
}

fn norm(mantissa: i64, exponent: i64) -> Result<Fixed, Error> {
	if mantissa == 0 {
		return Ok(Fixed::ZERO);
	}
	let negative = mantissa < 0;
	let mut unsigned = magnitude(mantissa);
	let mut adjusted = exponent;
	if unsigned >= 0x8000_0000_0000_0000 {
		unsigned >>= 1;
		adjusted = adjusted.checked_add(1).ok_or(Error::Numeric)?;
	} else if unsigned < TWO62 {
		let shift = unsigned.leading_zeros() - 1;
		unsigned <<= shift;
		adjusted = adjusted
			.checked_sub(i64::from(shift))
			.ok_or(Error::Numeric)?;
	}
	let e = i32::try_from(adjusted).map_err(|_| Error::Numeric)?;
	let value = unsigned as i64;
	Ok(Fixed {
		m: if negative {
			value.wrapping_neg()
		} else {
			value
		},
		e,
	})
}

fn div_magnitude(a: u64, b: u64) -> u64 {
	let quotient = a / b;
	let mut remainder = a % b;
	let mut fraction = 0_u64;
	for _ in 0..62 {
		remainder *= 2;
		fraction *= 2;
		if remainder >= b {
			remainder -= b;
			fraction += 1;
		}
	}
	quotient * TWO62 + fraction
}

fn reduce_remainder(value: Fixed, k: i64) -> Result<Fixed, Error> {
	value.sub(LN2.mul(Fixed::from_i64(k))?)
}

fn cos_radians(angle: Fixed) -> Result<Fixed, Error> {
	let squared = angle.mul(angle)?;
	let mut term = Fixed::from_i64(1);
	let mut accumulator = term;
	for n in 1..=COS_TERMS {
		term = term.mul(squared)?;
		term = term.mul(Fixed::from_ratio(1, ((2 * n - 1) * (2 * n)) as i64)?)?;
		term = term.neg();
		accumulator = accumulator.add(term)?;
	}
	Ok(accumulator)
}

fn sin_radians(angle: Fixed) -> Result<Fixed, Error> {
	let squared = angle.mul(angle)?;
	let mut term = angle;
	let mut accumulator = angle;
	for n in 1..=COS_TERMS {
		term = term.mul(squared)?;
		term = term.mul(Fixed::from_ratio(1, ((2 * n) * (2 * n + 1)) as i64)?)?;
		term = term.neg();
		accumulator = accumulator.add(term)?;
	}
	Ok(accumulator)
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn representative_exact_operations() {
		assert_eq!(
			Fixed::from_i64(2).mul(Fixed::from_i64(3)).unwrap(),
			Fixed::from_i64(6)
		);
		assert_eq!(
			Fixed::from_i64(3).sub(Fixed::from_i64(2)).unwrap(),
			Fixed::from_i64(1)
		);
		assert_eq!(Fixed::from_i64(9).sqrt().unwrap(), Fixed::from_i64(3));
		assert_eq!(
			Fixed::from_i64(2).pow(Fixed::from_i64(10)).unwrap(),
			Fixed::from_i64(1024)
		);
	}

	#[test]
	fn negative_division_truncates_toward_zero() {
		assert_eq!(
			Fixed::from_i64(-7)
				.div(Fixed::from_i64(11))
				.unwrap()
				.parts(),
			// Pinned independently by src/differential_driver.zig (`I 3`).
			(-5_869_418_568_907_584_605, -1)
		);
	}

	#[test]
	fn invalid_domains_are_typed_errors() {
		assert_eq!(
			Fixed::from_i64(1).div(Fixed::ZERO),
			Err(Error::InvalidArgument)
		);
		assert_eq!(Fixed::ZERO.ln(), Err(Error::InvalidArgument));
		assert_eq!(Fixed::from_i64(-1).sqrt(), Err(Error::InvalidArgument));
	}
}
