#ifndef __linux__
#define __linux__ 1
#endif
#define RANDOMZ_ENTROPY_BACKEND_BCRYPT 0
#define RANDOMZ_ENTROPY_BACKEND_ARC4RANDOM 0
#define RANDOMZ_ENTROPY_BACKEND_GETENTROPY 0
#include "entropy_backend.h"

/* Regression for the exact presence-vs-truth bug class that made a disabled
 * Coldcard hardware RNG select a deterministic fallback.  Defined-as-zero
 * backend flags must remain false; only the Linux selector evaluates true. */
#if RANDOMZ_ENTROPY_BACKEND_BCRYPT
#error "a defined-as-zero BCrypt flag evaluated true"
#endif
#if RANDOMZ_ENTROPY_BACKEND_ARC4RANDOM
#error "a defined-as-zero arc4random flag evaluated true"
#endif
#if RANDOMZ_ENTROPY_BACKEND_GETENTROPY
#error "a defined-as-zero getentropy flag evaluated true"
#endif
#if !RANDOMZ_ENTROPY_BACKEND_GETRANDOM
#error "the Linux getrandom selector did not evaluate true"
#endif

int main(void)
{
	return RANDOMZ_ENTROPY_BACKEND_COUNT == 1 ? 0 : 1;
}
