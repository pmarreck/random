//! Verified-work comparison adapter; all generation goes through the public API.
use randomr::{range, Drbg, Fixed, Geometric};

struct Parameters {
	zero: Fixed,
	one: Fixed,
	rate: Fixed,
	lambda: Fixed,
	mean: Fixed,
	stddev: Fixed,
	shape: Fixed,
	quarter: Fixed,
	sparse: Fixed,
}

fn integer_hash(hash: u32, value: i64) -> u32 {
	let bits = value as u64;
	(hash.rotate_left(5) ^ bits as u32).rotate_left(5) ^ (bits >> 32) as u32
}

fn clock(kind: libc::clockid_t) -> u64 {
	let mut stamp = libc::timespec {
		tv_sec: 0,
		tv_nsec: 0,
	};
	// SAFETY: the pointer is writable and both callers pass supported clock IDs.
	assert_eq!(
		unsafe { libc::clock_gettime(kind, &mut stamp) },
		0,
		"clock failed"
	);
	assert!(stamp.tv_sec >= 0 && (0..1_000_000_000).contains(&stamp.tv_nsec));
	u64::try_from(stamp.tv_sec)
		.unwrap()
		.checked_mul(1_000_000_000)
		.unwrap()
		.checked_add(u64::try_from(stamp.tv_nsec).unwrap())
		.unwrap()
}

fn work(
	source: &mut Drbg,
	params: &Parameters,
	kind: u32,
	n: usize,
	out: &mut [u8],
	mut hash: u32,
) -> u32 {
	if kind == 0 {
		source.fill(out).unwrap();
		for &byte in out.iter() {
			hash = hash.rotate_left(5) ^ u32::from(byte);
		}
	} else if kind <= 2 {
		let end = if kind == 1 { 6 } else { 1_i64 << 52 };
		for _ in 0..n {
			let value = range(source, 1, end).unwrap() as u64;
			hash = hash.rotate_left(5) ^ value as u32;
			hash = hash.rotate_left(5) ^ (value >> 32) as u32;
		}
	} else if kind == 11 {
		let mut values = [0; 96];
		let mut done = 0;
		while done < n {
			let count = (n - done).min(values.len());
			source
				.normal_int_batch(0, 255, &mut values[..count])
				.unwrap();
			for &value in &values[..count] {
				hash = integer_hash(hash, value);
			}
			done += count;
		}
	} else {
		for _ in 0..n {
			match kind {
				4 | 6 => {
					let value = if kind == 4 {
						randomr::normal_int(source, 0, 255).unwrap()
					} else {
						randomr::poisson(source, params.lambda).unwrap()
					};
					hash = integer_hash(hash, value);
				}
				9 | 10 => {
					// The public C/Lua APIs prepare per call; do the same here.
					let probability = if kind == 9 {
						params.quarter
					} else {
						params.sparse
					};
					let value = Geometric::new(probability).unwrap().sample(source).unwrap();
					for byte in value.to_blip() {
						hash = hash.rotate_left(5) ^ u32::from(byte);
					}
				}
				_ => {
					let value = match kind {
						3 => randomr::normal(source, params.zero, params.one).unwrap(),
						5 => randomr::exponential(source, params.rate).unwrap(),
						7 => randomr::log_normal(source, params.mean, params.stddev).unwrap(),
						8 => randomr::beta(source, params.one, params.shape).unwrap(),
						_ => panic!("unknown sampler"),
					};
					let (m, e) = value.parts();
					hash = integer_hash(hash, m).rotate_left(5) ^ e as u32;
				}
			}
		}
	}
	std::hint::black_box(hash)
}

fn batch(
	source: &mut Drbg,
	params: &Parameters,
	kind: u32,
	n: usize,
	out: &mut [u8],
	repeats: u32,
) -> u32 {
	source.seek(0).unwrap();
	let mut hash = 0_u32;
	for _ in 0..repeats {
		hash = work(source, params, kind, n, out, hash);
	}
	std::hint::black_box(hash)
}

