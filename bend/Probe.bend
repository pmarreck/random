# Only process arguments and output effects live here.
import Base
import ./ProbeModel.bend as Model

def emit(result: Result<&2, &2, String, String>) -> IO(Unit):
	match result:
		case Done{text}:
			IO.write(text)
		case Fail{error}:
			IO.die(Unit, 1, error)

def main() -> IO(Unit):
	do IO<Unit>:
		args : List<String> <- IO.args()
		emit(Model.run(args))
