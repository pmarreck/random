import Fixed
import Blake3
import Codec
import Drbg
import Draw
import Sampler
import Count
import Geometric
import Decimal
import Chart

main! : List(Str) => Try({}, [BadNumStr, Exit(I8), Invalid])
main! = |args| {
	match args {
		["chart", operation, a, b, count] => {
			kind : Chart.Kind
			kind = match operation {
				"normal" => Normal
				"exponential" => Exponential
				"poisson" => Poisson
				"geometric" => Geometric
				"log_normal" => LogNormal
				"beta" => Beta
				_ => return Err(Exit(1.I8))
			}
			first = match if operation == "geometric" Decimal.probability(a) else Decimal.parse(a) {
				Ok(value) => value
				Err(_) => return Err(Exit(1.I8))
			}
			second = match Decimal.parse(b) {
				Ok(value) => value
				Err(_) => return Err(Exit(1.I8))
			}
			model = match Chart.sample(kind, first, second, U64.from_str(count) ?? 0) {
				Ok(value) => value
				Err(_) => return Err(Exit(1.I8))
			}
			(lo, hi) = model.bounds()
			(lm, le) = lo.parts()
			(hm, he) = hi.parts()
			discrete = if model.discrete() "true" else "false"
			echo!("${lm.to_str()},${le.to_str()};${hm.to_str()},${he.to_str()};${discrete}\n")
			echo!(Str.join_with(model.heights().map(|height| height.to_str()), ","))
			return Ok({})
		}
		["integer_parse", text] => {
			value = Decimal.integer(text)?
			echo!(value.to_str())
			return Ok({})
		}
		["parse", text] => {
			value = match Decimal.parse(text) {
				Ok(result) => result
				Err(_) => return Err(Exit(1.I8))
			}
			(m, e) = value.parts()
			echo!("${m.to_str()},${e.to_str()}")
			return Ok({})
		}
		["probability", text] => {
			value = match Decimal.probability(text) {
				Ok(result) => result
				Err(_) => return Err(Exit(1.I8))
			}
			(m, e) = value.parts()
			echo!("${m.to_str()},${e.to_str()}")
			return Ok({})
		}
		["render", ms, es, ps] => {
			value = Fixed.from_parts(I64.from_str(ms)?, I32.from_str(es)?)?
			text = match Decimal.render(value, U64.from_str(ps)?) {
				Ok(result) => result
				Err(_) => return Err(Exit(1.I8))
			}
			echo!(text)
			return Ok({})
		}
		["hash", text] => {
			bytes = Codec.unhex(text)?
			echo!(Codec.hex(Blake3.hash32(bytes)?))
			return Ok({})
		}
		["xof", text, ps, cs] => {
			key = Codec.unhex(text)?
			position = U64.from_str(ps)?
			count = U64.from_str(cs)?
			echo!(Codec.hex(Blake3.keyed_xof(key, position, count)?))
			return Ok({})
		}
		["derive", context, material] => {
			echo!(Codec.hex(Blake3.derive_key(context.to_utf8(), Codec.unhex(material)?)?))
			return Ok({})
		}
		["seed", text] => {
			echo!(Codec.hex(Codec.seed(text)?))
			return Ok({})
		}
		["drbg", seed, ps, cs] => {
			state = Drbg.new(Codec.seed(seed)?)?.seek(U64.from_str(ps)?)?
			(bytes, _next) = state.bytes(U64.from_str(cs)?)?
			echo!(Codec.hex(bytes))
			return Ok({})
		}
		["sample", op, seed, cs] => {
			var $state = Drbg.new(Codec.seed(seed)?)?
			count = U64.from_str(cs)?
			if count > 1024 return Err(Exit(1.I8))
			for _index in 0..<count {
				program = match op {
					"normal" => Sampler.normal(Fixed.zero, Fixed.from_int(1))
					"exponential" => Sampler.exponential(Fixed.from_int(1))
					"log_normal" => Sampler.log_normal(Fixed.zero, Fixed.from_int(1))
					"beta" => Sampler.beta(Fixed.from_int(2), Fixed.from_int(2))
					_ => return Err(Exit(1.I8))
				}
				(value, next) = match program.run_with($state, |rng, n| rng.bytes(n)) {
					Ok(result) => result
					Err(_) => return Err(Exit(1.I8))
				}
				(m, e) = value.parts()
				echo!("${m.to_str()},${e.to_str()}\n")
				$state = next
			}
			echo!("pos=${$state.position().to_str()}\n")
			return Ok({})
		}
		["sample_params", op, seed, cs, ams, aes, bms, bes] => {
			var $state = Drbg.new(Codec.seed(seed)?)?
			count = U64.from_str(cs)?
			if count > 1024 return Err(Exit(1.I8))
			a = Fixed.from_parts(I64.from_str(ams)?, I32.from_str(aes)?)?
			b = Fixed.from_parts(I64.from_str(bms)?, I32.from_str(bes)?)?
			for _index in 0..<count {
				program = match op {
					"normal" => Sampler.normal(a, b)
					"exponential" => Sampler.exponential(a)
					"log_normal" => Sampler.log_normal(a, b)
					"beta" => Sampler.beta(a, b)
					_ => return Err(Exit(1.I8))
				}
				(value, next) = match program.run_with($state, |rng, n| rng.bytes(n)) {
					Ok(result) => result
					Err(_) => return Err(Exit(1.I8))
				}
				(m, e) = value.parts()
				echo!("${m.to_str()},${e.to_str()}\n")
				$state = next
			}
			echo!("pos=${$state.position().to_str()}\n")
			return Ok({})
		}
		["geometric", seed, ms, es, cs] => {
			probability = Fixed.from_parts(I64.from_str(ms)?, I32.from_str(es)?)?
			prepared = match Geometric.new(probability) {
				Ok(value) => value
				Err(_) => return Err(Exit(1.I8))
			}
			var $state = Drbg.new(Codec.seed(seed)?)?
			count = U64.from_str(cs)?
			if count > 1024 return Err(Exit(1.I8))
			for _index in 0..<count {
				(value, next) = match prepared.sample().run_with($state, |rng, n| rng.bytes(n)) {
					Ok(result) => result
					Err(_) => return Err(Exit(1.I8))
				}
				echo!("${Codec.hex(value.to_blip())}\n")
				$state = next
			}
			echo!("pos=${$state.position().to_str()}\n")
			return Ok({})
		}
		["integer", op, seed, cs, first_s, last_s] => {
			var $state = Drbg.new(Codec.seed(seed)?)?
			count = U64.from_str(cs)?
			first = I64.from_str(first_s)?
			last = I64.from_str(last_s)?
			if count > 1024 return Err(Exit(1.I8))
			for _index in 0..<count {
				program = match op {
					"range" => Sampler.range(first, last)
					"normal_int" => Sampler.normal_int(first, last)
					"poisson" => Sampler.poisson(Fixed.from_int(first))
					_ => return Err(Exit(1.I8))
				}
				(value, next) = match program.run_with($state, |rng, n| rng.bytes(n)) {
					Ok(result) => result
					Err(_) => return Err(Exit(1.I8))
				}
				echo!("${value.to_str()}\n")
				$state = next
			}
			echo!("pos=${$state.position().to_str()}\n")
			return Ok({})
		}
		_ => {}
	}
	match calculate(args) {
		Ok(value) => {
			(m, e) = value.parts()
			echo!("${m.to_str()},${e.to_str()}")
			Ok({})
		}
		Err(_) => Err(Exit(1.I8))
	}
}

