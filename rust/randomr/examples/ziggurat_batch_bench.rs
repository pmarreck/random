//! Opt-in shared-engine probe. Expected checksums come from the independent
//! experimental FFI array oracle, never from the implementation being timed.
use randomr::{Drbg, Fixed};

fn clock(kind: libc::clockid_t) -> u64 {
	let mut t = libc::timespec {
		tv_sec: 0,
		tv_nsec: 0,
	};
	// SAFETY: writable timespec; only the supported checked clock IDs are used.
	assert_eq!(
		unsafe { libc::clock_gettime(kind, &mut t) },
		0,
		"clock failed"
	);
	assert!(t.tv_sec >= 0 && (0..1_000_000_000).contains(&t.tv_nsec));
	u64::try_from(t.tv_sec)
		.unwrap()
		.checked_mul(1_000_000_000)
		.unwrap()
		.checked_add(u64::try_from(t.tv_nsec).unwrap())
		.unwrap()
}

fn checksum(auto: bool, count: usize, seed: u64) -> u64 {
	let mut material = [0; 32];
	material[24..].copy_from_slice(&seed.to_be_bytes());
	let mut source = Drbg::new(&material);
	let mut output = [0; 1024];
	let mut sum: u64 = 0;
	let mut remaining = count;
	while remaining != 0 {
		let n = remaining.min(output.len());
		if auto {
			source.normal_int_batch(0, 255, &mut output[..n]).unwrap();
		} else {
			randomr::normal_int_batch(&mut source, 0, 255, &mut output[..n]).unwrap();
		}
		for value in &output[..n] {
			let (m, e) = Fixed::from_i64(*value).parts();
			sum = sum
				.rotate_left(7)
				.wrapping_add(m as u64)
				.wrapping_add(i64::from(e) as u64);
		}
		remaining -= n;
	}
	std::hint::black_box(sum)
}

fn measure(auto: bool, count: usize, seed: u64, oracle: u64) -> (u64, u64) {
	let mut checks = [0; 8];
	let w0 = clock(libc::CLOCK_MONOTONIC);
	let c0 = clock(libc::CLOCK_PROCESS_CPUTIME_ID);
	for check in &mut checks {
		*check = checksum(auto, count, seed);
	}
	let c1 = clock(libc::CLOCK_PROCESS_CPUTIME_ID);
	let w1 = clock(libc::CLOCK_MONOTONIC);
	for check in checks {
		assert_eq!(check, oracle, "incorrect timed work");
	}
	assert!(c1 > c0 && w1 > w0);
	((c1 - c0) / 8, (w1 - w0) / 8)
}

fn main() {
	assert!(
		!cfg!(debug_assertions),
		"benchmark requires optimized release"
	);
	let args: Vec<String> = std::env::args().collect();
	assert_eq!(
		args.len(),
		5,
		"case sizes seed independent-checksums required"
	);
	let auto = match args[1].split('-').next().unwrap() {
		"rustauto" => true,
		"rustscalar" => false,
		_ => panic!("unknown batch mode"),
	};
	let sizes: Vec<usize> = args[2].split(',').map(|s| s.parse().unwrap()).collect();
	let seed = args[3].parse().unwrap();
	let expected: Vec<u64> = args[4].split(',').map(|s| s.parse().unwrap()).collect();
	assert_eq!(sizes.len(), expected.len());
	println!(
		"{{\"schema\":\"performance-measurement/v1\",\"correct\":true,\"build_mode\":\"Release\",\"clock\":\"checked clock_gettime process CPU and monotonic\",\"allocator_coverage\":\"fixed DRBG and 1024-item scratch; argv allocation excluded\",\"rows\":["
	);
	for (index, (&n, &oracle)) in sizes.iter().zip(&expected).enumerate() {
		assert!(n > 0);
		for _ in 0..2 {
			assert_eq!(checksum(auto, n, seed), oracle, "incorrect warmup");
			assert_eq!(checksum(!auto, n, seed), oracle, "incorrect warmup");
		}
		let mut cpu = [0; 24];
		let mut wall = [0; 24];
		let mut control_cpu = [0; 24];
		let mut control_wall = [0; 24];
		for i in 0..24 {
			let first = i % 2 != 0;
			let a = measure(first, n, seed, oracle);
			let b = measure(!first, n, seed, oracle);
			let (selected, other) = if first == auto { (a, b) } else { (b, a) };
			(cpu[i], wall[i]) = selected;
			(control_cpu[i], control_wall[i]) = other;
		}
		if index != 0 {
			println!(",");
		}
		print!(
			"{{\"size\":{n},\"checksum\":\"{oracle:x}\",\"samples\":{{\"cpu_ns\":{cpu:?},\"wall_ns\":{wall:?}}},\"paired_control\":{{\"auto\":{},\"repetitions_per_sample\":8,\"balanced_pairs\":24,\"normalization\":\"duration / 8 fresh-state workloads; SCALAR first on even rounds\",\"cpu_ns\":{control_cpu:?},\"wall_ns\":{control_wall:?}}}}}",
			!auto
		);
	}
	println!("]}}");
}
