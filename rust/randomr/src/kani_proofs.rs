//! Bounded verifier harnesses over unchanged production functions.
//! Domains are explicit in each contract; no entropy or cryptographic evaluation.

use crate::Fixed;

fn canonical() -> Fixed {
	let m: i64 = kani::any();
	let e: i32 = kani::any();
	let a = i128::from(m).abs();
	kani::assume((m == 0 && e == 0) || ((1_i128 << 62) <= a && a < (1_i128 << 63)));
	Fixed::from_parts(m, e).unwrap()
}

fn representation(value: Fixed) -> bool {
	let a = i128::from(value.m()).abs();
	(value.m() == 0 && value.e() == 0) || ((1_i128 << 62) <= a && a < (1_i128 << 63))
}

/// All canonical mantissas and all i32 exponents, including canonical zero.
#[kani::proof]
#[kani::unwind(2)]
fn negation_contract() {
	let value = canonical();
	let result = value.neg();
	assert!(result.is_valid(), "negation stays canonical");
	assert!(
		i128::from(result.m()) == -i128::from(value.m()),
		"negation reverses sign exactly"
	);
	#[cfg(not(kani_negative))]
	let expected = value;
	#[cfg(kani_negative)]
	let expected = Fixed::ZERO;
	assert!(result.e() == value.e(), "negation preserves exponent");
	kani::cover!(value.is_zero(), "negation zero reachable");
	kani::cover!(
		value.m() < 0 && value.e() == i32::MIN,
		"negation negative endpoint reachable"
	);
	kani::cover!(
		value.m() > 0 && value.e() == i32::MAX,
		"negation positive endpoint reachable"
	);
	assert!(result.neg() == expected, "double negation identity");
}

/// Constant normalized divisors; the numerator, signs and exponents are symbolic.
/// A quotient certificate checks exactness without a second division oracle.
fn division_named<const DIVISOR: u64>() {
	let raw: u64 = kani::any();
	kani::assume((1_u64 << 62) <= raw && raw < (1_u64 << 63));
	let minus_a: bool = kani::any();
	let minus_b: bool = kani::any();
	let ea: i32 = kani::any();
	let eb: i32 = kani::any();
	let signed = |a: u64, negative: bool| if negative { -(a as i64) } else { a as i64 };
	let a = Fixed::from_parts(signed(raw, minus_a), ea).unwrap();
	let b = Fixed::from_parts(signed(DIVISOR, minus_b), eb).unwrap();
	let result = a.div(b);
	let shift = raw < DIVISOR;
	if DIVISOR > (1_u64 << 62) {
		kani::cover!(
			raw == (1_u64 << 62) && result.is_ok(),
			"division normalization shift reachable"
		);
	}
	kani::cover!(
		raw == (1_u64 << 62) && result.is_ok(),
		"division minimum numerator reachable"
	);
	kani::cover!(
		raw == (1_u64 << 63) - 1 && result.is_ok(),
		"division maximum numerator reachable"
	);
	let expected_e = i64::from(ea) - i64::from(eb) - i64::from(shift);
	let fits = (i64::from(i32::MIN)..=i64::from(i32::MAX)).contains(&expected_e);
	assert!(result.is_ok() == fits, "division exponent acceptance");
	if let Ok(value) = result {
		assert!(value.is_valid(), "division result canonical");
		assert!(
			(value.m() < 0) == (minus_a != minus_b),
			"division sign restored"
		);
		assert!(
			i64::from(value.e()) == expected_e,
			"division exponent restored"
		);
		let mag = i128::from(value.m()).abs() as u128;
		assert!(!shift || mag % 2 == 0, "division normalization even");
		let q = if shift { mag >> 1 } else { mag };
		let n = u128::from(raw) << 62;
		#[cfg(not(kani_negative))]
		let q_checked = q;
		#[cfg(kani_negative)]
		let q_checked = q + 1;
		assert!(
			q_checked * u128::from(DIVISOR) <= n && n < (q_checked + 1) * u128::from(DIVISOR),
			"division quotient certificate"
		);
	} else {
		assert!(
			result == Err(crate::Error::Numeric),
			"division overflow typed"
		);
	}
	kani::cover!(
		ea == 0 && eb == 0 && !minus_a && !minus_b && result.is_ok(),
		"division positive success reachable"
	);
	kani::cover!(
		minus_a != minus_b && result.is_ok(),
		"division negative success reachable"
	);
	kani::cover!(
		ea == i32::MAX && eb == i32::MIN && result.is_err(),
		"division overflow reachable"
	);
}

