//! Cursor contracts over the real DRBG; cryptographic bytes are outside scope.
use super::*;
use core::mem::ManuallyDrop;

// Model only the zeroize optimization barrier's lack of program-memory effects.
// The actual volatile erasure writes remain under verification. This does not
// prove that a release compiler retains those writes or prove drop-time erasure.
fn compiler_barrier<T: ?Sized>(_val: &T) {}

#[kani::proof]
#[kani::unwind(33)]
#[kani::stub(zeroize::optimization_barrier, compiler_barrier)]
fn restore_contract() {
	let key: [u8; 32] = kani::any();
	let requested: u64 = kani::any();
	let index: usize = kani::any();
	kani::assume(index < CACHE_BYTES);
	let result = Drbg::from_state(key, requested);
	let accepted = result.is_ok();
	assert!(
		accepted == (requested <= MAX_EXACT_POSITION),
		"restore cap acceptance"
	);
	let exported = match result {
		Ok(value) => {
			let value = ManuallyDrop::new(value);
			assert!(
				value.cache[index] == 0 && value.cache_len == 0 && value.cache_start == 0,
				"restore starts with empty cache"
			);
			Some(value.state())
		}
		Err(error) => {
			assert!(error == Error::PositionOverflow, "restore error typed");
			None
		}
	};
	kani::cover!(requested == 0 && accepted, "restore zero reachable");
	kani::cover!(
		requested == MAX_EXACT_POSITION && accepted,
		"restore cap reachable"
	);
	kani::cover!(
		requested == MAX_EXACT_POSITION + 1 && !accepted,
		"restore cap plus one rejected reachable"
	);
	kani::cover!(
		requested == u64::MAX && !accepted,
		"restore maximum rejected reachable"
	);
	#[cfg(not(kani_negative))]
	let expected_pos = requested;
	#[cfg(kani_negative)]
	let expected_pos = requested.wrapping_add(1);
	assert!(
		exported
			== if accepted {
				Some((key, expected_pos))
			} else {
				None
			},
		"restore exported state exact"
	);
}

fn symbolic_state() -> ManuallyDrop<Drbg> {
	let position: u64 = kani::any();
	kani::assume(position <= MAX_EXACT_POSITION);
	ManuallyDrop::new(Drbg {
		key: kani::any(),
		position,
		cache: kani::any(),
		cache_start: kani::any(),
		cache_len: kani::any(),
	})
}

#[kani::proof]
#[kani::unwind(1025)]
#[kani::stub(zeroize::optimization_barrier, compiler_barrier)]
fn seek_contract() {
	let mut state = symbolic_state();
	let key = state.key;
	let index: usize = kani::any();
	kani::assume(index < CACHE_BYTES);
	let cache_byte = state.cache[index];
	let before = (state.position, state.cache_start, state.cache_len);
	let requested: u64 = kani::any();
	// Witness inputs before the long erasure path. The post-operation checks
	// still require reachable successful/error branches and exact semantics.
	kani::cover!(requested == 0, "seek zero reachable");
	kani::cover!(requested == MAX_EXACT_POSITION, "seek cap reachable");
	kani::cover!(requested > MAX_EXACT_POSITION, "seek error reachable");
	kani::cover!(index == 0, "seek first cache byte reachable");
	kani::cover!(index == CACHE_BYTES - 1, "seek last cache byte reachable");
	kani::cover!(
		cache_byte != 0 && requested <= MAX_EXACT_POSITION,
		"seek nonzero cache byte reachable"
	);
	let result = state.seek(requested);
	assert!(
		result.is_ok() == (requested <= MAX_EXACT_POSITION),
		"seek cap acceptance"
	);
	assert!(state.key == key, "seek preserves key");
	if result.is_ok() {
		assert!(state.position == requested, "seek requested position");
		assert!(
			state.cache_len == 0 && state.cache[index] == 0,
			"seek wipes cache"
		);
	} else {
		assert!(
			(state.position, state.cache_start, state.cache_len) == before
				&& state.cache[index] == cache_byte,
			"seek failure state unchanged"
		);
		#[cfg(not(kani_negative))]
		let expected = Error::PositionOverflow;
		#[cfg(kani_negative)]
		let expected = Error::Numeric;
		assert!(result == Err(expected), "seek error typed");
	}
}

