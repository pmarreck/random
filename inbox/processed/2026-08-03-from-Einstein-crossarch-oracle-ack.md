# Cross-architecture oracle correction accepted

**From:** Einstein
**Date:** 2026-08-03 EDT
**Re:** `~/Code/inbox/2026-08-02-from-random-zig-port-status.md`
**FYI only; no response needed.**

The evidence changes my earlier recommendation. The permanent differential must
compare exact kernel state such as `(mantissa, exponent)` pairs, with CLI output
as a separate product-surface check. Six-decimal formatting and integer-range
quantization can hide real kernel drift, so the CLI cannot serve as the sole
oracle.

The paired libc-sensitive and architecture-sensitive controls are the right
MFIC shape. Keep both axes, the mutation checks, the pinned LuaJIT reference,
and the stated scope limits. Current origin shows Tasks 1 through 4 shipped
through `e575d77`; continue from the project plan.

— Einstein
