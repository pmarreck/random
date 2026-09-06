use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::{ByteSource, Error, MAX_EXACT_POSITION};

const KDF_CONTEXT: &str = "random drbg 2026-08-04 v1";
const CACHE_BYTES: usize = 1024;

#[derive(Clone, Zeroize, ZeroizeOnDrop)]
/// Seekable BLAKE3 keyed-XOF deterministic random byte generator.
///
/// Small draws share a private 1-KiB cache; exported positions count only bytes
/// returned to callers. Requests of 1 KiB or more use the direct bulk path.
/// Key material and cached bytes are zeroized on drop. BLAKE3 keyed and KDF
/// temporaries are wrapped in zeroizing guards as well.
pub struct Drbg {
	key: [u8; 32],
	position: u64,
	cache: [u8; CACHE_BYTES],
	cache_start: u64,
	cache_len: usize,
}

impl Drbg {
	/// Derive a fresh stream key from exactly 32 bytes of seed material.
	///
	/// The caller retains and is responsible for wiping `seed_material`.
	#[must_use]
	pub fn new(seed_material: &[u8; 32]) -> Self {
		let mut derivation = zeroize::Zeroizing::new(blake3::Hasher::new_derive_key(KDF_CONTEXT));
		derivation.update(seed_material);
		let derived = zeroize::Zeroizing::new(derivation.finalize());
		let mut key = zeroize::Zeroizing::new([0_u8; 32]);
		key.copy_from_slice(derived.as_bytes());
		Self {
			key: *key,
			position: 0,
			cache: [0; CACHE_BYTES],
			cache_start: 0,
			cache_len: 0,
		}
	}

	/// Restore a derived key and byte position previously returned by [`Self::state`].
	pub fn from_state(key: [u8; 32], position: u64) -> Result<Self, Error> {
		let key = zeroize::Zeroizing::new(key);
		if position > MAX_EXACT_POSITION {
			return Err(Error::PositionOverflow);
		}
		Ok(Self {
			key: *key,
			position,
			cache: [0; CACHE_BYTES],
			cache_start: 0,
			cache_len: 0,
		})
	}

	#[must_use]
	/// Export the derived stream key and current byte position.
	///
	/// The key is sensitive and the caller owns zeroizing the returned copy.
	pub fn state(&self) -> ([u8; 32], u64) {
		(self.key, self.position)
	}

	#[must_use]
	/// Return the current byte position within the keyed XOF.
	pub fn position(&self) -> u64 {
		self.position
	}

	/// Reposition this initialized stream without exposing or replacing its key.
	pub fn seek(&mut self, position: u64) -> Result<(), Error> {
		if position > MAX_EXACT_POSITION {
			return Err(Error::PositionOverflow);
		}
		self.position = position;
		self.cache.zeroize();
		self.cache_len = 0;
		Ok(())
	}

	/// Fill `out` with the next contiguous stream bytes and advance by its length.
	pub fn fill(&mut self, out: &mut [u8]) -> Result<(), Error> {
		let count = u64::try_from(out.len()).map_err(|_| Error::PositionOverflow)?;
		if self.position > MAX_EXACT_POSITION
			|| count > MAX_EXACT_POSITION.saturating_sub(self.position)
		{
			return Err(Error::PositionOverflow);
		}
		if out.is_empty() {
			return Ok(());
		}
		// Large requests retain BLAKE3's direct bulk path. Small draws share
		// aligned XOF blocks; only returned bytes advance the exported cursor.
		if out.len() >= CACHE_BYTES {
			fill_xof(&self.key, self.position, out);
			self.position += count;
			self.cache.zeroize();
			self.cache_len = 0;
			return Ok(());
		}
		let mut written = 0;
		while written < out.len() {
			if self.cache_len == 0
				|| self.position < self.cache_start
				|| self.position - self.cache_start >= self.cache_len as u64
			{
				self.cache.zeroize();
				self.cache_start = self.position / CACHE_BYTES as u64 * CACHE_BYTES as u64;
				self.cache_len =
					(MAX_EXACT_POSITION - self.cache_start).min(CACHE_BYTES as u64) as usize;
				fill_xof(
					&self.key,
					self.cache_start,
					&mut self.cache[..self.cache_len],
				);
			}
			let offset = (self.position - self.cache_start) as usize;
			let take = (out.len() - written).min(self.cache_len - offset);
			out[written..written + take].copy_from_slice(&self.cache[offset..offset + take]);
			written += take;
			self.position += take as u64;
		}
		Ok(())
	}