fn forbidden_xof(_key: &[u8; 32], _position: u64, _out: &mut [u8]) {
	assert!(false, "XOF unreachable on preflight error");
}

// A forbidden call, not an erasure model: these read contracts must never
// reach any cache wipe. Successful seek separately checks the real writes.
fn forbidden_array_erasure<Z: Zeroize, const N: usize>(_array: &mut [Z; N]) {
	assert!(false, "cache erasure unreachable on read contract");
}

#[kani::proof]
#[kani::unwind(9)]
#[kani::stub(zeroize::optimization_barrier, compiler_barrier)]
#[kani::stub(super::fill_xof, forbidden_xof)]
#[kani::stub(<[u8; 1024] as zeroize::Zeroize>::zeroize, forbidden_array_erasure)]
fn fill_error_contract() {
	let mut state = symbolic_state();
	let index: usize = kani::any();
	kani::assume(index < CACHE_BYTES);
	let key_index: usize = kani::any();
	kani::assume(key_index < 32);
	let key_byte = state.key[key_index];
	let cache_byte = state.cache[index];
	let before = (state.position, state.cache_start, state.cache_len);
	let mut out: [u8; 8] = kani::any();
	let saved = out;
	let count: usize = kani::any();
	kani::assume(count <= out.len());
	kani::assume(count as u64 > MAX_EXACT_POSITION - state.position);
	let result = state.fill(&mut out[..count]);
	assert!(result == Err(Error::PositionOverflow), "read error typed");
	assert!(
		state.key[key_index] == key_byte
			&& (state.position, state.cache_start, state.cache_len) == before
			&& state.cache[index] == cache_byte,
		"read error state unchanged"
	);
	#[cfg(not(kani_negative))]
	let expected = saved;
	#[cfg(kani_negative)]
	let expected = {
		let mut wrong = saved;
		wrong[0] ^= 1;
		wrong
	};
	kani::cover!(
		before.0 == MAX_EXACT_POSITION && count == 1,
		"read at cap error reachable"
	);
	kani::cover!(
		before.0 == MAX_EXACT_POSITION - 7 && count == 8,
		"read crossing cap error reachable"
	);
	assert!(out == expected, "read error destination unchanged");
}

#[kani::proof]
#[kani::unwind(9)]
#[kani::stub(zeroize::optimization_barrier, compiler_barrier)]
#[kani::stub(super::fill_xof, forbidden_xof)]
#[kani::stub(<[u8; 1024] as zeroize::Zeroize>::zeroize, forbidden_array_erasure)]
fn cached_read_8_contract() {
	let mut state = symbolic_state();
	let count: usize = kani::any();
	let offset: usize = kani::any();
	kani::assume(count <= 8 && offset < CACHE_BYTES);
	kani::assume(state.cache_len <= CACHE_BYTES && offset + count <= state.cache_len);
	kani::assume(
		state.position >= offset as u64 && count as u64 <= MAX_EXACT_POSITION - state.position,
	);
	state.cache_start = state.position - offset as u64;
	let before = (state.position, state.cache_start, state.cache_len);
	let key_index: usize = kani::any();
	kani::assume(key_index < 32);
	let key_byte = state.key[key_index];
	let cache_index: usize = kani::any();
	kani::assume(cache_index < CACHE_BYTES);
	let cache_byte = state.cache[cache_index];
	let mut out: [u8; 8] = kani::any();
	let mut expected = out;
	for index in 0..count {
		expected[index] = state.cache[offset + index];
	}
	let result = state.fill(&mut out[..count]);
	assert!(result.is_ok(), "cached read success");
	assert!(
		state.key[key_index] == key_byte
			&& state.cache[cache_index] == cache_byte
			&& state.cache_start == before.1
			&& state.cache_len == before.2,
		"cached read immutable backing state"
	);
	assert!(
		state.position == before.0 + count as u64,
		"cached read exact cursor"
	);
	kani::cover!(
		count == 0 && before.0 == MAX_EXACT_POSITION,
		"cached empty read at cap reachable"
	);
	kani::cover!(
		count == 8 && offset == CACHE_BYTES - 8,
		"cached last eight bytes reachable"
	);
	kani::cover!(count == 1 && offset == 0, "cached first byte reachable");
	#[cfg(kani_negative)]
	{
		expected[0] ^= 1;
	}
	assert!(out == expected, "cached read exact bytes untouched tail");
}
