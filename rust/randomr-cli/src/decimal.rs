use randomr::Fixed;

pub const MAX_INT_PART_DIGITS: usize = 2000;
pub const SAFE_INT_MAGNITUDE: i64 = randomr::MAX_EXACT_INTEGER;

pub fn parse_fixed(input: &str) -> Option<Fixed> {
	let bytes = trim_ascii_space(input.as_bytes());
	if bytes.is_empty() {
		return None;
	}
	let (negative, mut index) = match bytes[0] {
		b'-' => (true, 1),
		b'+' => (false, 1),
		_ => (false, 0),
	};
	let integer_start = index;
	let mut accumulator = 0_i64;
	let mut overflow = false;
	while index < bytes.len() && bytes[index].is_ascii_digit() {
		let digit = i64::from(bytes[index] - b'0');
		if accumulator > (i64::MAX - digit) / 10 {
			overflow = true;
			break;
		}
		accumulator = accumulator * 10 + digit;
		index += 1;
	}
	let (mut value, integer_digits) = if overflow {
		let mut value = Fixed::ZERO;
		let mut scan = integer_start;
		let mut digits = 0_usize;
		while scan < bytes.len() && bytes[scan].is_ascii_digit() {
			digits += 1;
			if digits > MAX_INT_PART_DIGITS {
				return None;
			}
			value = value.mul(Fixed::from_i64(10)).ok()?;
			value = value
				.add(Fixed::from_i64(i64::from(bytes[scan] - b'0')))
				.ok()?;
			scan += 1;
		}
		index = scan;
		(value, digits)
	} else {
		(Fixed::from_i64(accumulator), index - integer_start)
	};

	let mut fraction = 0_i64;
	let mut fraction_digits = 0_usize;
	let mut digits_present = 0_usize;
	if index < bytes.len() && bytes[index] == b'.' {
		index += 1;
		while index < bytes.len() && bytes[index].is_ascii_digit() {
			digits_present += 1;
			if fraction_digits < 18 {
				fraction = fraction * 10 + i64::from(bytes[index] - b'0');
				fraction_digits += 1;
			}
			index += 1;
		}
	}
	if index != bytes.len() || (integer_digits == 0 && digits_present == 0) {
		return None;
	}
	if fraction_digits > 0 {
		let mut denominator = 1_i64;
		for _ in 0..fraction_digits {
			denominator *= 10;
		}
		value = value
			.add(
				Fixed::from_i64(fraction)
					.div(Fixed::from_i64(denominator))
					.ok()?,
			)
			.ok()?;
	}
	Some(if negative { value.neg() } else { value })
}

pub fn parse_i64(input: &str) -> Option<i64> {
	let bytes = trim_ascii_space(input.as_bytes());
	if bytes.is_empty() {
		return None;
	}
	let (negative, mut index) = match bytes[0] {
		b'-' => (true, 1),
		b'+' => (false, 1),
		_ => (false, 0),
	};
	if index == bytes.len() {
		return None;
	}
	let mut value = 0_i64;
	let start = index;
	while index < bytes.len() && bytes[index].is_ascii_digit() {
		let digit = i64::from(bytes[index] - b'0');
		value = value.checked_mul(10)?.checked_add(digit)?;
		index += 1;
	}
	if index == start || index != bytes.len() {
		return None;
	}
	Some(if negative { -value } else { value })
}

pub fn parse_safe_i64(input: &str) -> Option<i64> {
	let value = parse_i64(input)?;
	(value.abs() <= SAFE_INT_MAGNITUDE).then_some(value)
}

pub fn format_fixed(value: Fixed, places: usize) -> Result<String, &'static str> {
	if places > 64 {
		return Err("too many fractional places");
	}
	if value.is_zero() {
		return if places == 0 {
			Ok("0".to_owned())
		} else {
			Ok(format!("0.{:0<width$}", "", width = places))
		};
	}
	let negative = value.m() < 0;
	let absolute = if negative { value.neg() } else { value };
	let shift = i64::from(absolute.e()) - 62;
	let (integer, mut fraction) = if shift >= 0 {
		if shift > MAX_INT_PART_DIGITS as i64 - 19 {
			return Err("integer part too long");
		}
		let mut digits = absolute.m().to_string();
		for _ in 0..shift {
			decimal_double(&mut digits);
		}
		(digits, Fixed::ZERO)
	} else {
		let amount = -shift;
		let integer = if amount > 62 {
			0
		} else {
			absolute.m() / (1_i64 << amount as u32)
		};
		(
			integer.to_string(),
			absolute
				.sub(Fixed::from_i64(integer))
				.map_err(|_| "numeric formatting error")?,
		)
	};
	let mut output = String::with_capacity(integer.len() + places + 2);
	if negative {
		output.push('-');
	}
	output.push_str(&integer);
	if places > 0 {
		output.push('.');
		for _ in 0..places {
			fraction = fraction
				.mul(Fixed::from_i64(10))
				.map_err(|_| "numeric formatting error")?;
			let digit = fraction.to_i64_trunc().clamp(0, 9);
			output.push(char::from(b'0' + digit as u8));
			fraction = fraction
				.sub(Fixed::from_i64(digit))
				.map_err(|_| "numeric formatting error")?;
		}
	}
	Ok(output)
}

fn trim_ascii_space(mut bytes: &[u8]) -> &[u8] {
	while bytes.first().copied().is_some_and(is_lua_space) {
		bytes = &bytes[1..];
	}
	while bytes.last().copied().is_some_and(is_lua_space) {
		bytes = &bytes[..bytes.len() - 1];
	}
	bytes
}

fn is_lua_space(byte: u8) -> bool {
	matches!(byte, b' ' | b'\t' | b'\n' | b'\r' | 11 | 12)
}

fn decimal_double(digits: &mut String) {
	let mut bytes = digits.as_bytes().to_vec();
	let mut carry = 0_u8;
	for digit in bytes.iter_mut().rev() {
		let value = (*digit - b'0') * 2 + carry;
		*digit = b'0' + value % 10;
		carry = value / 10;
	}
	if carry > 0 {
		bytes.insert(0, b'0' + carry);
	}
	*digits = String::from_utf8(bytes).expect("decimal digits are UTF-8");
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn fixed_decimal_contract() {
		assert_eq!(
			parse_fixed("-1.5").unwrap().parts(),
			parse_fixed("1.5").unwrap().neg().parts()
		);
		assert!(parse_fixed("1.2.3").is_none());
		assert!(parse_fixed(".").is_none());
		assert_eq!(
			format_fixed(parse_fixed("1.5").unwrap(), 6).unwrap(),
			"1.500000"
		);
		assert_eq!(
			format_fixed(Fixed::from_i64(1_000_000_000_000_000), 0).unwrap(),
			"1000000000000000"
		);
		assert_eq!(
			format_fixed(Fixed::from_parts(4_611_686_018_427_387_904, 63).unwrap(), 0).unwrap(),
			"9223372036854775808"
		);
	}

	#[test]
	fn safe_integer_contract() {
		assert_eq!(parse_safe_i64("9007199254740992"), Some(SAFE_INT_MAGNITUDE));
		assert_eq!(parse_safe_i64("9007199254740993"), None);
		assert_eq!(parse_i64("1.5"), None);
	}
}
