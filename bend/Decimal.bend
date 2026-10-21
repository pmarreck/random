# Pure ASCII numeric codecs. Evaluation order and eighteen-place truncation
# deliberately match the portable kernel, without machine floats or locales.
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed
import ./Count.bend as Count
import ./Geometric.bend as Geometric

type Split is Data:
	Split{before: List<&2, U32>, after: List<&2, U32>, found: Bool}

type Signed is Data:
	Signed{negative: Bool, digits: List<&2, U32>}

type Whole is Data:
	Whole{text: String, fraction: Fixed.Fixed}

def digit(+byte: U32) -> Bool:
	U32.is_ge(byte, 48) && U32.is_le(byte, 57)

def space(+byte: U32) -> Bool:
	U32.is_eq(byte, 32) || (U32.is_ge(byte, 9) && U32.is_le(byte, 13))

def drop_space(bytes: List<&2, U32>) -> List<&2, U32>:
	match bytes:
		case Nil{}:
			Nil{}
		case Con{+head, +tail}:
			Fixed.branch(List<&2, U32>, space(head), u => drop_space(tail), u => Con{head, tail})

def trim(bytes: List<&2, U32>) -> List<&2, U32>:
	List.reverse(&2, U32, drop_space(List.reverse(&2, U32, drop_space(bytes))))

def sign(bytes: List<&2, U32>) -> Signed:
	match bytes:
		case Con{45, tail}:
			Signed{True{}, tail}
		case Con{43, tail}:
			Signed{False{}, tail}
		case other:
			Signed{False{}, other}

def split_prepend(head: U32, result: Split) -> Split:
	match result:
		case Split{before, after, found}:
			Split{Con{head, before}, after, found}

def split(bytes: List<&2, U32>, +first: U32, +second: U32) -> Split:
	match bytes:
		case Nil{}:
			Split{Nil{}, Nil{}, False{}}
		case Con{+head, +tail}:
			Fixed.branch(Split, U32.is_eq(head, first) || U32.is_eq(head, second),
				u => Split{Nil{}, tail, True{}}, u => split_prepend(head, split(tail, first, second)))

def digits(bytes: List<&2, U32>) -> Bool:
	match bytes:
		case Nil{}:
			True{}
		case Con{head, tail}:
			digit(head) && digits(tail)

def times_ten(+value: Core.Wide) -> Core.Wide:
	Core.u64_add(Fixed.shl(value, 3n), Fixed.shl(value, 1n))

def unsigned_go(bytes: List<&2, U32>, +quotient: Core.Wide, +remainder: Core.Wide, +value: Core.Wide) -> Result<&2, &2, U32, Core.Wide>:
	match bytes:
		case Nil{}:
			Done{value}
		case Con{+head, tail}:
			+next : Core.Wide = Core.Wide{0, (head - 48 : U32)}
			valid : Bool = digit(head) && Bool.not(Core.u64_lt(quotient, value)) &&
				(Core.u64_lt(value, quotient) || Bool.not(Core.u64_lt(remainder, next)))
			Count.guard(Core.Wide, valid, u => unsigned_go(tail, quotient, remainder, Core.u64_add(times_ten(value), next)))

def unsigned(+bytes: List<&2, U32>, +limit: Core.Wide) -> Result<&2, &2, U32, Core.Wide>:
	+q : Core.Wide = Fixed.quotient_bits(64n, limit, Core.Wide{0, 10}, Core.Wide{0, 0}, Core.Wide{0, 0})
	r : Core.Wide = Core.u64_sub(limit, times_ten(q))
	Count.guard(Core.Wide, Bool.not(Count.empty(bytes)), u => unsigned_go(bytes, q, r, Core.Wide{0, 0}))

def signed_parts(parts: Signed, +limit: Core.Wide) -> Result<&2, &2, U32, Core.Wide>:
	match parts:
		case Signed{+negative, raw}:
			do Result<&2, &2, U32, Core.Wide>:
				value : Core.Wide <- unsigned(raw, limit)
				return Fixed.signed_mantissa(negative, value)

def signed(bytes: List<&2, U32>, limit: Core.Wide) -> Result<&2, &2, U32, Core.Wide>:
	signed_parts(sign(bytes), limit)

def integer(bytes: List<&2, U32>) -> Result<&2, &2, U32, Core.Wide>:
	signed(trim(bytes), Core.Wide{2097152, 0})

def fold_integer(bytes: List<&2, U32>, +value: Fixed.Fixed) -> Result<&2, &2, U32, Fixed.Fixed>:
	match bytes:
		case Nil{}:
			Done{value}
		case Con{head, tail}:
			do Result<&2, &2, U32, Fixed.Fixed>:
				scaled : Fixed.Fixed <- Fixed.mul(value, Fixed.small(10))
				next : Fixed.Fixed <- Fixed.add(scaled, Fixed.small((head - 48 : U32)))
				fold_integer(tail, next)

