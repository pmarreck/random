app [run!] { pf: platform "./platform/main.roc", random: "./main.roc" }

import pf.Host
import random.Fixed
import random.Draw
import random.Sampler
import random.Geometric
import random.Count
import random.Decimal
import random.Drbg
import random.Chart
import random.Batch
import random.Selection

# The host supplies each requested byte chunk exactly once. Math, admission
# and sampler control flow remain in the imported functional core.
run! : U8, I64, I32, I64, I32, I64, I64, U64 => U8
run! = |op, am, ae, bm, be, first, last, capacity| {
	if op == 27 {
		match Selection.add_weight(first, last) {
			Ok(total) => return integer!(Draw.succeed(total))
			Err(_) => return 1
		}
	}
	if op == 24 or op == 25 {
		Host.reason!(0)
		prepared = match Selection.new(Host.weights!()) {
			Ok(value) => value
			Err(problem) => {
				Host.reason!(match problem {
					InvalidWeight => 1
					TotalTooLarge => 2
					ZeroTotal => 3
					Empty => 4
				})
				return 1
			}
		}
		if op == 24 return integer!(Draw.succeed(prepared.total()))
		return integer!(prepared.weighted())
	}
	if op == 26 {
		Host.begin!()
		indices = match interpret!(Selection.shuffle(capacity)) {
			Ok(values) => values
			Err(problem) => return status(problem)
		}
		_ = Host.permutation!(indices)
		return 0
	}
	if op == 23 {
		Host.begin!()
		batch = match Batch.normal(first, last, capacity, am) {
			Ok(prepared) => prepared
			Err(problem) => return status(problem)
		}
		var $batch = batch
		while Bool.True {
			match $batch.view() {
				Finished => return 0
				Item(item) => {
					value = match interpret!(item.program) {
						Ok(sampled) => sampled
						Err(problem) => return status(problem)
					}
					Host.item!(value, item.index, item.completed)
					$batch = item.after
				}
			}
		}
		return 0
	}
	if op >= 18 and op <= 22 return drbg!(op, first.to_u64_wrap(), capacity)
	if op == 6 return integer!(Sampler.range(first, last))
	if op == 7 return integer!(Sampler.normal_int(first, last))
	if op == 0 return numeric!(Sampler.uniform())
	if op == 10 return numeric!(Draw.succeed(Fixed.from_int(first)))
	if op == 13 or op == 14 {
		input = Host.input!()
		value = match (if op == 13 Decimal.parse_bytes(input) else Decimal.probability_bytes(input)) {
			Ok(parsed) => parsed
			Err(_) => return 1
		}
		return numeric!(Draw.succeed(value))
	}
	if op == 15 {
		value = match Decimal.integer_bytes(Host.input!()) {
			Ok(parsed) => parsed
			Err(_) => return 1
		}
		return integer!(Draw.succeed(value))
	}
	if op == 9 {
		value = match Count.from_blip(Host.input!()) {
			Ok(decoded) => decoded
			Err(problem) => return status(problem)
		}
		if first != 10 and first != 16 return 1
		Host.begin!()
		if first == 10 and value.bytes().len() > bm.to_u64_wrap() return 4
		text = if first == 10 value.to_decimal() else value.to_hex()
		bytes = text.to_utf8()
		if bytes.len() > capacity return 4
		_ = Host.output!(bytes)
		return 0
	}
	a = match Fixed.from_parts(am, ae) {
		Ok(value) => value
		Err(_) => return 1
	}
	if op == 11 return integer!(Draw.succeed(a.to_int_trunc()))
	if op == 12 return integer!(Draw.from_try(a.round_to_int()))
	if op == 16 {
		places = first.to_u64_wrap()
		if places > capacity or capacity - places < 3 return 4
		text = match Decimal.render(a, places) {
			Ok(rendered) => rendered
			Err(problem) => return status(problem)
		}
		bytes = text.to_utf8()
		if bytes.len() > capacity return 4
		_ = Host.output!(bytes)
		return 0
	}
	b = match Fixed.from_parts(bm, be) {
		Ok(value) => value
		Err(_) => return 1
	}
	if op == 17 {
		kind = match first {
			1 => Chart.Kind.Normal
			2 => Chart.Kind.Exponential
			3 => Chart.Kind.Poisson
			4 => Chart.Kind.LogNormal
			5 => Chart.Kind.Beta
			6 => Chart.Kind.Geometric
			_ => return 1
		}
		if capacity < 2 or capacity > 4096 return 1
		Host.count!(capacity)
		model = match Chart.sample(kind, a, b, capacity) {
			Ok(curve) => curve
			Err(problem) => return status(problem)
		}
		(minimum, maximum) = model.bounds()
		(lm, le) = minimum.parts()
		(hm, he) = maximum.parts()
		_ = Host.curve!(model.heights(), lm, le, hm, he)
		return 0
	}
	match op {
		1 => numeric!(Sampler.normal(a, b))
		2 => numeric!(Sampler.exponential(a))
		3 => integer!(Sampler.poisson(a))
		4 => numeric!(Sampler.log_normal(a, b))
		5 => numeric!(Sampler.beta(a, b))
		8 => {
			prepared = match Geometric.new(a) {
				Ok(value) => value
				Err(problem) => return status(problem)
			}
			Host.begin!()
			match interpret!(prepared.sample_bounded(capacity)) {
				Err(problem) => status(problem)
				Ok(value) => {
					_ = Host.output!(value.to_blip())
					0
				}
			}
		}
		_ => 1
	}
}

