app [main!] {
	pf: platform "__RANDOM_ROC_ECHO_PLATFORM__",
	random: "__RANDOM_ROC_LIBRARY__",
}

# A real package dependency, not an import that escapes its source root.
import pf.Echo
import random.Codec
import random.Drbg
import random.Geometric
import random.Decimal

main! = |args| {
	seed = args.first() ?? "42"
	match sample(seed) {
		Ok((value, position)) => {
			Echo.line!("${Codec.hex(value)}:${position.to_str()}")
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