fn main() {
	assert!(
		!cfg!(debug_assertions),
		"benchmark requires optimized release"
	);
	let args: Vec<String> = std::env::args().collect();
	assert_eq!(
		args.len(),
		8,
		"kind size repeats batch-checksum first-checksum warm-checksum seed required"
	);
	let kind: u32 = args[1].parse().unwrap();
	let n: usize = args[2].parse().unwrap();
	let repeats: u32 = args[3].parse().unwrap();
	let oracle = args[4] == "-";
	let expected: u32 = if oracle { 0 } else { args[4].parse().unwrap() };
	let first: u32 = args[5].parse().unwrap();
	let warm: u32 = args[6].parse().unwrap();
	let seed: u32 = args[7].parse().unwrap();
	assert!(kind <= 11 && (1..=8192).contains(&n) && (1..=1_000_000).contains(&repeats));
	let params = Parameters {
		zero: Fixed::from_i64(0),
		one: Fixed::from_i64(1),
		rate: Fixed::from_i64(4),
		lambda: Fixed::from_i64(5),
		shape: Fixed::from_i64(3),
		mean: Fixed::from_parts(-(1_i64 << 62), -2).unwrap(),
		stddev: Fixed::from_parts(7_i64 << 60, 0).unwrap(),
		quarter: Fixed::from_parts(1_i64 << 62, -2).unwrap(),
		sparse: Fixed::from_parts(1_i64 << 62, -100).unwrap(),
	};
	let mut material = [0; 32];
	material[28..].copy_from_slice(&seed.to_be_bytes());
	let mut source = Drbg::new(&material);
	let mut out = if kind == 0 { vec![0; n] } else { Vec::new() };
	if oracle {
		let hash = batch(&mut source, &params, kind, n, &mut out, repeats);
		println!("{{\"hash\":{hash},\"position\":\"{}\"}}", source.position());
		return;
	}
	assert_eq!(
		batch(&mut source, &params, kind, n, &mut out, 1),
		first,
		"incorrect first work"
	);
	println!("READY");
	assert_eq!(batch(&mut source, &params, kind, n, &mut out, 3), warm);
	let mut cpu = [0; 7];
	let mut wall = [0; 7];
	for sample in 0..7 {
		let w0 = clock(libc::CLOCK_MONOTONIC);
		let c0 = clock(libc::CLOCK_PROCESS_CPUTIME_ID);
		let result = batch(&mut source, &params, kind, n, &mut out, repeats);
		let c1 = clock(libc::CLOCK_PROCESS_CPUTIME_ID);
		let w1 = clock(libc::CLOCK_MONOTONIC);
		assert_eq!(result, expected, "incorrect timed work");
		assert!(c1 > c0 && w1 > w0);
		cpu[sample] = (c1 - c0) / u64::from(repeats);
		wall[sample] = (w1 - w0) / u64::from(repeats);
		assert!(cpu[sample] > 0 && wall[sample] > 0);
	}
	let status =
		std::fs::read_to_string("/proc/self/status").expect("Linux post-exec RSS required");
	let line = status
		.lines()
		.find_map(|line| line.strip_prefix("VmHWM:"))
		.unwrap();
	let mut fields = line.split_whitespace();
	let rss_kib: u64 = fields.next().unwrap().parse().unwrap();
	assert_eq!(fields.next(), Some("kB"));
	let rss_bytes = rss_kib.checked_mul(1024).unwrap();
	assert!(rss_bytes > 0);
	let position = source.position();
	println!("{{\"schema\":\"performance-measurement/v1\",\"correct\":true,\"build_mode\":\"optimized\",\"backend_build_mode\":\"Release\",\"allocator_coverage\":\"caller-owned output buffer; allocation counters unavailable; supplemental high-water RSS only\",\"rss_method\":\"Linux /proc/self/status VmHWM; supplemental approximate post-exec high water\",\"iterations\":{repeats},\"position\":\"{position}\",\"peak_rss_bytes\":{rss_bytes},\"rows\":[{{\"size\":{n},\"samples\":{{\"cpu_ns\":{cpu:?},\"wall_ns\":{wall:?}}}}}]}}");
}
