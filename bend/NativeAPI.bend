# Private transport algebra for the owned C ABI. This module is pure Bend;
# the host only marshals data, satisfies byte requests and copies responses.
import Base
import ./Core.bend as Core
import ./Fixed.bend as Fixed
import ./Draw.bend as Draw
import ./Count.bend as Count
import ./Geometric.bend as Geometric
import ./Sampler.bend as Sampler
import ./Decimal.bend as Decimal
import ./Chart.bend as Chart
import ./Batch.bend as Batch
import ./Selection.bend as Selection

type Request is Data:
	NoOp{}
	NewSeed{material: List<&2, U32>}
	Restore{key: List<&2, U32>, hi: U32, lo: U32}
	Preflight{key: List<&2, U32>, hi: U32, lo: U32, amount_hi: U32, amount_lo: U32}
	Fill{key: List<&2, U32>, hi: U32, lo: U32, count: U32}
	ReadWord{key: List<&2, U32>, hi: U32, lo: U32, width: U32}
	NumericMethod{op: U32, ah: U32, al: U32, ae: U32, bh: U32, bl: U32, be: U32}
	IntegerMethod{op: U32, ah: U32, al: U32, bh: U32, bl: U32}
	GeometricPrepare{mh: U32, ml: U32, e: U32}
	GeometricSample{base_hi: U32, base_lo: U32, levels: List<&2, Core.Wide>, tail_bits: U32, certain: U32, capacity_hi: U32, capacity_lo: U32}
	CountPrepare{bytes: List<&2, U32>, radix: U32}
	CountFormat{bytes: List<&2, U32>, radix: U32, scratch_hi: U32, scratch_lo: U32, capacity_hi: U32, capacity_lo: U32}
	Convert{op: U32, mh: U32, ml: U32, e: U32}
	Parse{op: U32, bytes: List<&2, U32>}
	Format{mh: U32, ml: U32, e: U32, places_hi: U32, places_lo: U32, capacity_hi: U32, capacity_lo: U32}
	Curve{phase: U32, kind: U32, ah: U32, al: U32, ae: U32, bh: U32, bl: U32, be: U32, capacity_hi: U32, capacity_lo: U32}
	BatchStart{ah: U32, al: U32, bh: U32, bl: U32, remaining_hi: U32, remaining_lo: U32, mode: U32}
	BatchNext{ah: U32, al: U32, bh: U32, bl: U32, remaining_hi: U32, remaining_lo: U32, index_hi: U32, index_lo: U32}
	Weights{op: U32, weights: List<&2, Core.Wide>}
	WeightAdd{total_hi: U32, total_lo: U32, weight_hi: U32, weight_lo: U32}
	Shuffle{count_hi: U32, count_lo: U32}

type Response is Data:
	Acknowledged{}
	StateOut{key: List<&2, U32>, hi: U32, lo: U32}
	PositionOut{hi: U32, lo: U32}
	BytesOut{bytes: List<&2, U32>, hi: U32, lo: U32}
	NumberOut{hi: U32, lo: U32, e: U32}
	IntegerOut{hi: U32, lo: U32}
	WordOut{value_hi: U32, value_lo: U32, position_hi: U32, position_lo: U32}
	TextOut{text: String}
	CurveOut{heights: List<&2, U32>, minimum_hi: U32, minimum_lo: U32, minimum_e: U32, maximum_hi: U32, maximum_lo: U32, maximum_e: U32}
	BatchReady{remaining_hi: U32, remaining_lo: U32, index_hi: U32, index_lo: U32}
	BatchEnd{}
	BatchItem{index_hi: U32, index_lo: U32, value_hi: U32, value_lo: U32, remaining_hi: U32, remaining_lo: U32, completed_hi: U32, completed_lo: U32}
	SelectionFailure{reason: U32}
	IndicesOut{indices: List<&2, Core.Wide>}
	GeometricReady{base_hi: U32, base_lo: U32, levels: List<&2, Core.Wide>, tail_bits: U32, certain: U32}
	CountReady{magnitude: List<&2, U32>}

def key_bytes(key: Core.CV) -> List<&2, U32>:
	match key:
		case Core.CV{a, b, c, d, e, f, g, h}:
			List.concat(&2, U32, [Count.owned(Core.word_bytes(a)), Count.owned(Core.word_bytes(b)), Count.owned(Core.word_bytes(c)), Count.owned(Core.word_bytes(d)), Count.owned(Core.word_bytes(e)), Count.owned(Core.word_bytes(f)), Count.owned(Core.word_bytes(g)), Count.owned(Core.word_bytes(h))])

