# Exact integer-only software numbers: signed m * 2^(e-62).
# m is a two's-complement pair of U32 limbs; e is an i32 bit pattern.
# No Nat ever stores a mantissa, product, signed value or cursor.
import Base
import ./Core.bend as Core

type Fixed is Data:
	Fixed{m: Core.Wide, e: U32}

type Product is Data:
	Product{upper: Core.Wide, lower: Core.Wide}

def branch(-A: Type, condition: Bool, yes: Unit -> A, no: Unit -> A) -> A:
	match condition:
		case True{}:
			yes(Unit{})
		case False{}:
			no(Unit{})

def zero() -> Fixed:
	Fixed{Core.Wide{0, 0}, 0}

def negative(value: Core.Wide) -> Bool:
	match value:
		case Core.Wide{hi, lo}:
			U32.is_ge(hi, 2147483648)

def opposite(value: Core.Wide) -> Core.Wide:
	Core.u64_sub(Core.Wide{0, 0}, value)

def magnitude(+value: Core.Wide) -> Core.Wide:
	Core.choose_wide(negative(value), opposite(value), value)

def shr(+value: Core.Wide, +amount: Nat) -> Core.Wide:
	match value:
		case Core.Wide{+hi, +lo}:
			branch(Core.Wide, Nat.is_ge(amount, 64n), u => Core.Wide{0, 0},
				u => branch(Core.Wide, Nat.is_ge(amount, 32n),
					u => Core.Wide{0, U32.shrn(hi, Nat.sub(amount, 32n))},
					u => branch(Core.Wide, Nat.is_eq(amount, 0n),
						u => Core.Wide{hi, lo},
						u => Core.Wide{U32.shrn(hi, amount), U32.or(U32.shrn(lo, amount), U32.shln(hi, Nat.sub(32n, amount)))})))

def shl(+value: Core.Wide, +amount: Nat) -> Core.Wide:
	match value:
		case Core.Wide{+hi, +lo}:
			branch(Core.Wide, Nat.is_ge(amount, 64n), u => Core.Wide{0, 0},
				u => branch(Core.Wide, Nat.is_ge(amount, 32n),
					u => Core.Wide{U32.shln(lo, Nat.sub(amount, 32n)), 0},
					u => branch(Core.Wide, Nat.is_eq(amount, 0n),
						u => Core.Wide{hi, lo},
						u => Core.Wide{U32.or(U32.shln(hi, amount), U32.shrn(lo, Nat.sub(32n, amount))), U32.shln(lo, amount)})))

# A 32x32 product uses four exact 16-bit partials. Each summed intermediate
# is <= 2^32-1, so U32 operations do not discard a required carry.
def mul_word_finish(p: U32, +t: U32, +a: U32, +b: U32) -> Core.Wide:
	+u = ((U32.and(a, 65535) * U32.shrn(b, 16n)) + U32.and(t, 65535) : U32)
	Core.Wide{(U32.shrn(a, 16n) * U32.shrn(b, 16n) + U32.shrn(t, 16n) + U32.shrn(u, 16n) : U32), U32.or(U32.shln(u, 16n), U32.and(p, 65535))}

def mul_word(+a: U32, +b: U32) -> Core.Wide:
	+p = (U32.and(a, 65535) * U32.and(b, 65535) : U32)
	mul_word_finish(p, (U32.shrn(a, 16n) * U32.and(b, 65535) + U32.shrn(p, 16n) : U32), a, b)

def product_add(a: Product, b: Product) -> Product:
	match a b:
		case Product{ah, +al} Product{bh, bl}:
			+lower = Core.u64_add(al, bl)
			carry = {Core.Wide{0, Core.bool_word(Core.u64_lt(lower, al))} : Core.Wide}
			Product{Core.u64_add(Core.u64_add(ah, bh), carry), lower}

def partial32(value: Core.Wide) -> Product:
	match value:
		case Core.Wide{hi, lo}:
			Product{Core.Wide{0, hi}, Core.Wide{lo, 0}}

def mul128(a: Core.Wide, b: Core.Wide) -> Product:
	match a b:
		case Core.Wide{+ah, +al} Core.Wide{+bh, +bl}:
			p0 = {Product{Core.Wide{0, 0}, mul_word(al, bl)} : Product}
			p1 = partial32(mul_word(al, bh))
			p2 = partial32(mul_word(ah, bl))
			p3 = {Product{mul_word(ah, bh), Core.Wide{0, 0}} : Product}
			product_add(product_add(p0, p1), product_add(p2, p3))