#[kani::proof]
#[kani::unwind(2)]
fn division_pow2_contract() {
	division_named::<0x4000_0000_0000_0000>();
}

#[kani::proof]
#[kani::unwind(2)]
fn division_pow2_plus_one_contract() {
	division_named::<0x4000_0000_0000_0001>();
}

#[kani::proof]
#[kani::unwind(2)]
fn division_zero_contract() {
	let value = canonical();
	let denominator_zero: bool = kani::any();
	let result = if denominator_zero {
		value.div(Fixed::ZERO)
	} else {
		Fixed::ZERO.div(value)
	};
	#[cfg(not(kani_negative))]
	let expected = if denominator_zero || value.is_zero() {
		Err(crate::Error::InvalidArgument)
	} else {
		Ok(Fixed::ZERO)
	};
	#[cfg(kani_negative)]
	let expected = Err(crate::Error::Numeric);
	kani::cover!(value.is_zero(), "division zero over zero reachable");
	kani::cover!(
		denominator_zero && !value.is_zero(),
		"division nonzero over zero reachable"
	);
	kani::cover!(
		!denominator_zero && value.m() < 0,
		"division zero over negative reachable"
	);
	assert!(result == expected, "division zero contract");
}

#[kani::proof]
#[kani::unwind(2)]
fn addition_subtraction_closure_contract() {
	let a = canonical();
	let b = canonical();
	let subtract: bool = kani::any();
	let result = if subtract { a.sub(b) } else { a.add(b) };
	if let Ok(value) = result {
		assert!(representation(value), "add subtract result canonical");
	} else {
		assert!(
			result == Err(crate::Error::Numeric),
			"add subtract overflow typed"
		);
	}
	let safe = (-1000..=1000).contains(&a.e()) && (-1000..=1000).contains(&b.e());
	assert!(
		!safe || result.is_ok(),
		"add subtract safe exponents succeed"
	);
	kani::cover!(
		subtract && a == b && !a.is_zero() && result == Ok(Fixed::ZERO),
		"subtraction cancellation reachable"
	);
	kani::cover!(
		!subtract && a == b && a.e() == i32::MAX && result.is_err(),
		"addition overflow reachable"
	);
	kani::cover!(
		safe && !a.is_zero() && !b.is_zero() && result.is_ok(),
		"addition subtraction safe success reachable"
	);
	#[cfg(not(kani_negative))]
	let expected = a;
	#[cfg(kani_negative)]
	let expected = a.neg();
	assert!(a.add(Fixed::ZERO) == Ok(expected), "addition zero identity");
}

