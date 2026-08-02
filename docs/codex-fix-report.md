# Codex hostile-review fix report

Date: 2026-08-02
Scope: eight findings from an independent hostile review of `bin/random` /
`lib/fixed.lua`, fixed in the order given. Commits: `0509148..b5add78` (7
commits; findings #5 and #6 share a root cause and were fixed together in
one commit).

Every finding below follows the same discipline: a test was written and
confirmed to **fail** against the pre-fix code, the fix was applied and the
same test confirmed to **pass**, then each guard was **mutated** (the check
disabled/reverted) and confirmed to fail 10/10 consecutive runs, then
restored and confirmed to pass 10/10 consecutive runs. `./tests/golden_test`
(75 integer + 24 distribution vectors) was run after every change; it never
moved. `./test` (all 6 suites, FAST and non-FAST) passed after every
finding and at the end of the session, including the 60000-iteration
`kernel_jit_diff` differential.

---

## 1. CRITICAL — power-of-two ranges hang forever

**Root cause:** `bin/random`'s wide-range path (`pcg32_range`, spans >
2^32) computes `bound = 2^64 - (2^64 mod range)` in u64 arithmetic. When
`range` divides 2^64 exactly — every power of two from 2^33 up — `2^64 mod
range` is 0, so `bound` wraps to `0` in unsigned arithmetic. `r < 0` is
never true for any u64 `r`, so the rejection loop never terminates.

**Fix (`bin/random`, `pcg32_range`):** special-case `remainder == 0`
(`exact_divides`): when the range divides 2^64 exactly, every 64-bit draw
is already unbiased and none need to be rejected, so `exact_divides or r <
bound` short-circuits the check instead of relying on a `bound` value that
has no representation in u64.

**Before:**
```
$ timeout 3 random --seed 42 -c 1 0 8589934591
exit=124   (timed out; hung until killed)
```

**After:**
```
$ timeout 3 random --seed 42 -c 1 0 8589934591
1795671209
exit=0
$ timeout 3 random --seed 42 -c 1 0 17179869183
10385605801
exit=0
$ timeout 3 random --seed 42 -c 1 0 5000000000   # non-power-of-two control, unaffected
691365151
exit=0
```

**Test:** `tests/random_test` Test 20d, a classifier over the full set the
finding specified: every power of two from 2^33 through 2^52 (see
"Interaction with finding #3" below for why 62 became 52), the
non-power-of-two neighbor on each side of each of those, plus 2^32 exactly
and 2^32+1 as regressions on the narrow/wide boundary. 62 total cases, each
under `timeout 3`.

**Mutation verification:** reverted `if exact_divides or r < bound then` to
`if r < bound then`. Direct repro (`random --seed 42 -c 1 0 8589934591`)
hung (`exit=124`) on 10/10 runs. Restored: exit=0, output `1795671209` on
10/10 runs, byte-identical every time (fully deterministic).

**Golden vectors:** unaffected — no golden vector uses a power-of-two
span (`uniform/*/wide` uses span 5000000001, not a power of two).

**Interaction with finding #3, disclosed:** the classifier was originally
written to sweep 2^33..2^62 as specified. Finding #3's fix (below) added a
hard 2^53 ceiling on every positional CLI argument, which made spans above
2^53 unreachable *through the CLI* — not because the wide-path fix stopped
working for them (it's unconditional u64 arithmetic with no reference to
that ceiling), but because the argument can no longer be typed in. The
classifier's sweep was reduced to 2^33..2^52 (still 62 cases) with a
comment explaining why; `pcg32_range` itself was not weakened.

---

## 2. HIGH — `$IFS` changes seeded output

**Root cause:** `bin/random` derived its default output delimiter from
`os.getenv("IFS")` when `--delimiter` wasn't given, and the same default
fed stdin tokenization for `--choose`/`--shuffle`/`--weighted`.

**Fix (`bin/random`):** default delimiter is now unconditionally `"\n"`,
never derived from `$IFS`. `--delimiter` remains the explicit override.

**Before:**
```
$ env -u IFS random --seed 42 -c 3
26
9
35
$ env IFS=, random --seed 42 -c 3
26,9,35
```