def exponent(+e: U32) -> Core.Wide:
	Core.Wide{Core.choose_word(U32.is_ge(e, 2147483648), 4294967295, 0), e}

def signed_mantissa(neg: Bool, +m: Core.Wide) -> Core.Wide:
	Core.choose_wide(neg, opposite(m), m)

def finish(valid: Bool, m: Core.Wide, e: U32) -> Result<&2, &2, U32, Fixed>:
	match valid:
		case False{}:
			Fail{5}
		case True{}:
			Done{Fixed{m, e}}

def narrow(m: Core.Wide, e: Core.Wide) -> Result<&2, &2, U32, Fixed>:
	match e:
		case Core.Wide{+hi, +lo}:
			valid = (U32.is_eq(hi, 0) && U32.is_lt(lo, 2147483648)) || (U32.is_eq(hi, 4294967295) && U32.is_ge(lo, 2147483648))
			finish(valid, m, lo)

def normalize_go(fuel: Nat, +neg: Bool, +mag: Core.Wide, +e: Core.Wide) -> Result<&2, &2, U32, Fixed>:
	match fuel:
		case 0n:
			Fail{5}
		case 1n+p:
			+next = p
			branch(Result<&2, &2, U32, Fixed>, Core.u64_lt(mag, Core.Wide{2147483648, 0}),
				u => branch(Result<&2, &2, U32, Fixed>, Core.u64_lt(mag, Core.Wide{1073741824, 0}),
					u => normalize_go(next, neg, Core.u64_shl(mag), Core.u64_sub(e, Core.Wide{0, 1})),
					u => narrow(signed_mantissa(neg, mag), e)),
				u => normalize_go(next, neg, shr(mag, 1n), Core.u64_add(e, Core.Wide{0, 1})))

def normalize(+neg: Bool, +mag: Core.Wide, e: Core.Wide) -> Result<&2, &2, U32, Fixed>:
	branch(Result<&2, &2, U32, Fixed>, Core.u64_zero(mag), u => Done{zero()}, u => normalize_go(64n, neg, mag, e))

def norm(+m: Core.Wide, e: U32) -> Result<&2, &2, U32, Fixed>:
	normalize(negative(m), magnitude(m), exponent(e))

def from_int(m: Core.Wide) -> Result<&2, &2, U32, Fixed>:
	norm(m, 62)

def valid(value: Fixed) -> Bool:
	match value:
		case Fixed{+m, +e}:
			+mag = magnitude(m)
			(Core.u64_zero(mag) && U32.is_eq(e, 0)) || (Bool.not(Core.u64_lt(mag, Core.Wide{1073741824, 0})) && Core.u64_lt(mag, Core.Wide{2147483648, 0}))

def neg(value: Fixed) -> Fixed:
	match value:
		case Fixed{m, e}:
			Fixed{opposite(m), e}

def add_aligned(+xm: Core.Wide, +xe: U32, +ym: Core.Wide, +ye: U32) -> Result<&2, &2, U32, Fixed>:
	+distance = (xe - ye : U32)
	branch(Result<&2, &2, U32, Fixed>, U32.is_ge(distance, 63), u => Done{Fixed{xm, xe}}, u => (
			+shifted = signed_mantissa(negative(ym), shr(magnitude(ym), U32.to_nat(distance)))
			branch(Result<&2, &2, U32, Fixed>, Bool.not(Bool.xor(negative(xm), negative(shifted))),
				u => (
					+sum = Core.u64_add(shr(magnitude(xm), 1n), shr(magnitude(shifted), 1n))
					normalize(negative(xm), sum, Core.u64_add(exponent(xe), Core.Wide{0, 1}))
				), u => (
					+sum = Core.u64_add(xm, shifted)
					normalize(negative(sum), magnitude(sum), exponent(xe))
				))
	))

def add_nonzero(+a: Fixed, +b: Fixed) -> Result<&2, &2, U32, Fixed>:
	match a b:
		case Fixed{+am, +ae} Fixed{+bm, +be}:
			branch(Result<&2, &2, U32, Fixed>, Core.u64_zero(am), u => Done{Fixed{bm, be}},
				u => branch(Result<&2, &2, U32, Fixed>, Core.u64_zero(bm), u => Done{Fixed{am, ae}},
					u => branch(Result<&2, &2, U32, Fixed>, U32.is_lt(U32.xor(ae, 2147483648), U32.xor(be, 2147483648)),
						u => add_aligned(bm, be, am, ae), u => add_aligned(am, ae, bm, be))))