fn multiplication_named<const MANTISSA: i64>() {
	let negative: bool = kani::any();
	let exponent: i32 = kani::any();
	let a = Fixed::from_parts(if negative { -MANTISSA } else { MANTISSA }, exponent).unwrap();
	let raw: u64 = kani::any();
	let negative_b: bool = kani::any();
	let exponent_b: i32 = kani::any();
	kani::assume(raw == 0 || ((1_u64 << 62) <= raw && raw < (1_u64 << 63)));
	kani::assume(raw != 0 || exponent_b == 0);
	let b = Fixed::from_parts(
		if negative_b {
			-(raw as i64)
		} else {
			raw as i64
		},
		exponent_b,
	)
	.unwrap();
	// Algebraic oracle: multiplying by 2^62 preserves the mantissa. For
	// (2^63-1)*raw, raw=2^62 takes the low branch with mantissa 2^63-1;
	// larger raw takes the high branch with floor(raw-raw/2^63)=raw-1.
	// For (2^62+1)*raw the high branch is only raw=MAX, with result 2^62;
	// every other nonzero raw produces raw+1 without an exponent increment.
	let zero = raw == 0;
	let high = if MANTISSA == i64::MAX {
		raw > (1_u64 << 62)
	} else {
		MANTISSA == (1_i64 << 62) + 1 && raw == i64::MAX as u64
	};
	let exponent = if zero {
		0
	} else {
		i64::from(a.e()) + i64::from(b.e()) + i64::from(high)
	};
	let fits = (i64::from(i32::MIN)..=i64::from(i32::MAX)).contains(&exponent);
	let result = a.mul(b);
	assert!(result.is_ok() == fits, "multiply exponent acceptance");
	if let Err(error) = result {
		assert!(error == crate::Error::Numeric, "multiply overflow typed");
	}
	kani::cover!(zero && result == Ok(Fixed::ZERO), "multiply zero reachable");
	if MANTISSA > (1_i64 << 62) {
		kani::cover!(
			high && result.is_ok(),
			"multiply high normalization reachable"
		);
	}
	kani::cover!(
		!high && !zero && result.is_ok(),
		"multiply low normalization reachable"
	);
	kani::cover!(result.is_err(), "multiply overflow reachable");
	if let Ok(value) = result {
		assert!(representation(value), "multiply result canonical");
		assert!(
			i64::from(value.e()) == exponent,
			"multiply exponent restored"
		);
		assert!(
			(value.m() < 0) == (!zero && (a.m() < 0) != (b.m() < 0)),
			"multiply sign restored"
		);
		let expected = if MANTISSA == (1_i64 << 62) || zero {
			raw
		} else if MANTISSA == (1_i64 << 62) + 1 {
			if high { 1_u64 << 62 } else { raw + 1 }
		} else if high {
			raw - 1
		} else {
			i64::MAX as u64
		};
		#[cfg(kani_negative)]
		let expected = expected + 1;
		assert!(
			i128::from(value.m()).abs() as u128 == u128::from(expected),
			"multiply exact mantissa"
		);
	}
}

#[kani::proof]
#[kani::unwind(2)]
fn multiplication_unit_mantissa_contract() {
	multiplication_named::<0x4000_0000_0000_0000>();
}

#[kani::proof]
#[kani::unwind(2)]
fn multiplication_incremented_unit_contract() {
	multiplication_named::<0x4000_0000_0000_0001>();
}

// Unaccepted experiment: both MiniSAT and CaDiCaL exceeded the budget.
// Deliberately NOT a #[kani::proof]; the report/PLAN retain this proof gap.
#[allow(dead_code)]
fn multiplication_max_mantissa_contract() {
	multiplication_named::<0x7fff_ffff_ffff_ffff>();
}

/// Canonical wire pairs have zero/zero or a signed 63-bit normalized magnitude.
/// The i128 specification avoids reproducing the implementation's i64 wrapping.
#[kani::proof]
#[kani::unwind(2)]
fn fixed_parts_contract() {
	let mantissa: i64 = kani::any();
	let exponent: i32 = kani::any();
	let magnitude = i128::from(mantissa).abs();
	let low = 1_i128 << 62;
	let high = 1_i128 << 63;
	#[cfg(not(kani_negative))]
	let nonzero = low <= magnitude && magnitude < high;
	// Deliberately wrong upper endpoint: i64::MIN is not canonical.
	#[cfg(kani_negative)]
	let nonzero = low <= magnitude && magnitude <= high;
	let expected = (mantissa == 0 && exponent == 0) || nonzero;
	let result = Fixed::from_parts(mantissa, exponent);
	assert!(result.is_ok() == expected, "canonical acceptance contract");
	if let Ok(value) = result {
		assert!(
			value.parts() == (mantissa, exponent),
			"accepted parts preserved"
		);
		assert!(value.is_valid(), "accepted value canonical");
	}
	kani::cover!(mantissa == 0 && exponent == 0, "canonical zero reachable");
	kani::cover!(
		mantissa == -(1_i64 << 62) && exponent == i32::MIN,
		"negative canonical endpoint reachable"
	);
	kani::cover!(
		mantissa == i64::MAX && exponent == i32::MAX,
		"positive canonical endpoint reachable"
	);
	kani::cover!(
		mantissa == i64::MIN && !result.is_ok(),
		"rejected minimum mantissa reachable"
	);
	kani::cover!(
		mantissa == 0 && exponent != 0 && !result.is_ok(),
		"noncanonical zero reachable"
	);
}
