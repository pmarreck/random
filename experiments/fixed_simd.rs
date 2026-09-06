//! Standalone AVX2 experiment; not linked into randomr or its CLI.
//! Every unsafe entry is gated by is_x86_feature_detected!("avx2").
use randomr::Fixed;
type Batch = [Fixed; 4];

#[cfg(target_arch = "x86_64")]
#[allow(unsafe_op_in_unsafe_fn)] // Entire module requires the checked AVX2 precondition.
mod avx2 {
	use super::{Batch, Fixed};
	use std::arch::x86_64::*;
	#[derive(Clone, Copy)]
	struct V {
		m: __m256i,
		e: __m256i,
	}
	#[target_feature(enable = "avx2")]
	unsafe fn splat(n: i64) -> __m256i {
		_mm256_set1_epi64x(n)
	}
	#[target_feature(enable = "avx2")]
	unsafe fn select(mask: __m256i, a: __m256i, b: __m256i) -> __m256i {
		_mm256_blendv_epi8(b, a, mask)
	}
	#[target_feature(enable = "avx2")]
	unsafe fn choose(mask: __m256i, a: V, b: V) -> V {
		V {
			m: select(mask, a.m, b.m),
			e: select(mask, a.e, b.e),
		}
	}
	#[target_feature(enable = "avx2")]
	unsafe fn neg(m: __m256i) -> __m256i {
		_mm256_sub_epi64(splat(0), m)
	}
	#[target_feature(enable = "avx2")]
	unsafe fn negative(m: __m256i) -> __m256i {
		_mm256_cmpgt_epi64(splat(0), m)
	}
	#[target_feature(enable = "avx2")]
	unsafe fn magnitude(m: __m256i) -> __m256i {
		select(negative(m), neg(m), m)
	}
	#[target_feature(enable = "avx2")]
	unsafe fn sign(m: __m256i, mask: __m256i) -> __m256i {
		select(mask, neg(m), m)
	}
	#[target_feature(enable = "avx2")]
	unsafe fn pack(xs: Batch) -> V {
		V {
			m: _mm256_set_epi64x(xs[3].m(), xs[2].m(), xs[1].m(), xs[0].m()),
			e: _mm256_set_epi64x(
				xs[3].e() as i64,
				xs[2].e() as i64,
				xs[1].e() as i64,
				xs[0].e() as i64,
			),
		}
	}
	#[target_feature(enable = "avx2")]
	unsafe fn unpack(x: V) -> Batch {
		let mut m = [0_i64; 4];
		let mut e = [0_i64; 4];
		_mm256_storeu_si256(m.as_mut_ptr().cast(), x.m);
		_mm256_storeu_si256(e.as_mut_ptr().cast(), x.e);
		std::array::from_fn(|i| Fixed::from_parts(m[i], i32::try_from(e[i]).unwrap()).unwrap())
	}
	#[target_feature(enable = "avx2")]
	unsafe fn constant(x: Fixed) -> V {
		V {
			m: splat(x.m()),
			e: splat(x.e() as i64),
		}
	}