def guard(valid: Bool, action: Unit -> Result<&2, &2, U32, Fixed>) -> Result<&2, &2, U32, Fixed>:
	match valid:
		case False{}:
			Fail{1}
		case True{}:
			action(Unit{})

def add(+a: Fixed, +b: Fixed) -> Result<&2, &2, U32, Fixed>:
	guard(valid(a) && valid(b), u => add_nonzero(a, b))

def sub(+a: Fixed, +b: Fixed) -> Result<&2, &2, U32, Fixed>:
	guard(valid(a) && valid(b), u => add_nonzero(a, neg(b)))

def mul_shift(+negative: Bool, product: Product, +e: Core.Wide) -> Result<&2, &2, U32, Fixed>:
	match product:
		case Product{+upper, +lower}:
			branch(Result<&2, &2, U32, Fixed>, Core.u64_lt(upper, Core.Wide{536870912, 0}), u => (
					m = Core.u64_add(shl(upper, 2n), shr(lower, 62n))
					narrow(signed_mantissa(negative, m), e)
			), u => (
					m = Core.u64_add(shl(upper, 1n), shr(lower, 63n))
					narrow(signed_mantissa(negative, m), Core.u64_add(e, Core.Wide{0, 1}))
			))

def mul_nonzero(a: Fixed, b: Fixed) -> Result<&2, &2, U32, Fixed>:
	match a b:
		case Fixed{+am, ae} Fixed{+bm, be}:
			branch(Result<&2, &2, U32, Fixed>, Core.u64_zero(am) || Core.u64_zero(bm), u => Done{zero()},
				u => mul_shift(Bool.xor(negative(am), negative(bm)), mul128(magnitude(am), magnitude(bm)), Core.u64_add(exponent(ae), exponent(be))))

def mul(+a: Fixed, +b: Fixed) -> Result<&2, &2, U32, Fixed>:
	guard(valid(a) && valid(b), u => mul_nonzero(a, b))

# Exact restoring division is the initial portable reference. Optimization is
# measured separately; the quotient must retain all 62 fractional bits.
def div_bits(fuel: Nat, +remainder: Core.Wide, +denominator: Core.Wide, +bits: Core.Wide) -> Core.Wide:
	match fuel:
		case 0n:
			bits
		case 1n+p:
			+next = p
			+doubled = Core.u64_shl(remainder)
			branch(Core.Wide, Core.u64_lt(doubled, denominator),
				u => div_bits(next, doubled, denominator, Core.u64_shl(bits)),
				u => div_bits(next, Core.u64_sub(doubled, denominator), denominator, Core.u64_add(Core.u64_shl(bits), Core.Wide{0, 1})))

def div_magnitude(+a: Core.Wide, +b: Core.Wide) -> Core.Wide:
	branch(Core.Wide, Core.u64_lt(a, b),
		u => div_bits(62n, a, b, Core.Wide{0, 0}),
		u => div_bits(62n, Core.u64_sub(a, b), b, Core.Wide{0, 1}))

def div_nonzero(a: Fixed, b: Fixed) -> Result<&2, &2, U32, Fixed>:
	match a b:
		case Fixed{+am, ae} Fixed{+bm, be}:
			branch(Result<&2, &2, U32, Fixed>, Core.u64_zero(bm), u => Fail{5},
				u => normalize(Bool.xor(negative(am), negative(bm)), div_magnitude(magnitude(am), magnitude(bm)), Core.u64_sub(exponent(ae), exponent(be))))

def div(+a: Fixed, +b: Fixed) -> Result<&2, &2, U32, Fixed>:
	guard(valid(a) && valid(b), u => div_nonzero(a, b))

def one() -> Fixed:
	Fixed{Core.Wide{1073741824, 0}, 0}

def half() -> Fixed:
	Fixed{Core.Wide{1073741824, 0}, 4294967295}

def ln2() -> Fixed:
	Fixed{Core.Wide{1488522235, 3907501269}, 4294967295}

def pi_over_two() -> Fixed:
	Fixed{Core.Wide{1686629713, 280256794}, 0}

def small(+value: U32) -> Fixed:
	branch(Fixed, U32.is_eq(value, 0), u => zero(), u => (
		+bits = U32.log2(value)
		Fixed{shl(Core.Wide{0, value}, Nat.sub(62n, bits)), U32.from_nat(bits)}
	))

