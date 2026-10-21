# Canonical chart model: relative integer heights and exact numerical bounds.
# No terminal detection, image encoding, byte output or ambient randomness.
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed
import ./Count.bend as Count
import ./Decimal.bend as Decimal
import ./Geometric.bend as Geometric

type Chart is Data:
	Chart{heights: List<&2, U32>, minimum: Fixed.Fixed, maximum: Fixed.Fixed, discrete: Bool}

type Scores is Data:
	Scores{kind: U32, a: Fixed.Fixed, b: Fixed.Fixed, count: Nat, certain: Bool}

def valid_parameter(+value: Fixed.Fixed, +minimum: U32, +maximum: U32, +positive: Bool) -> Result<&2, &2, U32, Unit>:
	Count.guard(Unit, Fixed.valid(value) && (Bool.not(positive) || (Bool.not(Fixed.is_negative(value)) && Bool.not(Fixed.is_zero(value)))), u =>
		Fixed.branch(Result<&2, &2, U32, Unit>, Fixed.exponent_in(value, minimum, maximum), u => Done{Unit{}}, u => Fail{5}))

def ratio(index: Nat, denominator: Nat) -> Result<&2, &2, U32, Fixed.Fixed>:
	do Result<&2, &2, U32, Fixed.Fixed>:
		a : Fixed.Fixed <- Fixed.from_int(Count.nat_wide(index))
		b : Fixed.Fixed <- Fixed.from_int(Count.nat_wide(denominator))
		Fixed.div(a, b)

def height(+value: Fixed.Fixed) -> Result<&2, &2, U32, U32>:
	Fixed.branch(Result<&2, &2, U32, U32>, Fixed.is_negative(value) || Fixed.is_zero(value), u => Done{0},
		u => Fixed.branch(Result<&2, &2, U32, U32>, Bool.not(Fixed.less(value, Fixed.one())), u => Done{65535}, u => (
			do Result<&2, &2, U32, U32>:
				scaled : Fixed.Fixed <- Fixed.mul(value, Fixed.small(65535))
				return Decimal.exponent_low(Fixed.to_int_trunc(scaled))
		)))

def relative(score: Fixed.Fixed, maximum: Fixed.Fixed) -> Result<&2, &2, U32, Fixed.Fixed>:
	do Result<&2, &2, U32, Fixed.Fixed>:
		+difference : Fixed.Fixed <- Fixed.sub(score, maximum)
		Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, Bool.not(Fixed.is_negative(difference)), u => Done{Fixed.one()},
			u => Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, Fixed.less(difference, Fixed.neg(Fixed.small(64))),
				u => Done{Fixed.zero()}, u => Fixed.exp(difference)))

# For k >= 2^62, the fixed grid is already integral. Do not use the public
# portable-integer conversion, whose 2^53 clamp is intentionally different.
def floor_positive(value: Fixed.Fixed) -> Result<&2, &2, U32, Fixed.Fixed>:
	match value:
		case Fixed.Fixed{+m, +e}:
			Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_ge(e, 2147483648), u => Done{Fixed.zero()},
				u => Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_lt(e, 62),
					u => Fixed.from_int(Fixed.shr(m, U32.to_nat((62 - e : U32)))), u => Done{value}))

