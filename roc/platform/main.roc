platform ""
	requires {
		run! : U8, I64, I32, I64, I32, I64, I64, U64 => U8
	}
	exposes [Host]
	packages {}
	provides { "randomroc_owned_bytes": fresh_bytes, "randomroc_owned_i64": fresh_i64, "randomroc_run": run_for_host! }
	hosted {
		"randomroc_host_source": Host.source!,
		"randomroc_host_status": Host.status!,
		"randomroc_host_numeric": Host.numeric!,
		"randomroc_host_integer": Host.integer!,
		"randomroc_host_begin": Host.begin!,
		"randomroc_host_output": Host.output!,
		"randomroc_host_input": Host.input!,
		"randomroc_host_state": Host.state!,
		"randomroc_host_chunk": Host.chunk!,
		"randomroc_host_u32": Host.u32!,
		"randomroc_host_u64": Host.u64!,
		"randomroc_host_count": Host.count!,
		"randomroc_host_curve": Host.curve!,
		"randomroc_host_item": Host.item!,
		"randomroc_host_weights": Host.weights!,
		"randomroc_host_reason": Host.reason!,
		"randomroc_host_permutation": Host.permutation!,
	}
	targets: {
		inputs_dir: "targets/",
		x64v1glibc: {
			inputs: ["libhost.a", app],
			output: Archive,
		},
		arm64glibc: {
			inputs: ["libhost.a", app],
			output: Archive,
		},
	}

import Host

run_for_host! : U8, I64, I32, I64, I32, I64, I64, U64 => U8
run_for_host! = |op, am, ae, bm, be, first, last, capacity| run!(op, am, ae, bm, be, first, last, capacity)

fresh_bytes : U64 -> List(U8)
fresh_bytes = |count| List.repeat(0.U8, count)

fresh_i64 : U64 -> List(I64)
fresh_i64 = |count| List.repeat(0.I64, count)