def is_zero(value: Fixed) -> Bool:
	match value:
		case Fixed{m, e}:
			Core.u64_zero(m)

def is_negative(value: Fixed) -> Bool:
	match value:
		case Fixed{m, e}:
			negative(m)

def exponent_in(value: Fixed, +minimum: U32, +maximum: U32) -> Bool:
	match value:
		case Fixed{m, +e}:
			Core.u64_zero(m) || (U32.is_ge(U32.xor(e, 2147483648), U32.xor(minimum, 2147483648)) && U32.is_le(U32.xor(e, 2147483648), U32.xor(maximum, 2147483648)))

def less(a: Fixed, b: Fixed) -> Bool:
	match a b:
		case Fixed{+am, +ae} Fixed{+bm, +be}:
			branch(Bool, Bool.xor(negative(am), negative(bm)), u => negative(am),
				u => branch(Bool, Core.u64_zero(am), u => Bool.not(Core.u64_zero(bm)),
					u => branch(Bool, Core.u64_zero(bm), u => False{},
						u => branch(Bool, U32.is_eq(ae, be), u => Core.u64_lt(Core.signed_bias(am), Core.signed_bias(bm)),
							u => Bool.xor(negative(am), U32.is_lt(U32.xor(ae, 2147483648), U32.xor(be, 2147483648)))))))

def to_int_trunc(value: Fixed) -> Core.Wide:
	match value:
		case Fixed{+m, +e}:
			branch(Core.Wide, Core.u64_zero(m) || U32.is_ge(e, 2147483648), u => Core.Wide{0, 0},
				u => branch(Core.Wide, U32.is_ge(e, 62), u => signed_mantissa(negative(m), Core.Wide{2097152, 0}),
					u => (
						+q = shr(magnitude(m), U32.to_nat((62 - e : U32)))
						clamped = Core.choose_wide(Core.u64_lt(Core.Wide{2097152, 0}, q), Core.Wide{2097152, 0}, q)
						signed_mantissa(negative(m), clamped)
					)))

def frac(+value: Fixed) -> Result<&2, &2, U32, Fixed>:
	do Result<&2, &2, U32, Fixed>:
		integer : Fixed <- from_int(to_int_trunc(value))
		sub(value, integer)

def round_to_int(+value: Fixed) -> Result<&2, &2, U32, Core.Wide>:
	do Result<&2, &2, U32, Core.Wide>:
		adjusted : Fixed <- branch(Result<&2, &2, U32, Fixed>, is_negative(value), u => sub(value, half()), u => add(value, half()))
		return to_int_trunc(adjusted)

def log_series(fuel: Nat, +index: U32, +square: Fixed, term: Fixed, +acc: Fixed) -> Result<&2, &2, U32, Fixed>:
	match fuel:
		case 0n:
			Done{acc}
		case 1n+p:
			do Result<&2, &2, U32, Fixed>:
				+next : Fixed <- mul(term, square)
				reciprocal : Fixed <- div(one(), small(index))
				contribution : Fixed <- mul(next, reciprocal)
				sum : Fixed <- add(acc, contribution)
				log_series(p, (index + 2 : U32), square, next, sum)

def log_finish(value: Fixed, +series: Fixed) -> Result<&2, &2, U32, Fixed>:
	match value:
		case Fixed{m, +e}:
			do Result<&2, &2, U32, Fixed>:
				+logarithm : Fixed <- add(series, series)
				branch(Result<&2, &2, U32, Fixed>, U32.is_eq(e, 0), u => Done{logarithm}, u => (
					do Result<&2, &2, U32, Fixed>:
						power : Fixed <- from_int(exponent(e))
						shifted : Fixed <- mul(ln2(), power)
						add(logarithm, shifted)
				))

def log_fraction(+value: Fixed) -> Fixed:
	match value:
		case Fixed{m, e}:
			Fixed{m, 0}

def ln(+value: Fixed) -> Result<&2, &2, U32, Fixed>:
	guard(valid(value) && Bool.not(is_zero(value)) && Bool.not(is_negative(value)), u => (
		do Result<&2, &2, U32, Fixed>:
			numerator : Fixed <- sub(log_fraction(value), one())
			denominator : Fixed <- add(log_fraction(value), one())
			+t : Fixed <- div(numerator, denominator)
			+square : Fixed <- mul(t, t)
			series : Fixed <- log_series(20n, 3, square, t, t)
			log_finish(value, series)
	))

type Reduced is Data:
	Reduced{candidate: Core.Wide, remainder: Fixed}