def score(plan: Scores, +index: Nat) -> Result<&2, &2, U32, Fixed.Fixed>:
	match plan:
		case Scores{+kind, +a, +b, +count, certain}:
			Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_eq(kind, 0), u => (
				do Result<&2, &2, U32, Fixed.Fixed>:
					part : Fixed.Fixed <- ratio(index, Nat.sub(count, 1n))
					scaled : Fixed.Fixed <- Fixed.mul(Fixed.small(8), part)
					+z : Fixed.Fixed <- Fixed.sub(scaled, Fixed.small(4))
					square : Fixed.Fixed <- Fixed.mul(z, z)
					value : Fixed.Fixed <- Fixed.div(square, Fixed.small(2))
					return Fixed.neg(value)
			), u => Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_eq(kind, 1), u => (
				do Result<&2, &2, U32, Fixed.Fixed>:
					part : Fixed.Fixed <- ratio(index, Nat.sub(count, 1n))
					value : Fixed.Fixed <- Fixed.mul(Fixed.small(6), part)
					return Fixed.neg(value)
			), u => Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_eq(kind, 2), u => (
				do Result<&2, &2, U32, Fixed.Fixed>:
					part : Fixed.Fixed <- ratio(index, Nat.sub(count, 1n))
					x : Fixed.Fixed <- Fixed.mul(b, part)
					log : Fixed.Fixed <- Fixed.ln(x)
					+shifted : Fixed.Fixed <- Fixed.add(log, a)
					square : Fixed.Fixed <- Fixed.mul(shifted, shifted)
					denominator : Fixed.Fixed <- Fixed.mul(Fixed.small(2), a)
					value : Fixed.Fixed <- Fixed.div(square, denominator)
					return Fixed.neg(value)
			), u => Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_eq(kind, 3), u => (
				do Result<&2, &2, U32, Fixed.Fixed>:
					+x : Fixed.Fixed <- ratio(Nat.add(Nat.mul(index, 2n), 1n), Nat.mul(count, 2n))
					log : Fixed.Fixed <- Fixed.ln(x)
					first : Fixed.Fixed <- Fixed.mul(a, log)
					complement : Fixed.Fixed <- Fixed.sub(Fixed.one(), x)
					log_second : Fixed.Fixed <- Fixed.ln(complement)
					second : Fixed.Fixed <- Fixed.mul(b, log_second)
					Fixed.add(first, second)
			), u => (
				do Result<&2, &2, U32, Fixed.Fixed>:
					part : Fixed.Fixed <- ratio(index, Nat.sub(count, 1n))
					x : Fixed.Fixed <- Fixed.mul(b, part)
					k : Fixed.Fixed <- floor_positive(x)
					Fixed.mul(a, k)
			)))))

def point(+plan: Scores, +index: Nat) -> Result<&2, &2, U32, U32>:
	match plan:
		case Scores{kind, a, b, count, +certain}:
			Fixed.branch(Result<&2, &2, U32, U32>, certain,
				u => (
					do Result<&2, &2, U32, U32>:
						part : Fixed.Fixed <- ratio(index, Nat.sub(count, 1n))
						x : Fixed.Fixed <- Fixed.mul(b, part)
						k : Fixed.Fixed <- floor_positive(x)
						return Core.choose_word(Fixed.is_zero(k), 65535, 0)
				), u => (
					do Result<&2, &2, U32, U32>:
						value : Fixed.Fixed <- score(plan, index)
						rel : Fixed.Fixed <- Fixed.exp(value)
						height(rel)
				))

def heights(fuel: Nat, +index: Nat, +plan: Scores) -> Result<&2, &2, U32, List<&2, U32>>:
	match fuel:
		case 0n:
			Done{Nil{}}
		case 1n+p:
			do Result<&2, &2, U32, List<&2, U32>>:
				first : U32 <- point(plan, index)
				rest : List<&2, U32> <- heights(p, Nat.add(index, 1n), plan)
				return Con{first, rest}

def scores(fuel: Nat, +index: Nat, +plan: Scores) -> Result<&2, &2, U32, List<&2, Fixed.Fixed>>:
	match fuel:
		case 0n:
			Done{Nil{}}
		case 1n+p:
			do Result<&2, &2, U32, List<&2, Fixed.Fixed>>:
				first : Fixed.Fixed <- score(plan, index)
				rest : List<&2, Fixed.Fixed> <- scores(p, Nat.add(index, 1n), plan)
				return Con{first, rest}

def maximum_go(values: List<&2, Fixed.Fixed>, +best: Fixed.Fixed) -> Fixed.Fixed:
	match values:
		case Nil{}:
			best
		case Con{+head, tail}:
			maximum_go(tail, Fixed.branch(Fixed.Fixed, Fixed.less(best, head), u => head, u => best))

def maximum(values: List<&2, Fixed.Fixed>) -> Result<&2, &2, U32, Fixed.Fixed>:
	match values:
		case Nil{}:
			Fail{5}
		case Con{head, tail}:
			Done{maximum_go(tail, head)}

