use randomr::{normal, ByteSource, Drbg, Fixed};

fn system_seed() -> Result<u64, randomr::Error> {
	let mut entropy = randomr::entropy::SystemEntropy::new(false);
	entropy.u64_be()
}

fn main() {
	let _system_seed_provider: fn() -> Result<u64, randomr::Error> = system_seed;
	let mut source = Drbg::new(&[0x42; 32]);
	let _value = normal(&mut source, Fixed::ZERO, Fixed::from_i64(1)).expect("valid parameters");
}
