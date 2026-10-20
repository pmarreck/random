# Measurement I/O only; kernels, parsing and formatting are pure model functions.
import Base
import ./Clock.bend as Clock
import ./BenchmarkModel.bend as Model

def failed() -> IO(Unit):
	IO.die(Unit, 1, "{\"error\":\"invalid benchmark arguments, clock interval or independent work checksum\"}\n")

def deliver_delta(value: Maybe<&1, (U32 & U32)>, next: U32 -> U32 -> IO(Unit)) -> IO(Unit):
	match value:
		case None{}:
			failed()
		case Some{(cpu, wall)}:
			next(cpu, wall)

def deliver(valid: Bool, value: Maybe<&1, (U32 & U32)>, next: U32 -> U32 -> IO(Unit)) -> IO(Unit):
	match valid:
		case False{}:
			failed()
		case True{}:
			deliver_delta(value, next)

def after_work(result: Result<&2, &2, U32, U32>, +params: Model.Params, w0: Clock.Stamp, c0: Clock.Stamp, next: U32 -> U32 -> IO(Unit)) -> IO(Unit):
	match result:
		case Fail{code}:
			failed()
		case Done{+checksum}:
			do IO<Unit>:
				c1 : Clock.Stamp <- IO.try(Clock.Stamp, Clock.now(1, checksum))
				w1 : Clock.Stamp <- IO.try(Clock.Stamp, Clock.now(0, checksum))
				deliver(U32.is_eq(checksum, Model.expected(params)), Model.deltas(Model.count(params), w0, c0, c1, w1), next)

def sample(+params: Model.Params, next: U32 -> U32 -> IO(Unit)) -> IO(Unit):
	do IO<Unit>:
		w0 : Clock.Stamp <- IO.try(Clock.Stamp, Clock.now(0, 0))
		c0 : Clock.Stamp <- IO.try(Clock.Stamp, Clock.now(1, 0))
		result : Result<&2, &2, U32, U32> = Model.execute(params, Model.count(params))
		after_work(result, params, w0, c0, next)

def samples(fuel: Nat, +params: Model.Params, cpu: String, wall: String) -> IO(Unit):
	match fuel:
		case 0n:
			do IO<Unit>:
				rss : Clock.Stamp <- IO.try(Clock.Stamp, Clock.peak_rss())
				IO.print(Model.protocol(params, cpu, wall, rss))
		case 1n+p:
			sample(params, c => w => samples(p, params, Model.push(cpu, c), Model.push(wall, w)))

def warmed(valid: Bool, params: Model.Params) -> IO(Unit):
	match valid:
		case False{}:
			failed()
		case True{}:
			samples(7n, params, "", "")

def ready(valid: Bool, +params: Model.Params) -> IO(Unit):
	match valid:
		case False{}:
			failed()
		case True{}:
			do IO<Unit>:
				IO.print("READY")
				warmed(Model.valid_result(Model.execute(params, 3), Model.warm(params)), params)

def start(params: Maybe<&2, Model.Params>) -> IO(Unit):
	match params:
		case None{}:
			failed()
		case Some{+p}:
			ready(Model.valid_result(Model.execute(p, 1), Model.first(p)), p)

def native_only(native: U32, args: List<String>) -> IO(Unit):
	match native:
		case 1:
			start(Model.parse_args(args))
		case other:
			IO.die(Unit, 1, "{\"error\":\"benchmark requires the optimized native artifact, not interpreted/JS/Debug execution\"}\n")

def main() -> IO(Unit):
	do IO<Unit>:
		args : List<String> <- IO.args()
		native : U32 <- Clock.optimized_native()
		native_only(native, args)