drbg! : U8, U64, U64 => U8
drbg! = |op, position, count| {
	# A zero-byte call does not inspect or mutate even an exhausted state.
	if op == 20 and count == 0 return 0
	if op != 18 and position > 9007199254740992 return 3
	if op == 20 and count > 9007199254740992 - position return 3
	if op == 21 and position > 9007199254740988 return 3
	if op == 22 and position > 9007199254740984 return 3
	input = Host.input!()
	rng = match (if op == 18 Drbg.new(input) else Drbg.restore(input, position)) {
		Ok(value) => value
		Err(_) => return 1
	}
	if op == 21 {
		(value, next) = match rng.u32() {
			Ok(result) => result
			Err(_) => return 3
		}
		Host.u32!(value)
		(key, cursor) = next.state()
		_ = Host.state!(key, cursor)
		return 0
	}
	if op == 22 {
		(value, next) = match rng.u64() {
			Ok(result) => result
			Err(_) => return 3
		}
		Host.u64!(value)
		(key, cursor) = next.state()
		_ = Host.state!(key, cursor)
		return 0
	}
	var $rng = rng
	if op == 20 {
		var $offset = 0.U64
		while $offset < count {
			remaining = count - $offset
			chunk = if remaining > 1048576 1048576 else remaining
			(bytes, next) = match $rng.bytes(chunk) {
				Ok(result) => result
				Err(_) => return 3
			}
			_ = Host.chunk!(bytes, $offset)
			$rng = next
			$offset = $offset + chunk
		}
	}
	(key, cursor) = $rng.state()
	_ = Host.state!(key, cursor)
	0
}

interpret! : Draw(a) => Try(a, [Invalid, Numeric, DivisionByZero, Source, BufferTooSmall])
interpret! = |initial| {
	var $program = initial
	var $answer = Missing
	var $done = Bool.False
	while !$done {
		match $program.view() {
			Done(value) => {
				$answer = Ready(value)
				$done = Bool.True
			}
			Failed(problem) => return Err(problem)
			Need(request) => {
				bytes = Host.source!(request.count)
				if Host.status!() != 0 return Err(Source)
				resume = request.after
				$program = resume(bytes)
			}
		}
	}
	match $answer {
		Ready(value) => Ok(value)
		Missing => Err(Invalid)
	}
}

status : [Invalid, Numeric, DivisionByZero, Source, BufferTooSmall] -> U8
status = |problem| match problem {
	Invalid => 1
	Numeric => 5
	DivisionByZero => 5
	Source => 2
	BufferTooSmall => 4
}

numeric! : Draw(Fixed) => U8
numeric! = |program| match interpret!(program) {
	Err(problem) => status(problem)
	Ok(value) => {
		(m, e) = value.parts()
		Host.numeric!(m, e)
		0
	}
}

integer! : Draw(I64) => U8
integer! = |program| match interpret!(program) {
	Err(problem) => status(problem)
	Ok(value) => {
		Host.integer!(value)
		0
	}
}
