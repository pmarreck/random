app [run!] { pf: platform "./platform/main.roc", random: "./core/main.roc" }

import pf.Host
import random.Fixed
import random.Drbg
import random.Draw
import random.Sampler

# Integration fixture only: the existing pure package does all computation.
# The platform transports caller-owned input/output and observes allocation.
run! : U8, I64, I32, U64, U64 => U8
run! = |op, m, e, position, count| match op {
	0 => match Fixed.from_parts(m, e) {
		Err(_) => 1
		Ok(value) => match value.ln() {
			Err(_) => 1
			Ok(answer) => {
				(am, ae) = answer.parts()
				Host.numeric!(am, ae, 0)
				0
			}
		}
	}
	1 => match Drbg.new(Host.input!(32)) {
		Err(_) => 1
		Ok(rng) => {
			(key, _) = rng.state()
			_ = Host.output!(key)
			0
		}
	}
	2 => match Drbg.restore(Host.input!(32), position) {
		Err(_) => 1
		Ok(rng) => match rng.bytes(count) {
			Err(_) => 1
			Ok((bytes, _)) => {
				_ = Host.output!(bytes)
				0
			}
		}
	}
	3 => match Drbg.restore(Host.input!(32), position) {
		Err(_) => 1
		Ok(rng) => {
			program = Sampler.normal(Fixed.zero, Fixed.from_int(1))
			answer = Draw.run_with(program, rng, |state, amount| state.bytes(amount))
			match answer {
				Err(_) => 1
				Ok((value, next)) => {
					(am, ae) = value.parts()
					Host.numeric!(am, ae, next.position())
					0
				}
			}
		}
	}
	_ => 1
}
