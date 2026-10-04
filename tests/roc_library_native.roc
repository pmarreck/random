# Native execution of the installed source overlay, using the bundled Echo
# host. The declared-package consumer is checked separately with its platform.
import Codec
import Drbg
import Geometric
import Decimal
import Chart
import Fixed
import Count

main! = |args| {
	seed = args.first() ?? "42"
	match sample(seed) {
		Ok((value, position)) => {
			echo!("${Codec.hex(value)}:${position.to_str()}")
			Ok({})
		}
		Err(_) => Err(Exit(1.I8))
	}
}

sample = |seed| {
	chart = Chart.sample(Normal, Fixed.zero, Fixed.from_int(1), 5)?
	if chart.heights() != [21, 8869, 65535, 8869, 21] return Err(Invalid)
	decoded_count = Count.from_blip([130, 0, 1])?
	if decoded_count.to_hex() != "100" return Err(Invalid)
	state = Drbg.new(Codec.seed(seed)?)?
	prepared = Geometric.new(Decimal.probability("2^-100")?)?
	(count, next) = prepared.sample().run_with(state, |rng, size| rng.bytes(size))?
	Ok((count.to_blip(), next.position()))
}