def normalized(values: List<&2, Fixed.Fixed>, +largest: Fixed.Fixed) -> Result<&2, &2, U32, List<&2, U32>>:
	match values:
		case Nil{}:
			Done{Nil{}}
		case Con{head, tail}:
			do Result<&2, &2, U32, List<&2, U32>>:
				rel : Fixed.Fixed <- relative(head, largest)
				first : U32 <- height(rel)
				rest : List<&2, U32> <- normalized(tail, largest)
				return Con{first, rest}

def normal(+mean: Fixed.Fixed, stddev: Fixed.Fixed, +count: Nat) -> Result<&2, &2, U32, Chart>:
	do Result<&2, &2, U32, Chart>:
		+spread : Fixed.Fixed <- Fixed.mul(Fixed.small(4), stddev)
		values : List<&2, U32> <- heights(count, 0n, Scores{0, Fixed.zero(), Fixed.zero(), count, False{}})
		minimum : Fixed.Fixed <- Fixed.sub(mean, spread)
		maximum : Fixed.Fixed <- Fixed.add(mean, spread)
		return Chart{values, minimum, maximum, False{}}

def exponential(rate: Fixed.Fixed, +count: Nat) -> Result<&2, &2, U32, Chart>:
	do Result<&2, &2, U32, Chart>:
		values : List<&2, U32> <- heights(count, 0n, Scores{1, Fixed.zero(), Fixed.zero(), count, False{}})
		maximum : Fixed.Fixed <- Fixed.div(Fixed.small(6), rate)
		return Chart{values, Fixed.zero(), maximum, False{}}

def poisson_down(fuel: Nat, +current: Nat, +lambda: Fixed.Fixed, probability: Fixed.Fixed) -> Result<&2, &2, U32, Fixed.Fixed>:
	match fuel:
		case 0n:
			Done{probability}
		case 1n+p:
			do Result<&2, &2, U32, Fixed.Fixed>:
				value : Fixed.Fixed <- Fixed.from_int(Count.nat_wide(current))
				factor : Fixed.Fixed <- Fixed.div(value, lambda)
				next : Fixed.Fixed <- Fixed.mul(probability, factor)
				poisson_down(p, Nat.sub(current, 1n), lambda, next)

def poisson_up(fuel: Nat, +current: Nat, +lambda: Fixed.Fixed, probability: Fixed.Fixed) -> Result<&2, &2, U32, Fixed.Fixed>:
	match fuel:
		case 0n:
			Done{probability}
		case 1n+p:
			do Result<&2, &2, U32, Fixed.Fixed>:
				+next_index : Nat = Nat.add(current, 1n)
				value : Fixed.Fixed <- Fixed.from_int(Count.nat_wide(next_index))
				factor : Fixed.Fixed <- Fixed.div(lambda, value)
				next : Fixed.Fixed <- Fixed.mul(probability, factor)
				poisson_up(p, next_index, lambda, next)

def poisson_heights(fuel: Nat, +index: Nat, +span: Nat, +denominator: Nat, +minimum: Nat, +current: Nat, +lambda: Fixed.Fixed, probability: Fixed.Fixed) -> Result<&2, &2, U32, List<&2, U32>>:
	match fuel:
		case 0n:
			Done{Nil{}}
		case 1n+p:
			do Result<&2, &2, U32, List<&2, U32>>:
				+target : Nat = Nat.add(minimum, Nat.div(Nat.add(Nat.mul(index, span), Nat.div(denominator, 2n)), denominator))
				+next : Fixed.Fixed <- poisson_up(Nat.sub(target, current), current, lambda, probability)
				first : U32 <- height(next)
				rest : List<&2, U32> <- poisson_heights(p, Nat.add(index, 1n), span, denominator, minimum, target, lambda, next)
				return Con{first, rest}

