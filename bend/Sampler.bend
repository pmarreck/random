# Pure reusable distribution programs; no I/O and no foreign numerical logic.
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed
import ./Draw.bend as Draw
import ./Ziggurat.bend as Ziggurat

def arithmetic(result: Result<&2, &2, U32, Fixed.Fixed>) -> Draw.Program(Fixed.Fixed):
	Draw.checked(&2, Fixed.Fixed, result)

def parameter(+value: Fixed.Fixed, minimum: U32, maximum: U32, positive: Bool) -> U32:
	invalid = Bool.not(Fixed.valid(value)) || (positive && (Fixed.is_negative(value) || Fixed.is_zero(value)))
	Core.choose_word(invalid, 1, Core.choose_word(Fixed.exponent_in(value, minimum, maximum), 0, 5))

def guard(-A: Type, +code: U32, action: Unit -> Draw.Program(A)) -> Draw.Program(A):
	Fixed.branch(Draw.Program(A), U32.is_eq(code, 0), action, u => Draw.reject(A, code))

def nonzero(+value: Fixed.Fixed) -> Fixed.Fixed:
	Fixed.branch(Fixed.Fixed, Fixed.is_zero(value), u => Fixed.Fixed{Core.Wide{1073741824, 0}, 4294967264}, u => value)

def uniform() -> Draw.Program(Fixed.Fixed):
	do Draw.Program<Fixed.Fixed>:
		bytes : List<U32> <- Draw.read(4)
		arithmetic(Fixed.norm(Core.be_word(bytes, Core.Wide{0, 0}), 30))

