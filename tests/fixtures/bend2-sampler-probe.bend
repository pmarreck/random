# Bounded native test transport, not the user CLI or its acceptance substitute.
import Base
import ../../bend/Core.bend as Core
import ../../bend/Fixed.bend as Fixed
import ../../bend/Draw.bend as Draw
import ../../bend/Sampler.bend as Sampler
import ../../bend/ProbeModel.bend as Seed

def integer_program(+op: U32, a: Fixed.Fixed, b: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	match a b:
		case Fixed.Fixed{+first, ae} Fixed.Fixed{+last, be}:
			do Draw.Program<Fixed.Fixed>:
				value : Core.Wide <- Fixed.branch(Draw.Program(Core.Wide), U32.is_eq(op, 6),
					u => Sampler.range(first, last), u => Sampler.normal_int(first, last))
				Sampler.arithmetic(Fixed.from_int(value))

def program(+op: U32, +a: Fixed.Fixed, +b: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 0), u => Sampler.uniform(),
		u => Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 1), u => Sampler.normal(a, b),
			u => Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 2), u => Sampler.exponential(a),
				u => Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 3), u => Sampler.poisson(a),
					u => Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 4), u => Sampler.log_normal(a, b),
						u => Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 5), u => Sampler.beta(a, b),
							u => integer_program(op, a, b)))))))

def position(state: Core.Stream) -> String:
	match state:
		case Core.Stream{key, hi, lo}:
			U32.show(hi) ++ ":" ++ U32.show(lo)

def after(result: Result<&2, &1, Core.Failure, Draw.Outcome<Fixed.Fixed>>, next: Core.Stream -> String) -> String:
	match result:
		case Done{Draw.Outcome{+state, Fixed.Fixed{Core.Wide{hi, lo}, e}}}:
			U32.show(hi) ++ ":" ++ U32.show(lo) ++ ":" ++ U32.show(e) ++ ":" ++ position(state) ++ "\n" ++ next(state)
		case Fail{Core.Failure{code, state}}:
			"error:" ++ U32.show(code) ++ ":" ++ position(state) ++ "\n"

def series(count: Nat, state: Core.Stream, +op: U32, +a: Fixed.Fixed, +b: Fixed.Fixed) -> String:
	match count:
		case 0n:
			""
		case 1n+p:
			after(Draw.run(Fixed.Fixed, state, program(op, a, b)), next => series(p, next, op, a, b))

def at(state: Core.Stream, hi: U32, lo: U32) -> Core.Stream:
	match state:
		case Core.Stream{key, old_hi, old_lo}:
			Core.Stream{key, hi, lo}

def seeded(result: Result<&2, &2, U32, Core.Stream>, op: U32, count: Nat, a: Fixed.Fixed, b: Fixed.Fixed, hi: U32, lo: U32) -> String:
	match result:
		case Done{state}:
			series(count, at(state, hi, lo), op, a, b)
		case Fail{error}:
			"seed-error\n"

def seed_material(+tag: U32) -> List<&2, U32>:
	Fixed.branch(List<&2, U32>, U32.is_eq(tag, 2), u => [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
		u => Seed.seed_material(Core.choose_word(U32.is_eq(tag, 1), 42, 0)))

def parsed(values: List<&2, U32>) -> String:
	match values:
		case Con{tag, Con{op, Con{count, Con{ah, Con{al, Con{ae, Con{bh, Con{bl, Con{be, Con{hi, Con{lo, Nil{}}}}}}}}}}}}:
			seeded(Core.new_seed(seed_material(tag)), op, U32.to_nat(count), Fixed.Fixed{Core.Wide{ah, al}, ae}, Fixed.Fixed{Core.Wide{bh, bl}, be}, hi, lo)
		case other:
			"parse-error\n"

def parse(values: List<String>) -> Maybe<&2, List<&2, U32>>:
	match values:
		case Nil{}:
			Some{Nil{}}
		case Con{head, tail}:
			do Maybe<&2, List<&2, U32>>:
				value : U32 <- U32.read(head)
				remaining : List<&2, U32> <- parse(tail)
				return Con{value, remaining}

def present(values: Maybe<&2, List<&2, U32>>) -> String:
	match values:
		case Some{items}:
			parsed(items)
		case None{}:
			"parse-error\n"

def run(args: List<String>) -> String:
	match args:
		case Nil{}:
			""
		case Con{tag, Con{op, Con{count, Con{ah, Con{al, Con{ae, Con{bh, Con{bl, Con{be, Con{hi, Con{lo, tail}}}}}}}}}}}:
			present(parse([tag, op, count, ah, al, ae, bh, bl, be, hi, lo])) ++ run(tail)
		case other:
			"argument-error\n"

def start(args: List<String>) -> IO(Unit):
	match args:
		case Con{program_name, tail}:
			IO.write(run(tail))
		case Nil{}:
			IO.die(Unit, 1, "missing executable name")

def main() -> IO(Unit):
	do IO<Unit>:
		args : List<String> <- IO.args()
		start(args)