# A test-only native entrypoint: arguments are runtime inputs so these checks
# also exercise LLVM output, rather than just Roc's expectation interpreter.
calculate = |args| {
	match args {
		[op, ms, es] => {
			m = I64.from_str(ms)?
			e = I32.from_str(es)?
			value = Fixed.from_parts(m, e)?
			match op {
				"ln" => value.ln()
				"exp" => value.exp()
				"sqrt" => value.sqrt()
				"cos" => value.cos_turns()
				_ => Err(Invalid)
			}
		}
		[op, ms, es, other_ms, other_es] => {
			a = Fixed.from_parts(I64.from_str(ms)?, I32.from_str(es)?)?
			b = Fixed.from_parts(I64.from_str(other_ms)?, I32.from_str(other_es)?)?
			match op {
				"add" => a.add(b)
				"sub" => a.sub(b)
				"mul" => a.mul(b)
				"div" => a.div(b)
				"pow" => a.pow(b)
				_ => Err(Invalid)
			}
		}
		_ => Err(Invalid)
	}
}

expect Fixed.from_int(0).parts() == (0, 0)
expect Fixed.from_int(1).parts() == (4611686018427387904, 0)
expect Fixed.from_int(-3).parts() == (-6917529027641081856, 1)
expect Fixed.from_parts(1, 0) == Err(Invalid)
expect Fixed.from_parts(0, 1) == Err(Invalid)
expect Fixed.from_parts(4611686018427387904, -1000000).is_ok()
expect Fixed.from_int(3).mul(Fixed.from_int(2)) == Ok(Fixed.from_int(6))
expect Fixed.from_int(3).add(Fixed.from_int(-2)) == Ok(Fixed.from_int(1))
expect Fixed.from_int(1).div(Fixed.from_int(2)) == Fixed.from_parts(4611686018427387904, -1)
expect Fixed.from_int(1).div(Fixed.from_int(0)) == Err(DivisionByZero)
expect Fixed.from_int(-7).to_int_trunc() == -7
expect {
	left = Fixed.from_int(9007199254740992)
	left.parts() == (4611686018427387904, 53)
}