def reduce_exp(fuel: Nat, +value: Fixed, +candidate: Core.Wide) -> Result<&2, &2, U32, Reduced>:
	match fuel:
		case 0n:
			Fail{5}
		case 1n+p:
			+next = p
			do Result<&2, &2, U32, Reduced>:
				k : Fixed <- from_int(candidate)
				shifted : Fixed <- mul(ln2(), k)
				+remainder : Fixed <- sub(value, shifted)
				branch(Result<&2, &2, U32, Reduced>, less(Fixed{Core.Wide{1488522235, 3907501269}, 4294967294}, remainder),
					u => reduce_exp(next, value, Core.u64_add(candidate, Core.Wide{0, 1})),
					u => branch(Result<&2, &2, U32, Reduced>, less(remainder, neg(Fixed{Core.Wide{1488522235, 3907501269}, 4294967294})),
						u => reduce_exp(next, value, Core.u64_sub(candidate, Core.Wide{0, 1})),
						u => Done{Reduced{candidate, remainder}}))

def exp_series(fuel: Nat, +index: U32, +value: Fixed, power: Fixed, factorial: Fixed, +acc: Fixed) -> Result<&2, &2, U32, Fixed>:
	match fuel:
		case 0n:
			Done{acc}
		case 1n+p:
			do Result<&2, &2, U32, Fixed>:
				+next_factorial : Fixed <- mul(factorial, small(index))
				reciprocal : Fixed <- div(one(), next_factorial)
				+next_power : Fixed <- mul(power, value)
				+contribution : Fixed <- mul(next_power, reciprocal)
				branch(Result<&2, &2, U32, Fixed>, is_zero(contribution), u => Done{acc}, u => (
					do Result<&2, &2, U32, Fixed>:
						sum : Fixed <- add(acc, contribution)
						exp_series(p, (index + 1 : U32), value, next_power, next_factorial, sum)
				))

def shift_exponent(value: Fixed, distance: Core.Wide) -> Result<&2, &2, U32, Fixed>:
	match value:
		case Fixed{+m, e}:
			normalize(negative(m), magnitude(m), Core.u64_add(exponent(e), distance))

def exp_finish(reduction: Reduced) -> Result<&2, &2, U32, Fixed>:
	match reduction:
		case Reduced{candidate, remainder}:
			do Result<&2, &2, U32, Fixed>:
				result : Fixed <- exp_series(16n, 1, remainder, one(), one(), one())
				# Adjust the exponent in a signed wide accumulator, never a wrapping i32.
				shift_exponent(result, candidate)

def exp(+value: Fixed) -> Result<&2, &2, U32, Fixed>:
	guard(valid(value), u => branch(Result<&2, &2, U32, Fixed>, is_zero(value), u => Done{one()}, u => (
		do Result<&2, &2, U32, Fixed>:
			quotient : Fixed <- div(value, ln2())
			reduction : Reduced <- reduce_exp(4n, value, to_int_trunc(quotient))
			exp_finish(reduction)
	)))

def trig_series(fuel: Nat, +index: U32, +sine: Bool, +square: Fixed, term: Fixed, acc: Fixed) -> Result<&2, &2, U32, Fixed>:
	match fuel:
		case 0n:
			Done{acc}
		case 1n+p:
			+twice = (index * 2 : U32)
			denominator = Core.choose_word(sine, (twice * (twice + 1) : U32), ((twice - 1) * twice : U32))
			do Result<&2, &2, U32, Fixed>:
				reciprocal : Fixed <- div(one(), small(denominator))
				scaled : Fixed <- mul(term, square)
				contribution : Fixed <- mul(scaled, reciprocal)
				+next_term : Fixed = neg(contribution)
				sum : Fixed <- add(acc, next_term)
				trig_series(p, (index + 1 : U32), sine, square, next_term, sum)

def trig(+angle: Fixed, +sine: Bool) -> Result<&2, &2, U32, Fixed>:
	do Result<&2, &2, U32, Fixed>:
		square : Fixed <- mul(angle, angle)
		+initial : Fixed = branch(Fixed, sine, u => angle, u => one())
		trig_series(14n, 1, sine, square, initial, initial)