def state_out(state: Core.Stream) -> Response:
	match state:
		case Core.Stream{key, hi, lo}:
			StateOut{key_bytes(key), hi, lo}

def number_out(value: Fixed.Fixed) -> Response:
	match value:
		case Fixed.Fixed{Core.Wide{hi, lo}, e}:
			NumberOut{hi, lo, e}

def integer_out(value: Core.Wide) -> Response:
	match value:
		case Core.Wide{hi, lo}:
			IntegerOut{hi, lo}

def restored(+key: List<&2, U32>, +hi: U32, +lo: U32) -> Result<&2, &2, U32, Core.Stream>:
	valid = Nat.is_eq(List.length(&2, U32, key), 32n) && Core.valid_bytes(key)
	Count.guard(Core.Stream, valid, u => Fixed.branch(Result<&2, &2, U32, Core.Stream>, Core.cursor_valid(hi, lo),
		u => Done{Core.Stream{Core.key_words(key), hi, lo}}, u => Fail{3}))

def filled(result: Result<&2, &1, U32, Core.Read>) -> Draw.Program(Response):
	match result:
		case Fail{+code}:
			Draw.reject(Response, Core.choose_word(U32.is_eq(code, 2), 3, code))
		case Done{Core.Read{Core.Stream{key, hi, lo}, bytes}}:
			Draw.pure(Response, BytesOut{Count.owned(bytes), hi, lo})

def word_position(value: Core.Wide, hi: U32, lo: U32) -> Draw.Program(Response):
	match value:
		case Core.Wide{vh, vl}:
			Draw.pure(Response, WordOut{vh, vl, hi, lo})

def word_out(result: Result<&2, &1, U32, Core.Read>) -> Draw.Program(Response):
	match result:
		case Fail{+code}:
			Draw.reject(Response, Core.choose_word(U32.is_eq(code, 2), 3, code))
		case Done{Core.Read{Core.Stream{key, hi, lo}, bytes}}:
			word_position(Core.be_word(bytes, Core.Wide{0, 0}), hi, lo)

def preflight_end(valid: Bool, end: Core.Wide) -> Draw.Program(Response):
	match end:
		case Core.Wide{+hi, +lo}:
			Fixed.branch(Draw.Program(Response), valid && Core.cursor_valid(hi, lo),
				u => Draw.pure(Response, PositionOut{hi, lo}), u => Draw.reject(Response, 3))

def preflight(state: Core.Stream, +amount_hi: U32, +amount_lo: U32) -> Draw.Program(Response):
	match state:
		case Core.Stream{key, hi, lo}:
			+next = Core.u64_add(Core.Wide{hi, lo}, Core.Wide{amount_hi, amount_lo})
			preflight_end(Core.cursor_valid(amount_hi, amount_lo), next)

def numeric(+op: U32, +a: Fixed.Fixed, +b: Fixed.Fixed) -> Draw.Program(Response):
	Fixed.branch(Draw.Program(Response), U32.is_eq(op, 3), u => (
		do Draw.Program<Response>:
			value : Fixed.Fixed <- Sampler.poisson(a)
			return integer_out(Fixed.to_int_trunc(value))
	), u => (
		do Draw.Program<Response>:
			value : Fixed.Fixed <- Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 0), u => Sampler.uniform(),
				u => Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 1), u => Sampler.normal(a, b),
					u => Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 2), u => Sampler.exponential(a),
						u => Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 4), u => Sampler.log_normal(a, b),
							u => Fixed.branch(Draw.Program(Fixed.Fixed), U32.is_eq(op, 5), u => Sampler.beta(a, b),
								u => Draw.reject(Fixed.Fixed, 1))))))
			return number_out(value)
	))

def integer(+op: U32, +first: Core.Wide, +last: Core.Wide) -> Draw.Program(Response):
	do Draw.Program<Response>:
		value : Core.Wide <- Fixed.branch(Draw.Program(Core.Wide), U32.is_eq(op, 0), u => Sampler.range(first, last),
			u => Fixed.branch(Draw.Program(Core.Wide), U32.is_eq(op, 1), u => Sampler.normal_int(first, last), u => Draw.reject(Core.Wide, 1)))
		return integer_out(value)

