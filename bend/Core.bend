# Independent single-block BLAKE3 subset used by the DRBG (not a general hash).
# U32 limbs preserve 64-bit XOF counters without the runtime's 48-bit Nat cap.
import Base

type CV is Data:
	CV{a: U32, b: U32, c: U32, d: U32, e: U32, f: U32, g: U32, h: U32}

type Words is Data:
	Words{a: U32, b: U32, c: U32, d: U32, e: U32, f: U32, g: U32, h: U32, i: U32, j: U32, k: U32, l: U32, m: U32, n: U32, o: U32, p: U32}

type Quad is Data:
	Quad{a: U32, b: U32, c: U32, d: U32}

def iv() -> CV:
	CV{1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635, 1541459225}

def zero_block() -> Words:
	Words{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}

# BLAKE3's add/rotate/xor G function, with explicit wrapping word arithmetic.
def rotate(+x: U32, +n: Nat) -> U32:
	U32.or(U32.shrn(x, n), U32.shln(x, Nat.sub(32n, n)))

def mix(a: U32, +b: U32, c: U32, d: U32, x: U32, y: U32) -> Quad:
	+a1 = (a + b + x : U32)
	+d1 = rotate(U32.xor(d, a1), 16n)
	+c1 = (c + d1 : U32)
	+b1 = rotate(U32.xor(b, c1), 12n)
	+a2 = (a1 + b1 + y : U32)
	+d2 = rotate(U32.xor(d1, a2), 8n)
	+c2 = (c1 + d2 : U32)
	Quad{a2, rotate(U32.xor(b1, c2), 7n), c2, d2}

def packed(q0: Quad, q1: Quad, q2: Quad, q3: Quad) -> Words:
	match q0 q1 q2 q3:
		case Quad{a, f, k, p} Quad{b, g, l, m} Quad{c, h, i, n} Quad{d, e, j, o}:
			Words{a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p}

def diagonal(q0: Quad, q1: Quad, q2: Quad, q3: Quad, x8: U32, x9: U32, x10: U32, x11: U32, x12: U32, x13: U32, x14: U32, x15: U32) -> Words:
	match q0 q1 q2 q3:
		case Quad{a, e, i, m} Quad{b, f, j, n} Quad{c, g, k, o} Quad{d, h, l, p}:
			packed(mix(a, f, k, p, x8, x9), mix(b, g, l, m, x10, x11), mix(c, h, i, n, x12, x13), mix(d, e, j, o, x14, x15))

def round(state: Words, message: Words) -> Words:
	match state message:
		case Words{a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p} Words{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15}:
			diagonal(mix(a, e, i, m, x0, x1), mix(b, f, j, n, x2, x3), mix(c, g, k, o, x4, x5), mix(d, h, l, p, x6, x7), x8, x9, x10, x11, x12, x13, x14, x15)

def permute(message: Words) -> Words:
	match message:
		case Words{a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p}:
			Words{c, g, d, k, h, a, e, n, b, l, m, f, j, o, p, i}

def rounds(fuel: Nat, state: Words, +message: Words) -> Words:
	match fuel:
		case 0n:
			state
		case 1n+p:
			rounds(p, round(state, message), permute(message))

def initial(cv: CV, lo: U32, hi: U32, size: U32, flags: U32) -> Words:
	match cv:
		case CV{a, b, c, d, e, f, g, h}:
			Words{a, b, c, d, e, f, g, h, 1779033703, 3144134277, 1013904242, 2773480762, lo, hi, size, flags}

def finalize(state: Words, cv: CV) -> Words:
	match state cv:
		case Words{a, b, c, d, e, f, g, h, +i, +j, +k, +l, +m, +n, +o, +p} CV{v0, v1, v2, v3, v4, v5, v6, v7}:
			Words{U32.xor(a, i), U32.xor(b, j), U32.xor(c, k), U32.xor(d, l), U32.xor(e, m), U32.xor(f, n), U32.xor(g, o), U32.xor(h, p), U32.xor(i, v0), U32.xor(j, v1), U32.xor(k, v2), U32.xor(l, v3), U32.xor(m, v4), U32.xor(n, v5), U32.xor(o, v6), U32.xor(p, v7)}