	/// Exact product via four 32-bit limb multiplies per lane. Operands are
	/// normalized, so partial sums fit without losing carries.
	#[target_feature(enable = "avx2")]
	unsafe fn mul(a: V, b: V) -> V {
		let aa = magnitude(a.m);
		let bb = magnitude(b.m);
		let a1 = _mm256_srli_epi64::<32>(aa);
		let b1 = _mm256_srli_epi64::<32>(bb);
		let p00 = _mm256_mul_epu32(aa, bb);
		let t = _mm256_add_epi64(_mm256_mul_epu32(a1, bb), _mm256_srli_epi64::<32>(p00));
		let middle = _mm256_add_epi64(
			_mm256_mul_epu32(aa, b1),
			_mm256_and_si256(t, splat(0xffffffff)),
		);
		let hi = _mm256_add_epi64(
			_mm256_add_epi64(_mm256_mul_epu32(a1, b1), _mm256_srli_epi64::<32>(t)),
			_mm256_srli_epi64::<32>(middle),
		);
		let lo = _mm256_or_si256(
			_mm256_slli_epi64::<32>(middle),
			_mm256_and_si256(p00, splat(0xffffffff)),
		);
		let high = _mm256_cmpgt_epi64(hi, splat((1 << 61) - 1));
		let mag = select(
			high,
			_mm256_or_si256(_mm256_slli_epi64::<1>(hi), _mm256_srli_epi64::<63>(lo)),
			_mm256_or_si256(_mm256_slli_epi64::<2>(hi), _mm256_srli_epi64::<62>(lo)),
		);
		V {
			m: sign(mag, _mm256_xor_si256(negative(a.m), negative(b.m))),
			e: select(
				_mm256_cmpeq_epi64(mag, splat(0)),
				splat(0),
				_mm256_add_epi64(_mm256_add_epi64(a.e, b.e), _mm256_and_si256(high, splat(1))),
			),
		}
	}

	/// Integer-only binary-search normalization; AVX2 has no packed u64 CLZ.
	/// The add contract guarantees magnitude below 2^63, including zero lanes.
	#[target_feature(enable = "avx2")]
	unsafe fn norm(m: __m256i, mut e: __m256i) -> V {
		let mut mag = magnitude(m);
		for shift in [32, 16, 8, 4, 2, 1] {
			let small = _mm256_cmpgt_epi64(splat(1_i64 << (63 - shift)), mag);
			mag = select(small, _mm256_sllv_epi64(mag, splat(shift)), mag);
			e = _mm256_sub_epi64(e, _mm256_and_si256(small, splat(shift)));
		}
		V {
			m: sign(mag, negative(m)),
			e: select(_mm256_cmpeq_epi64(m, splat(0)), splat(0), e),
		}
	}
	#[target_feature(enable = "avx2")]
	unsafe fn add(a: V, b: V) -> V {
		let swap = _mm256_cmpgt_epi64(b.e, a.e);
		let x = choose(swap, b, a);
		let y = choose(swap, a, b);
		let d = _mm256_sub_epi64(x.e, y.e);
		let far = _mm256_cmpgt_epi64(d, splat(62));
		let shifted = sign(_mm256_srlv_epi64(magnitude(y.m), d), negative(y.m));
		let same = _mm256_cmpeq_epi64(negative(x.m), negative(shifted));
		let half = sign(
			_mm256_add_epi64(
				_mm256_srli_epi64::<1>(magnitude(x.m)),
				_mm256_srli_epi64::<1>(magnitude(shifted)),
			),
			negative(x.m),
		);
		let out = norm(
			select(same, half, _mm256_add_epi64(x.m, shifted)),
			_mm256_add_epi64(x.e, _mm256_and_si256(same, splat(1))),
		);
		choose(
			_mm256_cmpeq_epi64(a.m, splat(0)),
			b,
			choose(_mm256_cmpeq_epi64(b.m, splat(0)), a, choose(far, x, out)),
		)
	}
	#[target_feature(enable = "avx2")]
	pub unsafe fn mul4(a: Batch, b: Batch) -> Batch {
		unpack(mul(pack(a), pack(b)))
	}
	#[target_feature(enable = "avx2")]
	#[cfg(test)]
	pub unsafe fn add4(a: Batch, b: Batch) -> Batch {
		unpack(add(pack(a), pack(b)))
	}

