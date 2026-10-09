/* Actual CLI execution: streamed stdout is consumed and checked in RAM.
 * Child CPU includes startup/parsing/formatting/writes; wall includes the sink.
 * No startup subtraction, shell, payload files, or unchecked clock failures. */
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void die(const char *message) { perror(message); exit(1); }
static uint64_t wall_clock(void) {
	struct timespec t;
	if (clock_gettime(CLOCK_MONOTONIC, &t) || t.tv_sec < 0 || t.tv_nsec < 0 || t.tv_nsec >= 1000000000) die("clock");
	return (uint64_t)t.tv_sec * 1000000000 + (uint64_t)t.tv_nsec;
}
static uint64_t cpu_clock(struct rusage *r) {
	return ((uint64_t)r->ru_utime.tv_sec + (uint64_t)r->ru_stime.tv_sec) * 1000000000 +
		((uint64_t)r->ru_utime.tv_usec + (uint64_t)r->ru_stime.tv_usec) * 1000;
}
static void run(char **command, uint64_t oracle, uint64_t *cpu, uint64_t *wall) {
	int stream[2];
	if (pipe(stream)) die("pipe");
	uint64_t begin = wall_clock();
	pid_t child = fork();
	if (child < 0) die("fork");
	if (child == 0) {
		int null = open("/dev/null", O_RDWR);
		if (null < 0 || dup2(null, 0) < 0 || dup2(stream[1], 1) < 0 || dup2(null, 2) < 0) _exit(125);
		close(null); close(stream[0]); close(stream[1]);
		execv(command[0], command);
		_exit(126);
	}
	close(stream[1]);
	uint64_t checksum = 0;
	unsigned char buffer[65536];
	for (;;) {
		ssize_t n = read(stream[0], buffer, sizeof buffer);
		if (n < 0) { if (errno == EINTR) continue; die("read"); }
		if (!n) break;
		for (ssize_t i = 0; i < n; i++) checksum = (checksum << 7 | checksum >> 57) + buffer[i];
	}
	close(stream[0]);
	struct rusage usage;
	int status;
	while (wait4(child, &status, 0, &usage) < 0) { if (errno != EINTR) die("wait4"); }
	*wall = wall_clock() - begin; *cpu = cpu_clock(&usage);
	if (!WIFEXITED(status) || WEXITSTATUS(status) || checksum != oracle || !*cpu || !*wall) {
		fprintf(stderr, "CLI work/status/clock mismatch: status=%d actual=%" PRIu64 " expected=%" PRIu64 "\n", status, checksum, oracle);
		exit(1);
	}
}
int main(int argc, char **argv) {
#ifndef NDEBUG
	fputs("benchmark requires optimized NDEBUG build\n", stderr); return 1;
#endif
	if (argc < 5) return 1;
	char *end;
	uint64_t size = strtoull(argv[1], &end, 10); if (!size || *end) return 1;
	uint64_t oracle = strtoull(argv[2], &end, 10); if (*end) return 1;
	uint64_t cpu[7], wall[7], ignored_cpu, ignored_wall;
	for (int i = 0; i < 2; i++) run(argv + 3, oracle, &ignored_cpu, &ignored_wall);
	for (int i = 0; i < 7; i++) run(argv + 3, oracle, cpu + i, wall + i);
	printf("{\"schema\":\"performance-measurement/v1\",\"correct\":true,\"build_mode\":\"Release\",\"clock\":\"wait4 child user+system CPU; checked monotonic wall\",\"allocator_coverage\":\"bounded 64-KiB parent sink; child allocation uninstrumented\",\"includes_startup\":true,\"rows\":[{\"size\":%" PRIu64 ",\"checksum\":\"%" PRIu64 "\",\"samples\":{\"cpu_ns\":[", size, oracle);
	for (int i = 0; i < 7; i++) printf("%s%" PRIu64, i ? "," : "", cpu[i]);
	fputs("],\"wall_ns\":[", stdout);
	for (int i = 0; i < 7; i++) printf("%s%" PRIu64, i ? "," : "", wall[i]);
	puts("]}}]}"); return 0;
}