def compress(+cv: CV, message: Words, lo: U32, hi: U32, size: U32, flags: U32) -> Words:
	finalize(rounds(7n, initial(cv, lo, hi, size, flags), message), cv)

# Interpret a padded little-endian word. Short inputs zero-fill their tail.
def pack_word(bytes: List<&2, U32>) -> U32:
	match bytes:
		case Nil{}:
			0
		case Con{a, Nil{}}:
			a
		case Con{a, Con{b, Nil{}}}:
			(a + b * 256 : U32)
		case Con{a, Con{b, Con{c, Nil{}}}}:
			(a + b * 256 + c * 65536 : U32)
		case Con{a, Con{b, Con{c, Con{d, rest}}}}:
			(a + b * 256 + c * 65536 + d * 16777216 : U32)

def word_at(bytes: List<&2, U32>, offset: Nat) -> U32:
	pack_word(List.drop(&2, U32, bytes, offset))

def key_words(+bytes: List<&2, U32>) -> CV:
	CV{word_at(bytes, 0n), word_at(bytes, 4n), word_at(bytes, 8n), word_at(bytes, 12n), word_at(bytes, 16n), word_at(bytes, 20n), word_at(bytes, 24n), word_at(bytes, 28n)}

def block_words(+bytes: List<&2, U32>) -> Words:
	Words{word_at(bytes, 0n), word_at(bytes, 4n), word_at(bytes, 8n), word_at(bytes, 12n), word_at(bytes, 16n), word_at(bytes, 20n), word_at(bytes, 24n), word_at(bytes, 28n), word_at(bytes, 32n), word_at(bytes, 36n), word_at(bytes, 40n), word_at(bytes, 44n), word_at(bytes, 48n), word_at(bytes, 52n), word_at(bytes, 56n), word_at(bytes, 60n)}

def word_bytes(+x: U32) -> List<U32>:
	[U32.and(x, 255), U32.and(U32.shrn(x, 8n), 255), U32.and(U32.shrn(x, 16n), 255), U32.shrn(x, 24n)]

def words_bytes(words: Words) -> List<U32>:
	match words:
		case Words{a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p}:
			List.concat(&1, U32, [word_bytes(a), word_bytes(b), word_bytes(c), word_bytes(d), word_bytes(e), word_bytes(f), word_bytes(g), word_bytes(h), word_bytes(i), word_bytes(j), word_bytes(k), word_bytes(l), word_bytes(m), word_bytes(n), word_bytes(o), word_bytes(p)])

def first_cv(words: Words) -> CV:
	match words:
		case Words{a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p}:
			CV{a, b, c, d, e, f, g, h}

# Internal primitive: caller supplies <=64 bytes in [0,255]. Flags exclude ROOT.
def block_xof(+bytes: List<&2, U32>, cv: CV, flags: U32, lo: U32, hi: U32) -> List<U32>:
	words_bytes(compress(cv, block_words(bytes), lo, hi, U32.from_nat(List.length(&2, U32, bytes)), U32.or(flags, 11)))

def seed_key(material: List<&2, U32>) -> CV:
	context = {[114, 97, 110, 100, 111, 109, 32, 100, 114, 98, 103, 32, 50, 48, 50, 54, 45, 48, 56, 45, 48, 52, 32, 118, 49] : List<&2, U32>}
	context_key = first_cv(compress(iv(), block_words(context), 0, 0, 25, 43))
	first_cv(compress(context_key, block_words(material), 0, 0, 32, 75))

def bool_word(value: Bool) -> U32:
	match value:
		case False{}:
			0
		case True{}:
			1

