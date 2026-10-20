# Benchmark-only I/O adapter. No generator logic enters these foreign effects.
import Base
type Stamp is Data:
	Stamp{hi: U32, lo: U32}

def now(kind: U32, token: U32) -> IO(Result<&1, &1, U32 & String, Stamp>):
	import "./clock.c"
	import "./clock.js"

def peak_rss() -> IO(Result<&1, &1, U32 & String, Stamp>):
	import "./rss.c"
	import "./rss.js"

def optimized_native() -> IO(U32):
	import "./optimized.c"
	import "./optimized.js"