# Exercise the actual numeric primitives required by the portable kernel.
expect U128.shl_wrap(1, 124).div_by(U128.shl_wrap(1, 62)) == 4611686018427387904
expect U128.times(9223372036854775807, 9223372036854775807) == 85070591730234615847396907784232501249
expect I128.div_trunc_by(-7, 2) == -3
expect U32.plus_wrap(4294967295, 1) == 0

expect Fixed.from_int(1).ln() == Ok(Fixed.zero)
expect Fixed.zero.exp() == Ok(Fixed.from_int(1))
expect Fixed.from_int(4).sqrt() == Ok(Fixed.from_int(2))
expect Fixed.from_int(-1).sqrt() == Err(Invalid)
expect Fixed.zero.ln() == Err(Invalid)
expect Fixed.zero.cos_turns() == Ok(Fixed.from_int(1))
expect Fixed.from_int(1).cos_turns() == Ok(Fixed.from_int(1))
expect Fixed.from_int(2).pow(Fixed.from_int(3)) == Fixed.from_parts(4611686018427387904, 3)
expect {
	maximum = Fixed.from_parts(4611686018427387904, 2147483647)?
	maximum.mul(Fixed.from_int(2)) == Err(Numeric)
}

# Frozen official BLAKE3 test vectors, not regenerated by the new port.
expect {
	bytes = Blake3.hash32([])?
	Codec.hex(bytes) == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
}
expect {
	bytes = Blake3.hash32([0])?
	Codec.hex(bytes) == "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"
}
expect {
	bytes = Blake3.keyed_xof("whats the Elvish word for friend".to_utf8(), 0, 32)?
	Codec.hex(bytes) == "92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26"
}
expect Blake3.keyed_xof([], 0, 1) == Err(Invalid)
expect Codec.unhex("aZ") == Err(Invalid)
expect Codec.unhex("a") == Err(Invalid)
expect Codec.unhex("00AbFF") == Ok([0, 171, 255])
expect Codec.seed("42") == Codec.seed("0x002A")
expect Codec.seed("-1") == Err(Invalid)
expect Codec.seed("1.0") == Err(Invalid)
expect Codec.seed("0x") == Err(Invalid)
expect Codec.seed("0x00000000000000000000000000000000000000000000000000000000000000000") == Err(Invalid)
expect Codec.seed("115792089237316195423570985008687907853269984665640564039457584007913129639936") == Err(Invalid)
expect Drbg.new([]) == Err(Invalid)
expect {
	state = Drbg.new(Codec.seed("42")?)?
	(value, next) = state.range(7, 7)?
	value == 7 and next.position() == 0
}
expect {
	state = Drbg.new(Codec.seed("42")?)?.seek(9007199254740992)?
	(bytes, next) = state.bytes(0)?
	bytes.is_empty() and next.position() == 9007199254740992
}
expect {
	state = Drbg.new(Codec.seed("42")?)?.seek(9007199254740991)?
	state.bytes(2) == Err(Invalid)
}
expect {
	program = Draw.read(2).and_then(|bytes| Draw.succeed(bytes.len()))
	program.run_with([1.U8, 2, 3], read_fixture) == Ok((2, [3]))
}
expect {
	program = Draw.read(2)
	program.run_with([1.U8], read_fixture) == Err(Source)
}