def fit_text(+text: String, capacity: Core.Wide) -> Draw.Program(Response):
	Fixed.branch(Draw.Program(Response), Core.u64_lt(capacity, Count.nat_wide(String.length(text))),
		u => Draw.reject(Response, 4), u => Draw.pure(Response, TextOut{text}))

def count_prepare(+bytes: List<&2, U32>, +radix: U32) -> Draw.Program(Response):
	do Draw.Program<Response>:
		value : Count.Count <- Draw.checked(&2, Count.Count, Count.from_blip(bytes))
		Sampler.guard(Response, Core.choose_word(U32.is_eq(radix, 10) || U32.is_eq(radix, 16), 0, 1),
			u => Draw.pure(Response, CountReady{Count.magnitude(value)}))

def count_format(+bytes: List<&2, U32>, +radix: U32, +scratch: Core.Wide, +capacity: Core.Wide) -> Draw.Program(Response):
	+value : Count.Count = Count.Count{bytes}
	+length : Nat = Count.length(value)
	insufficient : Bool = U32.is_eq(radix, 10) && Core.u64_lt(scratch, Count.nat_wide(length))
	minimum : Nat = Fixed.branch(Nat, Nat.is_eq(length, 0n), u => 1n, u => Nat.add(Nat.mul(Nat.sub(length, 1n), 2n), 1n))
	Fixed.branch(Draw.Program(Response), insufficient || Core.u64_lt(capacity, Count.nat_wide(minimum)),
		u => Draw.reject(Response, 4), u => fit_text(Fixed.branch(String, U32.is_eq(radix, 10),
			u => Count.to_decimal(value), u => Count.to_hex(value)), capacity))

def geometric_ready(prepared: Geometric.Prepared) -> Response:
	match prepared:
		case Geometric.Prepared{Core.Wide{hi, lo}, levels, tail_bits, certain}:
			GeometricReady{hi, lo, levels, tail_bits, Core.bool_word(certain)}

def raw_mantissa(value: Fixed.Fixed) -> Core.Wide:
	match value:
		case Fixed.Fixed{m, e}:
			m

def convert(+op: U32, +value: Fixed.Fixed) -> Draw.Program(Response):
	Fixed.branch(Draw.Program(Response), U32.is_eq(op, 0), u => (
		do Draw.Program<Response>:
			number : Fixed.Fixed <- Draw.checked(&2, Fixed.Fixed, Fixed.from_int(raw_mantissa(value)))
			return number_out(number)
	), u => Sampler.guard(Response, Core.choose_word(Fixed.valid(value), 0, 1), u =>
		Fixed.branch(Draw.Program(Response), U32.is_eq(op, 1), u => Draw.pure(Response, integer_out(Fixed.to_int_trunc(value))),
			u => Fixed.branch(Draw.Program(Response), U32.is_eq(op, 2), u => (
				do Draw.Program<Response>:
					integer : Core.Wide <- Draw.checked(&2, Core.Wide, Fixed.round_to_int(value))
					return integer_out(integer)
			), u => Draw.reject(Response, 1)))))

def parse(+op: U32, +bytes: List<&2, U32>) -> Draw.Program(Response):
	Fixed.branch(Draw.Program(Response), U32.is_eq(op, 2), u => (
		do Draw.Program<Response>:
			value : Core.Wide <- Draw.checked(&2, Core.Wide, Decimal.integer(bytes))
			return integer_out(value)
	), u => (
		do Draw.Program<Response>:
			value : Fixed.Fixed <- Draw.checked(&2, Fixed.Fixed,
				Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_eq(op, 0), u => Decimal.parse(bytes),
					u => Fixed.branch(Result<&2, &2, U32, Fixed.Fixed>, U32.is_eq(op, 1), u => Decimal.probability(bytes), u => Fail{1})))
			return number_out(value)
	))

