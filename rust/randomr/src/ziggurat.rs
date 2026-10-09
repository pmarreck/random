//! Fixed-point 256-strip normal kernel. Whole words have disjoint strip/sign/
//! coordinate fields; rejection never caches a spare or reuses a failed strip.
use crate::{ByteSource, Error, Fixed, fixed::ziggurat_tables::STRIPS};

/// Exact n/2^55, including canonical zero. No conversion through IEEE754.
fn unit(n: u64) -> Result<Fixed, Error> {
	if n == 0 {
		return Ok(Fixed::ZERO);
	}
	let shift = n.leading_zeros() - 1;
	Fixed::from_parts((n << shift) as i64, 7 - shift as i32)
}

pub(crate) fn normal(source: &mut impl ByteSource) -> Result<Fixed, Error> {
	loop {
		let word = source.u64_be()?;
		let index = (word & 255) as usize;
		let negative = word & 256 != 0;
		let coordinate = word >> 9;
		let strip = &STRIPS[index];
		let x = unit(coordinate)?.mul(strip.x)?;
		let signed = |x: Fixed| if negative { x.neg() } else { x };
		if coordinate < strip.k {
			return Ok(signed(x));
		}
		if index == 0 {
			let r = STRIPS[1].x;
			loop {
				let t = unit((source.u64_be()? >> 9) + 1)?.ln()?.neg().div(r)?;
				let y = unit((source.u64_be()? >> 9) + 1)?.ln()?.neg();
				if !y.add(y)?.cmp_value(t.mul(t)?).is_lt() {
					return Ok(signed(r.add(t)?));
				}
			}
		}
		let upper = if index == 255 {
			Fixed::from_i64(1)
		} else {
			STRIPS[index + 1].y
		};
		let y = strip
			.y
			.add(unit(source.u64_be()? >> 9)?.mul(upper.sub(strip.y)?)?)?;
		let square = x.mul(x)?.neg();
		let exponent = if square.is_zero() {
			square
		} else {
			Fixed::from_parts(square.m(), square.e() - 1)?
		};
		if y.cmp_value(exponent.exp()?).is_lt() {
			return Ok(signed(x));
		}
	}
}