# Emit at most one 64-byte compression per output block; scratch is block-sized.
def xof_blocks(fuel: Nat, +cv: CV, +hi: U32, +lo: U32, +skip: Nat, +left: Nat) -> List<U32>:
	match fuel:
		case 0n:
			Nil{}
		case 1n+p:
			all = words_bytes(compress(cv, zero_block(), lo, hi, 0, 27))
			+take = Nat.min(Nat.sub(64n, skip), left)
			chunk = List.take(&1, U32, List.drop(&1, U32, all, skip), take)
			+next = (lo + 1 : U32)
			carry = bool_word(U32.is_lt(next, lo))
			List.append(&1, U32, chunk, xof_blocks(p, cv, (hi + carry : U32), next, 0n, Nat.sub(left, take)))

# Internal bounded read; public checked state/domain adapters are a later layer.
def xof_at(cv: CV, +hi: U32, +lo: U32, count: Nat) -> List<U32>:
	match count:
		case 0n:
			Nil{}
		case 1n+p:
			+size = Nat.add(1n, p)
			+skip = U32.to_nat(U32.and(lo, 63))
			blocks = Nat.div(Nat.add(Nat.add(skip, size), 63n), 64n)
			xof_blocks(blocks, cv, U32.shrn(hi, 6n), U32.or(U32.shrn(lo, 6n), U32.shln(hi, 26n)), skip, size)

type Stream is Data:
	Stream{key: CV, hi: U32, lo: U32}

type Read is Type:
	Read{state: Stream, bytes: List<U32>}

# Public errors: 1 invalid arguments/state; 2 portable byte cursor exhausted.
def valid_bytes(bytes: List<&2, U32>) -> Bool:
	match bytes:
		case Nil{}:
			True{}
		case Con{head, tail}:
			U32.is_le(head, 255) && valid_bytes(tail)

def new_seed_if(valid: Bool, material: List<&2, U32>) -> Result<&2, &2, U32, Stream>:
	match valid:
		case False{}:
			Fail{1}
		case True{}:
			Done{Stream{seed_key(material), 0, 0}}

def new_seed(+material: List<&2, U32>) -> Result<&2, &2, U32, Stream>:
	new_seed_if(Nat.is_eq(List.length(&2, U32, material), 32n) && valid_bytes(material), material)

def cursor_valid(+hi: U32, lo: U32) -> Bool:
	U32.is_lt(hi, 2097152) || (U32.is_eq(hi, 2097152) && U32.is_eq(lo, 0))

def read_bounded(valid: Bool, +key: CV, hi: U32, lo: U32, next_hi: U32, next_lo: U32, count: Nat) -> Result<&2, &1, U32, Read>:
	match valid:
		case False{}:
			Fail{2}
		case True{}:
			Done{Read{Stream{key, next_hi, next_lo}, xof_at(key, hi, lo, count)}}

def read_checked(valid: Bool, key: CV, hi: U32, lo: U32, +next_hi: U32, +next_lo: U32, count: Nat) -> Result<&2, &1, U32, Read>:
	match valid:
		case False{}:
			Fail{1}
		case True{}:
			read_bounded(cursor_valid(next_hi, next_lo), key, hi, lo, next_hi, next_lo, count)

# Caller-owned immutable state; validate both endpoints before producing bytes.
def read(state: Stream, +count: U32) -> Result<&2, &1, U32, Read>:
	match state:
		case Stream{key, +hi, +lo}:
			+next_lo = (lo + count : U32)
			carry = bool_word(U32.is_lt(next_lo, lo))
			next_hi = (hi + carry : U32)
			read_checked(cursor_valid(hi, lo), key, hi, lo, next_hi, next_lo, U32.to_nat(count))

type Wide is Data:
	Wide{hi: U32, lo: U32}

# Two-limb modular arithmetic; neither counters nor signed values use Nat.
def u64_add(a: Wide, b: Wide) -> Wide:
	match a b:
		case Wide{ah, +al} Wide{bh, bl}:
			+lo = (al + bl : U32)
			Wide{(ah + bh + bool_word(U32.is_lt(lo, al)) : U32), lo}

