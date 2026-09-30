//! Named-cardinality contracts over production rejection and modulo reduction.
//! Symbolic words model the ByteSource word contract, not the BLAKE3 primitive.
use super::*;

struct Words {
	first: u64,
	reads: u8,
}

impl Words {
	fn word(&mut self) -> Result<u64, Error> {
		let value = if self.reads == 0 { self.first } else { 0 };
		self.reads += 1;
		Ok(value)
	}
}

impl ByteSource for Words {
	fn fill_exact(&mut self, _out: &mut [u8]) -> Result<(), Error> {
		panic!("range must use the word interface")
	}
	fn u32_be(&mut self) -> Result<u32, Error> {
		self.word().map(|value| value as u32)
	}
	fn u64_be(&mut self) -> Result<u64, Error> {
		self.word()
	}
}

fn named<const SPAN: u64>() {
	let start: i64 = kani::any();
	let last = i128::from(start) + i128::from(SPAN) - 1;
	kani::assume(last <= i128::from(i64::MAX));
	let end = last as i64;
	let universe = if SPAN <= (1_u64 << 32) {
		1_u128 << 32
	} else {
		1_u128 << 64
	};
	let draw = if SPAN <= (1_u64 << 32) {
		u64::from(kani::any::<u32>())
	} else {
		kani::any::<u64>()
	};
	let cutoff = universe - universe % u128::from(SPAN);
	let accepted = u128::from(draw) < cutoff;
	let mut source = Words {
		first: draw,
		reads: 0,
	};
	let actual = range(&mut source, start, end).unwrap();
	let offset = if accepted { draw % SPAN } else { 0 };
	#[cfg(not(kani_negative))]
	let expected = i128::from(start) + i128::from(offset);
	#[cfg(kani_negative)]
	let expected = i128::from(start) + i128::from(offset) + 1;
	assert!(
		source.reads == if accepted { 1 } else { 2 },
		"range rejection consumption"
	);
	assert!(actual >= start && actual <= end, "range output bounded");
	// Every residue r has exactly cutoff/SPAN preimages, indexed by j.
	// This symbolic inverse witnesses the rectangular accepted-domain mapping.
	let rank: u64 = kani::any();
	let residue: u64 = kani::any();
	kani::assume(u128::from(rank) < cutoff / u128::from(SPAN));
	kani::assume(residue < SPAN);
	let mapped = u128::from(rank) * u128::from(SPAN) + u128::from(residue);
	assert!(
		mapped < cutoff
			&& mapped % u128::from(SPAN) == u128::from(residue)
			&& mapped / u128::from(SPAN) == u128::from(rank),
		"range equal preimage certificate"
	);
	kani::cover!(draw == 0 && accepted, "range zero accepted reachable");
	kani::cover!(
		u128::from(draw) == cutoff - 1 && accepted,
		"range cutoff endpoint reachable"
	);
	if universe % u128::from(SPAN) != 0 {
		kani::cover!(!accepted, "range rejection reachable");
	}
	kani::cover!(residue == SPAN - 1, "range last residue reachable");
	assert!(i128::from(actual) == expected, "range exact reduction");
}

macro_rules! cardinality {
	($name:ident, $span:expr) => {
		#[kani::proof]
		#[kani::unwind(3)]
		fn $name() {
			named::<$span>();
		}
	};
}

cardinality!(span_3_contract, 3);
cardinality!(span_257_contract, 257);
cardinality!(span_u32_max_contract, 0xffff_ffff);
cardinality!(span_u32_universe_contract, 0x1_0000_0000);
cardinality!(span_u32_plus_one_contract, 0x1_0000_0001);
cardinality!(span_cap_minus_one_contract, { MAX_EXACT_POSITION - 1 });
cardinality!(span_cap_contract, MAX_EXACT_POSITION);
