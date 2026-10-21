# Arbitrary-width unsigned values, canonical little-endian byte magnitudes.
# Decimal groups stay below 2^38 (inside native Nat's 48-bit domain).
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed

type Count is Data:
	Count{bytes: List<&2, U32>}

def zero() -> Count:
	Count{Nil{}}

def empty(bytes: List<&2, U32>) -> Bool:
	match bytes:
		case Nil{}:
			True{}
		case Con{head, tail}:
			False{}

def guard(-A: Data, condition: Bool, action: Unit -> Result<&2, &2, U32, A>) -> Result<&2, &2, U32, A>:
	match condition:
		case True{}:
			action(Unit{})
		case False{}:
			Fail{1}

def trim(bytes: List<&2, U32>) -> List<&2, U32>:
	match bytes:
		case Nil{}:
			Nil{}
		case Con{+head, tail}:
			+rest = trim(tail)
			Fixed.branch(List<&2, U32>, U32.is_eq(head, 0) && empty(rest), u => Nil{}, u => Con{head, rest})

def from_bytes(+bytes: List<&2, U32>) -> Result<&2, &2, U32, Count>:
	guard(Count, Core.valid_bytes(bytes), u => Done{Count{trim(bytes)}})

def owned(bytes: List<U32>) -> List<&2, U32>:
	match bytes:
		case Nil{}:
			Nil{}
		case Con{head, tail}:
			Con{head, owned(tail)}

def magnitude(value: Count) -> List<&2, U32>:
	match value:
		case Count{bytes}:
			bytes

def length(value: Count) -> Nat:
	List.length(&2, U32, magnitude(value))

def last(bytes: List<&2, U32>, previous: U32) -> U32:
	match bytes:
		case Nil{}:
			previous
		case Con{head, tail}:
			last(tail, head)

# Internal scale <= 128 and carry < scale, except increment's carry=1.
def mul_add(bytes: List<&2, U32>, +scale: U32, +carry: U32) -> List<&2, U32>:
	match bytes:
		case Nil{}:
			Fixed.branch(List<&2, U32>, U32.is_eq(carry, 0), u => Nil{}, u => [carry])
		case Con{head, tail}:
			+combined = (head * scale + carry : U32)
			Con{U32.and(combined, 255), mul_add(tail, scale, U32.shrn(combined, 8n))}

def increment(value: Count) -> Count:
	Count{mul_add(magnitude(value), 1, 1)}

def double_add(+value: Count, +bit: U32) -> Result<&2, &2, U32, Count>:
	guard(Count, U32.is_le(bit, 1), u => Done{Count{mul_add(magnitude(value), 2, bit)}})

def combine_low(whole: Nat, +scale: U32, low: List<&2, U32>, high: List<&2, U32>) -> List<&2, U32>:
	match whole low:
		case 0n Nil{}:
			mul_add(high, scale, 0)
		case 0n Con{head, tail}:
			mul_add(high, scale, U32.mod(head, scale))
		case 1n+p Con{head, tail}:
			Con{head, combine_low(p, scale, tail, high)}
		case 1n+p Nil{}:
			Nil{}

def append_low_bits(+value: Count, +low: List<&2, U32>, +bits: U32) -> Result<&2, &2, U32, Count>:
	valid = U32.is_le(bits, 1000000) && Core.valid_bytes(low) && Nat.is_eq(List.length(&2, U32, low), U32.to_nat(U32.div((bits + 7 : U32), 8)))
	guard(Count, valid, u => from_bytes(combine_low(U32.to_nat(U32.div(bits, 8)), U32.shln(1, U32.to_nat(U32.mod(bits, 8))), low, magnitude(value))))

def nat_wide(+value: Nat) -> Core.Wide:
	+base = Nat.add(4294967295n, 1n)
	Core.Wide{U32.from_nat(Nat.div(value, base)), U32.from_nat(Nat.mod(value, base))}

def length_extension(fuel: Nat, +remaining: Nat) -> List<&2, U32>:
	match fuel:
		case 0n:
			Nil{}
		case 1n+p:
			+next = Nat.div(remaining, 128n)
			+byte = U32.from_nat(Nat.mod(remaining, 128n))
			Fixed.branch(List<&2, U32>, Nat.is_eq(next, 0n), u => [byte],
				u => Con{(byte + 128 : U32), length_extension(p, next)})

def blip_envelope(+bytes: List<&2, U32>) -> List<&2, U32>:
	+size = List.length(&2, U32, bytes)
	Fixed.branch(List<&2, U32>, Nat.is_lt(size, 32n), u => Con{(128 + U32.from_nat(size) : U32), bytes}, u => (
		header = {Con{(160 + U32.from_nat(Nat.mod(size, 32n)) : U32), length_extension(8n, Nat.div(size, 32n))} : List<&2, U32>}
		List.append(&2, U32, header, bytes)
	))

def blip_bytes(+bytes: List<&2, U32>) -> List<&2, U32>:
	match bytes:
		case Nil{}:
			[0]
		case Con{+head, Nil{}}:
			Fixed.branch(List<&2, U32>, U32.is_lt(head, 128), u => [head], u => [129, head])
		case Con{head, tail}:
			blip_envelope(Con{head, tail})

def to_blip(value: Count) -> List<&2, U32>:
	blip_bytes(magnitude(value))

