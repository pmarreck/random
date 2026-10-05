import Sampler
import Draw

# Prepared nonnegative weights and pure, source-injected item index plans.
# Parsing/byte spans and emission remain outside this domain module.
Selection :: { weights : List(I64), total : I64 }.{
	add_weight : I64, I64 -> Try(I64, [InvalidWeight, TotalTooLarge])
	add_weight = |total, weight| {
		if total < 0 or weight < 0 return Err(InvalidWeight)
		if total > 9007199254740992 or weight > 9007199254740992 - total return Err(TotalTooLarge)
		Ok(total + weight)
	}

	new : List(I64) -> Try(Selection, [Empty, InvalidWeight, TotalTooLarge, ZeroTotal])
	new = |weights| {
		if weights.is_empty() return Err(Empty)
		var $total = 0.I64
		for weight in weights {
			$total = add_weight($total, weight)?
		}
		if $total == 0 Err(ZeroTotal) else Ok({ weights, total: $total })
	}

	is_eq : Selection, Selection -> Bool
	is_eq = |a, b| a.weights == b.weights and a.total == b.total

	total : Selection -> I64
	total = |prepared| prepared.total

	weighted : Selection -> Draw(I64)
	weighted = |prepared| Sampler.range(1, prepared.total).and_then(
		|pick| {
			var $cumulative = 0.I64
			var $index = 0.I64
			for weight in prepared.weights {
				$cumulative = $cumulative + weight
				if pick <= $cumulative return Draw.succeed($index)
				$index = $index + 1
			}
			Draw.fail(Invalid)
		},
	)

	shuffle : U64 -> Draw(List(I64))
	shuffle = |count| {
		if count > 9007199254740992 return Draw.fail(Invalid)
		var $indices = List.with_capacity(count)
		for index in 0..<count {
			$indices = $indices.append(index.to_i64_wrap())
		}
		shuffle_loop($indices, count)
	}
}

shuffle_loop : List(I64), U64 -> Draw(List(I64))
shuffle_loop = |indices, remaining| {
	if remaining <= 1 Draw.succeed(indices)
	else Sampler.range(1, remaining.to_i64_wrap()).and_then(
		|pick| {
			last = remaining - 1
			chosen = (pick - 1).to_u64_wrap()
			a = indices.get(last) ?? -1
			b = indices.get(chosen) ?? -1
			if a < 0 or b < 0 return Draw.fail(Invalid)
			updated = match indices.set(last, b) {
				Ok(value) => value
				Err(_) => return Draw.fail(Invalid)
			}
			swapped = match updated.set(chosen, a) {
				Ok(value) => value
				Err(_) => return Draw.fail(Invalid)
			}
			shuffle_loop(swapped, last)
		},
	)
}