def poisson(+lambda: Fixed.Fixed, +capacity: Nat) -> Result<&2, &2, U32, Chart>:
	do Result<&2, &2, U32, Chart>:
		root : Fixed.Fixed <- Fixed.sqrt(lambda)
		spread : Fixed.Fixed <- Fixed.mul(Fixed.small(6), root)
		+mode : Nat = U32.to_nat(Decimal.exponent_low(Fixed.to_int_trunc(lambda)))
		+radius : Nat = Nat.add(U32.to_nat(Decimal.exponent_low(Fixed.to_int_trunc(spread))), 1n)
		+minimum : Nat = Nat.sub(mode, radius)
		+maximum : Nat = Nat.add(mode, radius)
		+span : Nat = Nat.sub(maximum, minimum)
		+integer_count : Nat = Nat.add(span, 1n)
		+count : Nat = Fixed.branch(Nat, Nat.is_lt(integer_count, capacity), u => integer_count, u => capacity)
		probability : Fixed.Fixed <- poisson_down(Nat.sub(mode, minimum), mode, lambda, Fixed.one())
		values : List<&2, U32> <- poisson_heights(count, 0n, span, Nat.sub(count, 1n), minimum, minimum, lambda, probability)
		lo : Fixed.Fixed <- Fixed.from_int(Count.nat_wide(minimum))
		hi : Fixed.Fixed <- Fixed.from_int(Count.nat_wide(maximum))
		return Chart{values, lo, hi, Nat.is_le(integer_count, capacity)}

def survival_series(fuel: Nat, +index: U32, +p: Fixed.Fixed, power: Fixed.Fixed, sum: Fixed.Fixed) -> Result<&2, &2, U32, Fixed.Fixed>:
	match fuel:
		case 0n:
			Done{Fixed.neg(sum)}
		case 1n+r:
			do Result<&2, &2, U32, Fixed.Fixed>:
				+next_power : Fixed.Fixed <- Fixed.mul(power, p)
				term : Fixed.Fixed <- Fixed.div(next_power, Fixed.small(index))
				next_sum : Fixed.Fixed <- Fixed.add(sum, term)
				survival_series(r, (index + 1 : U32), p, next_power, next_sum)

def log_survival(+p: Fixed.Fixed, +certain: Bool) -> Result<&2, &2, U32, Fixed.Fixed>:
	Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, certain, u => Done{Fixed.zero()},
		u => Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, Fixed.less(p, Fixed.Fixed{Core.Wide{1073741824, 0}, 4294967292}),
			u => survival_series(7n, 2, p, p, p), u => (
				do Result<&2, &2, U32, Fixed.Fixed>:
					complement : Fixed.Fixed <- Fixed.sub(Fixed.one(), p)
					Fixed.ln(complement)
			)))

def geometric(+p: Fixed.Fixed, +count: Nat) -> Result<&2, &2, U32, Chart>:
	do Result<&2, &2, U32, Chart>:
		+maximum : Fixed.Fixed <- Fixed.div(Fixed.small(6), p)
		+certain : Bool = Bool.not(Fixed.less(p, Fixed.one()))
		survival : Fixed.Fixed <- log_survival(p, certain)
		values : List<&2, U32> <- heights(count, 0n, Scores{4, survival, maximum, count, certain})
		return Chart{values, Fixed.zero(), maximum, False{}}

def log_normal(mean: Fixed.Fixed, +stddev: Fixed.Fixed, +count: Nat) -> Result<&2, &2, U32, Chart>:
	do Result<&2, &2, U32, Chart>:
		numerator : Fixed.Fixed <- Fixed.mul(stddev, Fixed.small(13))
		+unbounded : Fixed.Fixed <- Fixed.div(numerator, Fixed.small(8))
		+span : Fixed.Fixed = Fixed.branch(Fixed.Fixed, Fixed.less(unbounded, Fixed.small(20)), u => unbounded, u => Fixed.small(20))
		scaled : Fixed.Fixed <- Fixed.exp(span)
		sigma_squared : Fixed.Fixed <- Fixed.mul(stddev, stddev)
		+values : List<&2, Fixed.Fixed> <- scores(Nat.sub(count, 1n), 1n, Scores{2, sigma_squared, scaled, count, False{}})
		largest : Fixed.Fixed <- maximum(values)
		rel : List<&2, U32> <- normalized(values, largest)
		hi_log : Fixed.Fixed <- Fixed.add(mean, span)
		hi : Fixed.Fixed <- Fixed.exp(hi_log)
		return Chart{Con{0, rel}, Fixed.zero(), hi, False{}}