def integer_result(result: Result<&2, &2, U32, Core.Wide>, +bytes: List<&2, U32>) -> Result<&2, &2, U32, Fixed.Fixed>:
	match result:
		case Done{value}:
			Fixed.from_int(value)
		case Fail{code}:
			Count.guard(Fixed.Fixed, Nat.is_le(List.length(&2, U32, bytes), 2000n), u => fold_integer(bytes, Fixed.zero()))

def integer_part(+bytes: List<&2, U32>) -> Result<&2, &2, U32, Fixed.Fixed>:
	Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, Count.empty(bytes), u => Done{Fixed.zero()},
		u => integer_result(unsigned(bytes, Core.Wide{2147483647, 4294967295}), bytes))

def power_ten(fuel: Nat, value: Core.Wide) -> Core.Wide:
	match fuel:
		case 0n:
			value
		case 1n+p:
			power_ten(p, times_ten(value))

def decimal_parts(+integers: List<&2, U32>, +fraction: List<&2, U32>, +strict: Bool) -> Result<&2, &2, U32, Fixed.Fixed>:
	valid : Bool = digits(integers) && digits(fraction) && Bool.not(Count.empty(integers) && Count.empty(fraction)) &&
		(Bool.not(strict) || Nat.is_le(List.length(&2, U32, integers), 2000n))
	Count.guard(Fixed.Fixed, valid, u => (
		do Result<&2, &2, U32, Fixed.Fixed>:
			+whole : Fixed.Fixed <- integer_part(integers)
			Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, Count.empty(fraction), u => Done{whole}, u => (
				do Result<&2, &2, U32, Fixed.Fixed>:
					+short : List<&2, U32> = List.take(&2, U32, fraction, 18n)
					+den : Core.Wide = power_ten(List.length(&2, U32, short), Core.Wide{0, 1})
					part : Core.Wide <- unsigned(short, Core.Wide{2147483647, 4294967295})
					fm : Fixed.Fixed <- Fixed.from_int(part)
					dm : Fixed.Fixed <- Fixed.from_int(den)
					value : Fixed.Fixed <- Fixed.div(fm, dm)
					Fixed.add(whole, value)
			))
	))

def decimal_split(parts: Split, strict: Bool) -> Result<&2, &2, U32, Fixed.Fixed>:
	match parts:
		case Split{integers, fraction, found}:
			decimal_parts(integers, fraction, strict)

def decimal_signed(parts: Signed, +strict: Bool) -> Result<&2, &2, U32, Fixed.Fixed>:
	match parts:
		case Signed{+negative, raw}:
			do Result<&2, &2, U32, Fixed.Fixed>:
				+value : Fixed.Fixed <- decimal_split(split(raw, 46, 46), strict)
				return Fixed.branch(Fixed.Fixed, negative, u => Fixed.neg(value), u => value)

def decimal(bytes: List<&2, U32>, strict: Bool) -> Result<&2, &2, U32, Fixed.Fixed>:
	decimal_signed(sign(trim(bytes)), strict)

def parse(bytes: List<&2, U32>) -> Result<&2, &2, U32, Fixed.Fixed>:
	decimal(bytes, False{})

def exponent_power(fuel: Nat, +remaining: U32, +factor: Fixed.Fixed, +multiplier: Fixed.Fixed) -> Result<&2, &2, U32, Fixed.Fixed>:
	match fuel:
		case 0n:
			Done{multiplier}
		case 1n+p:
			Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_eq(remaining, 0), u => Done{multiplier}, u => (
				do Result<&2, &2, U32, Fixed.Fixed>:
					+next : Fixed.Fixed <- Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_eq(U32.and(remaining, 1), 0),
						u => Done{multiplier}, u => Fixed.mul(multiplier, factor))
					+half : U32 = U32.shrn(remaining, 1n)
					Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_eq(half, 0), u => Done{next}, u => (
						do Result<&2, &2, U32, Fixed.Fixed>:
							square : Fixed.Fixed <- Fixed.mul(factor, factor)
							exponent_power(p, half, square, next)
					))
			))

def exponent_low(value: Core.Wide) -> U32:
	match value:
		case Core.Wide{hi, lo}:
			lo

def scientific_digits(bytes: List<&2, U32>) -> Bool:
	match bytes:
		case Nil{}:
			True{}
		case Con{+head, tail}:
			(digit(head) || U32.is_eq(head, 46)) && scientific_digits(tail)

def scientific(+mantissa: List<&2, U32>, raw: List<&2, U32>) -> Result<&2, &2, U32, Fixed.Fixed>:
	allowed : Bool = scientific_digits(mantissa)
	Count.guard(Fixed.Fixed, allowed && Bool.not(Count.empty(mantissa)), u => (
		do Result<&2, &2, U32, Fixed.Fixed>:
			+value : Fixed.Fixed <- decimal(mantissa, True{})
			+exponent : Core.Wide <- signed(raw, Core.Wide{0, 1000000})
			+multiplier : Fixed.Fixed <- exponent_power(20n, exponent_low(Fixed.magnitude(exponent)), Fixed.small(10), Fixed.one())
			Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, Fixed.negative(exponent),
				u => Fixed.div(value, multiplier), u => Fixed.mul(value, multiplier))
	))

