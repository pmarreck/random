# Pure byte-request programs. Deterministic and OS-backed edge interpreters
# execute the SAME sampling decisions; arithmetic never calls a foreign RNG.
import Base
import ./Core.bend as Core

type Step<-A: Type> is Type:
	Finished{value: A}
	Rejected{code: U32}
	Request{count: U32, next: List<U32> -> Step<A>}

# Continuation encoding keeps composition nonrecursive. The pinned checker
# does not recognize higher-order Step continuations as structural subterms.
def Program(-A: Type) -> Type:
	@-R: Type -> @done: (A -> Step<R>) -> Step<R>

type Outcome<-A: Type> is Type:
	Outcome{state: Core.Stream, value: A}

def Program.pure(-A: Type, value: A) -> Program(A):
	R => done => done(value)

def Program.bind(-A: Type, -B: Type, program: Program(A), action: A -> Program(B)) -> Program(B):
	R => done => program(R, value => action(value, R, done))

def reject(-A: Type, code: U32) -> Program(A):
	R => done => Rejected{code}

def checked(b, -A: Kind(b), result: Result<&2, b, U32, A>) -> Program(A):
	match result:
		case Done{value}:
			Program.pure(A, value)
		case Fail{code}:
			reject(A, code)

def read(count: U32) -> Program(List<U32>):
	R => done => Request{count, done}

def steps(-A: Type, program: Program(A)) -> Step<A>:
	program(A, value => Finished{value})

def after_read(-A: Type, before: Core.Stream, result: Result<&2, &1, U32, Core.Read>, next: List<U32> -> Step<A>, continue: Core.Stream -> Step<A> -> Result<&2, &1, Core.Failure, Outcome<A>>) -> Result<&2, &1, Core.Failure, Outcome<A>>:
	match result:
		case Fail{code}:
			Fail{Core.Failure{code, before}}
		case Done{Core.Read{state, bytes}}:
			continue(state, next(bytes))

def step_once(-A: Type, +state: Core.Stream, program: Step<A>, continue: Core.Stream -> Step<A> -> Result<&2, &1, Core.Failure, Outcome<A>>) -> Result<&2, &1, Core.Failure, Outcome<A>>:
	match program:
		case Finished{value}:
			Done{Outcome{state, value}}
		case Rejected{code}:
			Fail{Core.Failure{code, state}}
		case Request{count, next}:
			after_read(A, state, Core.read(state, count), next, continue)

def run_steps(-A: Type, high: Nat, low: Nat, +state: Core.Stream, program: Step<A>) -> Result<&2, &1, Core.Failure, Outcome<A>>:
	match high low:
		case 0n 0n:
			step_once(A, state, program, last => step => Fail{Core.Failure{5, last}})
		case 0n 1n+p:
			step_once(A, state, program, next => step => run_steps(A, 0n, p, next, step))
		case 1n+h 0n:
			run_steps(A, h, 4294967295n, state, program)
		case 1n+h 1n+p:
			step_once(A, state, program, next => step => run_steps(A, 1n+h, p, next, step))

def run_checked(-A: Type, valid: Bool, state: Core.Stream, program: Program(A)) -> Result<&2, &1, Core.Failure, Outcome<A>>:
	match valid:
		case False{}:
			Fail{Core.Failure{1, state}}
		case True{}:
			run_steps(A, 2097152n, 4294967295n, state, steps(A, program))

def run(-A: Type, +state: Core.Stream, program: Program(A)) -> Result<&2, &1, Core.Failure, Outcome<A>>:
	run_checked(A, Core.stream_valid(state), state, program)

# Plain exported names are convenient for generated-JavaScript consumers.
def pure(-A: Type, value: A) -> Program(A):
	Program.pure(A, value)

def bind(-A: Type, -B: Type, program: Program(A), action: A -> Program(B)) -> Program(B):
	Program.bind(A, B, program, action)