def format(+value: Fixed.Fixed, +places: Core.Wide, +capacity: Core.Wide) -> Draw.Program(Response):
	Sampler.guard(Response, Core.choose_word(Fixed.valid(value), 0, 1), u => (
		insufficient : Bool = Core.u64_lt(capacity, places) || Core.u64_lt(Core.u64_sub(capacity, places), Core.Wide{0, 3})
		Fixed.branch(Draw.Program(Response), insufficient, u => Draw.reject(Response, 4), u => (
			Sampler.guard(Response, Core.choose_word(Bool.not(Core.u64_lt(Core.Wide{0, 18}, places)), 0, 1), u => (
			do Draw.Program<Response>:
				text : String <- Draw.checked(&2, String, Decimal.render(value, U32.to_nat(Decimal.exponent_low(places))))
				fit_text(text, capacity)
			))
		))
	))

def curve_out(model: Chart.Chart) -> Response:
	match model:
		case Chart.Chart{heights, Fixed.Fixed{Core.Wide{lh, ll}, le}, Fixed.Fixed{Core.Wide{hh, hl}, he}, discrete}:
			CurveOut{heights, lh, ll, le, hh, hl, he}

def curve(+phase: U32, +kind: U32, +a: Fixed.Fixed, +b: Fixed.Fixed, +capacity: Core.Wide) -> Draw.Program(Response):
	valid : Bool = U32.is_ge(kind, 1) && U32.is_le(kind, 6) && Fixed.valid(a) && Fixed.valid(b) &&
		Bool.not(Core.u64_lt(capacity, Core.Wide{0, 2})) && Bool.not(Core.u64_lt(Core.Wide{0, 4096}, capacity))
	Sampler.guard(Response, Core.choose_word(valid, 0, 1), u => (
		Fixed.branch(Draw.Program(Response), U32.is_eq(phase, 0), u => Draw.pure(Response, integer_out(capacity)),
			u => Sampler.guard(Response, Core.choose_word(U32.is_eq(phase, 1), 0, 1), u => (
				do Draw.Program<Response>:
					model : Chart.Chart <- Draw.checked(&2, Chart.Chart, Chart.sample(kind, a, b, U32.to_nat(Decimal.exponent_low(capacity))))
					return curve_out(model)
			)))
	))

def batch_ready(plan: Batch.Batch) -> Response:
	match plan:
		case Batch.Batch{first, last, Core.Wide{rh, rl}, Core.Wide{ih, il}}:
			BatchReady{rh, rl, ih, il}

def batch_item(index: Core.Wide, value: Core.Wide, after: Batch.Batch, completed: Core.Wide) -> Response:
	match index value after completed:
		case Core.Wide{ih, il} Core.Wide{vh, vl} Batch.Batch{first, last, Core.Wide{rh, rl}, next_index} Core.Wide{ch, cl}:
			BatchItem{ih, il, vh, vl, rh, rl, ch, cl}

def batch_view(view: Batch.View) -> Draw.Program(Response):
	match view:
		case Batch.Finished{}:
			Draw.pure(Response, BatchEnd{})
		case Batch.Item{index, completed, after, program}:
			do Draw.Program<Response>:
				value : Core.Wide <- program
				return batch_item(index, value, after, completed)

def selection(result: Result<&2, &2, U32, Selection.Prepared>, +op: U32) -> Draw.Program(Response):
	match result:
		case Fail{reason}:
			Draw.pure(Response, SelectionFailure{reason})
		case Done{+prepared}:
			Fixed.branch(Draw.Program(Response), U32.is_eq(op, 0), u => Draw.pure(Response, integer_out(Selection.total(prepared))),
				u => Sampler.guard(Response, Core.choose_word(U32.is_eq(op, 1), 0, 1), u => (
					do Draw.Program<Response>:
						index : Core.Wide <- Selection.weighted(prepared)
						return integer_out(index)
				)))

def added_weight(result: Result<&2, &2, U32, Core.Wide>) -> Draw.Program(Response):
	match result:
		case Fail{reason}:
			Draw.reject(Response, 1)
		case Done{value}:
			Draw.pure(Response, integer_out(value))

