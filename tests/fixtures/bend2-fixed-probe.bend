# Batched ASCII-only test transport. All numerical work is in the Bend core.
import Base
import ../../bend/Core.bend as Core
import ../../bend/Fixed.bend as Fixed

def show_wide(value: Core.Wide) -> String:
	match value:
		case Core.Wide{hi, lo}:
			U32.show(hi) ++ ":" ++ U32.show(lo)

def show(result: Result<&2, &2, U32, Fixed.Fixed>) -> String:
	match result:
		case Fail{error}:
			"error:" ++ U32.show(error) ++ "\n"
		case Done{Fixed.Fixed{m, e}}:
			show_wide(m) ++ ":" ++ U32.show(e) ++ "\n"

def binary(+op: U32, +a: Fixed.Fixed, +b: Fixed.Fixed) -> String:
	Fixed.branch(String, U32.is_eq(op, 0), u => show(Fixed.add(a, b)),
		u => Fixed.branch(String, U32.is_eq(op, 1), u => show(Fixed.sub(a, b)),
			u => Fixed.branch(String, U32.is_eq(op, 2), u => show(Fixed.mul(a, b)),
				u => show(Fixed.div(a, b)))))

def show_product(value: Fixed.Product) -> String:
	match value:
		case Fixed.Product{upper, lower}:
			show_wide(upper) ++ ":" ++ show_wide(lower) ++ "\n"

def advanced(+op: U32, +a: Fixed.Fixed, b: Fixed.Fixed) -> String:
	Fixed.branch(String, U32.is_eq(op, 8), u => show(Fixed.ln(a)),
		u => Fixed.branch(String, U32.is_eq(op, 9), u => show(Fixed.exp(a)),
			u => Fixed.branch(String, U32.is_eq(op, 10), u => show(Fixed.cos_turns(a)),
				u => Fixed.branch(String, U32.is_eq(op, 11), u => show(Fixed.sqrt(a)),
					u => show(Fixed.pow(a, b))))))

def special(+op: U32, +a: Core.Wide, +ae: U32, +b: Core.Wide, +be: U32) -> String:
	Fixed.branch(String, U32.is_lt(op, 4), u => binary(op, Fixed.Fixed{a, ae}, Fixed.Fixed{b, be}),
		u => Fixed.branch(String, U32.is_eq(op, 4), u => show(Fixed.norm(a, ae)),
			u => Fixed.branch(String, U32.is_eq(op, 5), u => show_wide(Fixed.shl(a, U32.to_nat(ae))) ++ "\n",
				u => Fixed.branch(String, U32.is_eq(op, 6), u => show_wide(Fixed.shr(a, U32.to_nat(ae))) ++ "\n",
					u => Fixed.branch(String, U32.is_eq(op, 7), u => show_product(Fixed.mul128(a, b)),
						u => advanced(op, Fixed.Fixed{a, ae}, Fixed.Fixed{b, be}))))))

def parse(op: Maybe<&2, U32>, ah: Maybe<&2, U32>, al: Maybe<&2, U32>, ae: Maybe<&2, U32>, bh: Maybe<&2, U32>, bl: Maybe<&2, U32>, be: Maybe<&2, U32>) -> String:
	match op ah al ae bh bl be:
		case Some{o} Some{h} Some{l} Some{e} Some{j} Some{k} Some{f}:
			special(o, Core.Wide{h, l}, e, Core.Wide{j, k}, f)
		case o h l e j k f:
			"parse-error\n"

def run(args: List<String>) -> String:
	match args:
		case Nil{}:
			""
		case Con{op, Con{ah, Con{al, Con{ae, Con{bh, Con{bl, Con{be, tail}}}}}}}:
			parse(U32.read(op), U32.read(ah), U32.read(al), U32.read(ae), U32.read(bh), U32.read(bl), U32.read(be)) ++ run(tail)
		case other:
			"argument-error\n"

def start(args: List<String>) -> IO(Unit):
	match args:
		case Con{program, tail}:
			IO.write(run(tail))
		case Nil{}:
			IO.die(Unit, 1, "missing executable name")

def main() -> IO(Unit):
	do IO<Unit>:
		args : List<String> <- IO.args()
		start(args)
