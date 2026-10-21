# Failures before success, matching the portable significant-level recurrence.
# Counts remain arbitrary-width, including fair low bits for tiny probabilities.
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed
import ./Count.bend as Count
import ./Draw.bend as Draw
import ./Ziggurat.bend as Word

type Prepared is Data:
	Prepared{base: Core.Wide, levels: List<&2, Core.Wide>, tail_bits: U32, certain: Bool}

def threshold(value: Fixed.Fixed) -> Result<&2, &2, U32, Core.Wide>:
	match value:
		case Fixed.Fixed{+m, +e}:
			valid = Bool.not(Fixed.negative(m)) && Bool.not(Core.u64_zero(m)) && (U32.is_eq(e, 4294967294) || U32.is_eq(e, 4294967295))
			Fixed.branch(Result<&2, &2, U32, Core.Wide>, valid,
				u => Done{Fixed.shl(m, U32.to_nat((e + 2 : U32)))}, u => Fail{5})

def prepare_loop(fuel: Nat, +value: Fixed.Fixed, +levels: List<&2, Core.Wide>, +tail_bits: U32) -> Result<&2, &2, U32, Prepared>:
	match fuel:
		case 0n:
			Fail{5}
		case 1n+p:
			Fixed.branch(Result<&2, &2, U32, Prepared>, Fixed.less(value, Fixed.half()), u => (
				do Result<&2, &2, U32, Prepared>:
					numerator : Fixed.Fixed <- Fixed.sub(Fixed.one(), value)
					denominator : Fixed.Fixed <- Fixed.sub(Fixed.small(2), value)
					fraction : Fixed.Fixed <- Fixed.div(numerator, denominator)
					bit : Core.Wide <- threshold(fraction)
					doubled : Fixed.Fixed <- Fixed.shift_exponent(value, Core.Wide{0, 1})
					square : Fixed.Fixed <- Fixed.mul(value, value)
					next : Fixed.Fixed <- Fixed.sub(doubled, square)
					prepare_loop(p, next, Con{bit, levels}, tail_bits)
			), u => (
				do Result<&2, &2, U32, Prepared>:
					base : Core.Wide <- threshold(value)
					return Prepared{base, levels, tail_bits, False{}}
			))

def prepare_start(value: Fixed.Fixed) -> Result<&2, &2, U32, Prepared>:
	match value:
		case Fixed.Fixed{+m, +e}:
			+tiny = U32.is_lt(U32.xor(e, 2147483648), U32.xor(4294967234, 2147483648))
			prepare_loop(129n, Fixed.Fixed{m, Core.choose_word(tiny, 4294967234, e)}, Nil{}, Core.choose_word(tiny, (4294967234 - e : U32), 0))

def prepare(+value: Fixed.Fixed) -> Result<&2, &2, U32, Prepared>:
	valid = Fixed.valid(value) && Bool.not(Fixed.is_zero(value)) && Bool.not(Fixed.is_negative(value)) && Fixed.exponent_in(value, 4293967296, 0) && Bool.not(Fixed.less(Fixed.one(), value))
	Count.guard(Prepared, valid, u => Fixed.branch(Result<&2, &2, U32, Prepared>, Bool.not(Fixed.less(value, Fixed.one())),
		u => Done{Prepared{Core.Wide{0, 0}, Nil{}, 0, True{}}}, u => prepare_start(value)))

def within(+value: Count.Count, +capacity: Core.Wide, action: Count.Count -> Draw.Program(Count.Count)) -> Draw.Program(Count.Count):
	Fixed.branch(Draw.Program(Count.Count), Core.u64_lt(capacity, Count.nat_wide(Count.length(value))),
		u => Draw.reject(Count.Count, 4), u => action(value))

def base_step(+base: Core.Wide, +value: Count.Count, +capacity: Core.Wide, retry: Count.Count -> Draw.Program(Count.Count)) -> Draw.Program(Count.Count):
	do Draw.Program<Count.Count>:
		word : Core.Wide <- Word.word()
		Fixed.branch(Draw.Program(Count.Count), Core.u64_lt(word, base), u => Draw.pure(Count.Count, value),
			u => within(Count.increment(value), capacity, retry))

