#include <errno.h>
#include <stddef.h>
#include <sys/types.h>

/* LD_PRELOAD fault injector: an OS-policy denial must be surfaced, never
 * converted into a weak or deterministic entropy fallback. */
ssize_t getrandom(void *buffer, size_t length, unsigned int flags)
{
	(void)buffer;
	(void)length;
	(void)flags;
	errno = EPERM;
	return -1;
}
