# Pure narrow benchmark adapter model. This is not the production CLI surface.
import Base
import ./Core.bend as Core

def nibble(+value: U32) -> Char:
	Chr{(value + Core.choose_word(U32.is_lt(value, 10), 48, 87) : U32)}

def hex(bytes: List<U32>) -> String:
	match bytes:
		case Nil{}:
			SNil{}
		case Con{+head, tail}:
			SCon{nibble(U32.shrn(head, 4n)), SCon{nibble(U32.and(head, 15)), hex(tail)}}

def seed_material(+seed: U32) -> List<&2, U32>:
	[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, U32.shrn(seed, 24n), U32.and(U32.shrn(seed, 16n), 255), U32.and(U32.shrn(seed, 8n), 255), U32.and(seed, 255)]

def invalid() -> Result<&2, &2, String, String>:
	Fail{"{\"error\":\"usage: bend2-probe SEED_U32 COUNT (0..4096)\"}\n"}

def bounded(valid: Bool, seed: U32, count: U32) -> Result<&2, &2, String, String>:
	match valid:
		case False{}:
			invalid()
		case True{}:
			Done{hex(Core.xof_at(Core.seed_key(seed_material(seed)), 0, 0, U32.to_nat(count)))}

def parsed(seed: Maybe<&2, U32>, count: Maybe<&2, U32>) -> Result<&2, &2, String, String>:
	match seed count:
		case Some{s} Some{+n}:
			bounded(U32.is_le(n, 4096), s, n)
		case rest_seed rest_count:
			invalid()

def run(args: List<String>) -> Result<&2, &2, String, String>:
	match args:
		case Con{program, Con{seed, Con{count, Nil{}}}}:
			parsed(U32.read(seed), U32.read(count))
		case rest:
			invalid()
