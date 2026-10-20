/* Supplemental process high-water RSS, not live allocations or a leak proof. */
#include <errno.h>
#include <stdio.h>

Term random_bend_rss_run(Env e, Term *f, IoWork *w) {
	(void)f;
	(void)w;
#if defined(__linux__)
	FILE *status = fopen("/proc/self/status", "r");
	if (!status) return io_fail(e, errno, NULL);
	char line[256]; unsigned long long kib = 0; int found = 0;
	while (fgets(line, sizeof(line), status)) {
		if (sscanf(line, "VmHWM: %llu kB", &kib) == 1) { found = 1; break; }
	}
	const int bad = ferror(status); fclose(status);
	if (bad || !found || !kib) return io_fail(e, EIO, "post-exec RSS unavailable");
	if (kib > UINT64_MAX / 1024) return io_fail(e, EOVERFLOW, "process RSS overflow");
	const uint64_t bytes = (uint64_t)kib * 1024;
	return io_done(e, io_node(e, CID(Stamp), (Term)(uint32_t)(bytes >> 32), (Term)(uint32_t)bytes));
#else
	return io_fail(e, ENOTSUP, "post-exec RSS probe currently requires Linux");
#endif
}

static void __attribute__((constructor)) random_bend_rss_use(void) {
	io_eff(CID(peak_rss), random_bend_rss_run);
}