def u64_sub(a: Wide, b: Wide) -> Wide:
	match a b:
		case Wide{ah, +al} Wide{bh, +bl}:
			Wide{(ah - bh - bool_word(U32.is_lt(al, bl)) : U32), (al - bl : U32)}

def u64_lt(a: Wide, b: Wide) -> Bool:
	match a b:
		case Wide{+ah, al} Wide{+bh, bl}:
			U32.is_lt(ah, bh) || (U32.is_eq(ah, bh) && U32.is_lt(al, bl))

def u64_zero(a: Wide) -> Bool:
	match a:
		case Wide{hi, lo}:
			U32.is_eq(hi, 0) && U32.is_eq(lo, 0)

def u64_top(a: Wide) -> U32:
	match a:
		case Wide{hi, lo}:
			U32.shrn(hi, 31n)

def u64_shl(a: Wide) -> Wide:
	match a:
		case Wide{hi, +lo}:
			Wide{U32.or(U32.shln(hi, 1n), U32.shrn(lo, 31n)), U32.shln(lo, 1n)}

def choose_wide(condition: Bool, yes: Wide, no: Wide) -> Wide:
	match condition:
		case True{}:
			yes
		case False{}:
			no

# Exact bounded-domain remainder: 0 < divisor <= 2^53. A shifted remainder
# is below 2^54, so the two-limb intermediate cannot overflow.
def u64_mod_go(fuel: Nat, +input: Wide, +divisor: Wide, remainder: Wide) -> Wide:
	match fuel:
		case 0n:
			remainder
		case 1n+p:
			+shifted = u64_add(u64_shl(remainder), Wide{0, u64_top(input)})
			next = choose_wide(u64_lt(shifted, divisor), shifted, u64_sub(shifted, divisor))
			u64_mod_go(p, u64_shl(input), divisor, next)

def u64_mod(input: Wide, divisor: Wide) -> Wide:
	u64_mod_go(64n, input, divisor, Wide{0, 0})

type Sample is Data:
	Sample{state: Stream, value: Wide}

type Failure is Data:
	Failure{code: U32, state: Stream}

type Prepared is Data:
	Prepared{start: Wide, span: Wide, limit: Wide, count: U32}

def int_valid(value: Wide) -> Bool:
	match value:
		case Wide{+hi, lo}:
			U32.is_ge(hi, 4292870144) || cursor_valid(hi, lo)

def signed_bias(value: Wide) -> Wide:
	match value:
		case Wide{hi, lo}:
			Wide{U32.xor(hi, 2147483648), lo}

def width_valid(width: Wide) -> Bool:
	match width:
		case Wide{hi, lo}:
			U32.is_lt(hi, 2097152)

def stream_valid(state: Stream) -> Bool:
	match state:
		case Stream{key, hi, lo}:
			cursor_valid(hi, lo)

def span_small(span: Wide) -> Bool:
	match span:
		case Wide{+hi, lo}:
			U32.is_eq(hi, 0) || (U32.is_eq(hi, 1) && U32.is_eq(lo, 0))

def mod_full(full: Bool, value: U32, divisor: U32) -> Wide:
	match full:
		case True{}:
			Wide{0, value}
		case False{}:
			Wide{0, U32.mod(value, divisor)}

def sample_mod(small: Bool, input: Wide, span: Wide) -> Wide:
	match small:
		case True{}:
			match input span:
				case Wide{ih, il} Wide{sh, sl}:
					mod_full(U32.is_eq(sh, 1), il, sl)
		case False{}:
			u64_mod(input, span)

def choose_word(condition: Bool, yes: U32, no: U32) -> U32:
	match condition:
		case True{}:
			yes
		case False{}:
			no

def append_byte(value: Wide, byte: U32) -> Wide:
	match value:
		case Wide{hi, +lo}:
			Wide{U32.or(U32.shln(hi, 8n), U32.shrn(lo, 24n)), U32.or(U32.shln(lo, 8n), byte)}

