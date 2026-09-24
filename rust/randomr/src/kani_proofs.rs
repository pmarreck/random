//! Bounded verifier harnesses over unchanged production functions.
//! No assumptions, stubs, entropy or symbolic cryptographic evaluation.

use crate::Fixed;

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
