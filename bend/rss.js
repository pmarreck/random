function random_bend_rss() {
	if (process.platform !== "linux") return io_fail(95);
	const text = require("node:fs").readFileSync("/proc/self/status", "utf8");
	const match = /^VmHWM:\s+(\d+) kB$/m.exec(text);
	if (!match) return io_fail(5);
	const bytes = BigInt(match[1]) * 1024n;
	if (bytes <= 0n || bytes > 0xffffffffffffffffn) return io_fail(75);
	return io_done({$: CID(Stamp), hi: Number(bytes >> 32n), lo: Number(bytes & 0xffffffffn)});
}
io_eff(CID(peak_rss), random_bend_rss);