	pub struct Coefficients {
		odd: [Fixed; 20],
		cosine: [Fixed; 14],
		sine: [Fixed; 14],
	}
	impl Coefficients {
		pub fn new() -> Self {
			Self {
				odd: std::array::from_fn(|n| Fixed::from_ratio(1, (2 * n + 3) as i64).unwrap()),
				cosine: std::array::from_fn(|n| {
					Fixed::from_ratio(1, ((2 * n + 1) * (2 * n + 2)) as i64).unwrap()
				}),
				sine: std::array::from_fn(|n| {
					Fixed::from_ratio(1, ((2 * n + 2) * (2 * n + 3)) as i64).unwrap()
				}),
			}
		}
	}
	#[target_feature(enable = "avx2")]
	pub unsafe fn ln4(xs: Batch, coefficients: &Coefficients) -> Batch {
		let one = Fixed::from_i64(1);
		let initial = xs.map(|x| {
			let f = Fixed::from_parts(x.m(), 0).unwrap();
			f.sub(one).unwrap().div(f.add(one).unwrap()).unwrap()
		});
		let t = pack(initial);
		let t2 = mul(t, t);
		let mut term = t;
		let mut acc = t;
		for &c in &coefficients.odd {
			term = mul(term, t2);
			acc = add(acc, mul(term, constant(c)));
		}
		let mut out = unpack(add(acc, acc));
		let ln2 = Fixed::from_parts(6393154322601327829, -1).unwrap();
		for (x, result) in xs.iter().zip(&mut out) {
			if x.e() != 0 {
				*result = result
					.add(ln2.mul(Fixed::from_i64(x.e() as i64)).unwrap())
					.unwrap();
			}
		}
		out
	}
	#[target_feature(enable = "avx2")]
	pub unsafe fn cos4(xs: Batch, coefficients: &Coefficients) -> Batch {
		let one = Fixed::from_i64(1);
		let mut quadrants = [0_i64; 4];
		let angles = std::array::from_fn(|lane| {
			let mut f = xs[lane].frac().unwrap();
			if f.m() < 0 {
				f = f.add(one).unwrap();
			}
			let q4 = f.mul(Fixed::from_i64(4)).unwrap();
			let q = q4.to_i64_trunc();
			quadrants[lane] = q;
			q4.sub(Fixed::from_i64(q))
				.unwrap()
				.mul(Fixed::from_parts(7244019458077122842, 0).unwrap())
				.unwrap()
		});
		let q = _mm256_loadu_si256(quadrants.as_ptr().cast());
		// The scalar default branch also handles a tiny negative wrap rounded to 4.
		let cosine_mask = _mm256_or_si256(
			_mm256_cmpeq_epi64(q, splat(0)),
			_mm256_cmpeq_epi64(q, splat(2)),
		);
		let sin_mask = _mm256_xor_si256(cosine_mask, splat(-1));
		let neg_mask = _mm256_or_si256(
			_mm256_cmpeq_epi64(q, splat(1)),
			_mm256_cmpeq_epi64(q, splat(2)),
		);
		let angle = pack(angles);
		let a2 = mul(angle, angle);
		let mut term = choose(sin_mask, angle, constant(one));
		let mut acc = term;
		for (&c, &s) in coefficients.cosine.iter().zip(&coefficients.sine) {
			term = mul(mul(term, a2), choose(sin_mask, constant(s), constant(c)));
			term.m = neg(term.m);
			acc = add(acc, term);
		}
		acc.m = select(neg_mask, neg(acc.m), acc.m);
		unpack(acc)
	}
}

// A fixed integer mixer supplies reproducible benchmark inputs, never RNG output.
fn input(index: u64) -> Fixed {
	let x = index.wrapping_mul(0x9e3779b97f4a7c15);
	let k = ((x ^ (x >> 29)) as u32) | 1;
	let value = Fixed::from_i64(k as i64);
	Fixed::from_parts(value.m(), value.e() - 32).unwrap()
}

