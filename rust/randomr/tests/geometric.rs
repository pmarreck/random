use randomr::{ByteSource, Drbg, Fixed, Geometric, UnsignedCount};

struct Scripted {
	bytes: Vec<u8>,
	position: usize,
}

impl ByteSource for Scripted {
	fn fill_exact(&mut self, out: &mut [u8]) -> Result<(), randomr::Error> {
		let end = self.position + out.len();
		let bytes = self
			.bytes
			.get(self.position..end)
			.ok_or(randomr::Error::Entropy)?;
		out.copy_from_slice(bytes);
		self.position = end;
		Ok(())
	}
}

#[test]
fn geometric_contract() {
	let mut seed = [0_u8; 32];
	seed[31] = 42;
	let mut source = Drbg::new(&seed);
	let prepared = Geometric::new(Fixed::from_ratio(1, 2).unwrap()).unwrap();
	let values: Vec<_> = (0..8)
		.map(|_| prepared.sample(&mut source).unwrap().to_decimal())
		.collect();
	assert_eq!(values, ["0", "4", "1", "4", "0", "0", "3", "1"]);
	assert_eq!(source.position(), 168);
	let certain = Geometric::new(Fixed::from_i64(1)).unwrap();
	assert_eq!(certain.sample(&mut source).unwrap().to_blip(), [0]);
	assert_eq!(source.position(), 168);
	for p in [Fixed::ZERO, Fixed::from_i64(-1), Fixed::from_i64(2)] {
		assert!(Geometric::new(p).is_err());
	}
	let above_half = Geometric::new(Fixed::from_parts((1_i64 << 62) + 1, -1).unwrap()).unwrap();
	let mut scripted = Scripted {
		bytes: vec![128, 0, 0, 0, 0, 0, 0, 1],
		position: 0,
	};
	assert_eq!(above_half.sample(&mut scripted).unwrap().to_decimal(), "0");
	assert_eq!(scripted.position, 8);
}

#[test]
fn arbitrary_count_formatting_and_tiny_probability() {
	for (decimal, blip) in [
		("128", vec![0x81, 0x80]),
		(
			"18446744073709551616",
			vec![0x89, 0, 0, 0, 0, 0, 0, 0, 0, 1],
		),
	] {
		let value = UnsignedCount::from_decimal(decimal).unwrap();
		assert_eq!(value.to_decimal(), decimal);
		assert_eq!(value.to_blip(), blip);
	}
	for invalid in ["", "-1", "1.5", "1e3"] {
		assert!(UnsignedCount::from_decimal(invalid).is_err());
	}
	let mut seed = [0_u8; 32];
	seed[31] = 42;
	let mut source = Drbg::new(&seed);
	let p = Fixed::from_parts(1_i64 << 62, -100).unwrap();
	let value = Geometric::new(p).unwrap().sample(&mut source).unwrap();
	assert_eq!(value.to_decimal(), "50065276213116078233391743926");
	assert_eq!(source.position(), 509);
}

#[test]
fn probability_syntax_and_cancellation_safe_charts() {
	for text in ["0", "1e -1", "2^ -1", "2^-1000001", "NaN"] {
		assert!(Geometric::parse_probability(text).is_err(), "{text}");
	}
	assert!(Geometric::parse_probability(&("0".repeat(2001) + ".5")).is_err());
	assert_eq!(
		Geometric::parse_probability("5e-1").unwrap(),
		Fixed::from_ratio(1, 2).unwrap()
	);
	let expected = [65535, 30956, 14623, 6907, 3262, 1541, 728, 344, 162];
	for exponent in [-30, -62, -63, -100, -1000] {
		let p = Fixed::from_parts(1_i64 << 62, exponent).unwrap();
		let chart =
			randomr::Curve::sample(randomr::Distribution::Geometric, p, Fixed::ZERO, 9).unwrap();
		for (actual, expected) in chart.heights.iter().zip(expected) {
			assert!(
				i32::abs(i32::from(*actual) - expected) <= 1,
				"p=2^{exponent}: {actual} != {expected}"
			);
		}
	}
}