def blip_length(value: Count) -> Nat:
	+bytes = magnitude(value)
	+size = List.length(&2, U32, bytes)
	Fixed.branch(Nat, Nat.is_eq(size, 0n) || (Nat.is_eq(size, 1n) && U32.is_lt(last(bytes, 0), 128)),
		u => 1n, u => Fixed.branch(Nat, Nat.is_lt(size, 32n), u => Nat.add(size, 1n),
			u => Nat.add(Nat.add(size, 1n), List.length(&2, U32, length_extension(8n, Nat.div(size, 32n))))))

def payload(+size: Core.Wide, +bytes: List<&2, U32>) -> Result<&2, &2, U32, Count>:
	+len = List.length(&2, U32, bytes)
	valid = Bool.not(Core.u64_zero(size)) && Core.u64_zero(Core.u64_sub(size, nat_wide(len))) && U32.is_ne(last(bytes, 0), 0) && (Bool.not(Nat.is_eq(len, 1n)) || U32.is_ge(last(bytes, 0), 128))
	guard(Count, valid, u => Done{Count{bytes}})

def parse_length(fuel: Nat, bytes: List<&2, U32>, +shift: Nat, acc: Core.Wide, +maximum: Core.Wide) -> Result<&2, &2, U32, Count>:
	match fuel bytes:
		case 0n items:
			Fail{1}
		case 1n+p Nil{}:
			Fail{1}
		case 1n+p Con{+head, +tail}:
			+low = U32.and(head, 127)
			+updated = Core.u64_add(acc, Fixed.shl(Core.Wide{0, low}, shift))
			valid = Nat.is_lt(shift, 64n) && (Bool.not(Nat.is_eq(shift, 61n)) || U32.is_lt(low, 8)) && Bool.not(Core.u64_lt(maximum, updated))
			guard(Count, valid, u => Fixed.branch(Result<&2, &2, U32, Count>, U32.is_ne(U32.and(head, 128), 0),
				u => parse_length(p, tail, Nat.add(shift, 7n), updated, maximum),
				u => guard(Count, U32.is_ne(low, 0), u => payload(updated, tail))))

def decode_blip(+bytes: List<&2, U32>) -> Result<&2, &2, U32, Count>:
	match bytes:
		case Nil{}:
			Fail{1}
		case Con{+head, +tail}:
			Fixed.branch(Result<&2, &2, U32, Count>, U32.is_lt(head, 128),
				u => guard(Count, empty(tail), u => from_bytes([head])),
				u => guard(Count, U32.is_lt(head, 192), u => Fixed.branch(Result<&2, &2, U32, Count>, U32.is_ne(U32.and(head, 32), 0),
					u => parse_length(10n, tail, 5n, Core.Wide{0, U32.and(head, 31)}, nat_wide(Nat.add(List.length(&2, U32, tail), 1n))),
					u => payload(Core.Wide{0, U32.and(head, 31)}, tail))))

def from_blip(+bytes: List<&2, U32>) -> Result<&2, &2, U32, Count>:
	guard(Count, Core.valid_bytes(bytes), u => decode_blip(bytes))

def decimal_go(text: String, value: Count) -> Result<&2, &2, U32, Count>:
	match text:
		case SNil{}:
			Done{value}
		case SCon{head, tail}:
			+digit = Char.to_u32(head)
			guard(Count, U32.is_ge(digit, 48) && U32.is_le(digit, 57),
				u => decimal_go(tail, Count{mul_add(magnitude(value), 10, (digit - 48 : U32))}))

def from_decimal(+text: String) -> Result<&2, &2, U32, Count>:
	guard(Count, Bool.not(String.is_empty(text)), u => decimal_go(text, zero()))

def hex_digit(+value: U32) -> Char:
	Chr{(value + Core.choose_word(U32.is_lt(value, 10), 48, 87) : U32)}

def hex_go(bytes: List<&2, U32>, +first: Bool) -> String:
	match bytes:
		case Nil{}:
			""
		case Con{+head, +tail}:
			Fixed.branch(String, first && U32.is_lt(head, 16),
				u => SCon{hex_digit(head), hex_go(tail, False{})},
				u => SCon{hex_digit(U32.shrn(head, 4n)), SCon{hex_digit(U32.and(head, 15)), hex_go(tail, False{})}})

def to_hex(value: Count) -> String:
	+bytes = magnitude(value)
	Fixed.branch(String, empty(bytes), u => "0", u => hex_go(List.reverse(&2, U32, bytes), True{}))

def groups_add(groups: List<&2, Nat>, +carry: Nat) -> List<&2, Nat>:
	match groups:
		case Nil{}:
			Fixed.branch(List<&2, Nat>, Nat.is_eq(carry, 0n), u => Nil{}, u => [carry])
		case Con{group, tail}:
			+combined = Nat.add(Nat.mul(group, 256n), carry)
			Con{Nat.mod(combined, 1000000000n), groups_add(tail, Nat.div(combined, 1000000000n))}

def groups(bytes: List<&2, U32>, current: List<&2, Nat>) -> List<&2, Nat>:
	match bytes:
		case Nil{}:
			current
		case Con{head, tail}:
			groups(tail, groups_add(current, U32.to_nat(head)))

def show_groups(values: List<&2, Nat>, +first: Bool) -> String:
	match values:
		case Nil{}:
			""
		case Con{head, tail}:
			+part = Nat.show(head)
			prefix = Fixed.branch(String, first, u => "", u => String.repeat("0", Nat.sub(9n, String.length(part))))
			prefix ++ part ++ show_groups(tail, False{})

def to_decimal(value: Count) -> String:
	+bytes = magnitude(value)
	Fixed.branch(String, empty(bytes), u => "0", u => show_groups(List.reverse(&2, Nat, groups(List.reverse(&2, U32, bytes), Nil{})), True{}))
