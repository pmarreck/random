# Pure verified-work kernels for measurement; no clocks, processes or output.
import Base
import ./Core.bend as Core
import ./ProbeModel.bend as Probe
import ./Clock.bend as Clock

def key(seed: U32) -> Core.CV:
	Core.seed_key(Probe.seed_material(seed))

def mix(hash: U32, value: U32) -> U32:
	U32.xor(Core.rotate(hash, 27n), value)

def mix_wide(hash: U32, value: Core.Wide) -> U32:
	match value:
		case Core.Wide{hi, lo}:
			mix(mix(hash, lo), hi)

def sum_bytes(bytes: List<U32>, hash: U32) -> U32:
	match bytes:
		case Nil{}:
			hash
		case Con{head, tail}:
			sum_bytes(tail, mix(hash, head))

type Work is Data:
	Work{state: Core.Stream, hash: U32}

def sum_read(result: Result<&2, &1, U32, Core.Read>, hash: U32) -> Result<&2, &2, U32, Work>:
	match result:
		case Fail{code}:
			Fail{code}
		case Done{Core.Read{state, bytes}}:
			Done{Work{state, sum_bytes(bytes, hash)}}

def range_continue(result: Result<&2, &2, Core.Failure, Core.Sample>, hash: U32, next: Core.Stream -> U32 -> Result<&2, &2, U32, Work>) -> Result<&2, &2, U32, Work>:
	match result:
		case Fail{Core.Failure{code, state}}:
			Fail{code}
		case Done{Core.Sample{state, value}}:
			next(state, mix_wide(hash, value))

def range_fold(fuel: Nat, state: Core.Stream, +end: Core.Wide, hash: U32) -> Result<&2, &2, U32, Work>:
	match fuel:
		case 0n:
			Done{Work{state, hash}}
		case 1n+p:
			range_continue(Core.range(state, Core.Wide{0, 1}, end), hash, next => h => range_fold(p, next, end, h))

# Modes: raw bytes, inclusive d6, inclusive 1..2^52. Carry one continuous
# stream and checksum across a sample's work units; reset only between samples.
def stream_work(kind: U32, count: Nat, state: Core.Stream, hash: U32) -> Result<&2, &2, U32, Work>:
	match kind:
		case 0:
			sum_read(Core.read(state, U32.from_nat(count)), hash)
		case 1:
			range_fold(count, state, Core.Wide{0, 6}, hash)
		case 2:
			range_fold(count, state, Core.Wide{1048576, 0}, hash)
		case other:
			Fail{1}

def repeat_continue(result: Result<&2, &2, U32, Work>, next: Core.Stream -> U32 -> Result<&2, &2, U32, U32>) -> Result<&2, &2, U32, U32>:
	match result:
		case Fail{code}:
			Fail{code}
		case Done{Work{state, hash}}:
			next(state, hash)

def repeat_state(fuel: Nat, +kind: U32, +count: Nat, state: Core.Stream, hash: U32) -> Result<&2, &2, U32, U32>:
	match fuel:
		case 0n:
			Done{hash}
		case 1n+p:
			repeat_continue(stream_work(kind, count, state, hash), next => h => repeat_state(p, kind, count, next, h))

def repeat(fuel: Nat, kind: U32, count: Nat, key: Core.CV, hash: U32) -> Result<&2, &2, U32, U32>:
	repeat_state(fuel, kind, count, Core.Stream{key, 0, 0}, hash)

def work(kind: U32, count: Nat, key: Core.CV) -> Result<&2, &2, U32, U32>:
	repeat(1n, kind, count, key, 0)

type Params is Data:
	Params{kind: U32, size: U32, repeats: U32, expected: U32, first: U32, warm: U32, seed: U32, key: Core.CV}

def construct(valid: Bool, kind: U32, size: U32, repeats: U32, expected: U32, first: U32, warm: U32, +seed: U32) -> Maybe<&2, Params>:
	match valid:
		case False{}:
			None{}
		case True{}:
			Some{Params{kind, size, repeats, expected, first, warm, seed, key(seed)}}

def parsed(kind: Maybe<&2, U32>, size: Maybe<&2, U32>, repeats: Maybe<&2, U32>, expected: Maybe<&2, U32>, first: Maybe<&2, U32>, warm: Maybe<&2, U32>, seed: Maybe<&2, U32>) -> Maybe<&2, Params>:
	match kind size repeats expected first warm seed:
		case Some{+k} Some{+n} Some{+r} Some{e} Some{f} Some{w} Some{s}:
			construct(U32.is_le(k, 2) && U32.is_ge(n, 1) && U32.is_le(n, 8192) && U32.is_ge(r, 1) && U32.is_le(r, 1000000), k, n, r, e, f, w, s)
		case a b c d e f g:
			None{}

