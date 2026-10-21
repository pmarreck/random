# Public experimental facade. Compile this entire module graph once for JS:
# independently emitted graphs do not share imported sum-constructor names.
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed
import ./Draw.bend as Draw
import ./Count.bend as Count
import ./Geometric.bend as Geometric
import ./ZigguratTables.bend as Tables
import ./Sampler.bend as Sampler
import ./Decimal.bend as Decimal
import ./Chart.bend as Chart
import ./Batch.bend as Batch
import ./Selection.bend as Selection

def new_seed(material: List<&2, U32>) -> Result<&2, &2, U32, Core.Stream>:
	Core.new_seed(material)

def read(state: Core.Stream, count: U32) -> Result<&2, &1, U32, Core.Read>:
	Core.read(state, count)

def run(-A: Type, state: Core.Stream, program: Draw.Program(A)) -> Result<&2, &1, Core.Failure, Draw.Outcome<A>>:
	Draw.run(A, state, program)

def pure(-A: Type, value: A) -> Draw.Program(A):
	Draw.pure(A, value)

def reject(-A: Type, code: U32) -> Draw.Program(A):
	Draw.reject(A, code)

def bind(-A: Type, -B: Type, program: Draw.Program(A), action: A -> Draw.Program(B)) -> Draw.Program(B):
	Draw.bind(A, B, program, action)

def steps(-A: Type, program: Draw.Program(A)) -> Draw.Step<A>:
	Draw.steps(A, program)

def read_request(count: U32) -> Draw.Program(List<U32>):
	Draw.read(count)

def fixed(+hi: U32, +lo: U32, +e: U32) -> Result<&2, &2, U32, Fixed.Fixed>:
	Fixed.guard(Fixed.valid(Fixed.Fixed{Core.Wide{hi, lo}, e}), u => Done{Fixed.Fixed{Core.Wide{hi, lo}, e}})

def strip(+index: U32) -> Result<&2, &2, U32, Tables.Strip>:
	Fixed.branch(Result<&2, &2, U32, Tables.Strip>, U32.is_lt(index, 256), u => Done{Tables.lookup(index)}, u => Fail{1})

def uniform() -> Draw.Program(Fixed.Fixed):
	Sampler.uniform()

def normal(mean: Fixed.Fixed, stddev: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	Sampler.normal(mean, stddev)

def range(first: Core.Wide, last: Core.Wide) -> Draw.Program(Core.Wide):
	Sampler.range(first, last)

def normal_int(first: Core.Wide, last: Core.Wide) -> Draw.Program(Core.Wide):
	Sampler.normal_int(first, last)

def exponential(rate: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	Sampler.exponential(rate)

def poisson(lambda: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	Sampler.poisson(lambda)

def log_normal(mean: Fixed.Fixed, stddev: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	Sampler.log_normal(mean, stddev)

def gamma(alpha: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	Sampler.gamma(alpha)

def beta(alpha: Fixed.Fixed, shape: Fixed.Fixed) -> Draw.Program(Fixed.Fixed):
	Sampler.beta(alpha, shape)

def geometric_prepare(probability: Fixed.Fixed) -> Result<&2, &2, U32, Geometric.Prepared>:
	Geometric.prepare(probability)

def geometric_sample(prepared: Geometric.Prepared) -> Draw.Program(Count.Count):
	Geometric.sample(prepared)

def geometric_bounded(prepared: Geometric.Prepared, capacity: Core.Wide) -> Draw.Program(Count.Count):
	Geometric.sample_bounded(prepared, capacity)

def parse(bytes: List<&2, U32>) -> Result<&2, &2, U32, Fixed.Fixed>:
	Decimal.parse(bytes)

def probability(bytes: List<&2, U32>) -> Result<&2, &2, U32, Fixed.Fixed>:
	Decimal.probability(bytes)

def integer(bytes: List<&2, U32>) -> Result<&2, &2, U32, Core.Wide>:
	Decimal.integer(bytes)

def render(value: Fixed.Fixed, places: Nat) -> Result<&2, &2, U32, String>:
	Decimal.render(value, places)

def chart(kind: U32, a: Fixed.Fixed, b: Fixed.Fixed, count: Nat) -> Result<&2, &2, U32, Chart.Chart>:
	Chart.sample(kind, a, b, count)

def batch(first: Core.Wide, last: Core.Wide, count: Core.Wide, mode: U32) -> Result<&2, &2, U32, Batch.Batch>:
	Batch.prepare(first, last, count, mode)

def batch_view(plan: Batch.Batch) -> Batch.View:
	Batch.view(plan)

def selection(weights: List<&2, Core.Wide>) -> Result<&2, &2, U32, Selection.Prepared>:
	Selection.prepare(weights)

def weighted(prepared: Selection.Prepared) -> Draw.Program(Core.Wide):
	Selection.weighted(prepared)

def shuffle(count: Core.Wide) -> Draw.Program(List<&2, Core.Wide>):
	Selection.shuffle(count)
