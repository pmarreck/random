# Compiled outside the repository against only the installed Bend SDK.
import Base
import ./random/Library.bend as Random
import ./random/Core.bend as Core
import ./random/Draw.bend as Draw

def sampled(result: Result<&2, &1, Core.Failure, Draw.Outcome<Core.Wide>>) -> IO(Unit):
	match result:
		case Done{Draw.Outcome{Core.Stream{key, hi, lo}, Core.Wide{vh, vl}}}:
			IO.write(U32.show(vh) ++ ":" ++ U32.show(vl) ++ ":" ++ U32.show(hi) ++ ":" ++ U32.show(lo) ++ "\n")
		case Fail{failure}:
			IO.die(Unit, 1, "installed Bend sampler failed")

def seeded(result: Result<&2, &2, U32, Core.Stream>) -> IO(Unit):
	match result:
		case Done{state}:
			sampled(Random.run(Core.Wide, state, Random.range(Core.Wide{0, 1}, Core.Wide{0, 20})))
		case Fail{code}:
			IO.die(Unit, 1, "installed Bend seed failed")

def main() -> IO(Unit):
	seeded(Random.new_seed([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 42]))