#[cfg(target_arch = "x86_64")]
fn main() {
	use std::io::Write;
	assert!(
		std::is_x86_feature_detected!("avx2"),
		"AVX2 is required for this experiment"
	);
	let mode = std::env::args()
		.nth(1)
		.expect("scalar-ln|vector-ln|scalar-cos|vector-cos|scalar-mul|vector-mul");
	let (style, op) = mode.split_once('-').unwrap();
	let verify = std::env::args().nth(2).is_some_and(|arg| {
		assert_eq!(arg, "--verify");
		true
	});
	assert!(matches!(style, "scalar" | "vector") && matches!(op, "ln" | "cos" | "mul"));
	let coefficients = avx2::Coefficients::new();
	let data: Vec<Batch> = (0..2048)
		.map(|batch| std::array::from_fn(|lane| input(batch * 4 + lane as u64)))
		.collect();
	let mut checksum = 0_u64;
	let repetitions = if verify {
		1
	} else if op == "mul" {
		4096
	} else {
		128
	};
	let mut output = std::io::BufWriter::new(std::io::stdout().lock());
	for _ in 0..repetitions {
		for (index, &batch) in data.iter().enumerate() {
			let other = data[(index + 1) % data.len()];
			let out = if style == "vector" {
				// SAFETY: runtime AVX2 detection above; inputs are normalized Fixed values.
				unsafe {
					match op {
						"ln" => avx2::ln4(batch, &coefficients),
						"cos" => avx2::cos4(batch, &coefficients),
						_ => avx2::mul4(batch, other),
					}
				}
			} else {
				std::array::from_fn(|lane| match op {
					"ln" => batch[lane].ln().unwrap(),
					"cos" => batch[lane].cos_turns().unwrap(),
					_ => batch[lane].mul(other[lane]).unwrap(),
				})
			};
			std::hint::black_box(out);
			for x in out {
				if verify {
					writeln!(output, "{} {}", x.m(), x.e()).unwrap();
				}
				checksum = checksum
					.rotate_left(7)
					.wrapping_add(x.m() as u64)
					.wrapping_add(x.e() as u64);
			}
		}
	}
	if !verify {
		writeln!(output, "{checksum:x}").unwrap();
	}
	output.flush().unwrap();
}

#[cfg(not(target_arch = "x86_64"))]
fn main() {
	panic!("The Rust AVX2 experiment currently requires x86_64");
}

#[test]
#[cfg(target_arch = "x86_64")]
fn exact_scalar_control() {
	assert!(
		std::is_x86_feature_detected!("avx2"),
		"Run this AVX2 control on supported hardware"
	);
	let coefficients = avx2::Coefficients::new();
	for exponent in [-60, -61, -62, -63, -64, -65, -1000] {
		let xs = [
			Fixed::from_parts(-(1 << 62), exponent).unwrap(),
			Fixed::from_parts(-(1 << 62) - 1, exponent).unwrap(),
			Fixed::from_parts(-(1 << 62), -32).unwrap(),
			Fixed::ZERO,
		];
		// SAFETY: AVX2 was detected and all inputs are canonical.
		assert_eq!(
			unsafe { avx2::cos4(xs, &coefficients) },
			xs.map(|x| x.cos_turns().unwrap())
		);
	}
	for n in 0..10000 {
		let positive: Batch = std::array::from_fn(|lane| input(n * 4 + lane as u64));
		let a = std::array::from_fn(|lane| {
			if lane % 2 == 0 {
				positive[lane].neg()
			} else {
				positive[lane]
			}
		});
		let b = std::array::from_fn(|lane| match n % 3 {
			0 => Fixed::ZERO,
			1 => a[lane].neg(),
			_ => input(n + lane as u64 + 3),
		});
		// SAFETY: runtime AVX2 detection above and canonical Fixed inputs.
		unsafe {
			assert_eq!(
				avx2::mul4(a, b),
				std::array::from_fn(|lane| a[lane].mul(b[lane]).unwrap())
			);
			assert_eq!(
				avx2::add4(a, b),
				std::array::from_fn(|lane| a[lane].add(b[lane]).unwrap())
			);
			assert_eq!(
				avx2::ln4(positive, &coefficients),
				positive.map(|x| x.ln().unwrap())
			);
			assert_eq!(
				avx2::cos4(a, &coefficients),
				a.map(|x| x.cos_turns().unwrap())
			);
		}
	}
}