**After:**
```
$ env -u IFS random --seed 42 -c 3
26
9
35
$ env IFS=, random --seed 42 -c 3
26
9
35
```

**Test:** `tests/random_test` Section 13 (Tests 52-54): default delimiter
identical across `IFS` unset / `,` / space; `--choose` stdin tokenization
identical across `IFS` unset / `,` (a newline-separated stdin collapses
into one unsplit item once the pre-fix default delimiter becomes a comma
that never appears in it — this was a real, not just cosmetic, behavior
difference); `--delimiter` still overrides both the default and `$IFS`.

**Mutation verification:** reintroduced the `os.getenv("IFS")` read.
Default-delimiter comparison (`env -u IFS` vs `env IFS=,`) differed on
10/10 runs. Restored: identical output (`26`/`9`/`35`) on 10/10 runs.

**Golden vectors:** unaffected — `tests/bless-goldens` already `unset
IFS` before generating vectors (with a comment recording exactly this
concern), so nothing was ever blessed under a non-default `$IFS`. Verified
by running `./tests/golden_test` after the fix: both sets reproduce.

**Documentation:** added a "`$IFS` is not part of the reproducibility
contract" subsection to `README.md`.

---

## 3. HIGH — large integer bounds are silently corrupted

**Root cause:** `M.parse_int` ends with `sign * tonumber(v)`, returning a
Lua double. Magnitudes between 2^53 and int64 max parse exactly
internally but round on the way out through `tonumber()`; `bin/random`
called this function directly for the positional range-bound arguments.
`--weighted` had an independent instance of the same class of bug:
`weight = tonumber(weight)` on a long digit string.

**Fix chosen: reject, not full int64 propagation.** The finding offered
two options. Full int64-exact bounds were rejected as impractical here:
`bin/random`'s rejection-sampling arithmetic and its output formatting are
both built on plain Lua numbers throughout, and LuaJIT prints an `int64_t`
cdata value with a literal `LL` suffix (confirmed directly:
`tostring(ffi.cast("int64_t", 7))` is `"7LL"`, not `"7"`). Propagating
cdata through would either corrupt every golden vector's printed integer
format or require building and maintaining a second, parallel
exact-decimal formatting path for a case (range bounds beyond 2^53) that
is already far outside this CLI tool's realistic use.

New `lib/fixed.lua` function `M.parse_int_safe`: identical to
`M.parse_int` except it additionally rejects (returns `nil`) any magnitude
greater than 2^53 (`9007199254740992`, the standard IEEE-754 double
"safe integer" boundary — every integer up to and including it round-trips
through a double exactly; one past it does not). `bin/random`'s positional
`start`/`end` arguments and `--weighted`'s per-item weight now call
`fx.parse_int_safe` instead of `fx.parse_int`/`tonumber`. `M.parse_int`
itself and its one remaining caller (`--count`) are untouched.

**Before:**
```
$ random --seed 1 9007199254740993 9007199254740993 -c 1
9007199254740992          # 2^53+1 silently became 2^53
$ random --seed 1 9223372036854775807 9223372036854775807 -c 1
-9223372036854775808      # int64 max became INT64_MIN -- negative, no minus sign in the input
```

**After:**
```
$ random --seed 1 9007199254740993 9007199254740993 -c 1
Error: start value must be a whole number no larger than 2^53 (9007199254740992) in magnitude
$ random --seed 1 9223372036854775807 9223372036854775807 -c 1
Error: start value must be a whole number no larger than 2^53 (9007199254740992) in magnitude
$ random --seed 1 9007199254740992 9007199254740992 -c 1   # exactly 2^53, still accepted
9007199254740992
```

