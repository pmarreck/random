# Native execution of the installed source overlay, using the bundled Echo
# host. The declared-package consumer is checked separately with its platform.
import Codec
import Drbg
import Geometric
import Decimal

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
	state = Drbg.new(Codec.seed(seed)?)?
	prepared = Geometric.new(Decimal.probability("2^-100")?)?
	(count, next) = prepared.sample().run_with(state, |rng, size| rng.bytes(size))?
	Ok((count.to_blip(), next.position()))
}
