function random_bend_clock(kind, token) {
	void token;
	if (kind !== 0 && kind !== 1) return io_fail(22);
	const cpu = kind === 1 ? process.cpuUsage() : null;
	const ns = cpu === null ? process.hrtime.bigint()
		: (BigInt(cpu.user) + BigInt(cpu.system)) * 1000n;
	if (ns < 0n || ns > 0xffffffffffffffffn) return io_fail(75);
	return io_done({$: CID(Stamp), hi: Number(ns >> 32n), lo: Number(ns & 0xffffffffn)});
}
io_eff(CID(now), random_bend_clock);
