import Sampler
import Draw

# Constant-workspace output plan. The interpreter transports each completed
# item before requesting the next, retaining no sample or entropy history.
Batch :: { first : I64, last : I64, remaining : U64, index : U64 }.{
	normal : I64, I64, U64, I64 -> Try(Batch, [Invalid, Numeric, DivisionByZero, Source, BufferTooSmall])
	normal = |first, last, count, mode| {
		# SIMD (2) permits the same portable scalar fallback as the Zig ABI.
		if mode < 0 or mode > 2 return Err(Invalid)
		match Sampler.normal_int(first, last).view() {
			Failed(problem) => Err(problem)
			_ => Ok({ first, last, remaining: count, index: 0 })
		}
	}

	view : Batch -> [Finished, Item({ index : U64, completed : U64, program : Draw(I64), after : Batch })]
	view = |batch| {
		if batch.remaining == 0 Finished
		else Item({
			index: batch.index,
			completed: batch.index + 1,
			program: Sampler.normal_int(batch.first, batch.last),
			after: { ..batch, index: batch.index + 1, remaining: batch.remaining - 1 },
		})
	}
}