def normal(+mean: Fixed.Fixed, +stddev: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	guard(Fixed.Fixed, parameter(mean, 4293967296, 1000000, False{}), u =>
		guard(Fixed.Fixed, parameter(stddev, 4293967296, 1000000, True{}), u => (
			do Draw.Program<Fixed.Fixed>:
				standard : Fixed.Fixed <- Ziggurat.normal()
				scaled : Fixed.Fixed <- arithmetic(Fixed.mul(standard, stddev))
				arithmetic(Fixed.add(mean, scaled))
		)))

def exponential(+rate: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	guard(Fixed.Fixed, parameter(rate, 4293967296, 1000000, True{}), u => (
		do Draw.Program<Fixed.Fixed>:
			u : Fixed.Fixed <- uniform()
			logarithm : Fixed.Fixed <- arithmetic(Fixed.ln(nonzero(u)))
			arithmetic(Fixed.div(Fixed.neg(logarithm), rate))
	))

def poisson_step(+lambda: Fixed.Fixed, +count: Core.Wide, sum: Fixed.Fixed, retry: Core.Wide -> Fixed.Fixed -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	do Draw.Program<Fixed.Fixed>:
		u : Fixed.Fixed <- uniform()
		logarithm : Fixed.Fixed <- arithmetic(Fixed.ln(nonzero(u)))
		+next : Fixed.Fixed <- arithmetic(Fixed.add(sum, Fixed.neg(logarithm)))
		Fixed.branch(Draw.Program(Fixed.Fixed), Fixed.less(lambda, next),
			u => arithmetic(Fixed.from_int(count)),
			u => retry(Core.u64_add(count, Core.Wide{0, 1}), next))

def poisson_loop(high: Nat, low: Nat, +lambda: Fixed.Fixed, count: Core.Wide, sum: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	match high low:
		case 0n 0n:
			Draw.reject(Fixed.Fixed, 5)
		case 0n 1n+p:
			poisson_step(lambda, count, sum, next_count => next_sum => poisson_loop(0n, p, lambda, next_count, next_sum))
		case 1n+h 0n:
			poisson_loop(h, 4294967295n, lambda, count, sum)
		case 1n+h 1n+p:
			poisson_step(lambda, count, sum, next_count => next_sum => poisson_loop(1n+h, p, lambda, next_count, next_sum))

def poisson(+lambda: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	guard(Fixed.Fixed, parameter(lambda, 4293967296, 19, True{}),
		u => poisson_loop(2097152n, 4294967295n, lambda, Core.Wide{0, 0}, Fixed.zero()))

def log_normal(+mean: Fixed.Fixed, +stddev: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	guard(Fixed.Fixed, parameter(mean, 4293967296, 27, False{}), u =>
		guard(Fixed.Fixed, parameter(stddev, 4293967296, 23, True{}), u => (
			do Draw.Program<Fixed.Fixed>:
				value : Fixed.Fixed <- normal(mean, stddev)
				arithmetic(Fixed.exp(value))
		)))

type GammaParameters is Data:
	GammaParameters{d: Fixed.Fixed, c: Fixed.Fixed}

def gamma_parameters(alpha: Fixed.Fixed) -> Result<&2, &2, U32, GammaParameters>:
	do Result<&2, &2, U32, GammaParameters>:
		third : Fixed.Fixed <- Fixed.div(Fixed.one(), Fixed.small(3))
		+d : Fixed.Fixed <- Fixed.sub(alpha, third)
		nine_d : Fixed.Fixed <- Fixed.mul(Fixed.small(9), d)
		root : Fixed.Fixed <- Fixed.sqrt(nine_d)
		c : Fixed.Fixed <- Fixed.div(Fixed.one(), root)
		return GammaParameters{d, c}

def gamma_log(positive: Bool, +u: Fixed.Fixed, +d: Fixed.Fixed, x2: Fixed.Fixed, +v3: Fixed.Fixed, retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	match positive:
		case False{}:
			retry(Unit{})
		case True{}:
			do Draw.Program<Fixed.Fixed>:
				log_u : Fixed.Fixed <- arithmetic(Fixed.ln(u))
				log_v : Fixed.Fixed <- arithmetic(Fixed.ln(v3))
				half_x2 : Fixed.Fixed <- arithmetic(Fixed.mul(Fixed.half(), x2))
				one_minus_v : Fixed.Fixed <- arithmetic(Fixed.sub(Fixed.one(), v3))
				correction : Fixed.Fixed <- arithmetic(Fixed.add(one_minus_v, log_v))
				term : Fixed.Fixed <- arithmetic(Fixed.mul(d, correction))
				right : Fixed.Fixed <- arithmetic(Fixed.add(half_x2, term))
				Fixed.branch(Draw.Program(Fixed.Fixed), Fixed.less(log_u, right),
					u => arithmetic(Fixed.mul(d, v3)), retry)

def gamma_decide(quick: Bool, +d: Fixed.Fixed, x2: Fixed.Fixed, +v3: Fixed.Fixed, +u: Fixed.Fixed, retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	match quick:
		case True{}:
			arithmetic(Fixed.mul(d, v3))
		case False{}:
			gamma_log(Bool.not(Fixed.is_zero(u)), u, d, x2, v3, retry)

def gamma_test(+d: Fixed.Fixed, +x: Fixed.Fixed, +v: Fixed.Fixed, retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	do Draw.Program<Fixed.Fixed>:
		v2 : Fixed.Fixed <- arithmetic(Fixed.mul(v, v))
		+v3 : Fixed.Fixed <- arithmetic(Fixed.mul(v2, v))
		+u : Fixed.Fixed <- uniform()
		+x2 : Fixed.Fixed <- arithmetic(Fixed.mul(x, x))
		x4 : Fixed.Fixed <- arithmetic(Fixed.mul(x2, x2))
		coefficient : Fixed.Fixed = Fixed.Fixed{Core.Wide{1137307339, 4212503923}, 4294967291}
		correction : Fixed.Fixed <- arithmetic(Fixed.mul(coefficient, x4))
		limit : Fixed.Fixed <- arithmetic(Fixed.sub(Fixed.one(), correction))
		gamma_decide(Fixed.less(u, limit), d, x2, v3, u, retry)

def gamma_positive(positive: Bool, d: Fixed.Fixed, x: Fixed.Fixed, v: Fixed.Fixed, retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	match positive:
		case True{}:
			gamma_test(d, x, v, retry)
		case False{}:
			retry(Unit{})

def gamma_step(params: GammaParameters, retry: Unit -> Draw.Program(Fixed.Fixed)) -> Draw.Program(Fixed.Fixed):
	match params:
		case GammaParameters{d, c}:
			do Draw.Program<Fixed.Fixed>:
				+x : Fixed.Fixed <- Ziggurat.normal()
				scaled : Fixed.Fixed <- arithmetic(Fixed.mul(c, x))
				+v : Fixed.Fixed <- arithmetic(Fixed.add(Fixed.one(), scaled))
				gamma_positive(Fixed.less(Fixed.zero(), v), d, x, v, retry)

def gamma_loop(high: Nat, low: Nat, +params: GammaParameters) -> Draw.Program(Fixed.Fixed):
	match high low:
		case 0n 0n:
			Draw.reject(Fixed.Fixed, 5)
		case 0n 1n+p:
			gamma_step(params, u => gamma_loop(0n, p, params))
		case 1n+h 0n:
			gamma_loop(h, 4294967295n, params)
		case 1n+h 1n+p:
			gamma_step(params, u => gamma_loop(1n+h, p, params))

def gamma_large(alpha: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	do Draw.Program<Fixed.Fixed>:
		params : GammaParameters <- Draw.checked(&2, GammaParameters, gamma_parameters(alpha))
		gamma_loop(2097152n, 4294967295n, params)

def gamma(+alpha: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	guard(Fixed.Fixed, parameter(alpha, 4294967276, 20, True{}),
		u => Fixed.branch(Draw.Program(Fixed.Fixed), Fixed.less(alpha, Fixed.one()), u => (
			do Draw.Program<Fixed.Fixed>:
				u : Fixed.Fixed <- uniform()
				larger : Fixed.Fixed <- arithmetic(Fixed.add(Fixed.one(), alpha))
				g : Fixed.Fixed <- gamma_large(larger)
				inverse : Fixed.Fixed <- arithmetic(Fixed.div(Fixed.one(), alpha))
				p : Fixed.Fixed <- arithmetic(Fixed.pow(nonzero(u), inverse))
				arithmetic(Fixed.mul(g, p))
		), u => gamma_large(alpha)))

def beta(+alpha: Fixed.Fixed, +shape: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	guard(Fixed.Fixed, parameter(alpha, 4294967276, 20, True{}), u =>
		guard(Fixed.Fixed, parameter(shape, 4294967276, 20, True{}), u => (
			do Draw.Program<Fixed.Fixed>:
				+x : Fixed.Fixed <- gamma(alpha)
				y : Fixed.Fixed <- gamma(shape)
				sum : Fixed.Fixed <- arithmetic(Fixed.add(x, y))
				arithmetic(Fixed.div(x, sum))
		)))

def ordered(+first: Core.Wide, +last: Core.Wide) -> Bool:
	Core.int_valid(first) && Core.int_valid(last) && Bool.not(Core.u64_lt(Core.signed_bias(last), Core.signed_bias(first)))

def in_range(+value: Core.Wide, first: Core.Wide, last: Core.Wide) -> Bool:
	Bool.not(Core.u64_lt(Core.signed_bias(value), Core.signed_bias(first))) && Bool.not(Core.u64_lt(Core.signed_bias(last), Core.signed_bias(value)))

def range_candidate(input: Core.Wide, params: Core.Prepared, retry: Unit -> Draw.Program(Core.Wide)) -> Draw.Program(Core.Wide):
	match params:
		case Core.Prepared{start, +span, +limit, count}:
			+value = input
			Fixed.branch(Draw.Program(Core.Wide), Core.u64_zero(limit) || Core.u64_lt(value, limit),
				u => Draw.pure(Core.Wide, Core.u64_add(start, Core.sample_mod(Core.span_small(span), value, span))), retry)

def range_step(+params: Core.Prepared, retry: Unit -> Draw.Program(Core.Wide)) -> Draw.Program(Core.Wide):
	do Draw.Program<Core.Wide>:
		bytes : List<U32> <- Draw.read(Core.range_bytes(params))
		range_candidate(Core.be_word(bytes, Core.Wide{0, 0}), params, retry)

def range_loop(high: Nat, low: Nat, +params: Core.Prepared) -> Draw.Program(Core.Wide):
	match high low:
		case 0n 0n:
			Draw.reject(Core.Wide, 5)
		case 0n 1n+p:
			range_step(params, u => range_loop(0n, p, params))
		case 1n+h 0n:
			range_loop(h, 4294967295n, params)
		case 1n+h 1n+p:
			range_step(params, u => range_loop(1n+h, p, params))

def range_prepare(first: Core.Wide, +span: Core.Wide) -> Core.Prepared:
	+small = Core.span_small(span)
	+remainder = Core.sample_mod(small, Core.u64_sub(Core.Wide{0, 0}, span), span)
	limit = Core.choose_wide(small, Core.u64_sub(Core.Wide{1, 0}, remainder), Core.u64_sub(Core.Wide{0, 0}, remainder))
	Core.Prepared{first, span, limit, Core.choose_word(small, 4, 8)}

def range(+first: Core.Wide, +last: Core.Wide) -> Draw.Program(Core.Wide):
	guard(Core.Wide, Core.choose_word(ordered(first, last) && Core.width_valid(Core.u64_sub(last, first)), 0, 1),
		u => Fixed.branch(Draw.Program(Core.Wide), Core.u64_zero(Core.u64_sub(last, first)),
			u => Draw.pure(Core.Wide, first),
			u => range_loop(2097152n, 4294967295n, range_prepare(first, Core.u64_add(Core.u64_sub(last, first), Core.Wide{0, 1})))))

type NormalRange is Data:
	NormalRange{first: Core.Wide, last: Core.Wide, start: Fixed.Fixed, sixth: Fixed.Fixed, half: Fixed.Fixed}

def normal_range_parameters(+first: Core.Wide, +last: Core.Wide) -> Result<&2, &2, U32, NormalRange>:
	do Result<&2, &2, U32, NormalRange>:
		+start : Fixed.Fixed <- Fixed.from_int(first)
		end : Fixed.Fixed <- Fixed.from_int(last)
		+width : Fixed.Fixed <- Fixed.sub(end, start)
		sixth : Fixed.Fixed <- Fixed.div(width, Fixed.small(6))
		half : Fixed.Fixed <- Fixed.div(width, Fixed.small(2))
		return NormalRange{first, last, start, sixth, half}

def round_allowed(value: Fixed.Fixed) -> Bool:
	match value:
		case Fixed.Fixed{+m, +e}:
			Fixed.exponent_in(Fixed.Fixed{m, e}, 2147483648, 53) && (U32.is_ne(e, 53) || Core.u64_lt(Fixed.magnitude(m), Core.Wide{1073741824, 256}))

def normal_int_round(allowed: Bool, value: Fixed.Fixed, +first: Core.Wide, +last: Core.Wide, retry: Unit -> Draw.Program(Core.Wide)) -> Draw.Program(Core.Wide):
	match allowed:
		case False{}:
			retry(Unit{})
		case True{}:
			do Draw.Program<Core.Wide>:
				+rounded : Core.Wide <- Draw.checked(&2, Core.Wide, Fixed.round_to_int(value))
				Fixed.branch(Draw.Program(Core.Wide), in_range(rounded, first, last), u => Draw.pure(Core.Wide, rounded), retry)

def normal_int_step(params: NormalRange, retry: Unit -> Draw.Program(Core.Wide)) -> Draw.Program(Core.Wide):
	match params:
		case NormalRange{first, last, start, sixth, half}:
			do Draw.Program<Core.Wide>:
				standard : Fixed.Fixed <- Ziggurat.normal()
				scaled : Fixed.Fixed <- arithmetic(Fixed.mul(standard, sixth))
				middle : Fixed.Fixed <- arithmetic(Fixed.add(scaled, half))
				+value : Fixed.Fixed <- arithmetic(Fixed.add(middle, start))
				normal_int_round(round_allowed(value), value, first, last, retry)

def normal_int_loop(high: Nat, low: Nat, +params: NormalRange) -> Draw.Program(Core.Wide):
	match high low:
		case 0n 0n:
			Draw.reject(Core.Wide, 5)
		case 0n 1n+p:
			normal_int_step(params, u => normal_int_loop(0n, p, params))
		case 1n+h 0n:
			normal_int_loop(h, 4294967295n, params)
		case 1n+h 1n+p:
			normal_int_step(params, u => normal_int_loop(1n+h, p, params))

def normal_int(+first: Core.Wide, +last: Core.Wide) -> Draw.Program(Core.Wide):
	guard(Core.Wide, Core.choose_word(ordered(first, last), 0, 1), u => (
		do Draw.Program<Core.Wide>:
			params : NormalRange <- Draw.checked(&2, NormalRange, normal_range_parameters(first, last))
			normal_int_loop(2097152n, 4294967295n, params)
	))
