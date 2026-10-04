use alloc::vec::Vec;

use crate::{ByteSource, Error, Fixed, UnsignedCount};

/// Cached geometric parameters for failures before success, without a native
/// word-width result ceiling. Sampling uses no hidden bit reservoir.
#[derive(Clone, Debug)]
pub struct Geometric {
	base: u64,
	levels: Vec<u64>,
	tail_bits: usize,
	certain: bool,
}

// Dyadic Bernoulli probabilities in [1/3,1) compare exactly against u64 draws.
fn threshold(value: Fixed) -> Result<u64, Error> {
	if value.m() <= 0 || !(-2..=-1).contains(&value.e()) {
		return Err(Error::Numeric);
	}
	Ok((value.m() as u64) << (value.e() + 2))
}

impl Geometric {
	/// Parse the portable probability syntax without floating-point conversion.
	/// Decimal mantissas keep the existing eighteen-fractional-digit contract.
	pub fn parse_probability(text: &str) -> Result<Fixed, Error> {
		let invalid = Error::InvalidArgument;
		let value = if let Some(exponent) = text.strip_prefix("2^") {
			let exponent = exponent.parse::<i32>().map_err(|_| invalid)?;
			if !(-1_000_000..=0).contains(&exponent) {
				return Err(invalid);
			}
			Fixed::from_parts(1_i64 << 62, exponent)?
		} else if let Some(index) = text.find(['e', 'E']) {
			let mantissa = &text[..index];
			if !mantissa
				.bytes()
				.all(|byte| byte.is_ascii_digit() || byte == b'.')
			{
				return Err(invalid);
			}
			let value = parse_decimal(mantissa)?;
			let exponent = text[index + 1..].parse::<i32>().map_err(|_| invalid)?;
			if !(-1_000_000..=1_000_000).contains(&exponent) {
				return Err(invalid);
			}
			let mut remaining = exponent.unsigned_abs();
			let mut factor = Fixed::from_i64(10);
			let mut multiplier = Fixed::from_i64(1);
			while remaining != 0 {
				if remaining & 1 != 0 {
					multiplier = multiplier.mul(factor)?;
				}
				remaining /= 2;
				if remaining != 0 {
					factor = factor.mul(factor)?;
				}
			}
			if exponent < 0 {
				value.div(multiplier)?
			} else {
				value.mul(multiplier)?
			}
		} else {
			parse_decimal(text)?
		};
		Self::new(value)?;
		Ok(value)
	}

	/// Validate 0<p<=1 and prepare the significant block levels once.
	/// Fixed recurrence rounding is portable but is not exact real arithmetic.
	pub fn new(mut p: Fixed) -> Result<Self, Error> {
		let one = Fixed::from_i64(1);
		if !p.is_valid() || p.m() <= 0 || !p.exponent_in(-1_000_000, 0) || p.cmp_value(one).is_gt()
		{
			return Err(Error::InvalidArgument);
		}
		let mut prepared = Self {
			base: 0,
			levels: Vec::new(),
			tail_bits: 0,
			certain: p == one,
		};
		if prepared.certain {
			return Ok(prepared);
		}
		if p.e() < -62 {
			prepared.tail_bits = (-62 - p.e()) as usize;
			p = Fixed::from_parts(p.m(), -62)?;
		}
		let half = Fixed::from_ratio(1, 2)?;
		let two = Fixed::from_i64(2);
		prepared
			.levels
			.try_reserve(128)
			.map_err(|_| Error::Numeric)?;
		while p.cmp_value(half).is_lt() {
			if prepared.levels.len() == 128 {
				return Err(Error::Numeric);
			}
			prepared
				.levels
				.push(threshold(one.sub(p)?.div(two.sub(p)?)?)?);
			let doubled = Fixed::from_parts(p.m(), p.e() + 1)?;
			p = doubled.sub(p.mul(p)?)?;
		}
		prepared.base = threshold(p)?;
		Ok(prepared)
	}

	/// Sample an exact arbitrary-width integer. A failing source may already
	/// have consumed bytes; an opaque ByteSource cannot be rolled back here.
	/// Base and reverse-order significant bits use eight-byte big-endian draws.
	/// Fair tail bytes are low little-endian bits, with high padding discarded.
	pub fn sample(&self, source: &mut impl ByteSource) -> Result<UnsignedCount, Error> {
		let mut value = UnsignedCount::default();
		if self.certain {
			return Ok(value);
		}
		while source.u64_be()? >= self.base {
			value.multiply_add(1, 1)?;
		}
		for probability in self.levels.iter().rev() {
			let bit = u16::from(source.u64_be()? < *probability);
			value.multiply_add(2, bit)?;
		}
		if self.tail_bits != 0 {
			let whole = self.tail_bits / 8;
			let remainder = self.tail_bits % 8;
			let tail_length = self.tail_bits.div_ceil(8);
			let extra = usize::from(
				!value.0.is_empty()
					&& remainder != 0
					&& value.0[value.0.len() - 1] >> (8 - remainder) != 0,
			);
			let shifted_length = value.0.len() + whole + extra;
			let mut output = Vec::new();
			output
				.try_reserve_exact(shifted_length.max(tail_length))
				.map_err(|_| Error::Numeric)?;
			output.resize(shifted_length.max(tail_length), 0);
			for (index, byte) in value.0.iter().enumerate() {
				output[index + whole] |= byte << remainder;
				if remainder != 0 && index + whole + 1 < output.len() {
					output[index + whole + 1] |= byte >> (8 - remainder);
				}
			}
			let high_partial = if remainder != 0 { output[whole] } else { 0 };
			source.fill_exact(&mut output[..tail_length])?;
			if remainder != 0 {
				output[whole] = high_partial | (output[whole] & ((1_u8 << remainder) - 1));
			}
			while output.last() == Some(&0) {
				output.pop();
			}
			value.0 = output;
		}
		Ok(value)
	}
}

fn parse_decimal(text: &str) -> Result<Fixed, Error> {
	let invalid = Error::InvalidArgument;
	let text = text.trim_matches([' ', '\t', '\n', '\r', '\u{b}', '\u{c}']);
	let (negative, text) = if let Some(rest) = text.strip_prefix('-') {
		(true, rest)
	} else {
		(false, text.strip_prefix('+').unwrap_or(text))
	};
	let mut parts = text.split('.');
	let integer = parts.next().ok_or(invalid)?;
	let fractional = parts.next();
	if parts.next().is_some()
		|| integer.len() > 2000
		|| !integer.bytes().all(|byte| byte.is_ascii_digit())
		|| fractional.is_some_and(|part| !part.bytes().all(|byte| byte.is_ascii_digit()))
		|| (integer.is_empty() && fractional.is_none_or(str::is_empty))
	{
		return Err(invalid);
	}
	let mut value = if integer.is_empty() {
		Fixed::ZERO
	} else if let Ok(number) = integer.parse::<i64>() {
		Fixed::from_i64(number)
	} else {
		let mut value = Fixed::ZERO;
		for digit in integer.bytes() {
			value = value
				.mul(Fixed::from_i64(10))?
				.add(Fixed::from_i64(i64::from(digit - b'0')))?;
		}
		value
	};
	if let Some(fraction) = fractional {
		let mut numerator = 0_i64;
		let mut denominator = 1_i64;
		for digit in fraction.bytes().take(18) {
			numerator = numerator * 10 + i64::from(digit - b'0');
			denominator *= 10;
		}
		if denominator != 1 {
			value = value.add(Fixed::from_ratio(numerator, denominator)?)?;
		}
	}
	Ok(if negative { value.neg() } else { value })
}
