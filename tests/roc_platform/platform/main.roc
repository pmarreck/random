platform ""
	requires {
		run! : U8, I64, I32, U64, U64 => U8
	}
	exposes [Host]
	packages {}
	provides { "roc_probe_bytes": fresh_bytes, "roc_probe_run": run_for_host! }
	hosted {
		"roc_probe_input": Host.input!,
		"roc_probe_numeric": Host.numeric!,
		"roc_probe_output": Host.output!,
	}
	targets: {
		inputs_dir: "targets/",
		x64glibc: {
			inputs: ["libhost.a", app],
			output: Shared,
		},
	}

import Host

run_for_host! : U8, I64, I32, U64, U64 => U8
run_for_host! = |op, m, e, position, count| run!(op, m, e, position, count)

# Return fresh unique storage for the host to fill and transfer back to Roc.
# Output is returned to Roc too, so its generated drop handles ownership.
fresh_bytes : U64 -> List(U8)
fresh_bytes = |count| List.repeat(0.U8, count)