def base_loop(high: Nat, low: Nat, +base: Core.Wide, value: Count.Count, +capacity: Core.Wide) -> Draw.Program(Count.Count):
	match high low:
		case 0n 0n:
			Draw.reject(Count.Count, 5)
		case 0n 1n+p:
			base_step(base, value, capacity, next => base_loop(0n, p, base, next, capacity))
		case 1n+h 0n:
			base_loop(h, 4294967295n, base, value, capacity)
		case 1n+h 1n+p:
			base_step(base, value, capacity, next => base_loop(1n+h, p, base, next, capacity))

def low_bits(+value: Count.Count, +bits: U32, +capacity: Core.Wide) -> Draw.Program(Count.Count):
	Fixed.branch(Draw.Program(Count.Count), U32.is_eq(bits, 0), u => Draw.pure(Count.Count, value), u => (
		+remaining = U32.to_nat(U32.mod(bits, 8))
		+extra = Core.bool_word(U32.is_ne(U32.shrn(Count.last(Count.magnitude(value), 0), Nat.sub(8n, remaining)), 0))
		shifted = Count.nat_wide(Nat.add(Nat.add(Count.length(value), U32.to_nat(U32.div(bits, 8))), U32.to_nat(extra)))
		+length = U32.div((bits + 7 : U32), 8)
		allowed = Bool.not(Core.u64_lt(capacity, shifted)) && Bool.not(Core.u64_lt(capacity, Core.Wide{0, length}))
		Fixed.branch(Draw.Program(Count.Count), allowed, u => (
			do Draw.Program<Count.Count>:
				bytes : List<U32> <- Draw.read(length)
				Draw.checked(&2, Count.Count, Count.append_low_bits(value, Count.owned(bytes), bits))
		), u => Draw.reject(Count.Count, 4))
	))

def levels_loop(levels: List<&2, Core.Wide>, +bits: U32, value: Count.Count, +capacity: Core.Wide) -> Draw.Program(Count.Count):
	match levels:
		case Nil{}:
			low_bits(value, bits, capacity)
		case Con{threshold, tail}:
			do Draw.Program<Count.Count>:
				word : Core.Wide <- Word.word()
				next : Count.Count <- Draw.checked(&2, Count.Count, Count.double_add(value, Core.bool_word(Core.u64_lt(word, threshold))))
				within(next, capacity, value => levels_loop(tail, bits, value, capacity))

def sample_prepared(prepared: Prepared, +capacity: Core.Wide) -> Draw.Program(Count.Count):
	match prepared:
		case Prepared{base, +levels, +bits, certain}:
			Fixed.branch(Draw.Program(Count.Count), certain, u => Draw.pure(Count.Count, Count.zero()), u => (
				minimum = Count.nat_wide(Nat.div(Nat.add(Nat.add(U32.to_nat(bits), List.length(&2, Core.Wide, levels)), 7n), 8n))
				Fixed.branch(Draw.Program(Count.Count), Core.u64_lt(capacity, minimum), u => Draw.reject(Count.Count, 4), u => (
					do Draw.Program<Count.Count>:
						value : Count.Count <- base_loop(2097152n, 4294967295n, base, Count.zero(), capacity)
						+complete : Count.Count <- levels_loop(levels, bits, value, capacity)
						Fixed.branch(Draw.Program(Count.Count), Core.u64_lt(capacity, Count.nat_wide(Count.blip_length(complete))),
							u => Draw.reject(Count.Count, 4), u => Draw.pure(Count.Count, complete))
				))
			))

def sample_bounded(prepared: Prepared, +capacity: Core.Wide) -> Draw.Program(Count.Count):
	Fixed.branch(Draw.Program(Count.Count), Core.u64_zero(capacity), u => Draw.reject(Count.Count, 4), u => sample_prepared(prepared, capacity))

def sample(prepared: Prepared) -> Draw.Program(Count.Count):
	sample_bounded(prepared, Core.Wide{4294967295, 4294967295})