read_fixture = |bytes, count| {
	if bytes.len() < count Err(Source)
	else Ok((bytes.take_first(count), bytes.drop_first(count)))
}

expect {
	(value, remaining) = Sampler.poisson(Fixed.from_int(1)).run_with([0.U8, 0, 0, 0], read_fixture)?
	value == 0 and remaining.is_empty()
}
expect Sampler.normal(Fixed.zero, Fixed.zero).run_with([], read_fixture) == Err(Invalid)
expect Sampler.range(5, 5).run_with([], read_fixture) == Ok((5, []))
expect Sampler.range(2, 1).run_with([], read_fixture) == Err(Invalid)
expect Sampler.normal(Fixed.zero, Fixed.from_int(1)).run_with([0.U8], read_fixture) == Err(Source)
expect Count.zero.to_decimal() == "0"
expect Count.from_bytes([0, 0]).to_decimal() == "0"
expect Count.from_decimal("18446744073709551616")?.to_blip() == [137, 0, 0, 0, 0, 0, 0, 0, 0, 1]
expect Count.from_decimal("128")?.to_blip() == [129, 128]
expect Count.from_decimal("127")?.to_blip() == [127]
expect Count.from_decimal("12a") == Err(Invalid)
expect Count.zero.double_add(2) == Err(Invalid)
expect Count.from_bytes([255, 255]).increment().bytes() == [0, 0, 1]
expect Count.from_bytes([1]).append_low_bits([255], 3)?.to_decimal() == "15"
expect Geometric.new(Fixed.zero) == Err(Invalid)
expect {
	prepared = Geometric.new(Fixed.from_int(1))?
	prepared.sample().run_with([], read_fixture) == Ok((Count.zero, []))
}
expect {
	prepared = Geometric.new(Fixed.power_of_two(-1))?
	(value, remaining) = prepared.sample().run_with(List.repeat(0.U8, 8), read_fixture)?
	value == Count.zero and remaining.is_empty()
}
expect {
	prepared = Geometric.new(Fixed.power_of_two(-2))?
	prepared.sample().run_with(List.repeat(0.U8, 8), read_fixture) == Err(Source)
}