	/// Read the next four stream bytes as a big-endian `u32`.
	pub fn u32(&mut self) -> Result<u32, Error> {
		let mut bytes = [0_u8; 4];
		self.fill(&mut bytes)?;
		Ok(u32::from_be_bytes(bytes))
	}

	/// Read the next eight stream bytes as a big-endian `u64`.
	pub fn u64(&mut self) -> Result<u64, Error> {
		let mut bytes = [0_u8; 8];
		self.fill(&mut bytes)?;
		Ok(u64::from_be_bytes(bytes))
	}

	/// Explicitly wipe the derived key and cached bytes, and reset the position.
	pub fn zeroize(&mut self) {
		Zeroize::zeroize(self);
	}
}

/// Generate an exact XOF span; zeroize the temporary keyed state on return.
fn fill_xof(key: &[u8; 32], position: u64, out: &mut [u8]) {
	let hasher = zeroize::Zeroizing::new(blake3::Hasher::new_keyed(key));
	let mut reader = zeroize::Zeroizing::new(hasher.finalize_xof());
	reader.set_position(position);
	reader.fill(out);
}

impl ByteSource for Drbg {
	fn fill_exact(&mut self, out: &mut [u8]) -> Result<(), Error> {
		self.fill(out)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn buffered_draws_match_upstream_xof_across_boundaries_and_seeks() {
		let mut rng = Drbg::new(&[0x39; 32]);
		let (key, _) = rng.state();
		let mut reference = blake3::Hasher::new_keyed(&key).finalize_xof();
		for start in [0, 1, 63, 64, 1023, 1024, 1025, MAX_EXACT_POSITION - 5000] {
			rng.seek(start).unwrap();
			reference.set_position(start);
			for count in [0, 1, 4, 8, 63, 64, 1023, 1024, 2049] {
				let mut expected = vec![0; count];
				let mut actual = vec![0; count];
				reference.fill(&mut expected);
				rng.fill(&mut actual).unwrap();
				assert_eq!(actual, expected);
				assert_eq!(rng.position(), reference.position());
			}
		}
		rng.seek(0).unwrap();
		rng.u32().unwrap();
		assert_eq!(rng.cache_len, CACHE_BYTES);
		assert_eq!(
			rng.position(),
			4,
			"prefetch must not advance the logical cursor"
		);
		let mut clone = rng.clone();
		assert_eq!(rng.u64().unwrap(), clone.u64().unwrap());
		rng.seek(0).unwrap();
		assert_eq!(rng.cache_len, 0);
		assert!(rng.cache.iter().all(|&b| b == 0));
		rng.u32().unwrap();
		rng.zeroize();
		assert!(rng.cache.iter().all(|&b| b == 0));
		assert_eq!(rng.cache_len, 0);
	}

	#[test]
	fn cached_position_cap_errors_are_atomic_and_restore_does_not_reuse_bytes() {
		let mut rng = Drbg::new(&[0x17; 32]);
		rng.u32().unwrap();
		let mut unchanged = rng.clone();
		assert_eq!(
			rng.seek(MAX_EXACT_POSITION + 1),
			Err(Error::PositionOverflow)
		);
		assert_eq!(rng.position, unchanged.position);
		assert_eq!(rng.cache, unchanged.cache);
		assert_eq!(rng.u64().unwrap(), unchanged.u64().unwrap());
		rng.seek(MAX_EXACT_POSITION - 1).unwrap();
		let mut untouched = [0xa5; 2];
		assert_eq!(rng.fill(&mut untouched), Err(Error::PositionOverflow));
		assert_eq!(untouched, [0xa5; 2]);
		assert_eq!(rng.position(), MAX_EXACT_POSITION - 1);
		rng.fill(&mut untouched[..1]).unwrap();
		assert_eq!(rng.position(), MAX_EXACT_POSITION);
		rng.fill(&mut []).unwrap();
		assert_eq!(rng.fill(&mut untouched), Err(Error::PositionOverflow));
		let (key, _) = rng.state();
		let mut restored = Drbg::from_state(key, 0).unwrap();
		assert_eq!(restored.cache_len, 0);
		let mut fresh = Drbg::new(&[0x17; 32]);
		assert_eq!(restored.u64().unwrap(), fresh.u64().unwrap());
	}

	#[test]
	fn seed_42_matches_frozen_stream() {
		let mut seed = [0_u8; 32];
		seed[31] = 42;
		let mut rng = Drbg::new(&seed);
		let mut output = [0_u8; 64];
		rng.fill(&mut output).unwrap();
		assert_eq!(
            output,
            hex64(b"69dfe2e9b579cf6dfe3d71b11024db6eb49d5b9861505b3ecfc3d379a6dc8f04b6900db333d20760661226da010db589c5080aaf5f6068fc0874ce62aca36f60")
        );
	}

	#[test]
	fn chunking_is_position_independent() {
		let seed = [0xa5; 32];
		let mut whole = Drbg::new(&seed);
		let mut chunked = Drbg::new(&seed);
		let mut expected = [0_u8; 131];
		let mut actual = [0_u8; 131];
		whole.fill(&mut expected).unwrap();
		chunked.fill(&mut actual[..31]).unwrap();
		chunked.fill(&mut actual[31..65]).unwrap();
		chunked.fill(&mut actual[65..]).unwrap();
		assert_eq!(actual, expected);
	}

	#[test]
	fn state_cap_endian_helpers_and_zeroization_are_typed() {
		let key = [0x5a; 32];
		assert_eq!(
			Drbg::from_state(key, MAX_EXACT_POSITION + 1).err(),
			Some(Error::PositionOverflow)
		);
		let mut at_cap = Drbg::from_state(key, MAX_EXACT_POSITION).unwrap();
		assert_eq!(at_cap.fill(&mut []), Ok(()));
		assert_eq!(at_cap.fill(&mut [0]), Err(Error::PositionOverflow));

		let mut source = Drbg::new(&[0_u8; 32]);
		let mut reference = source.clone();
		let mut bytes = [0_u8; 12];
		reference.fill(&mut bytes).unwrap();
		assert_eq!(
			source.u32().unwrap(),
			u32::from_be_bytes(bytes[..4].try_into().unwrap())
		);
		assert_eq!(
			source.u64().unwrap(),
			u64::from_be_bytes(bytes[4..].try_into().unwrap())
		);

		source.zeroize();
		assert_eq!(source.state(), ([0_u8; 32], 0));
	}

	#[test]
	fn seek_repositions_a_seeded_stream_without_exporting_its_key() {
		let seed = [0x39; 32];
		let mut reference = Drbg::new(&seed);
		let mut resumed = Drbg::new(&seed);
		let mut skipped = [0_u8; 37];
		let mut expected = [0_u8; 29];
		let mut actual = [0_u8; 29];
		reference.fill(&mut skipped).unwrap();
		reference.fill(&mut expected).unwrap();
		resumed.seek(37).unwrap();
		resumed.fill(&mut actual).unwrap();
		assert_eq!(actual, expected);
		assert_eq!(
			resumed.seek(MAX_EXACT_POSITION + 1),
			Err(Error::PositionOverflow)
		);
	}

	fn hex64(input: &[u8; 128]) -> [u8; 64] {
		let mut out = [0_u8; 64];
		for (index, pair) in input.chunks_exact(2).enumerate() {
			out[index] = (nibble(pair[0]) << 4) | nibble(pair[1]);
		}
		out
	}

	fn nibble(value: u8) -> u8 {
		match value {
			b'0'..=b'9' => value - b'0',
			b'a'..=b'f' => value - b'a' + 10,
			_ => panic!("invalid frozen hex"),
		}
	}
}