def beta(alpha: Fixed.Fixed, beta_shape: Fixed.Fixed, +count: Nat) -> Result<&2, &2, U32, Chart>:
	do Result<&2, &2, U32, Chart>:
		a : Fixed.Fixed <- Fixed.sub(alpha, Fixed.one())
		b : Fixed.Fixed <- Fixed.sub(beta_shape, Fixed.one())
		+values : List<&2, Fixed.Fixed> <- scores(count, 0n, Scores{3, a, b, count, False{}})
		largest : Fixed.Fixed <- maximum(values)
		rel : List<&2, U32> <- normalized(values, largest)
		return Chart{rel, Fixed.zero(), Fixed.one(), False{}}

def positive(+value: Fixed.Fixed) -> Bool:
	Bool.not(Fixed.is_negative(value)) && Bool.not(Fixed.is_zero(value))

def normal_checked(+a: Fixed.Fixed, +b: Fixed.Fixed, +count: Nat) -> Result<&2, &2, U32, Chart>:
	Count.guard(Chart, positive(b), u => (
		do Result<&2, &2, U32, Chart>:
			va : Unit <- valid_parameter(a, 4293967296, 1000000, False{})
			vb : Unit <- valid_parameter(b, 4293967296, 1000000, True{})
			normal(a, b, count)
	))

def log_normal_checked(+a: Fixed.Fixed, +b: Fixed.Fixed, +count: Nat) -> Result<&2, &2, U32, Chart>:
	Count.guard(Chart, positive(b), u => (
		do Result<&2, &2, U32, Chart>:
			va : Unit <- valid_parameter(a, 4293967296, 27, False{})
			vb : Unit <- valid_parameter(b, 4293967296, 23, True{})
			log_normal(a, b, count)
	))

def beta_checked(+a: Fixed.Fixed, +b: Fixed.Fixed, +count: Nat) -> Result<&2, &2, U32, Chart>:
	Count.guard(Chart, positive(a) && positive(b), u => (
		do Result<&2, &2, U32, Chart>:
			va : Unit <- valid_parameter(a, 4294967276, 20, True{})
			vb : Unit <- valid_parameter(b, 4294967276, 20, True{})
			beta(a, b, count)
	))

def sample(+kind: U32, +a: Fixed.Fixed, +b: Fixed.Fixed, +count: Nat) -> Result<&2, &2, U32, Chart>:
	Count.guard(Chart, Fixed.valid(a) && Fixed.valid(b) && Nat.is_ge(count, 2n) && Nat.is_le(count, 4096n), u =>
		Fixed.branch(Result<&2, &2, U32, Chart>, U32.is_eq(kind, 1), u => normal_checked(a, b, count),
		u => Fixed.branch(Result<&2, &2, U32, Chart>, U32.is_eq(kind, 4), u => log_normal_checked(a, b, count),
		u => Fixed.branch(Result<&2, &2, U32, Chart>, U32.is_eq(kind, 5), u => beta_checked(a, b, count),
		u => Count.guard(Chart, Fixed.is_zero(b), u =>
			Fixed.branch(Result<&2, &2, U32, Chart>, U32.is_eq(kind, 2), u => (
				do Result<&2, &2, U32, Chart>:
					va : Unit <- valid_parameter(a, 4293967296, 1000000, True{})
					exponential(a, count)
			), u => Fixed.branch(Result<&2, &2, U32, Chart>, U32.is_eq(kind, 3), u => (
				do Result<&2, &2, U32, Chart>:
					va : Unit <- valid_parameter(a, 4293967296, 19, True{})
					poisson(a, count)
			), u => Fixed.branch(Result<&2, &2, U32, Chart>, U32.is_eq(kind, 6), u => (
				do Result<&2, &2, U32, Chart>:
					prepared : Geometric.Prepared <- Geometric.prepare(a)
					geometric(a, count)
			), u => Fail{1}))))))))
