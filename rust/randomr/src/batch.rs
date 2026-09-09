use crate::{ByteSource, Drbg, Error, Fixed, normal_int};

/// Failure after a successfully written prefix of a batch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BatchError {
	/// Number of initialized outputs; the remaining destination is untouched.
	pub written: usize,
	/// Scalar-equivalent failure, with identical source consumption.
	pub error: Error,
}

impl core::fmt::Display for BatchError {
	fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		write!(
			formatter,
			"batch failed after {} values: {}",
			self.written, self.error
		)
	}
}

#[cfg(feature = "std")]
impl std::error::Error for BatchError {
	fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
		Some(&self.error)
	}
}

/// Fill a caller-owned slice with sequential range-scaled normal samples.
///
/// This portable scalar entry works with any byte source. Use
/// [`Drbg::normal_int_batch`] for automatic SIMD selection. Errors report the
/// initialized prefix; the remaining destination is unchanged. Invalid bounds
/// fail before consuming bytes, including for an empty destination.
/// Bounds must be ordered and each within ±[`crate::MAX_EXACT_INTEGER`].
pub fn normal_int_batch(
	source: &mut impl ByteSource,
	start: i64,
	end: i64,
	out: &mut [i64],
) -> Result<(), BatchError> {
	parameters(start, end).map_err(|error| BatchError { written: 0, error })?;
	for (written, slot) in out.iter_mut().enumerate() {
		*slot = normal_int(source, start, end).map_err(|error| BatchError { written, error })?;
	}
	Ok(())
}

fn parameters(start: i64, end: i64) -> Result<(Fixed, Fixed), Error> {
	if start > end || start < -crate::MAX_EXACT_INTEGER || end > crate::MAX_EXACT_INTEGER {
		return Err(Error::InvalidArgument);
	}
	let width =
		i64::try_from(i128::from(end) - i128::from(start)).map_err(|_| Error::InvalidArgument)?;
	Ok((
		Fixed::from_i64(width).div(Fixed::from_i64(6))?,
		Fixed::from_i64(width).div(Fixed::from_i64(2))?,
	))
}

impl Drbg {
	/// Fill a bounded-memory batch, preserving scalar output and byte positions.
	///
	/// Uses AVX2 when available on std-enabled x86_64 builds; otherwise scalar.
	/// Four candidates are computed at a time, in stream order. Rejected tails
	/// consume the same bytes as repeated [`normal_int`] calls. Scratch space is
	/// constant regardless of destination length; no samples are retained.
	/// A failing group is replayed scalarly to preserve the exact error prefix.
	/// Bounds must be ordered and each within ±[`crate::MAX_EXACT_INTEGER`];
	/// invalid bounds leave the source and destination untouched, even if empty.
	pub fn normal_int_batch(
		&mut self,
		start: i64,
		end: i64,
		out: &mut [i64],
	) -> Result<(), BatchError> {
		#[cfg(all(feature = "std", target_arch = "x86_64"))]
		if std::is_x86_feature_detected!("avx2") && out.len() >= 4 {
			return vector_batch(self, start, end, out);
		}
		normal_int_batch(self, start, end, out)
	}
}