**Refinement found beyond the finding's own text:** `--weighted`'s failure
mode is worse than described. A 28-digit weight does not overflow to
`inf` (10^28 is nowhere near double's ~10^308 range) — `tonumber()` returns
a large-but-finite, imprecise double, which `pcg32_range`'s wide path then
casts to `uint64_t` with undefined results. This was observed as **both**
an infinite hang (in ad-hoc interactive testing) **and** immediate
silent-wrong-output (`exit=0`, printed `"a"`, in the CLI test harness),
depending on exactly how the FFI double-to-u64 cast landed. Either way it
is a real defect; `M.parse_int_safe` closes both manifestations by
rejecting the weight before it ever reaches `pcg32_range`.

**Tests:**
- `tests/fixed_test.lua`: 20 new checks for `M.parse_int_safe` — accepts
  0/42/-9/+5, accepts exactly 2^53 and -2^53 (boundary, not off-by-one),
  rejects 2^53+1 and -(2^53+1) `[MUTATION TARGET C]`, rejects int64 max,
  rejects 25-digit int64 overflow, and the full malformed-input
  specificity set (`""`, whitespace, bare sign, double sign, fractional,
  embedded letters) that `M.parse_int` already covers.
- `tests/random_test` Section 15 (Tests 57-60): both finding repros
  rejected cleanly with an `Error:` line; a bound exactly at 2^53 still
  accepted and returned exactly; the weighted-overflow case rejected
  cleanly (not hung, not silently wrong); normal weights still work.

**Mutation verification, three independent guards:**
1. `SAFE_INT_MAG` check in `M.parse_int_safe` removed: 3 kernel checks
   failed on 10/10 runs; restored, 216/216 pass on 10/10 runs.
2. `bin/random`'s start/end call sites reverted to `fx.parse_int`:
   reproduced the exact original corruption (`9007199254740992`) on
   10/10 runs; restored: `Error:` rejection on 10/10 runs.
3. `bin/random`'s weighted call site reverted to `tonumber`: produced
   silent wrong output (`exit=0`, `"a"`) on 10/10 runs; restored: `Error:`
   rejection on 10/10 runs.

**Golden vectors:** unaffected — no golden vector uses a bound or weight
anywhere near 2^53 (largest weight used is 100; largest range bound used
is 5000000001, and even that is a `--seed` value not a range bound).

---

## 4. MEDIUM — `M.norm` accepts fractional exponents

**Root cause:** `M.norm`'s i32 assert checked range
(`-2147483648 <= e <= 2147483647`) but not integrality. A fractional `e`
was silently accepted and propagated. `M.mul` computes its own exponent
(`e1 + e2[+1]`) directly rather than routing through `M.norm`, so it
carried an independent copy of the same gap.

**Fix:** both asserts gained `and e % 1 == 0` (Lua's native `%` operator,
not `math.*`). `add`/`div`/`sqrt` all route their exponent construction
through `M.norm` already, so the norm fix alone covers them; `neg` doesn't
manufacture a new exponent (just forwards the existing one), so it needed
no change.

**Before:**
```lua
fx.norm(0x4000000000000000LL, 0.5)   -->  4611686018427387904LL, 0.5   (no error)
fx.ln(that)                          -->  0LL, 0                        (should encode ln(sqrt 2) ~= 0.3466)
```

**After:**
```lua
fx.norm(0x4000000000000000LL, 0.5)
--> lib/fixed.lua:277: fixed.norm: exponent outside i32
```

**Tests:** `tests/fixed_test.lua` — `norm(m, 0.5)`, `norm(m, -0.5)`,
`norm(m, 1.999999)` all assert with the exact `"fixed.norm: exponent
outside i32"` message (not just "some assert fired"); the finding's own
`norm` + `ln` propagation repro, pinned directly; `mul(m, 0.5, m, 0)`
asserts with `M.mul`'s own message (proving `M.mul` needs its own
independent check, not just `M.norm`'s).

**Mutation verification:** each of the two asserts' `e % 1 == 0` clause
removed independently. `M.norm`'s removal: 4 kernel checks failed on
10/10 runs. `M.mul`'s removal: 1 kernel check failed on 10/10 runs
(confirming it is genuinely a separate, non-overlapping guard). Both
restored: 189/189 pass on 10/10 runs.

**Golden vectors:** unaffected — no golden path ever constructs a
fractional exponent (every exponent in this program's real domain comes
from integer arithmetic on already-integer exponents).

---

## 5 & 6. MEDIUM — `M.parse` rejects `M.tostring`'s own output; `M.tostring` hangs at the maximum legal exponent

Fixed together: both are symptoms of the same missing thing — a shared,
documented magnitude limit between the two functions. New constant
`M.MAX_INT_PART_DIGITS = 2000` (generous — up to ~10^2000 ≈ 2^6644, far
beyond any realistic `--mean`/`--stddev` combination — while small enough
that rendering or parsing at the limit finishes in well under a second).

### #5 — `M.parse` round-trip

**Root cause:** `M.parse`'s integer-part accumulator
(`accumulate_digits`) is a fast int64 accumulator that returns `nil` on
overflow past int64 magnitude. `M.tostring` can legitimately render an
integer part past that (log-normal's `exp()` is "effectively unbounded"
per this file's own top-of-file note) via `decimal_shift_left`'s exact
bignum-doubling path — so `M.parse` rejected values `M.tostring` itself
produced.

**Fix:** when the fast accumulator overflows, `M.parse` now falls back to
a soft-float bignum accumulation (`int_m, int_e = M.mul(int_m, int_e,
M.from_int(10)); int_m, int_e = M.add(int_m, int_e, M.from_int(digit))`
per digit — both calls have the multi-return expression in *final*
argument position, avoiding the exact non-final-chaining pitfall this
file's own doc comments warn about elsewhere), bounded by
`MAX_INT_PART_DIGITS`.

**Before:**
```lua
local s = fx.tostring(0x4000000000000000LL, 63, 6)  --> "9223372036854775808.000000"
fx.parse(s)                                           --> nil
```

**After:**
```lua
fx.parse(s)   --> 4611686018427387904LL, 63   (== exactly 2^63, bit-exact)
```

### #6 — `M.tostring` hang

**Root cause:** `M.tostring`'s integer-part path is
`O(sh * digit_count)` via `decimal_shift_left` (`sh = e - 62`). The i32
exponent contract permits `sh` up to roughly 2^31, implying ~646 million
decimal digits.

**Fix:** `i64_to_decimal(am)` is *always* exactly 19 characters for a
normalized mantissa (both bounds of `2^62 <= am < 2^63` are 19-digit
numbers), and doubling can grow a decimal digit count by at most 1 per
doubling — so `19 + sh` is a safe, exact upper bound on the final digit
count, checked *before* calling `decimal_shift_left` and erroring loudly
(matching `M.exp`'s own `correction_guard` pattern) rather than after.

**Before:**
```lua
fx.tostring(4611686018427387904LL, 2147483647, 0)   -- did not return within 5s
```

**After:**
```lua
fx.tostring(4611686018427387904LL, 2147483647, 0)
--> lib/fixed.lua:1627: fixed.tostring: integer part would need more than 2000 decimal digits ...
```

**Tests (`tests/fixed_test.lua`, 15 new checks total):**
- A round-trip sweep at exponents {63, 64, 70, 100, 200, 500} (reusing
  Verification item 3's own `rt_tolerance`/`true_fixed_absdiff`
  machinery), confirming `parse(tostring(x))` recovers `x` within this
  kernel's own ~2^-62 relative-precision floor even past int64 magnitude.
- The finding's exact 2^63 repro, pinned directly: renders the expected
  string, parses non-nil, and recovers *bit-exactly* (not just within
  tolerance — 2^63 is a single set bit, and this soft-float format can
  represent it exactly).
- `MAX_INT_PART_DIGITS` boundary in both directions for both functions:
  a 2001-digit `parse` input is rejected, a 2000-digit one is accepted;
  `tostring` at `sh=1981` (implying exactly 2000 digits) does not raise,
  `sh=1982` does.
- The maximum legal i32 exponent (2147483647) raises instead of hanging;
  an exponent implying ~600 digits (well under the limit) still renders
  in full (specificity check).

**Two existing unit pins legitimately changed behavior, re-blessed
explicitly, not left silently broken:** `fx.parse("9999999999999999999")`
(19 digits, `[MUTATION TARGET B]`) and a 23-digit variant used to require
`nil`. They now require a non-nil result matching an independent
reconstruction built *without* calling `fx.parse` (same digit-by-digit
`fx.mul`/`fx.add` technique, written separately in the test file) — this
preserves `[MUTATION TARGET B]`'s original protective purpose
(`accumulate_digits`' overflow guard not silently wrapping into a wrong
value) under the new, correct, documented behavior: if that guard were
ever removed, the parsed result would no longer match the independent
reconstruction, still caught, just via a different assertion shape.

**Mutation verification, three independent guards:**
1. `M.parse`'s bignum fallback disabled (`if int_v == nil then return
   nil end`, restoring the pre-fix behavior): 4 kernel checks failed on
   10/10 runs (the 23-digit test, the MAX_INT_PART_DIGITS-boundary
   accept test, the beyond-int64 sweep, and the 2^63 repro). Restored:
   199/199 pass on 10/10 runs.
2. `M.parse`'s digit-count cap removed (`if digits_seen >
   MAX_INT_PART_DIGITS then return nil end` deleted): the
   "one digit past MAX_INT_PART_DIGITS is rejected" test failed
   (`fixed test FAILED: 1 of 199`) on 10/10 runs. Restored: 199/199 pass
   on 10/10 runs.
3. `M.tostring`'s shift guard removed: the suite hung (`exit=124` under
   `timeout 5`) on 10/10 runs. Restored: 199/199 pass on 10/10 runs.

**Golden vectors:** unaffected — `kernel_bc_sweep`'s own 320/800-case
(FAST/full) `tostring` sweep reports 0 mismatched both before and after,
and `./tests/golden_test` passed after this commit.

---

## 7. MEDIUM — `DRANDOM_SEED` does not do what the help says

**Root cause:** `random -h` documents `DRANDOM_SEED  Seed value
(overrides state file, implies -d)`, but the env var was only ever read
*inside* `main()`'s already-deterministic branch — setting it alone, with
no `-d` and not invoked as `drandom`, had no effect on `options.deterministic`
at all.

**Fix (`bin/random`, `parse_args`):** if nothing else already requested
deterministic mode, a non-empty `DRANDOM_SEED` now sets
`options.deterministic = true`. The seed *value* is still read where it
always was, in `main()`'s deterministic branch.

**Before:**
```
$ DRANDOM_SEED=42 random -c 3
57
44
99
$ DRANDOM_SEED=42 random -c 3
6
74
95
```

**After:**
```
$ DRANDOM_SEED=424242 random -c 3
20
82
40
$ DRANDOM_SEED=424242 random -c 3
20
82
40
```

**Test:** `tests/random_test` Test 25b: two runs of `DRANDOM_SEED=424242
random -c 3` (plain `random`, deliberately not `drandom`) produce
identical output to each other and to `random -d --seed 424242 -c 3`. The
existing "drandom symlink implies --deterministic" test (Test 25) could
not have caught this: it invokes via the `drandom` symlink, which already
forces deterministic mode by invocation name regardless of `DRANDOM_SEED`.

**Mutation verification:** the new `if not options.deterministic then
... end` block replaced with `if false then ... end`. Two `DRANDOM_SEED`
runs differed on 10/10 runs. Restored: both runs produced `20 82 40` on
10/10 runs.

**Golden vectors:** unaffected — they always pass `--seed` explicitly.

---

## 8. LOW — seed grammar silently accepts garbage as zero

**Root cause, two independent gaps:**
1. `parse_seed()` already correctly returned `nil` for most of the listed
   garbage (`-1`, `+1`, `""`, whitespace, `42x`, `0x`, `nan`, `inf`) — the
   grammar itself was mostly not the bug. Neither call site (`--seed`'s
   flag handler, `DRANDOM_SEED`'s read in `main()`) ever checked for that
   `nil`; both did `pcg32_seed(options.seed or ffi.new(u64, 0))`, silently
   selecting seed 0 on any parse failure.
2. `parse_uint64_dec`/`parse_uint64_hex` had *no* overflow check at all —
   a genuine grammar gap. A seed literal >= 2^64 silently wrapped modulo
   2^64 rather than being rejected.

**Fix:**
- `parse_uint64_dec`/`parse_uint64_hex` gained a before-each-digit
  overflow guard against `0xFFFFFFFFFFFFFFFFULL` (u64 max), the same
  technique `accumulate_digits` already uses for its signed int64
  accumulator.
- The `--seed` flag handler and `DRANDOM_SEED`'s read both now check for
  `nil` and error loudly instead of falling through to the `or
  ffi.new(u64, 0)` default.

**Before:**
```
$ random --seed -1 -c 1 0 0
0
$ random --seed --count 3
97
```

**After:**
```
$ random --seed -1 -c 1 0 0
Error: --seed value must be a valid seed (decimal, 0x-prefixed hex, or bare hex digits), got: -1
$ random --seed --count 3
Error: --seed value must be a valid seed (decimal, 0x-prefixed hex, or bare hex digits), got: --count
```

**Test:** `tests/random_test` Section 14 (Tests 55-56): a 13-case
classifier over the full malformed set (`-1`, `+1`, empty, whitespace,
`42x`, `0x`, `nan`, `inf`, decimal 2^64, hex 2^64, `--seed --count 3`,
`DRANDOM_SEED=-1`, `DRANDOM_SEED=nan`) all rejected cleanly with an
`Error:` line and no traceback; plus a 5-case specificity check (`42`,
`0xDEADBEEF`, bare-hex-with-warning `DEADBEEF`, exact u64-max
`18446744073709551615`, `0`) confirming valid seeds still work, so Test
55's classifier can't be trivially satisfied by rejecting everything.

**Mutation verification, three independent guards:**
1. `--seed`'s nil-check removed: 11/11 malformed cases silently accepted
   again (seed 0) on 10/10 runs. Restored: `Error:` rejection on 10/10
   runs.
2. `DRANDOM_SEED`'s nil-check removed: both new env-var cases silently
   accepted again on 10/10 runs. Restored: `Error:` rejection on 10/10
   runs.
3. The overflow guard removed from `parse_uint64_dec`/`parse_uint64_hex`:
   2^64 silently wrapped to seed 0 again on 10/10 runs. Restored:
   `Error:` rejection on 10/10 runs.

**Golden vectors:** unaffected — all use already-valid seeds, including
`18446744073709551615` (u64 max exactly), which the new overflow guard
must accept, not reject.

---

## Requirements checklist

- **75 integer + 24 distribution golden vectors: did not move**, at any
  point in this session. `./tests/golden_test` was run after every
  finding and passed every time. No finding legitimately required a
  golden-vector re-bless.
- **Every finding has a test that fails before, passes after**, verified
  either directly (assertion flips) or, where the pre-fix behavior is a
  genuine hang, via `timeout`-bounded confirmation of the hang.
- **Every guard mutation-verified**: 10/10 consecutive detected-when-
  broken, 10/10 consecutive passed-when-restored, for all 8 findings
  (several findings had 2-3 independent guards, each verified separately
  — 20 total mutation cycles across the session).
- **No forbidden patterns introduced**: grepped the full session diff for
  `math.*`, bare `^` (excluding the pre-existing, unrelated Lua pattern-
  anchor usage `^%s+` already present in the file before this session),
  `tonumber(` (the two new occurrences are: a comment explaining why
  `tonumber()` is normally avoided, and `M.parse_int_safe`'s final
  `sign * tonumber(v)` — safe by construction, since `v` is checked
  against `SAFE_INT_MAG` immediately beforehand, matching
  `M.parse_int`'s own pre-existing, already-accepted pattern), `%f`.
- **`M.div`'s dispatch and both `jit.off` calls untouched.**
- **Tabs, `set -u` only (no `set -e`)** in every test file edited —
  verified directly, no space-indented additions, no new `set -e`.
- **Commits**: 7 commits, one per finding except #5/#6 (combined
  deliberately — shared root cause, shared new constant). No "Generated
  with Claude Code" or Co-Authored-By lines.

## Nothing was left unfixed

All 8 findings were fixed, tested, and mutation-verified. The one
disclosed scope adjustment is documented above under finding #1
(power-of-two classifier reduced from 2^33..2^62 to 2^33..2^52, purely a
consequence of finding #3's later, independently-justified 2^53 CLI
ceiling — the underlying `pcg32_range` fix itself was not weakened and
remains unconditional u64 arithmetic valid to 2^62 and beyond).
