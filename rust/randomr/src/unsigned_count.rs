use alloc::{string::String, vec::Vec};
use core::fmt::Write;

use crate::Error;

/// Exact nonnegative integer in canonical little-endian magnitude bytes.
/// Its BLIP form is unsigned, not blip_mp's signed two's-complement encoding.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct UnsignedCount(pub(crate) Vec<u8>);

impl UnsignedCount {
	/// Parse unsigned decimal digits without a native-width integer conversion.
	pub fn from_decimal(text: &str) -> Result<Self, Error> {
		if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
			return Err(Error::InvalidArgument);
		}
		let mut value = Self::default();
		for byte in text.bytes() {
			value.multiply_add(10, u16::from(byte - b'0'))?;
		}
		Ok(value)
	}

	// Only decimal parsing and bit reconstruction use this small multiplier.
	pub(crate) fn multiply_add(&mut self, multiplier: u16, mut carry: u16) -> Result<(), Error> {
		self.0.try_reserve(1).map_err(|_| Error::Numeric)?;
		for byte in &mut self.0 {
			let value = u16::from(*byte) * multiplier + carry;
			*byte = (value & 255) as u8;
			carry = value >> 8;
		}
		while carry != 0 {
			self.0.push((carry & 255) as u8);
			carry >>= 8;
		}
		Ok(())
	}

	/// Borrow the canonical magnitude, with an empty slice denoting zero.
	pub fn magnitude(&self) -> &[u8] {
		&self.0
	}

	/// Return a canonical unsigned little-endian BLIP v1.2 encoding.
	pub fn to_blip(&self) -> Vec<u8> {
		if self.0.is_empty() {
			return alloc::vec![0];
		}
		if self.0.len() == 1 && self.0[0] < 128 {
			return self.0.clone();
		}
		let mut output = Vec::with_capacity(self.0.len() + 11);
		output.push(0x80 | ((self.0.len() & 31) as u8));
		if self.0.len() >= 32 {
			output[0] |= 0x20;
			let mut remaining = self.0.len() >> 5;
			while remaining != 0 {
				let next = remaining >> 7;
				output.push((remaining & 127) as u8 | if next != 0 { 128 } else { 0 });
				remaining = next;
			}
		}
		output.extend_from_slice(&self.0);
		output
	}

	/// Exact decimal text using base-10^9 scratch digits, never an IEEE float.
	pub fn to_decimal(&self) -> String {
		if self.0.is_empty() {
			return String::from("0");
		}
		let mut digits = alloc::vec![0_u64];
		for byte in self.0.iter().rev() {
			let mut carry = u64::from(*byte);
			for digit in &mut digits {
				let value = *digit * 256 + carry;
				*digit = value % 1_000_000_000;
				carry = value / 1_000_000_000;
			}
			if carry != 0 {
				digits.push(carry);
			}
		}
		let mut text = alloc::format!("{}", digits[digits.len() - 1]);
		for digit in digits[..digits.len() - 1].iter().rev() {
			write!(&mut text, "{digit:09}").expect("writing to a String is infallible");
		}
		text
	}

	/// Exact numeric hexadecimal text, without the BLIP header or a prefix.
	pub fn to_hex(&self) -> String {
		if self.0.is_empty() {
			return String::from("0");
		}
		let mut text = alloc::format!("{:x}", self.0[self.0.len() - 1]);
		for byte in self.0[..self.0.len() - 1].iter().rev() {
			write!(&mut text, "{byte:02x}").expect("writing to a String is infallible");
		}
		text
	}
}
