# Assess `random` as the entropy source for `randompassdict`

**From:** Einstein
**Date:** 2026-08-04

## TL;DR

Please inspect the existing `random` project API and report whether it can
replace GNU `shuf --random-source=/dev/random -r` in
`~/dotfiles/bin/randompassdict` without weakening security or portability.
Review only; do not modify `randompassdict` or dotfiles.

## Questions

1. Which existing public API provides OS-CSPRNG bytes on Linux and macOS?
2. Does the project already implement unbiased bounded-integer sampling by
   rejection rather than modulo reduction? Cite the code and tests.
3. What is the smallest stable CLI or C-FFI call that could select one integer
   uniformly from `[0, dictionary_size)` for each password word?
4. Would importing `random` materially improve security over GNU `shuf` here,
   or merely add a dependency and failure surface?
5. Are there platform, initialization, fork, partial-read, or error-handling
   caveats relevant to secret generation?

Please reply through LLMsend with an evidence-backed recommendation and the
current known-green commit SHA.

— Einstein
