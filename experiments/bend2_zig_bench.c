/* Common public C ABI probe. Backend bindings select the actual library;
 * no alternative generator or sampler lives here. */
#include "randomz.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#ifndef RANDOM_BENCH_SOURCE
#define RANDOM_BENCH_SOURCE "Zig buffered C ABI"
#endif
#ifndef RANDOM_BENCH_BUILD_MODE
#define RANDOM_BENCH_BUILD_MODE "ReleaseFast-C-driver-O3"
#endif

static randomz_fixed zero, one, rate, lambda, mean, stddev, shape, quarter, sparse;

static void require(int ok, const char *message) {
	if (!ok) { fprintf(stderr, "%s\n", message); exit(1); }
}
static uint64_t clock_ns(clockid_t kind) {
	struct timespec ts;
	require(clock_gettime(kind, &ts) == 0, "clock failed");
	require(ts.tv_sec >= 0 && ts.tv_nsec >= 0 && ts.tv_nsec < 1000000000L, "invalid clock");
	require((uint64_t)ts.tv_sec <= (UINT64_MAX-(uint64_t)ts.tv_nsec)/UINT64_C(1000000000), "clock overflow");
	return (uint64_t)ts.tv_sec*UINT64_C(1000000000)+(uint64_t)ts.tv_nsec;
}
static uint32_t mix(uint32_t h, uint32_t value) { return ((h<<5)|(h>>27))^value; }
static int fill(void *state, uint8_t *out, size_t n) {
	return randomz_buffered_drbg_fill(state, out, n);
}
static uint32_t integer_hash(uint32_t hash, int64_t value) {
	return mix(mix(hash, (uint32_t)(uint64_t)value), (uint32_t)((uint64_t)value >> 32));
}
static uint32_t work(randomz_buffered_drbg *source, unsigned kind, size_t n, uint8_t *out, uint32_t hash) {
	if (kind == 0) {
		require(fill(source, out, n) == RANDOMZ_OK, "byte generation failed");
		for (size_t i=0;i<n;i++) hash=mix(hash,out[i]);
	} else if (kind <= 2) {
		const int64_t end = kind == 1 ? 6 : INT64_C(4503599627370496);
		for (size_t i=0;i<n;i++) {
			int64_t value;
			require(randomz_range(fill,source,1,end,&value)==RANDOMZ_OK,"range failed");
			hash=mix(mix(hash,(uint32_t)(uint64_t)value),(uint32_t)((uint64_t)value>>32));
		}
	} else if (kind == 11) {
		int64_t values[96];
		for (size_t done = 0; done < n;) {
			size_t count = n - done < 96 ? n - done : 96, written = 0;
			require(randomz_normal_int_batch(fill, source, 0, 255, values, count, &written, RANDOMZ_BATCH_AUTO) == RANDOMZ_OK && written == count, "batch failed");
			for (size_t i = 0; i < count; i++) hash = integer_hash(hash, values[i]);
			done += count;
		}
	} else {
		for (size_t i = 0; i < n; i++) {
			randomz_fixed value;
			int64_t integer;
			int status;
			switch (kind) {
			case 3: status = randomz_normal(fill, source, zero, one, &value); break;
			case 4: status = randomz_normal_int(fill, source, 0, 255, &integer); break;
			case 5: status = randomz_exponential(fill, source, rate, &value); break;
			case 6: status = randomz_poisson(fill, source, lambda, &integer); break;
			case 7: status = randomz_log_normal(fill, source, mean, stddev, &value); break;
			case 8: status = randomz_beta(fill, source, one, shape, &value); break;
			default: {
				uint8_t encoded[512]; size_t written = 0;
				status = randomz_geometric(fill, source, kind == 9 ? quarter : sparse, encoded, sizeof encoded, &written);
				require(status == RANDOMZ_OK, "geometric failed");
				for (size_t j = 0; j < written; j++) hash = mix(hash, encoded[j]);
				continue;
			}}
			require(status == RANDOMZ_OK, "sampler failed");
			if (kind == 4 || kind == 6) hash = integer_hash(hash, integer);
			else hash = mix(integer_hash(hash, value.m), (uint32_t)value.e);
		}
	}
	return hash;
}
static uint32_t batch(randomz_buffered_drbg *source, unsigned kind, size_t n, uint8_t *out, uint32_t repeats) {
	require(randomz_buffered_drbg_seek(source,0)==RANDOMZ_OK,"seek failed");
	uint32_t hash=0;
	for(uint32_t i=0;i<repeats;i++) hash=work(source,kind,n,out,hash);
	return hash;
}
static uint32_t number(const char *text) {
	char *end;
	require(text[0]>='0' && text[0]<='9',"invalid number");
	unsigned long long n=strtoull(text,&end,10);
	require(*end=='\0' && n<=UINT32_MAX,"invalid number");
	return (uint32_t)n;
}
static uint64_t post_exec_rss(void) {
	FILE *status=fopen("/proc/self/status","r");require(status!=NULL,"post-exec RSS unavailable");
	char line[256];unsigned long long kib=0;int found=0;
	while(fgets(line,sizeof(line),status)) {
		if(sscanf(line,"VmHWM: %llu kB",&kib)==1) {found=1;break;}
	}
	const int bad=ferror(status);fclose(status);
	require(!bad && found && kib>0 && kib<=UINT64_MAX/1024,"invalid post-exec RSS");
	return (uint64_t)kib*1024;
}
int main(int argc,char **argv) {
#ifndef __OPTIMIZE__
	require(0,"benchmark requires optimized release");
#endif
	require(argc==8,"kind size repeats batch-checksum first-checksum warm-checksum seed required");
	const uint32_t kind=number(argv[1]),n=number(argv[2]),repeats=number(argv[3]);
	const int oracle=strcmp(argv[4],"-")==0;
	const uint32_t expected=oracle?0:number(argv[4]),first=number(argv[5]),warm=number(argv[6]),seed=number(argv[7]);
	require(kind<=11 && n>=1 && n<=8192 && repeats>=1 && repeats<=1000000,"invalid arguments");
	if (kind >= 3) {
		zero = randomz_fixed_from_int(0); one = randomz_fixed_from_int(1);
		rate = randomz_fixed_from_int(4); lambda = randomz_fixed_from_int(5); shape = randomz_fixed_from_int(3);
		require(randomz_fixed_parse("-0.25", 5, &mean) == RANDOMZ_OK, "mean parse failed");
		require(randomz_fixed_parse("1.75", 4, &stddev) == RANDOMZ_OK, "stddev parse failed");
		quarter = (randomz_fixed){INT64_C(4611686018427387904), -2};
		sparse = (randomz_fixed){INT64_C(4611686018427387904), -100};
	}
	uint8_t material[32]={0};
	for(unsigned i=0;i<4;i++) material[31-i]=(uint8_t)(seed>>(i*8));
	randomz_buffered_drbg source;
	require(randomz_buffered_drbg_init(&source,material)==RANDOMZ_OK,"init failed");
	uint8_t *out=kind==0 ? malloc(n) : NULL;
	require(kind!=0 || out!=NULL,"output allocation failed");
	if(oracle) {
		uint32_t hash=batch(&source,kind,n,out,repeats);uint8_t key[32];uint64_t pos;
		require(randomz_buffered_drbg_get_state(&source,key,&pos)==RANDOMZ_OK,"state unavailable");
		printf("{\"hash\":%u,\"position\":\"%llu\"}\n",hash,(unsigned long long)pos);
		free(out);randomz_buffered_drbg_zeroize(&source);return 0;
	}
	require(batch(&source,kind,n,out,1)==first,"incorrect first work");
	puts("READY"); fflush(stdout);
	require(batch(&source,kind,n,out,3)==warm,"incorrect warmup");
	uint64_t cpu[7],wall[7];
	for(unsigned sample=0;sample<7;sample++) {
		const uint64_t w0=clock_ns(CLOCK_MONOTONIC),c0=clock_ns(CLOCK_PROCESS_CPUTIME_ID);
		uint32_t result=batch(&source,kind,n,out,repeats);
		volatile uint32_t token=result; (void)token;
		const uint64_t c1=clock_ns(CLOCK_PROCESS_CPUTIME_ID),w1=clock_ns(CLOCK_MONOTONIC);
		require(result==expected,"incorrect timed work");
		require(c1>c0 && w1>w0,"nonpositive clock interval");
		cpu[sample]=(c1-c0)/repeats;wall[sample]=(w1-w0)/repeats;
		require(cpu[sample]>0 && wall[sample]>0,"zero normalized sample");
	}
	const uint64_t rss=post_exec_rss();
	uint8_t final_key[32]; uint64_t position;
	require(randomz_buffered_drbg_get_state(&source,final_key,&position)==RANDOMZ_OK,"final state unavailable");
	printf("{\"schema\":\"performance-measurement/v1\",\"correct\":true,\"build_mode\":\"optimized\",\"backend_build_mode\":\"%s\",\"allocator_coverage\":\"probe output malloc only; library/runtime allocations uninstrumented; RSS supplemental\",\"source_backend\":\"%s\",\"rss_method\":\"Linux /proc/self/status VmHWM; supplemental approximate post-exec high water\",\"output_requested_bytes\":%u,\"state_bytes\":%zu,\"iterations\":%u,\"position\":\"%llu\",\"peak_rss_bytes\":%llu,\"rows\":[{\"size\":%u,\"samples\":{\"cpu_ns\":[",RANDOM_BENCH_BUILD_MODE,RANDOM_BENCH_SOURCE,kind==0?n:0,sizeof(source),repeats,(unsigned long long)position,(unsigned long long)rss,n);
	for(unsigned i=0;i<7;i++) printf("%s%llu",i?",":"",(unsigned long long)cpu[i]);
	fputs("],\"wall_ns\":[",stdout);
	for(unsigned i=0;i<7;i++) printf("%s%llu",i?",":"",(unsigned long long)wall[i]);
	puts("]}}]}");
	free(out);randomz_buffered_drbg_zeroize(&source);
	return 0;
}
