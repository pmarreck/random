# Integer-only 256-strip standard normal; exact production draw order.
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed
import ./Draw.bend as Draw
import ./ZigguratTables.bend as Tables

def arithmetic(result: Result<&2, &2, U32, Fixed.Fixed>) -> Draw.Program(Fixed.Fixed):
	Draw.checked(&2, Fixed.Fixed, result)

def word() -> Draw.Program(Core.Wide):
	do Draw.Program<Core.Wide>:
		bytes : List<U32> <- Draw.read(8)
		return Core.be_word(bytes, Core.Wide{0, 0})

def signed(negative: Bool, +value: Fixed.Fixed) -> Fixed.Fixed:
	Fixed.branch(Fixed.Fixed, negative, u => Fixed.neg(value), u => value)

def unit(coordinate: Core.Wide) -> Draw.Program(Fixed.Fixed):
	arithmetic(Fixed.norm(coordinate, 7))

def table_radius_value(value: Tables.Strip) -> Fixed.Fixed:
	match value:
		case Tables.Strip{x, y, k}:
			x

def table_radius() -> Fixed.Fixed:
	table_radius_value(Tables.lookup(1))

def tail_step(+negative: Bool, retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	do Draw.Program<Fixed.Fixed>:
		first : Core.Wide <- word()
		tuniform : Fixed.Fixed <- unit(Core.u64_add(Fixed.shr(first, 9n), Core.Wide{0, 1}))
		logarithm : Fixed.Fixed <- arithmetic(Fixed.ln(tuniform))
		t : Fixed.Fixed <- arithmetic(Fixed.div(Fixed.neg(logarithm), table_radius()))
		second : Core.Wide <- word()
		yuniform : Fixed.Fixed <- unit(Core.u64_add(Fixed.shr(second, 9n), Core.Wide{0, 1}))
		log_y : Fixed.Fixed <- arithmetic(Fixed.ln(yuniform))
		+y : Fixed.Fixed = Fixed.neg(log_y)
		doubled : Fixed.Fixed <- arithmetic(Fixed.add(y, y))
		+tcopy : Fixed.Fixed = t
		square : Fixed.Fixed <- arithmetic(Fixed.mul(tcopy, tcopy))
		Fixed.branch(Draw.Program(Fixed.Fixed), Bool.not(Fixed.less(doubled, square)), u => (
			do Draw.Program<Fixed.Fixed>:
				value : Fixed.Fixed <- arithmetic(Fixed.add(table_radius(), tcopy))
				return signed(negative, value)
		), retry)

def tail(high: Nat, low: Nat, +negative: Bool) -> Draw.Program(Fixed.Fixed):
	match high low:
		case 0n 0n:
			Draw.reject(Fixed.Fixed, 5)
		case 0n 1n+p:
			tail_step(negative, u => tail(0n, p, negative))
		case 1n+h 0n:
			tail(h, 4294967295n, negative)
		case 1n+h 1n+p:
			tail_step(negative, u => tail(1n+h, p, negative))

def wedge(+negative: Bool, +x: Fixed.Fixed, +y: Fixed.Fixed, upper: Fixed.Fixed, retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	do Draw.Program<Fixed.Fixed>:
		difference : Fixed.Fixed <- arithmetic(Fixed.sub(upper, y))
		coordinate : Core.Wide <- word()
		u : Fixed.Fixed <- unit(Fixed.shr(coordinate, 9n))
		scaled : Fixed.Fixed <- arithmetic(Fixed.mul(u, difference))
		candidate : Fixed.Fixed <- arithmetic(Fixed.add(y, scaled))
		square : Fixed.Fixed <- arithmetic(Fixed.mul(x, x))
		exponent : Fixed.Fixed <- arithmetic(Fixed.shift_exponent(Fixed.neg(square), Core.Wide{4294967295, 4294967295}))
		density : Fixed.Fixed <- arithmetic(Fixed.exp(exponent))
		Fixed.branch(Draw.Program(Fixed.Fixed), Fixed.less(candidate, density),
			u => Draw.pure(Fixed.Fixed, signed(negative, x)), retry)

def upper_height(value: Tables.Strip) -> Fixed.Fixed:
	match value:
		case Tables.Strip{x, y, k}:
			y

def fallback(+index: U32, +negative: Bool, +x: Fixed.Fixed, y: Fixed.Fixed, retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(index, 0),
		u => tail(2097152n, 4294967295n, negative), u => (
			upper = Fixed.branch(Fixed.Fixed, U32.is_eq(index, 255), u => Fixed.one(), u => upper_height(Tables.lookup((index + 1 : U32))))
			wedge(negative, x, y, upper, retry)
		))

def strip(+index: U32, +negative: Bool, +coordinate: Core.Wide, row: Tables.Strip, retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	match row:
		case Tables.Strip{x, y, k}:
			do Draw.Program<Fixed.Fixed>:
				u : Fixed.Fixed <- unit(coordinate)
				+value : Fixed.Fixed <- arithmetic(Fixed.mul(u, x))
				Fixed.branch(Draw.Program(Fixed.Fixed), Core.u64_lt(coordinate, k),
					u => Draw.pure(Fixed.Fixed, signed(negative, value)),
					u => fallback(index, negative, value, y, retry))

def header(+input: Core.Wide, retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	match input:
		case Core.Wide{+hi, +lo}:
			+index = U32.and(lo, 255)
			negative = U32.is_ne(U32.and(lo, 256), 0)
			strip(index, negative, Fixed.shr(Core.Wide{hi, lo}, 9n), Tables.lookup(index), retry)

def step(retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	do Draw.Program<Fixed.Fixed>:
		input : Core.Wide <- word()
		header(input, retry)

def loop(high: Nat, low: Nat) -> Draw.Program(Fixed.Fixed):
	match high low:
		case 0n 0n:
			Draw.reject(Fixed.Fixed, 5)
		case 0n 1n+p:
			step(u => loop(0n, p))
		case 1n+h 0n:
			loop(h, 4294967295n)
		case 1n+h 1n+p:
			step(u => loop(1n+h, p))

def normal() -> Draw.Program(Fixed.Fixed):
	loop(2097152n, 4294967295n)
