#![cfg_attr(not(feature = "std"), no_std)]
#![deny(unsafe_code)]
#![warn(missing_docs)]
//! Pure, integer-only deterministic random generation shared by `randomr`.
//!
//! A seed is replay material, not a password: identical seed and calls
//! intentionally produce identical bytes on every supported target. Keep it
//! secret whenever the generated stream must remain unpredictable. The
//! stateful [`Drbg`] is the only deterministic state; samplers accept any
//! caller-owned [`ByteSource`], which keeps entropy selection outside the math.
//!
//! ```
//! use randomr::{Drbg, range};
//!
//! let mut seed = [0_u8; 32];
//! seed[31] = 42;
//! let mut source = Drbg::new(&seed);
//! assert_eq!(range(&mut source, 0, 99)?, 97);
//! # Ok::<(), randomr::Error>(())
//! ```

extern crate alloc;

mod batch;
#[cfg(all(feature = "std", target_arch = "x86_64"))]
mod batch_avx2;
mod curve;
mod distribution;
mod drbg;
mod error;
mod fixed;

#[cfg(feature = "entropy")]
pub mod entropy;

pub use batch::{BatchError, normal_int_batch};
pub use curve::{Curve, Distribution};
pub use distribution::{
	beta, exponential, log_normal, normal, normal_int, poisson, range, uniform,
};
pub use drbg::Drbg;
pub use error::Error;
pub use fixed::Fixed;

/// Largest exactly supported signed-integer magnitude and range cardinality.
pub const MAX_EXACT_INTEGER: i64 = 9_007_199_254_740_992;
/// Largest exactly supported DRBG byte position.
pub const MAX_EXACT_POSITION: u64 = MAX_EXACT_INTEGER as u64;

/// Minimal fallible byte-source interface consumed by all samplers.
pub trait ByteSource {
	/// Fill the complete destination or return a typed failure.
	fn fill_exact(&mut self, out: &mut [u8]) -> Result<(), Error>;

	/// Read one big-endian `u32` without changing source semantics.
	fn u32_be(&mut self) -> Result<u32, Error> {
		let mut bytes = [0_u8; 4];
		self.fill_exact(&mut bytes)?;
		Ok(u32::from_be_bytes(bytes))
	}

	/// Read one big-endian `u64` without changing source semantics.
	fn u64_be(&mut self) -> Result<u64, Error> {
		let mut bytes = [0_u8; 8];
		self.fill_exact(&mut bytes)?;
		Ok(u64::from_be_bytes(bytes))
	}
}
