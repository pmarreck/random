/* Benchmark-only monotonic/process-CPU clocks; the token orders measured work. */
#include <errno.h>
#include <time.h>

Term random_bend_clock_run(Env e, Term *f, IoWork *w) {
	(void)w;
	const uint32_t kind = (uint32_t)f[0];
	volatile uint32_t work_token = (uint32_t)f[1];
	(void)work_token;
	if (kind > 1) return io_fail(e, EINVAL, "invalid benchmark clock");
	struct timespec ts;
	if (clock_gettime(kind == 0 ? CLOCK_MONOTONIC : CLOCK_PROCESS_CPUTIME_ID, &ts) != 0)
		return io_fail(e, errno, NULL);
	if (ts.tv_sec < 0 || ts.tv_nsec < 0 || ts.tv_nsec >= 1000000000L ||
		(uint64_t)ts.tv_sec > (UINT64_MAX - (uint64_t)ts.tv_nsec) / UINT64_C(1000000000))
		return io_fail(e, EOVERFLOW, "benchmark clock outside u64 domain");
	const uint64_t ns = (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
	return io_done(e, io_node(e, CID(Stamp), (Term)(uint32_t)(ns >> 32), (Term)(uint32_t)ns));
}

static void __attribute__((constructor)) random_bend_clock_use(void) {
	io_eff(CID(now), random_bend_clock_run);
}
