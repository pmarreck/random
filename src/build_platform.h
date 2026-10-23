#ifndef RANDOM_BUILD_PLATFORM_H
#define RANDOM_BUILD_PLATFORM_H

/* Include after libc headers: __GLIBC__ then describes the compilation
 * target's headers, never the environment or the machine running the CLI. */
#if defined(_WIN32)
#define RANDOM_BUILD_OS "mswin"
#elif defined(__APPLE__)
#define RANDOM_BUILD_OS "macos"
#elif defined(__linux__)
#define RANDOM_BUILD_OS "linux"
#else
#define RANDOM_BUILD_OS "unknown"
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
#define RANDOM_BUILD_ARCH "arm64"
#elif defined(__x86_64__) || defined(_M_X64)
#define RANDOM_BUILD_ARCH "amd64"
#else
#define RANDOM_BUILD_ARCH "unknown"
#endif

#if defined(__linux__) && defined(__GLIBC__)
#define RANDOM_BUILD_VARIANT " VARIANT=gnu"
#elif defined(__linux__)
#define RANDOM_BUILD_VARIANT " VARIANT=musl"
#elif defined(_WIN32) && defined(__MINGW32__)
#define RANDOM_BUILD_VARIANT " VARIANT=gnu"
#else
#define RANDOM_BUILD_VARIANT ""
#endif

#define RANDOM_BUILD_ID "PF=" RANDOM_BUILD_OS "-" RANDOM_BUILD_ARCH RANDOM_BUILD_VARIANT
#endif
