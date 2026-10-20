import Base
import ../../bend/Clock.bend as Clock

def good(result: Result<&1, &1, U32 & String, Clock.Stamp>) -> Bool:
	match result:
		case Done{value}:
			True{}
		case Fail{error}:
			False{}

def finish(valid: Bool) -> IO(Unit):
	match valid:
		case True{}:
			IO.print("clock adapter passed")
		case False{}:
			IO.die(Unit, 1, "clock adapter failed")

def main() -> IO(Unit):
	do IO<Unit>:
		a : Result<&1, &1, U32 & String, Clock.Stamp> <- Clock.now(0, 0)
		b : Result<&1, &1, U32 & String, Clock.Stamp> <- Clock.now(1, 0)
		c : Result<&1, &1, U32 & String, Clock.Stamp> <- Clock.now(2, 0)
		d : Result<&1, &1, U32 & String, Clock.Stamp> <- Clock.now(4294967295, 0)
		finish(good(a) && good(b) && Bool.not(good(c)) && Bool.not(good(d)))
