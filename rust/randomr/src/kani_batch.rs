//! Portable wrapper composition and an actual scalar immediate-source-failure path.
//! AVX2 and successful nonlinear scalar calculations are outside these contracts.
use super::*;

struct Script {
	values: [u64; 4],
	index: usize,
	fail_at: usize,
	attempts: usize,
}

impl ByteSource for Script {
	fn fill_exact(&mut self, _out: &mut [u8]) -> Result<(), Error> {
		self.attempts += 1;
		Err(Error::EndOfSource)
	}
	fn u64_be(&mut self) -> Result<u64, Error> {
		self.attempts += 1;
		if self.index == self.fail_at {
			return Err(Error::EndOfSource);
		}
		let value = self.values[self.index];
		self.index += 1;
		Ok(value)
	}
}

// Explicit contract assumption: one modeled word returns one scalar sample or
// the original source error. The production wrapper and parameter kernel run.
fn modeled_scalar(
	source: &mut impl ByteSource,
	_start: i64,
	_end: i64,
	_sixth: Fixed,
	_half: Fixed,
	_first: Fixed,
) -> Result<i64, Error> {
	source.u64_be().map(|value| value as i64)
}

// A stale/unused scalar stub must fail promptly rather than accidentally
// expanding the nonlinear sampler or silently changing the proof's scope.
fn forbidden_normal(_source: &mut impl ByteSource) -> Result<Fixed, Error> {
	assert!(
		false,
		"nonlinear normal unreachable under batch scalar model"
	);
	Ok(Fixed::ZERO)
}

#[kani::proof]
#[kani::unwind(33)]
#[kani::stub(crate::batch::sample_prepared, modeled_scalar)]
#[kani::stub(crate::ziggurat::normal, forbidden_normal)]
fn portable_wrapper_contract() {
	let values: [u64; 4] = kani::any();
	let fail_at: usize = kani::any();
	let count: usize = kani::any();
	kani::assume(fail_at <= 4 && count <= 4);
	let mut source = Script {
		values,
		index: 0,
		fail_at,
		attempts: 0,
	};
	let mut out: [i64; 4] = kani::any();
	let mut expected_out = out;
	let result = normal_int_batch(&mut source, 0, 20, &mut out[..count]);
	let initialized = count.min(fail_at);
	for index in 0..initialized {
		expected_out[index] = values[index] as i64;
	}
	let expected_result = if fail_at < count {
		Err(BatchError {
			written: fail_at,
			error: Error::EndOfSource,
		})
	} else {
		Ok(())
	};
	assert!(result == expected_result, "batch typed prefix result");
	assert!(
		source.index == initialized
			&& source.attempts == initialized + usize::from(fail_at < count),
		"batch scalar source consumption"
	);
	kani::cover!(count == 0, "batch empty reachable");
	kani::cover!(count == 4 && fail_at == 4, "batch four successes reachable");
	kani::cover!(
		count == 4 && fail_at == 2,
		"batch partial failure reachable"
	);
	kani::cover!(
		count == 1 && fail_at == 0,
		"batch immediate failure reachable"
	);
	#[cfg(kani_negative)]
	{
		expected_out[0] ^= 1;
	}
	assert!(
		out == expected_out,
		"batch initialized prefix untouched tail"
	);
}

#[kani::proof]
#[kani::unwind(33)]
fn portable_source_error_contract() {
	let count: usize = kani::any();
	kani::assume(count <= 4);
	let mut source = Script {
		values: [0; 4],
		index: 0,
		fail_at: 0,
		attempts: 0,
	};
	let mut out: [i64; 4] = kani::any();
	let mut saved = out;
	let result = normal_int_batch(&mut source, 0, 20, &mut out[..count]);
	let expected = if count == 0 {
		Ok(())
	} else {
		Err(BatchError {
			written: 0,
			error: Error::EndOfSource,
		})
	};
	assert!(result == expected, "batch actual scalar source error typed");
	assert!(
		source.attempts == usize::from(count != 0) && source.index == 0,
		"batch actual scalar source error consumption"
	);
	kani::cover!(
		count == 0 && result.is_ok(),
		"batch actual empty success reachable"
	);
	kani::cover!(
		count == 4 && result.is_err(),
		"batch actual first error reachable"
	);
	#[cfg(kani_negative)]
	{
		saved[0] ^= 1;
	}
	assert!(
		out == saved,
		"batch actual source error destination unchanged"
	);
}