#[cfg(all(feature = "std", target_arch = "x86_64"))]
fn vector_batch(
	source: &mut Drbg,
	start: i64,
	end: i64,
	out: &mut [i64],
) -> Result<(), BatchError> {
	let (sixth, half) = parameters(start, end).map_err(|error| BatchError { written: 0, error })?;
	let mut written = 0;
	while out.len() - written >= 4 {
		let position = source.position();
		let candidates = (|| -> Result<[i64; 4], Error> {
			let mut u1 = [Fixed::ZERO; 4];
			let mut u2 = [Fixed::ZERO; 4];
			for lane in 0..4 {
				u1[lane] = Fixed::from_ratio(crate::range(source, 1, 1_000_000)?, 1_000_000)?;
				u2[lane] = Fixed::from_ratio(crate::range(source, 1, 1_000_000)?, 1_000_000)?;
			}
			let (logs, cosines) = crate::batch_avx2::uniform_kernels(u1, u2)?;
			let mut values = [0; 4];
			for lane in 0..4 {
				let radius = Fixed::from_i64(-2).mul(logs[lane])?.sqrt()?;
				values[lane] = radius
					.mul(cosines[lane])?
					.mul(sixth)?
					.add(half)?
					.add(Fixed::from_i64(start))?
					.round_to_i64()?;
			}
			Ok(values)
		})();
		match candidates {
			Ok(values) => {
				for value in values {
					if value >= start && value <= end {
						out[written] = value;
						written += 1;
					}
				}
			}
			Err(_) => {
				// Replay the failing speculative group with scalar call boundaries.
				// No output from this group was committed, and seek wipes its cache.
				source.seek(position).expect("saved position is valid");
				return normal_int_batch(source, start, end, &mut out[written..]).map_err(
					|failure| BatchError {
						written: written + failure.written,
						error: failure.error,
					},
				);
			}
		}
	}
	normal_int_batch(source, start, end, &mut out[written..]).map_err(|failure| BatchError {
		written: written + failure.written,
		error: failure.error,
	})
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn unsupported_ranges_fail_before_source_or_destination_changes() {
		let limit = crate::MAX_EXACT_INTEGER;
		for (start, end) in [
			(2, 1),
			(-limit - 1, 0),
			(0, limit + 1),
			(-limit - 1, -limit - 1),
			(limit + 1, limit + 1),
			(i64::MIN, i64::MAX),
			(i64::MAX - 32, i64::MAX),
			(i64::MIN, i64::MIN + 32),
		] {
			for count in [0, 1, 4, 9] {
				let mut a = Drbg::new(&[0; 32]);
				a.u32().unwrap();
				let mut b = a.clone();
				let expected_state = a.state();
				let mut x = alloc::vec![123;count];
				let mut y = x.clone();
				let expected = Err(BatchError {
					written: 0,
					error: Error::InvalidArgument,
				});
				assert_eq!(a.normal_int_batch(start, end, &mut x), expected);
				assert_eq!(normal_int_batch(&mut b, start, end, &mut y), expected);
				assert_eq!(x, alloc::vec![123;count]);
				assert_eq!(y, x);
				assert_eq!(a.state(), expected_state);
				assert_eq!(b.state(), expected_state);
				assert_eq!(a.u64().unwrap(), b.u64().unwrap());
			}
		}
	}
	#[test]
	fn supported_endpoints_and_full_interval_match_scalar() {
		let limit = crate::MAX_EXACT_INTEGER;
		for (start, end) in [
			(-limit, -limit),
			(limit, limit),
			(-limit, limit),
			(-limit, -limit + 1),
			(limit - 1, limit),
			(7, 7),
		] {
			for count in [0, 1, 4, 9] {
				let mut scalar = Drbg::new(&[42; 32]);
				let mut batch = scalar.clone();
				let mut generic = scalar.clone();
				let expected: alloc::vec::Vec<i64> = (0..count)
					.map(|_| normal_int(&mut scalar, start, end).unwrap())
					.collect();
				let mut actual = alloc::vec![123;count];
				batch.normal_int_batch(start, end, &mut actual).unwrap();
				assert_eq!(actual, expected);
				actual.fill(123);
				normal_int_batch(&mut generic, start, end, &mut actual).unwrap();
				assert_eq!(actual, expected);
				assert_eq!(batch.position(), scalar.position());
				assert_eq!(generic.position(), scalar.position());
			}
		}
	}
	#[test]
	fn split_batches_preserve_rejection_order() {
		let mut scalar = Drbg::new(&[0; 32]);
		let mut batch = scalar.clone();
		let mut whole = [0; 4096];
		normal_int_batch(&mut scalar, 0, 255, &mut whole).unwrap();
		assert!(
			scalar.position() > whole.len() as u64 * 8,
			"corpus must exercise rejection"
		);
		let mut actual = [0; 4096];
		for part in actual.chunks_mut(37) {
			batch.normal_int_batch(0, 255, part).unwrap();
		}
		assert_eq!(actual, whole);
		assert_eq!(batch.position(), scalar.position());
	}
	#[test]
	fn generic_partial_read_failures_preserve_scalar_calls() {
		struct Failing {
			bytes: alloc::vec::Vec<u8>,
			cursor: usize,
			cap: usize,
		}
		impl ByteSource for Failing {
			fn fill_exact(&mut self, out: &mut [u8]) -> Result<(), Error> {
				for slot in out {
					if self.cursor == self.cap {
						return Err(Error::Entropy);
					}
					*slot = self.bytes[self.cursor];
					self.cursor += 1;
				}
				Ok(())
			}
		}
		let mut bytes = alloc::vec![0;128];
		Drbg::new(&[42; 32]).fill(&mut bytes).unwrap();
		// Force uniform rejection, then a normal tail rejection (u1≈0,u2≈1).
		bytes[..12].copy_from_slice(&[255, 255, 255, 255, 0, 0, 0, 0, 0, 15, 66, 63]);
		for cap in 0..80 {
			let mut a = Failing {
				bytes: bytes.clone(),
				cursor: 0,
				cap,
			};
			let mut b = Failing {
				bytes: bytes.clone(),
				cursor: 0,
				cap,
			};
			let mut expected = [999; 9];
			let mut result = Ok(());
			for (written, slot) in expected.iter_mut().enumerate() {
				match normal_int(&mut a, 0, 255) {
					Ok(v) => *slot = v,
					Err(error) => {
						result = Err(BatchError { written, error });
						break;
					}
				}
			}
			let mut actual = [999; 9];
			assert_eq!(normal_int_batch(&mut b, 0, 255, &mut actual), result);
			assert_eq!(actual, expected);
			assert_eq!(a.cursor, b.cursor);
		}
	}
	#[test]
	fn batches_preserve_scalar_values_positions_and_tails() {
		for seed in 0..16 {
			for count in [0, 1, 2, 3, 4, 5, 7, 8, 31, 127] {
				let mut scalar = Drbg::new(&[seed; 32]);
				let mut batch = scalar.clone();
				let mut actual = alloc::vec![0; count];
				batch.normal_int_batch(-100, 255, &mut actual).unwrap();
				for value in actual {
					assert_eq!(value, normal_int(&mut scalar, -100, 255).unwrap());
				}
				assert_eq!(batch.position(), scalar.position());
			}
		}
	}
	#[test]
	fn every_cap_boundary_has_identical_prefix_error_and_cursor() {
		for remaining in 0..65 {
			let mut scalar = Drbg::new(&[42; 32]);
			scalar.seek(crate::MAX_EXACT_POSITION - remaining).unwrap();
			let mut batch = scalar.clone();
			let mut expected = [i64::MIN; 9];
			let mut result = Ok(());
			for (written, slot) in expected.iter_mut().enumerate() {
				match normal_int(&mut scalar, 0, 255) {
					Ok(value) => *slot = value,
					Err(error) => {
						result = Err(BatchError { written, error });
						break;
					}
				}
			}
			let mut actual = [i64::MIN; 9];
			assert_eq!(batch.normal_int_batch(0, 255, &mut actual), result);
			assert_eq!(actual, expected);
			assert_eq!(batch.position(), scalar.position());
		}
	}
}
