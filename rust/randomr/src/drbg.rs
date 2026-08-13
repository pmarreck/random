use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::{ByteSource, Error, MAX_EXACT_POSITION};

const KDF_CONTEXT: &str = "random drbg 2026-08-04 v1";

#[derive(Clone, Zeroize, ZeroizeOnDrop)]
/// Seekable BLAKE3 keyed-XOF deterministic random byte generator.
///
/// Stored key material is zeroized on drop. BLAKE3 keyed and KDF temporaries
/// are wrapped in zeroizing guards as well.
pub struct Drbg {
	key: [u8; 32],
	position: u64,
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
		let hasher = zeroize::Zeroizing::new(blake3::Hasher::new_keyed(&self.key));
		let mut reader = zeroize::Zeroizing::new(hasher.finalize_xof());
		reader.set_position(self.position);
		reader.fill(out);
		self.position += count;
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

	/// Explicitly wipe the derived key and reset the position.
	pub fn zeroize(&mut self) {
		Zeroize::zeroize(self);
	}
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