def cosine_quadrant(+quadrant: Core.Wide, +angle: Fixed) -> Result<&2, &2, U32, Fixed>:
	branch(Result<&2, &2, U32, Fixed>, Core.u64_zero(quadrant) || Core.u64_zero(Core.u64_sub(quadrant, Core.Wide{0, 4})),
		u => trig(angle, False{}), u => (
			do Result<&2, &2, U32, Fixed>:
				+result : Fixed <- trig(angle, Bool.not(Core.u64_zero(Core.u64_sub(quadrant, Core.Wide{0, 2}))))
				return branch(Fixed, Core.u64_zero(Core.u64_sub(quadrant, Core.Wide{0, 3})), u => result, u => neg(result))
		))

def cos_turns(+value: Fixed) -> Result<&2, &2, U32, Fixed>:
	guard(valid(value), u => (
		do Result<&2, &2, U32, Fixed>:
			+fraction : Fixed <- frac(value)
			wrapped : Fixed <- branch(Result<&2, &2, U32, Fixed>, is_negative(fraction), u => add(fraction, one()), u => Done{fraction})
			+qvalue : Fixed <- mul(wrapped, small(4))
			+quadrant : Core.Wide = to_int_trunc(qvalue)
			integer : Fixed <- from_int(quadrant)
			within : Fixed <- sub(qvalue, integer)
			angle : Fixed <- mul(within, pi_over_two())
			cosine_quadrant(quadrant, angle)
	))

# General unsigned quotient for the integer Newton seed. Its denominator is
# positive and <= 2^63, so each shifted remainder fits the two U32 limbs.
def quotient_bits(fuel: Nat, +input: Core.Wide, +denominator: Core.Wide, remainder: Core.Wide, bits: Core.Wide) -> Core.Wide:
	match fuel:
		case 0n:
			bits
		case 1n+p:
			+shifted = Core.u64_add(Core.u64_shl(remainder), Core.Wide{0, Core.u64_top(input)})
			+take = Bool.not(Core.u64_lt(shifted, denominator))
			next_remainder = Core.choose_wide(take, Core.u64_sub(shifted, denominator), shifted)
			next_bits = Core.u64_add(Core.u64_shl(bits), Core.Wide{0, Core.bool_word(take)})
			quotient_bits(p, Core.u64_shl(input), denominator, next_remainder, next_bits)

def integer_sqrt(fuel: Nat, +mag: Core.Wide, +estimate: Core.Wide) -> Core.Wide:
	match fuel:
		case 0n:
			estimate
		case 1n+p:
			quotient = quotient_bits(64n, mag, estimate, Core.Wide{0, 0}, Core.Wide{0, 0})
			+next = shr(Core.u64_add(estimate, quotient), 1n)
			branch(Core.Wide, Core.u64_zero(Core.u64_sub(next, estimate)), u => estimate, u => integer_sqrt(p, mag, next))

def sqrt_refine(fuel: Nat, +value: Fixed, +estimate: Fixed) -> Result<&2, &2, U32, Fixed>:
	match fuel:
		case 0n:
			Done{estimate}
		case 1n+p:
			do Result<&2, &2, U32, Fixed>:
				quotient : Fixed <- div(value, estimate)
				sum : Fixed <- add(estimate, quotient)
				next : Fixed <- shift_exponent(sum, Core.Wide{4294967295, 4294967295})
				sqrt_refine(p, value, next)

def sqrt_initial(+value: Fixed) -> Result<&2, &2, U32, Fixed>:
	match value:
		case Fixed{+m, +e}:
			+odd = U32.is_ne(U32.and(e, 1), 0)
			mag = Core.choose_wide(odd, shr(m, 1n), m)
			+adjusted = Core.u64_add(exponent(e), Core.Wide{0, Core.bool_word(odd)})
			power = signed_mantissa(negative(adjusted), shr(magnitude(adjusted), 1n))
			do Result<&2, &2, U32, Fixed>:
				seed : Fixed <- normalize(False{}, integer_sqrt(40n, mag, Core.Wide{1, 0}), Core.u64_add(power, Core.Wide{0, 31}))
				sqrt_refine(3n, value, seed)

def sqrt(+value: Fixed) -> Result<&2, &2, U32, Fixed>:
	guard(valid(value) && Bool.not(is_negative(value)),
		u => branch(Result<&2, &2, U32, Fixed>, is_zero(value), u => Done{zero()}, u => sqrt_initial(value)))

def pow(+base: Fixed, +power: Fixed) -> Result<&2, &2, U32, Fixed>:
	guard(valid(base) && valid(power), u => (
		do Result<&2, &2, U32, Fixed>:
			logarithm : Fixed <- ln(base)
			product : Fixed <- mul(power, logarithm)
			exp(product)
	))
