# Pure weighted-choice and Fisher-Yates index plans. Caller byte spans and
# their transport/arrangement are deliberately absent from this model.
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed
import ./Count.bend as Count
import ./Draw.bend as Draw
import ./Sampler.bend as Sampler

type Prepared is Data:
	Prepared{weights: List<&2, Core.Wide>, total: Core.Wide}

def add_weight(+total: Core.Wide, +weight: Core.Wide) -> Result<&2, &2, U32, Core.Wide>:
	Fixed.branch(Result<&2, &2, U32, Core.Wide>, Fixed.negative(total) || Fixed.negative(weight), u => Fail{1},
		u => Fixed.branch(Result<&2, &2, U32, Core.Wide>, Core.u64_lt(Core.Wide{2097152, 0}, total) ||
			Core.u64_lt(Core.u64_sub(Core.Wide{2097152, 0}, total), weight), u => Fail{2},
			u => Done{Core.u64_add(total, weight)}))

def total_go(weights: List<&2, Core.Wide>, +total: Core.Wide) -> Result<&2, &2, U32, Core.Wide>:
	match weights:
		case Nil{}:
			Fixed.branch(Result<&2, &2, U32, Core.Wide>, Core.u64_zero(total), u => Fail{3}, u => Done{total})
		case Con{head, tail}:
			do Result<&2, &2, U32, Core.Wide>:
				next : Core.Wide <- add_weight(total, head)
				total_go(tail, next)

def prepare(+weights: List<&2, Core.Wide>) -> Result<&2, &2, U32, Prepared>:
	match weights:
		case Nil{}:
			Fail{4}
		case Con{head, tail}:
			do Result<&2, &2, U32, Prepared>:
				total : Core.Wide <- total_go(weights, Core.Wide{0, 0})
				return Prepared{weights, total}

def total(prepared: Prepared) -> Core.Wide:
	match prepared:
		case Prepared{weights, total}:
			total

def choose(weights: List<&2, Core.Wide>, +pick: Core.Wide, +cumulative: Core.Wide, +index: Core.Wide) -> Draw.Program(Core.Wide):
	match weights:
		case Nil{}:
			Draw.reject(Core.Wide, 1)
		case Con{head, tail}:
			+next : Core.Wide = Core.u64_add(cumulative, head)
			Fixed.branch(Draw.Program(Core.Wide), Bool.not(Core.u64_lt(next, pick)), u => Draw.pure(Core.Wide, index),
				u => choose(tail, pick, next, Core.u64_add(index, Core.Wide{0, 1})))

def weighted(prepared: Prepared) -> Draw.Program(Core.Wide):
	match prepared:
		case Prepared{weights, total}:
			do Draw.Program<Core.Wide>:
				pick : Core.Wide <- Sampler.range(Core.Wide{0, 1}, total)
				choose(weights, pick, Core.Wide{0, 0}, Core.Wide{0, 0})

def at(values: List<&2, Core.Wide>, +index: Core.Wide) -> Result<&2, &2, U32, Core.Wide>:
	match values:
		case Nil{}:
			Fail{1}
		case Con{head, tail}:
			Fixed.branch(Result<&2, &2, U32, Core.Wide>, Core.u64_zero(index), u => Done{head},
				u => at(tail, Core.u64_sub(index, Core.Wide{0, 1})))

def replace(values: List<&2, Core.Wide>, +index: Core.Wide, +value: Core.Wide) -> Result<&2, &2, U32, List<&2, Core.Wide>>:
	match values:
		case Nil{}:
			Fail{1}
		case Con{head, +tail}:
			Fixed.branch(Result<&2, &2, U32, List<&2, Core.Wide>>, Core.u64_zero(index), u => Done{Con{value, tail}}, u => (
				do Result<&2, &2, U32, List<&2, Core.Wide>>:
					rest : List<&2, Core.Wide> <- replace(tail, Core.u64_sub(index, Core.Wide{0, 1}), value)
					return Con{head, rest}
			))

def swap(+values: List<&2, Core.Wide>, +first: Core.Wide, +second: Core.Wide) -> Result<&2, &2, U32, List<&2, Core.Wide>>:
	do Result<&2, &2, U32, List<&2, Core.Wide>>:
		a : Core.Wide <- at(values, first)
		b : Core.Wide <- at(values, second)
		updated : List<&2, Core.Wide> <- replace(values, first, b)
		replace(updated, second, a)

def shuffle_step(values: List<&2, Core.Wide>, +remaining: Core.Wide, next: List<&2, Core.Wide> -> Draw.Program(List<&2, Core.Wide>)) -> Draw.Program(List<&2, Core.Wide>):
	do Draw.Program<List<&2, Core.Wide>>:
		pick : Core.Wide <- Sampler.range(Core.Wide{0, 1}, remaining)
		updated : List<&2, Core.Wide> <- Draw.checked(&2, List<&2, Core.Wide>, swap(values,
			Core.u64_sub(remaining, Core.Wide{0, 1}), Core.u64_sub(pick, Core.Wide{0, 1})))
		next(updated)

def shuffle_loop(high: Nat, low: Nat, +values: List<&2, Core.Wide>) -> Draw.Program(List<&2, Core.Wide>):
	match high low:
		case 0n 0n:
			Draw.pure(List<&2, Core.Wide>, values)
		case 0n 1n++p:
			Fixed.branch(Draw.Program(List<&2, Core.Wide>), Nat.is_eq(p, 0n),
				u => Draw.pure(List<&2, Core.Wide>, values),
				u => shuffle_step(values, Core.Wide{0, U32.from_nat(1n+p)}, updated => shuffle_loop(0n, p, updated)))
		case 1n++h 0n:
			shuffle_step(values, Core.Wide{U32.from_nat(1n+h), 0}, updated => shuffle_loop(h, 4294967295n, updated))
		case 1n++h 1n++p:
			shuffle_step(values, Core.Wide{U32.from_nat(1n+h), U32.from_nat(1n+p)}, updated => shuffle_loop(1n+h, p, updated))

def indices(high: Nat, low: Nat, +index: Core.Wide) -> List<&2, Core.Wide>:
	match high low:
		case 0n 0n:
			Nil{}
		case 0n 1n+p:
			Con{index, indices(0n, p, Core.u64_add(index, Core.Wide{0, 1}))}
		case 1n+h 0n:
			Con{index, indices(h, 4294967295n, Core.u64_add(index, Core.Wide{0, 1}))}
		case 1n+h 1n+p:
			Con{index, indices(1n+h, p, Core.u64_add(index, Core.Wide{0, 1}))}

def shuffle_count(count: Core.Wide) -> Draw.Program(List<&2, Core.Wide>):
	match count:
		case Core.Wide{+hi, +lo}:
			shuffle_loop(U32.to_nat(hi), U32.to_nat(lo), indices(U32.to_nat(hi), U32.to_nat(lo), Core.Wide{0, 0}))

def shuffle(+count: Core.Wide) -> Draw.Program(List<&2, Core.Wide>):
	Sampler.guard(List<&2, Core.Wide>, Core.choose_word(Bool.not(Core.u64_lt(Core.Wide{2097152, 0}, count)), 0, 1), u => shuffle_count(count))
