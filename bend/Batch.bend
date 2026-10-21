# Pure bounded-workspace output plan. The edge transports each completed item
# before asking for the next one; no samples or random bytes are prefetched.
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed
import ./Draw.bend as Draw
import ./Sampler.bend as Sampler

type Batch is Data:
	Batch{first: Core.Wide, last: Core.Wide, remaining: Core.Wide, index: Core.Wide}

type View is Type:
	Finished{}
	Item{index: Core.Wide, completed: Core.Wide, after: Batch, program: Draw.Program(Core.Wide)}

def prepare(+first: Core.Wide, +last: Core.Wide, remaining: Core.Wide, +mode: U32) -> Result<&2, &2, U32, Batch>:
	Fixed.branch(Result<&2, &2, U32, Batch>, U32.is_le(mode, 2) && Sampler.ordered(first, last), u => (
		do Result<&2, &2, U32, Batch>:
			parameters : Sampler.NormalRange <- Sampler.normal_range_parameters(first, last)
			return Batch{first, last, remaining, Core.Wide{0, 0}}
	), u => Fail{1})

def view(batch: Batch) -> View:
	match batch:
		case Batch{+first, +last, +remaining, +index}:
			Fixed.branch(View, Core.u64_zero(remaining), u => Finished{}, u => (
				+completed : Core.Wide = Core.u64_add(index, Core.Wide{0, 1})
				after : Batch = Batch{first, last, Core.u64_sub(remaining, Core.Wide{0, 1}), completed}
				Item{index, completed, after, Sampler.normal_int(first, last)}
			))