# Review controls: source length, domain validation before any source call,
# public materialization caps and exact low-bit reconstruction.
expect Draw.read(2).run_with({}, |_state, _size| Ok(([0.U8], {}))) == Err(Source)
expect Draw.read(2).run_with({}, |_state, _size| Ok(([0.U8, 0, 0], {}))) == Err(Source)
expect Draw.read(0).run_with({}, |_state, _size| Err(Source)) == Ok(([], {}))
expect Draw.read(1048577).run_with({}, |_state, _size| Err(Source)) == Err(Invalid)
expect Sampler.normal_int(9007199254740993, 9007199254740993).run_with({}, |_state, _size| Err(Source)) == Err(Invalid)
expect Sampler.range(-9007199254740992, 0).run_with({}, |_state, _size| Err(Source)) == Err(Invalid)
expect Sampler.beta(Fixed.power_of_two(-21), Fixed.from_int(1)).run_with({}, |_state, _size| Err(Source)) == Err(Invalid)
expect Sampler.beta(Fixed.from_int(1), Fixed.power_of_two(21)).run_with({}, |_state, _size| Err(Source)) == Err(Invalid)
expect Sampler.poisson(Fixed.power_of_two(20)).run_with({}, |_state, _size| Err(Source)) == Err(Invalid)
expect Sampler.exponential(Fixed.zero).run_with({}, |_state, _size| Err(Source)) == Err(Invalid)
expect Sampler.log_normal(Fixed.power_of_two(28), Fixed.from_int(1)).run_with({}, |_state, _size| Err(Source)) == Err(Invalid)
expect Sampler.log_normal(Fixed.zero, Fixed.power_of_two(24)).run_with({}, |_state, _size| Err(Source)) == Err(Invalid)
expect Geometric.new(Fixed.power_of_two(-1000001)) == Err(Invalid)
expect Geometric.new(Fixed.from_int(2)) == Err(Invalid)
expect Drbg.restore(List.repeat(0.U8, 32), 9007199254740993) == Err(Invalid)
expect {
	rng = Drbg.restore(List.repeat(0.U8, 32), 0)?
	rng.bytes(1048577) == Err(Invalid)
}
expect Blake3.hash32(List.repeat(0.U8, 65)) == Err(Invalid)
expect Blake3.derive_key(List.repeat(0.U8, 65), []) == Err(Invalid)
expect Count.from_bytes([0, 1]).append_low_bits([255], 3)?.to_decimal() == "2055"
expect Count.from_bytes([1]).append_low_bits([], 0)?.to_decimal() == "1"
expect Count.from_bytes([1]).append_low_bits([], 1) == Err(Invalid)
expect Count.from_bytes([1]).append_low_bits([1], 1000001) == Err(Invalid)

# Decimal/probability contracts preceded implementation, then were checked
# again through optimized native runtime oracles in the Bash gate.
expect Decimal.parse("0.5") == Ok(Fixed.power_of_two(-1))
expect Decimal.parse("-.5") == Ok(Fixed.power_of_two(-1).neg())
expect Decimal.parse(" +42 \n") == Ok(Fixed.from_int(42))
expect Decimal.parse("1.") == Ok(Fixed.from_int(1))
expect Decimal.parse(".") == Err(Invalid)
expect Decimal.parse("1e-3") == Err(Invalid)
expect Decimal.parse("1.2.3") == Err(Invalid)
expect Decimal.parse("1x") == Err(Invalid)
expect Decimal.parse("1 2") == Err(Invalid)
expect Decimal.parse("+") == Err(Invalid)
expect Decimal.parse(" 1") == Err(Invalid)
expect Decimal.parse("123456789012345678") == Ok(Fixed.from_int(123456789012345678))
expect Decimal.parse(Str.repeat("9", 2001)) == Err(Invalid)
expect Decimal.parse(Str.repeat("0", 2001)) == Ok(Fixed.zero)
expect Decimal.integer("9007199254740992") == Ok(9007199254740992)
expect Decimal.integer("-9007199254740992") == Ok(-9007199254740992)
expect Decimal.integer("9007199254740993") == Err(Invalid)
expect Decimal.integer("-9007199254740993") == Err(Invalid)
expect Decimal.integer("1.") == Err(Invalid)
expect Decimal.integer("--1") == Err(Invalid)
expect Decimal.render(Fixed.zero, 18) == Ok("0.000000000000000000")
expect Decimal.render(Fixed.from_int(-1), 0) == Ok("-1")
expect Decimal.render(Fixed.power_of_two(-1), 18) == Ok("0.500000000000000000")
expect Decimal.render(Fixed.power_of_two(63), 0) == Ok("9223372036854775808")
expect Decimal.render(Fixed.power_of_two(2147483647), 18) == Err(Numeric)
expect Decimal.render(Fixed.zero, 19) == Err(Invalid)
expect Decimal.probability("2^-1000000") == Ok(Fixed.power_of_two(-1000000))
expect Decimal.probability("1e-20").is_ok()
expect Decimal.probability("1E+0") == Ok(Fixed.from_int(1))
expect Decimal.probability("0") == Err(Invalid)
expect Decimal.probability("-0.1") == Err(Invalid)
expect Decimal.probability("2^-1000001") == Err(Invalid)
expect Decimal.probability("2^1") == Err(Invalid)
expect Decimal.probability("1e--3") == Err(Invalid)
expect Decimal.probability("-1e-3") == Err(Invalid)
expect Decimal.probability(" 2^-2 ") == Err(Invalid)
expect Decimal.probability(Str.repeat("0", 2001)) == Err(Invalid)
expect Decimal.parse_bytes([255]) == Err(Invalid)
expect Decimal.parse_bytes([49, 0]) == Err(Invalid)
expect Decimal.integer_bytes([255]) == Err(Invalid)
expect Decimal.integer_bytes([49, 0]) == Err(Invalid)
expect Decimal.probability_bytes([255]) == Err(Invalid)
expect Decimal.probability_bytes([49, 0]) == Err(Invalid)

