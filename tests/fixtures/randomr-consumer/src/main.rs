use randomr::{ByteSource, Drbg, Fixed, normal};

fn system_seed() -> Result<u64, randomr::Error> {
	let mut entropy = randomr::entropy::SystemEntropy::new(false);
	entropy.u64_be()
}

fn main() {
	let _system_seed_provider: fn() -> Result<u64, randomr::Error> = system_seed;
	let mut seed = [0_u8; 32];
	seed[31] = 42;
	let mut source = Drbg::new(&seed);
	let mut bytes = [0_u8; 64];
	source.fill(&mut bytes).expect("valid cursor");
	let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
	assert_eq!(
		hex,
		concat!(
			"69dfe2e9b579cf6dfe3d71b11024db6eb49d5b9861505b3ecfc3d379a6dc8f04",
			"b6900db333d20760661226da010db589c5080aaf5f6068fc0874ce62aca36f60"
		)
	);
	assert_eq!(source.position(), 64);
	let (key, position) = source.state();
	let mut resumed = Drbg::from_state(key, position).expect("exported state");
	assert_eq!(source.u64().unwrap(), resumed.u64().unwrap());
	let mut source = Drbg::new(&seed);
	let value = normal(&mut source, Fixed::ZERO, Fixed::from_i64(1)).expect("valid parameters");
	assert_eq!(value.parts(), (-6_261_580_692_471_259_166, -2));
	assert_eq!(source.position(), 8);
}