def parse_args(args: List<String>) -> Maybe<&2, Params>:
	match args:
		case Con{program, Con{kind, Con{size, Con{repeats, Con{expected, Con{first, Con{warm, Con{seed, Nil{}}}}}}}}}:
			parsed(U32.read(kind), U32.read(size), U32.read(repeats), U32.read(expected), U32.read(first), U32.read(warm), U32.read(seed))
		case other:
			None{}

def execute(params: Params, repeats: U32) -> Result<&2, &2, U32, U32>:
	match params:
		case Params{kind, size, r, expected, first, warm, seed, key}:
			repeat(U32.to_nat(repeats), kind, U32.to_nat(size), key, 0)

def count(params: Params) -> U32:
	match params:
		case Params{kind, size, repeats, expected, first, warm, seed, key}:
			repeats

def expected(params: Params) -> U32:
	match params:
		case Params{kind, size, r, expected, first, warm, seed, key}:
			expected

def first(params: Params) -> U32:
	match params:
		case Params{kind, size, r, expected, first, warm, seed, key}:
			first

def warm(params: Params) -> U32:
	match params:
		case Params{kind, size, r, expected, first, warm, seed, key}:
			warm

def valid_result(result: Result<&2, &2, U32, U32>, expected: U32) -> Bool:
	match result:
		case Fail{code}:
			False{}
		case Done{value}:
			U32.is_eq(value, expected)

def stamp(value: Clock.Stamp) -> Core.Wide:
	match value:
		case Clock.Stamp{hi, lo}:
			Core.Wide{hi, lo}

def delta_if(valid: Bool, elapsed: U32, repeats: U32) -> Maybe<&2, U32>:
	match valid:
		case False{}:
			None{}
		case True{}:
			Some{U32.div(elapsed, repeats)}

# Each measured interval must fit u32 nanoseconds and have positive CPU/wall
# duration. A clock/interval error is a failure, never a fabricated zero sample.
def delta(elapsed: Core.Wide, +repeats: U32) -> Maybe<&2, U32>:
	match elapsed:
		case Core.Wide{hi, +lo}:
			delta_if(U32.is_eq(hi, 0) && U32.is_ge(lo, repeats) && U32.is_gt(repeats, 0), lo, repeats)

def deltas_pair(cpu: Maybe<&2, U32>, wall: Maybe<&2, U32>) -> Maybe<&1, (U32 & U32)>:
	match cpu wall:
		case Some{c} Some{w}:
			Some{(c, w)}
		case a b:
			None{}

def deltas(+repeats: U32, w0: Clock.Stamp, c0: Clock.Stamp, c1: Clock.Stamp, w1: Clock.Stamp) -> Maybe<&1, (U32 & U32)>:
	deltas_pair(delta(Core.u64_sub(stamp(c1), stamp(c0)), repeats), delta(Core.u64_sub(stamp(w1), stamp(w0)), repeats))

def push(text: String, value: U32) -> String:
	match text:
		case SNil{}:
			U32.show(value)
		case SCon{head, tail}:
			SCon{head, tail} ++ "," ++ U32.show(value)

def protocol(params: Params, cpu: String, wall: String, rss: Clock.Stamp) -> String:
	match params rss:
		case Params{kind, +size, repeats, expected, first, warm, seed, key} Clock.Stamp{hi, lo}:
			"{\"schema\":\"performance-measurement/v1\",\"correct\":true,\"build_mode\":\"optimized\",\"backend_build_mode\":\"Release-Clang-O3\",\"allocator_coverage\":\"Bend allocator counters unavailable; supplemental high-water RSS only\",\"clock\":\"clock_gettime process CPU and monotonic; normalized per repeated work unit\",\"iterations\":" ++ U32.show(repeats) ++ ",\"peak_rss_hi\":" ++ U32.show(hi) ++ ",\"peak_rss_lo\":" ++ U32.show(lo) ++ ",\"rows\":[{\"size\":" ++ U32.show(size) ++ ",\"samples\":{\"cpu_ns\":[" ++ cpu ++ "],\"wall_ns\":[" ++ wall ++ "]}}]}"
