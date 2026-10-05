# A pure sampling program, interpreted by either caller-owned DRBG state or
# an I/O edge. Need contains only the next continuation; no past byte history
# is accumulated, no host callback is falsely declared pure, and no reservoir
# can alter the specified source-read order.
Draw(a) :: {
	step : [Done(a), Need({ count : U64, after : List(U8) -> Draw(a) }), Failed([Invalid, Numeric, DivisionByZero, Source, BufferTooSmall])],
}.{
	succeed : a -> Draw(a)
	succeed = |value| { step: Done(value) }

	fail : [Invalid, Numeric, DivisionByZero, Source, BufferTooSmall] -> Draw(a)
	fail = |problem| { step: Failed(problem) }

	from_try : Try(a, [Invalid, Numeric, DivisionByZero, Source, BufferTooSmall]) -> Draw(a)
	from_try = |result| match result {
		Ok(value) => succeed(value)
		Err(problem) => fail(problem)
	}

	read : U64 -> Draw(List(U8))
	read = |count| {
		if count > 1048576 {
			fail(Invalid)
		} else if count == 0 {
			succeed([])
		} else {
			{
				step: Need({
					count,
					after: |bytes| if bytes.len() == count succeed(bytes) else fail(Source),
				}),
			}
		}
	}

	view : Draw(a) -> [Done(a), Need({ count : U64, after : List(U8) -> Draw(a) }), Failed([Invalid, Numeric, DivisionByZero, Source, BufferTooSmall])]
	view = |program| program.step

	and_then : Draw(a), (a -> Draw(b)) -> Draw(b)
	and_then = |program, continue| match program.step {
		Done(value) => continue(value)
		Failed(problem) => fail(problem)
		Need(request) => {
			resume = request.after
			{
				step: Need({
					count: request.count,
					after: |bytes| and_then(resume(bytes), continue),
				}),
			}
		}
	}

	# The functional interpreter advances a supplied source value explicitly.
	# An effectful platform instead inspects view and supplies each requested
	# byte chunk once, then invokes request.after with that result.
	run_with : Draw(a), state, (state, U64 -> Try((List(U8), state), [Invalid, Numeric, DivisionByZero, Source, BufferTooSmall])) -> Try((a, state), [Invalid, Numeric, DivisionByZero, Source, BufferTooSmall])
	run_with = |program, initial, reader| {
		var $current = program
		var $source = initial
		var $answer = Missing
		var $done = Bool.False
		while !$done {
			match $current.view() {
				Done(value) => {
					$answer = Ready(value)
					$done = Bool.True
				}
				Failed(problem) => return Err(problem)
				Need(request) => {
					(bytes, updated) = reader($source, request.count)?
					$source = updated
					resume = request.after
					$current = resume(bytes)
				}
			}
		}
		match $answer {
			Ready(value) => Ok((value, $source))
			Missing => Err(Invalid)
		}
	}
}