def program(request: Request) -> Draw.Program(Response):
	match request:
		case NoOp{}:
			Draw.pure(Response, Acknowledged{})
		case NewSeed{material}:
			do Draw.Program<Response>:
				state : Core.Stream <- Draw.checked(&2, Core.Stream, Core.new_seed(material))
				return state_out(state)
		case Restore{key, hi, lo}:
			do Draw.Program<Response>:
				state : Core.Stream <- Draw.checked(&2, Core.Stream, restored(key, hi, lo))
				return state_out(state)
		case Preflight{key, hi, lo, ah, al}:
			do Draw.Program<Response>:
				state : Core.Stream <- Draw.checked(&2, Core.Stream, restored(key, hi, lo))
				preflight(state, ah, al)
		case Fill{key, hi, lo, count}:
			do Draw.Program<Response>:
				state : Core.Stream <- Draw.checked(&2, Core.Stream, restored(key, hi, lo))
				filled(Core.read(state, count))
		case ReadWord{key, hi, lo, +width}:
			Sampler.guard(Response, Core.choose_word(U32.is_eq(width, 4) || U32.is_eq(width, 8), 0, 1), u => (
				do Draw.Program<Response>:
					state : Core.Stream <- Draw.checked(&2, Core.Stream, restored(key, hi, lo))
					word_out(Core.read(state, width))
			))
		case NumericMethod{op, ah, al, ae, bh, bl, be}:
			numeric(op, Fixed.Fixed{Core.Wide{ah, al}, ae}, Fixed.Fixed{Core.Wide{bh, bl}, be})
		case IntegerMethod{op, ah, al, bh, bl}:
			integer(op, Core.Wide{ah, al}, Core.Wide{bh, bl})
		case GeometricPrepare{mh, ml, e}:
			do Draw.Program<Response>:
				prepared : Geometric.Prepared <- Draw.checked(&2, Geometric.Prepared, Geometric.prepare(Fixed.Fixed{Core.Wide{mh, ml}, e}))
				return geometric_ready(prepared)
		case GeometricSample{bh, bl, levels, tail_bits, certain, ch, cl}:
			do Draw.Program<Response>:
				value : Count.Count <- Geometric.sample_bounded(Geometric.Prepared{Core.Wide{bh, bl}, levels, tail_bits, U32.is_ne(certain, 0)}, Core.Wide{ch, cl})
				return BytesOut{Count.to_blip(value), 0, 0}
		case CountPrepare{bytes, radix}:
			count_prepare(bytes, radix)
		case CountFormat{bytes, radix, sh, sl, ch, cl}:
			count_format(bytes, radix, Core.Wide{sh, sl}, Core.Wide{ch, cl})
		case Convert{op, mh, ml, e}:
			convert(op, Fixed.Fixed{Core.Wide{mh, ml}, e})
		case Parse{op, bytes}:
			parse(op, bytes)
		case Format{mh, ml, e, ph, pl, ch, cl}:
			format(Fixed.Fixed{Core.Wide{mh, ml}, e}, Core.Wide{ph, pl}, Core.Wide{ch, cl})
		case Curve{phase, kind, ah, al, ae, bh, bl, be, ch, cl}:
			curve(phase, kind, Fixed.Fixed{Core.Wide{ah, al}, ae}, Fixed.Fixed{Core.Wide{bh, bl}, be}, Core.Wide{ch, cl})
		case BatchStart{ah, al, bh, bl, rh, rl, mode}:
			do Draw.Program<Response>:
				plan : Batch.Batch <- Draw.checked(&2, Batch.Batch, Batch.prepare(Core.Wide{ah, al}, Core.Wide{bh, bl}, Core.Wide{rh, rl}, mode))
				return batch_ready(plan)
		case BatchNext{ah, al, bh, bl, rh, rl, ih, il}:
			batch_view(Batch.view(Batch.Batch{Core.Wide{ah, al}, Core.Wide{bh, bl}, Core.Wide{rh, rl}, Core.Wide{ih, il}}))
		case Weights{op, weights}:
			selection(Selection.prepare(weights), op)
		case WeightAdd{th, tl, wh, wl}:
			added_weight(Selection.add_weight(Core.Wide{th, tl}, Core.Wide{wh, wl}))
		case Shuffle{hi, lo}:
			do Draw.Program<Response>:
				indices : List<&2, Core.Wide> <- Selection.shuffle(Core.Wide{hi, lo})
				return IndicesOut{indices}

# The host obtains this boxed function from the effect payload. Ordinary
# function segments are compiler-flattened, including function-valued returns;
# only the runtime's closure application boundary has a boxed argument/result.
def touch(value: Request -> Draw.Step<Response>) -> IO(Unit):
	import "./native_touch.c"
	import "./native_touch.js"

def main() -> IO(Unit):
	touch(request => Draw.steps(Response, program(request)))