def be_word(bytes: List<U32>, acc: Wide) -> Wide:
	match bytes:
		case Nil{}:
			acc
		case Con{head, tail}:
			be_word(tail, append_byte(acc, head))

def range_bytes(params: Prepared) -> U32:
	match params:
		case Prepared{start, span, limit, count}:
			count

def range_accept(ok: Bool, state: Stream, draw: Wide, start: Wide, +span: Wide, retry: Stream -> Result<&2, &2, Failure, Sample>) -> Result<&2, &2, Failure, Sample>:
	match ok:
		case True{}:
			Done{Sample{state, u64_add(start, sample_mod(span_small(span), draw, span))}}
		case False{}:
			retry(state)

def range_candidate(+draw: Wide, state: Stream, params: Prepared, retry: Stream -> Result<&2, &2, Failure, Sample>) -> Result<&2, &2, Failure, Sample>:
	match params:
		case Prepared{start, span, +limit, count}:
			range_accept(u64_zero(limit) || u64_lt(draw, limit), state, draw, start, span, retry)

def range_after_read(result: Result<&2, &1, U32, Read>, before: Stream, params: Prepared, retry: Stream -> Result<&2, &2, Failure, Sample>) -> Result<&2, &2, Failure, Sample>:
	match result:
		case Fail{code}:
			Fail{Failure{code, before}}
		case Done{Read{state, bytes}}:
			range_candidate(be_word(bytes, Wide{0, 0}), state, params, retry)

def range_step(+state: Stream, +params: Prepared, retry: Stream -> Result<&2, &2, Failure, Sample>) -> Result<&2, &2, Failure, Sample>:
	range_after_read(read(state, range_bytes(params)), state, params, retry)

# Lexicographic structural fuel exceeds every possible number of four-byte
# draws before the 2^53 byte cap. Separate limbs avoid the 48-bit Nat ceiling.
# Rejection consumes state sequentially; failures retain its exact byte cursor.
def range_loop(high: Nat, low: Nat, state: Stream, +params: Prepared) -> Result<&2, &2, Failure, Sample>:
	match high low:
		case 0n 0n:
			Fail{Failure{3, state}}
		case 0n 1n+p:
			range_step(state, params, next => range_loop(0n, p, next, params))
		case 1n+h 0n:
			range_loop(h, 4294967295n, state, params)
		case 1n+h 1n+p:
			range_step(state, params, next => range_loop(1n+h, p, next, params))

def range_start(state: Stream, start: Wide, +span: Wide) -> Result<&2, &2, Failure, Sample>:
	+small = span_small(span)
	+remainder = sample_mod(small, u64_sub(Wide{0, 0}, span), span)
	limit = choose_wide(small, u64_sub(Wide{1, 0}, remainder), u64_sub(Wide{0, 0}, remainder))
	range_loop(2097152n, 4294967295n, state, Prepared{start, span, limit, choose_word(small, 4, 8)})

def range_single(single: Bool, state: Stream, +start: Wide, end: Wide) -> Result<&2, &2, Failure, Sample>:
	match single:
		case True{}:
			Done{Sample{state, start}}
		case False{}:
			range_start(state, start, u64_add(u64_sub(end, start), Wide{0, 1}))

def range_checked(valid: Bool, state: Stream, +start: Wide, +end: Wide) -> Result<&2, &2, Failure, Sample>:
	match valid:
		case False{}:
			Fail{Failure{1, state}}
		case True{}:
			range_single(u64_zero(u64_sub(end, start)), state, start, end)

# Inclusive signed bounds and two's-complement results, matching the portable
# ±2^53 range domain and at-most-2^53 inclusive span of the other cores.
def range(+state: Stream, +start: Wide, +end: Wide) -> Result<&2, &2, Failure, Sample>:
	valid = stream_valid(state) && int_valid(start) && int_valid(end) && Bool.not(u64_lt(signed_bias(end), signed_bias(start))) && width_valid(u64_sub(end, start))
	range_checked(valid, state, start, end)