# Canonical model contracts and external frozen height witnesses; encodings
# and terminal effects are not part of this pure geometry boundary.
expect match Chart.sample(Normal, Fixed.zero, Fixed.from_int(1), 5) {
	Ok(model) => model.heights() == [21, 8869, 65535, 8869, 21] and
		model.bounds() == (Fixed.from_int(-4), Fixed.from_int(4)) and !model.discrete()
	Err(_) => Bool.False
}
expect match Chart.sample(Exponential, Fixed.from_int(1), Fixed.zero, 5) {
	Ok(model) => model.heights() == [65535, 14622, 3262, 728, 162]
	Err(_) => Bool.False
}
expect match Chart.sample(Beta, Fixed.from_int(1), Fixed.from_int(1), 5) {
	Ok(model) => model.heights() == [65535, 65535, 65535, 65535, 65535]
	Err(_) => Bool.False
}
expect match Chart.sample(Geometric, Fixed.from_int(1), Fixed.zero, 8) {
	Ok(model) => model.heights() == [65535, 65535, 0, 0, 0, 0, 0, 0]
	Err(_) => Bool.False
}
expect match Chart.sample(Poisson, Fixed.from_int(3), Fixed.zero, 2) {
	Ok(model) => model.heights() == [14563, 0] and
		model.bounds() == (Fixed.zero, Fixed.from_int(14)) and !model.discrete()
	Err(_) => Bool.False
}
expect match Chart.sample(LogNormal, Fixed.zero, Fixed.from_int(1), 2) {
	Ok(model) => model.heights() == [0, 65535] and
		model.bounds() == (Fixed.zero, Fixed.from_parts(5855018517369714258, 2) ?? Fixed.zero)
	Err(_) => Bool.False
}
expect Chart.sample(Normal, Fixed.zero, Fixed.from_int(1), 1) == Err(Invalid)
expect Chart.sample(Normal, Fixed.zero, Fixed.from_int(1), 4097) == Err(Invalid)
expect Chart.sample(Normal, Fixed.zero, Fixed.zero, 2) == Err(Invalid)
expect Chart.sample(Exponential, Fixed.from_int(1), Fixed.from_int(1), 2) == Err(Invalid)
expect Chart.sample(Beta, Fixed.power_of_two(-21), Fixed.from_int(1), 2) == Err(Numeric)
