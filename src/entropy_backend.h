#ifndef RANDOMZ_ENTROPY_BACKEND_H
#define RANDOMZ_ENTROPY_BACKEND_H

/* Exactly one production CSPRNG backend is selected. These are numeric feature
 * values and are always tested by value, never merely by macro presence. */
#if defined(_WIN32)
#define RANDOMZ_ENTROPY_BACKEND_BCRYPT 1
#elif defined(__linux__) || defined(__sun) || defined(__illumos__)
#define RANDOMZ_ENTROPY_BACKEND_GETRANDOM 1
#elif defined(__APPLE__) || defined(__OpenBSD__) || defined(__FreeBSD__) || \
	defined(__NetBSD__) || defined(__DragonFly__)
#define RANDOMZ_ENTROPY_BACKEND_ARC4RANDOM 1
#elif defined(__wasi__)
#error "the C CLI is not the WASM frontend; build randomz-wasi.wasm instead"
#else
#define RANDOMZ_ENTROPY_BACKEND_GETENTROPY 1
#endif

#ifndef RANDOMZ_ENTROPY_BACKEND_BCRYPT
#define RANDOMZ_ENTROPY_BACKEND_BCRYPT 0
#endif
#ifndef RANDOMZ_ENTROPY_BACKEND_GETRANDOM
#define RANDOMZ_ENTROPY_BACKEND_GETRANDOM 0
#endif
#ifndef RANDOMZ_ENTROPY_BACKEND_ARC4RANDOM
#define RANDOMZ_ENTROPY_BACKEND_ARC4RANDOM 0
#endif
#ifndef RANDOMZ_ENTROPY_BACKEND_GETENTROPY
#define RANDOMZ_ENTROPY_BACKEND_GETENTROPY 0
#endif

#define RANDOMZ_ENTROPY_BACKEND_COUNT ( \
	RANDOMZ_ENTROPY_BACKEND_BCRYPT + \
	RANDOMZ_ENTROPY_BACKEND_GETRANDOM + \
	RANDOMZ_ENTROPY_BACKEND_ARC4RANDOM + \
	RANDOMZ_ENTROPY_BACKEND_GETENTROPY)

#if RANDOMZ_ENTROPY_BACKEND_COUNT != 1
#error "randomz requires exactly one OS CSPRNG backend"
#endif

#if RANDOMZ_ENTROPY_BACKEND_BCRYPT
#define RANDOMZ_ENTROPY_BACKEND_NAME "BCryptGenRandom"
#elif RANDOMZ_ENTROPY_BACKEND_GETRANDOM
#define RANDOMZ_ENTROPY_BACKEND_NAME "getrandom"
#elif RANDOMZ_ENTROPY_BACKEND_ARC4RANDOM
#define RANDOMZ_ENTROPY_BACKEND_NAME "arc4random_buf"
#else
#define RANDOMZ_ENTROPY_BACKEND_NAME "getentropy"
#endif

#endif