def probability_split(parts: Split) -> Result<&2, &2, U32, Fixed.Fixed>:
	match parts:
		case Split{+before, +after, found}:
			Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, found,
				u => scientific(before, after), u => decimal(before, True{}))

def probability_value(+bytes: List<&2, U32>) -> Result<&2, &2, U32, Fixed.Fixed>:
	match bytes:
		case Con{50, Con{94, rest}}:
			do Result<&2, &2, U32, Fixed.Fixed>:
				+exponent : Core.Wide <- signed(rest, Core.Wide{0, 1000000})
				Count.guard(Fixed.Fixed, Fixed.negative(exponent) || Core.u64_zero(exponent),
					u => Done{Fixed.Fixed{Core.Wide{1073741824, 0}, exponent_low(exponent)}})
		case other:
			probability_split(split(other, 101, 69))

def probability(bytes: List<&2, U32>) -> Result<&2, &2, U32, Fixed.Fixed>:
	do Result<&2, &2, U32, Fixed.Fixed>:
		+value : Fixed.Fixed <- probability_value(bytes)
		prepared : Geometric.Prepared <- Geometric.prepare(value)
		return value

def count_wide(+value: Core.Wide) -> Count.Count:
	match value:
		case Core.Wide{hi, lo}:
			Count.Count{Count.trim(List.append(&2, U32, Count.owned(Core.word_bytes(lo)), Count.owned(Core.word_bytes(hi))))}

def zero_bytes(fuel: Nat) -> List<&2, U32>:
	match fuel:
		case 0n:
			Nil{}
		case 1n+p:
			Con{0, zero_bytes(p)}

def whole(+value: Fixed.Fixed) -> Result<&2, &2, U32, Whole>:
	match value:
		case Fixed.Fixed{+m, +e}:
			Fixed.branch(Result<&2, &2, U32, Whole>, U32.is_ge(e, 62) && U32.is_lt(e, 2147483648), u => (
				+shift : U32 = (e - 62 : U32)
				Fixed.branch(Result<&2, &2, U32, Whole>, U32.is_le(shift, 1981), u => (
					do Result<&2, &2, U32, Whole>:
						zeros : List<&2, U32> = zero_bytes(U32.to_nat(U32.div((shift + 7 : U32), 8)))
						integer : Count.Count <- Count.append_low_bits(count_wide(m), zeros, shift)
						return Whole{Count.to_decimal(integer), Fixed.zero()}
				), u => Fail{5})
			), u => (
				do Result<&2, &2, U32, Whole>:
					+integer : Core.Wide = Fixed.shr(m, U32.to_nat((62 - e : U32)))
					number : Fixed.Fixed <- Fixed.from_int(integer)
					fraction : Fixed.Fixed <- Fixed.sub(value, number)
					return Whole{Count.to_decimal(count_wide(integer)), fraction}
			))

def fraction_digits(fuel: Nat, fraction: Fixed.Fixed) -> Result<&2, &2, U32, String>:
	match fuel:
		case 0n:
			Done{""}
		case 1n+p:
			do Result<&2, &2, U32, String>:
				+scaled : Fixed.Fixed <- Fixed.mul(fraction, Fixed.small(10))
				+integer : Core.Wide = Fixed.to_int_trunc(scaled)
				Count.guard(String, Bool.not(Core.u64_lt(Core.Wide{0, 9}, integer)), u => (
					do Result<&2, &2, U32, String>:
						as_fixed : Fixed.Fixed <- Fixed.from_int(integer)
						next : Fixed.Fixed <- Fixed.sub(scaled, as_fixed)
						rest : String <- fraction_digits(p, next)
						return SCon{Chr{(48 + exponent_low(integer) : U32)}, rest}
				))

def render_parts(parts: Whole, +negative: Bool, +places: Nat) -> Result<&2, &2, U32, String>:
	match parts:
		case Whole{+text, fraction}:
			do Result<&2, &2, U32, String>:
				tail : String <- fraction_digits(places, fraction)
				prefix : String = Fixed.branch(String, negative, u => "-", u => "")
				suffix : String = Fixed.branch(String, Nat.is_eq(places, 0n), u => "", u => "." ++ tail)
				return prefix ++ text ++ suffix

def render(+value: Fixed.Fixed, +places: Nat) -> Result<&2, &2, U32, String>:
	Count.guard(String, Fixed.valid(value) && Nat.is_le(places, 18n), u => (
		Fixed.branch(Result<&2, &2, U32, String>, Fixed.is_zero(value),
			u => Done{Fixed.branch(String, Nat.is_eq(places, 0n), u => "0", u => "0." ++ String.repeat("0", places))}, u => (
				do Result<&2, &2, U32, String>:
					+negative : Bool = Fixed.is_negative(value)
					positive : Fixed.Fixed = Fixed.branch(Fixed.Fixed, negative, u => Fixed.neg(value), u => value)
					parts : Whole <- whole(positive)
					render_parts(parts, negative, places)
			))
	))
