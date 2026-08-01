# Deterministic Numeric Kernel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `bin/random` produce bit-identical seeded streams on every platform by replacing all libm floating-point math with an integer-only normalized soft-float kernel.

**Architecture:** A new `lib/fixed.lua` implements a software float (`value = m · 2^(e−62)`, `|m| ∈ [2^62, 2^63)`) using only 64-bit integer operations, plus `ln`/`exp`/`cos`/`sqrt`/`pow` built on it. `bin/random` converts its distributions to call that kernel, and closes the two remaining float boundaries (decimal parsing and decimal formatting). The LuaJIT implementation stays in place permanently as the differential oracle for the later Zig port.

**Tech Stack:** LuaJIT 2.1 (FFI + `bit`), bash test harness, `bc` (arbitrary-precision, used as an independent oracle), `xxd`, `awk`.

## Global Constraints

- **Spec:** `docs/specs/2026-07-31-deterministic-fixed-point-rng-design.md`. Read it before Task 1.
- **No floating point on any deterministic path.** No `tonumber` on numeric input, no `math.*`, no `string.format("%f"/"%.6f"/"%g")`, no `^` operator (in LuaJIT `^` is floating-point exponentiation even on integer cdata — this already caused one bug during design).
- **Rounding is truncation toward zero, everywhere, unconditionally.** No round-to-nearest, no tie-breaking rule.
- **Mantissa invariant:** every nonzero soft-float satisfies `2^62 ≤ |m| < 2^63`. Zero is `m = 0, e = 0`.
- **Never use `set -euo pipefail` in test scripts.** Use `set -u` alone. `set -e` aborts on the non-zero exits that error-path tests deliberately produce.
- **Tabs, not spaces**, in Lua and bash. Match surrounding style.
- **Lua expands multiple returns only in the FINAL argument position.** Soft-floats
  are `(m, e)` pairs, so this is a live footgun on nearly every line:
  - `fx.div(fx.from_int(1), fx.from_int(2))` passes **three** args, not four. The
    first `from_int` is truncated to its first value. Silent, and produces
    garbage rather than an error.
  - `fx.mul(am, ae, fx.from_int(4))` is **correct** — the call is in final
    position, so both returns expand.
  - When a constructed value is not last, bind it first:
    `local om, oe = fx.from_int(1); fx.div(om, oe, dm, de)`.
  Assume any nested constructor that is not the last argument is a bug.
- **Tests must run clean.** Expected stderr is captured and asserted on, never printed.
- **Never commit red.** `./test` must pass before every commit.
- `bin/random` must remain runnable with nothing but `luajit` on PATH. No compiled artifacts, no build step.
- Commit messages: no "Generated with Claude Code", no Co-Authored-By.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `lib/fixed.lua` | create | Soft-float type and all integer-only math. No I/O, no globals. |
| `bin/random` | modify | CLI. Loads `lib/fixed.lua`, converts distributions, closes I/O float boundaries. |
| `tests/fixed_test` | create | Unit tests for the kernel, run under `luajit`. |
| `tests/kernel_bc_sweep` | create | MFIC control: sweeps the kernel against `bc` and against `luajit -joff`. |
| `tests/golden_test` | create | Asserts committed golden vectors still reproduce. |
| `tests/bless-goldens` | create | Regenerates golden vectors. Run deliberately, never by `./test`. |
| `tests/golden/integer.txt` | create | Golden vectors, integer paths (Task 3). |
| `tests/golden/dist.txt` | create | Golden vectors, distributions (Task 13). |
| `test` | modify | Runs all suites, accumulates failures into the exit code. |
| `flake.nix` | modify | Install `lib/`, add `bc` to check inputs. |

`bin/random` finds the library relative to its own path:

```lua
local here = (arg[0] or ""):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../lib/?.lua;" .. here .. "/lib/?.lua;" .. package.path
local fx = require("fixed")
```

Full hexagonal separation (pure core / adapters) is deliberately **not** done here. That is the Zig port's job (spec §3); doing it now would churn `bin/random` twice.

---

### Task 1: Fix the `pcg32_range` infinite loop

`bin/random:172-182` computes `bound = 4294967296 - (4294967296 % range)`. For any `range > 2^32` that is `4294967296 - 4294967296 = 0`, so `r < bound` is never true and the loop never terminates.

**Files:**
- Modify: `bin/random:172-182`
- Test: `tests/random_test` (new test in Section 3)

**Interfaces:**
- Consumes: nothing
- Produces: `pcg32_range(start_val, end_val)` unchanged in signature; now terminates for all ranges.

- [ ] **Step 1: Write the failing test**

Add to `tests/random_test`, immediately after Test 20 (the PCG32 known-output test, around line 354):

```bash
	# Test 20b: ranges wider than 2^32 must terminate (regression: infinite loop)
	(( tests++ ))
	echo "Testing range wider than 2^32 terminates..."

	local wide_out wide_status
	wide_out=$(timeout 5 random -d --seed 7 0 5000000000 2>/dev/null)
	wide_status=$?

	if [ $wide_status -eq 124 ]; then
		echo "✗ Wide range test failed: timed out (infinite loop)" >&2
		(( fails++ ))
	elif [ $wide_status -ne 0 ]; then
		echo "✗ Wide range test failed: exit $wide_status" >&2
		(( fails++ ))
	elif [ "$wide_out" -ge 0 ] && [ "$wide_out" -le 5000000000 ]; then
		echo "✓ Wide range test passed ($wide_out in [0, 5000000000])"
	else
		echo "✗ Wide range test failed: $wide_out out of range" >&2
		(( fails++ ))
	fi
```

- [ ] **Step 2: Run it and watch it hang, then fail**

Run: `./test 2>&1 | grep -A2 'wider than 2'`
Expected: FAIL with "timed out (infinite loop)" after 5 seconds. If it passes, the bug is not reproduced and the test is wrong.

- [ ] **Step 3: Implement the fix**

Replace `pcg32_range` (`bin/random:172-182`) with:

```lua
-- Uniform integer in [start_val, end_val] by rejection sampling.
-- Ranges up to 2^32 use a single 32-bit draw; wider ranges compose two draws
-- into 64 bits. The original single-draw form computed bound = 0 for any
-- range > 2^32 and looped forever.
local function pcg32_range(start_val, end_val)
	local range = end_val - start_val + 1
	if range <= 1 then return start_val end
	if range <= 4294967296 then
		local bound = 4294967296 - (4294967296 % range)
		while true do
			local r = pcg32_random()
			if r < bound then
				return start_val + (r % range)
			end
		end
	end
	-- Wide path: build a 64-bit draw from two 32-bit draws.
	-- The bound must be computed entirely in u64. Two tempting forms are wrong:
	--   (0 - (0 % urange))        -- 0 % urange is 0, so bound is 0 and this
	--                             -- reintroduces the infinite loop being fixed
	--   ((2^32 % r) * (2^32 % r) % r)  -- Lua's % on doubles loses precision past
	--                             -- 2^53; verified wrong against bc for 5 of 5
	--                             -- sampled ranges, biasing low output buckets
	-- (0 - urange) is 2^64 - range by unsigned wraparound, and taking that mod
	-- range yields 2^64 mod range exactly. Verified against bc.
	local urange = ffi.cast(u64, range)
	local remainder = (ffi.cast(u64, 0) - urange) % urange   -- 2^64 mod range
	local bound = ffi.cast(u64, 0) - remainder               -- 2^64 - (2^64 mod range)
	while true do
		local hi = ffi.cast(u64, pcg32_random())
		local lo = ffi.cast(u64, pcg32_random())
		local r = hi * 4294967296ULL + lo
		if r < bound then
			return start_val + tonumber(r % urange)
		end
	end
end
```

Note `ffi.cast(u64, 0) - (ffi.cast(u64, 0) % urange)` computes `2^64 mod range` correctly by unsigned wraparound: `0 - (0 % range)` in `u64` is `2^64 - (2^64 % range)` because `2^64 ≡ 0`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `./test 2>&1 | grep -A2 'wider than 2'`
Expected: PASS, and the value is in range.

- [ ] **Step 5: Verify no existing behavior changed**

Run: `./test`
Expected: all tests pass, including Test 20 (`seed 42 → 26`). The narrow path is byte-identical to before.

- [ ] **Step 6: Commit**

```bash
git add bin/random tests/random_test
git commit -m "fix: pcg32_range looped forever for ranges wider than 2^32

bound = 2^32 - (2^32 % range) evaluates to 0 whenever range > 2^32, so
the rejection test r < bound was never satisfied. Ranges up to 2^32 keep
the single-draw path unchanged; wider ranges now compose two 32-bit draws
into a 64-bit value and reject against 2^64 - (2^64 % range)."
```

---

### Task 2: Multi-suite test runner

`./test` currently execs a single suite, so a second suite cannot be added without losing its exit code.

**Files:**
- Modify: `test`

**Interfaces:**
- Produces: `./test` runs every executable suite and exits with the count of failed suites.

- [ ] **Step 1: Rewrite the runner**

```bash
#!/usr/bin/env bash
# Run every test suite with this project's bin/ on PATH.
# Usage: ./test            (FAST mode by default — quick, quiet on success)
#        FAST= ./test      (full statistical run)
#        ./test fixed      (run only suites whose name matches 'fixed')
# Accumulates per-suite failures and returns the count as the exit code.
# NOTE: no `set -e` here on purpose. Suites deliberately exercise non-zero
# exit paths, and errexit would abort the runner on the first one.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$here/bin:$PATH"
export RANDOM_TEST_FILE="$here/tests/random_test"
export FAST="${FAST-1}"

filter="${1-}"
failed=0
ran=0

for suite in "$here"/tests/*_test "$here"/tests/kernel_bc_sweep; do
	[ -x "$suite" ] || continue
	name="$(basename "$suite")"
	if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then continue; fi
	ran=$((ran + 1))
	if ! "$suite"; then
		failed=$((failed + 1))
		echo "SUITE FAILED: $name" >&2
	fi
done

if [ "$ran" -eq 0 ]; then
	echo "No test suites matched '${filter}'" >&2
	exit 1
fi

if [ "$failed" -gt 0 ]; then
	echo "" >&2
	echo "$failed of $ran suite(s) FAILED" >&2
else
	echo ""
	echo "All $ran suite(s) passed"
fi
exit "$failed"
```

- [ ] **Step 2: Verify it still runs the existing suite**

Run: `./test`
Expected: the existing 46 tests run and pass, followed by `All 1 suite(s) passed`.

- [ ] **Step 3: Verify the filter works**

Run: `./test nosuchsuite; echo "exit=$?"`
Expected: `No test suites matched 'nosuchsuite'` and `exit=1`.

- [ ] **Step 4: Commit**

```bash
git add test
git commit -m "test: run all suites and accumulate failures into the exit code"
```

---

### Task 3: Golden vectors for the integer paths

These lock in every path that must **not** change when the kernel lands. Blessing them now, before any kernel work, is what makes them a control rather than a rubber stamp (spec §8).

**Files:**
- Create: `tests/bless-goldens`, `tests/golden_test`, `tests/golden/integer.txt`

**Interfaces:**
- Produces: `tests/golden/integer.txt`, one record per line: `<label><TAB><output with newlines as \n>`.

- [ ] **Step 1: Write the generator**

Create `tests/bless-goldens`, `chmod +x`:

```bash
#!/usr/bin/env bash
# Regenerate golden vectors. Run DELIBERATELY, never from ./test.
# Usage: tests/bless-goldens integer   (integer paths — Task 3)
#        tests/bless-goldens dist      (distributions — Task 13)
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$here/../bin:$PATH"
export DRANDOM_STATE_HOME="$(mktemp -d)"
trap 'rm -rf "$DRANDOM_STATE_HOME"' EXIT
# bin/random derives its default output delimiter from $IFS. If a caller has
# exported IFS, every default-delimiter vector silently changes. Pin it.
unset IFS

which="${1-}"
[ -n "$which" ] || { echo "usage: bless-goldens integer|dist [output_path]" >&2; exit 1; }
# Second argument redirects output. golden_test uses it to generate into a temp
# file and diff, so a test run never writes to tracked files.
outfile="${2-}"

emit() {  # emit <label> <command...>
	local label="$1"; shift
	local out
	out="$("$@" 2>/dev/null | sed -z 's/\n/\\n/g')"
	printf '%s\t%s\n' "$label" "$out"
}

emit_stdin() {  # emit_stdin <label> <input> <command...>
	local label="$1" input="$2"; shift 2
	local out
	out="$(printf '%s' "$input" | "$@" 2>/dev/null | sed -z 's/\n/\\n/g')"
	printf '%s\t%s\n' "$label" "$out"
}

mkdir -p "$here/golden"

case "$which" in
integer)
	{
		for seed in 1 42 12345 0xDEADBEEF 18446744073709551615; do
			emit "uniform/$seed/default" random -d --seed "$seed" -c 8
			emit "uniform/$seed/0-9"     random -d --seed "$seed" -c 8 0 9
			emit "uniform/$seed/1-6"     random -d --seed "$seed" -c 20 1 6
			emit "uniform/$seed/wide"    random -d --seed "$seed" -c 4 0 5000000000
			emit "uniform/$seed/single"  random -d --seed "$seed" -c 3 5 5
			# no -c: locks the `count = options.count or 1` default branch
			emit "uniform/$seed/defcount" random -d --seed "$seed"
			emit "hex/$seed"             random -d --seed "$seed" -c 8 --hex
			emit "delim/$seed"           random -d --seed "$seed" -c 5 --delimiter , 0 10
			emit "binhex/$seed"          bash -c "random -d --seed $seed -b -c 64 | xxd -p | tr -d '\n'"
			# no -c: locks the `count = options.count or 1024` binary default branch
			emit "bindef/$seed"          bash -c "random -d --seed $seed -b | xxd -p | tr -d '\n'"
			# ranged binary: locks the constrained-range branch, not just 0..255
			emit "binrange/$seed"        bash -c "random -d --seed $seed -b -c 32 64 192 | xxd -p | tr -d '\n'"
			emit "b64/$seed"             random -d --seed "$seed" -b -c 30 --base64
			emit_stdin "choose/$seed"   $'apple\nbanana\ncherry\ndate' random --choose -d --seed "$seed"
			emit_stdin "shuffle/$seed"  $'1\n2\n3\n4\n5\n6\n7\n8' random --shuffle -d --seed "$seed"
			emit_stdin "weighted/$seed" $'rare:1\ncommon:10\nverycommon:100' random --weighted -d --seed "$seed"
		done
	} > "${outfile:-$here/golden/integer.txt}"
	echo "wrote $(wc -l < "${outfile:-$here/golden/integer.txt}") integer vectors" >&2
	;;
dist)
	{
		for seed in 1 42 12345; do
			emit "normal/$seed"      random -d -n --seed "$seed" -c 12 0 100
			emit "normalms/$seed"    random -d -n --seed "$seed" -c 12 --mean 75 --stddev 5
			emit "exponential/$seed" random -d --exponential --seed "$seed" -c 12
			emit "poisson/$seed"     random -d --poisson --mean 5 --seed "$seed" -c 12
			emit "lognormal/$seed"   random -d --log-normal --seed "$seed" -c 12
			emit "beta/$seed"        random -d --beta --alpha 2 --beta-param 5 --seed "$seed" -c 12
		done
	} > "${outfile:-$here/golden/dist.txt}"
	echo "wrote $(wc -l < "${outfile:-$here/golden/dist.txt}") distribution vectors" >&2
	;;
*)
	echo "unknown set: $which" >&2; exit 1 ;;
esac
```

- [ ] **Step 2: Write the checker**

Create `tests/golden_test`, `chmod +x`:

```bash
#!/usr/bin/env bash
# Verify committed golden vectors still reproduce exactly.
# NOTE: no `set -e` — see ./test.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$here/../bin:$PATH"
export DRANDOM_STATE_HOME="$(mktemp -d)"
trap 'rm -rf "$DRANDOM_STATE_HOME"' EXIT
unset IFS

fails=0
checked=0

echo "Verifying golden vectors..."
echo "============================================"

for set_file in "$here"/golden/*.txt; do
	[ -f "$set_file" ] || continue
	set_name="$(basename "$set_file" .txt)"
	# Regenerate into a temp file and diff against the committed one. Never write
	# to a tracked file during a test run: that would clobber deliberate
	# uncommitted golden edits and make ./test mutate the repo.
	tmp="$(mktemp)"
	"$here/bless-goldens" "$set_name" "$tmp" >/dev/null 2>&1
	if diff -q "$set_file" "$tmp" >/dev/null 2>&1; then
		echo "✓ $set_name: all vectors reproduce"
	else
		echo "✗ $set_name: vectors CHANGED" >&2
		diff --unified=0 "$set_file" "$tmp" | head -20 >&2
		fails=$((fails + 1))
	fi
	checked=$((checked + 1))
	rm -f "$tmp"
done

echo "============================================"
# A control that passes when it checked nothing is worse than no control: a
# deleted or renamed golden directory would otherwise report success forever.
if [ "$checked" -eq 0 ]; then
	echo "golden test FAILED: no golden sets found in $here/golden" >&2
	exit 1
fi
if [ "$fails" -gt 0 ]; then
	echo "golden test FAILED: $fails of $checked set(s) changed" >&2
	exit "$fails"
fi
echo "golden test PASSED: All $checked set(s) reproduce"
exit 0
```

- [ ] **Step 3: Bless the integer vectors**

```bash
tests/bless-goldens integer
wc -l tests/golden/integer.txt
head -3 tests/golden/integer.txt
```
Expected: 60 vectors (5 seeds × 12 commands). Inspect the first few by eye and confirm they look like plausible output (numbers in range, hex is hex, base64 is base64).

- [ ] **Step 4: Verify the checker passes on unmodified code**

Run: `./test golden`
Expected: `golden test PASSED: All 1 set(s) reproduce`.

- [ ] **Step 5: Prove the checker actually bites**

Temporarily corrupt the stream, confirm the control fires, then revert:

```bash
sed -i 's/local pcg_mult = ffi.new(u64, 6364136223846793005ULL)/local pcg_mult = ffi.new(u64, 6364136223846793007ULL)/' bin/random
./test golden; echo "exit=$?"
git checkout -- bin/random
./test golden; echo "exit=$?"
```
Expected: first run FAILS with a visible diff and non-zero exit; second run passes. A control that cannot fail is not a control.

- [ ] **Step 6: Commit**

```bash
git add tests/bless-goldens tests/golden_test tests/golden/integer.txt
git commit -m "test: bless golden vectors for the integer paths

These lock in every path that must not change when the integer kernel
lands: uniform (incl. the new wide-range path), hex, base64, binary,
choose, shuffle, weighted, delimiters. Blessed before the kernel work
rather than after, so they are an independent control rather than a
recording of whatever the new code happens to produce.

Deliberately excludes the distributions: their current values are
platform-dependent libm output, which is the defect being fixed."
```

---

### Task 4: Kernel core — representation, `mul128`, `sfmul`, `normalize`

**Files:**
- Create: `lib/fixed.lua`, `tests/fixed_test`

**Interfaces:**
- Produces:
  - `M.mul128(a, b) -> hi, lo` — `u64 × u64 → u64, u64`
  - `M.mul(m1, e1, m2, e2) -> m, e` — soft-float multiply
  - `M.norm(m, e) -> m, e` — renormalize to the mantissa invariant
  - `M.ZERO_M = 0LL`, `M.ZERO_E = 0`
  - Representation: `value = m · 2^(e−62)`, `m` is `int64_t` with `2^62 ≤ |m| < 2^63`, or `m = 0, e = 0`.

- [ ] **Step 1: Write the failing test**

Create `tests/fixed_test`, `chmod +x`:

```bash
#!/usr/bin/env bash
# Unit tests for the integer-only numeric kernel.
# NOTE: no `set -e` — see ./test.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec luajit "$here/fixed_test.lua"
```

Create `tests/fixed_test.lua`:

```lua
package.path = (arg[0] or ""):match("^(.*)/[^/]+$") .. "/../lib/?.lua;" .. package.path
local ffi = require("ffi")
local fx = require("fixed")

local fails, checks = 0, 0
local function ok(cond, label, detail)
	checks = checks + 1
	if cond then
		print("✓ " .. label)
	else
		io.stderr:write("✗ " .. label .. (detail and ("  " .. detail) or "") .. "\n")
		fails = fails + 1
	end
end

print("Testing integer-only numeric kernel...")
print("============================================")
print("")
print("--- Section 1: representation and multiply ---")

-- 1.0 is mantissa 2^62 with exponent 0
local ONE_M, ONE_E = fx.from_int(1)
ok(ONE_M == 0x4000000000000000LL and ONE_E == 0, "from_int(1) is normalized",
   ("got m=%s e=%d"):format(tostring(ONE_M), ONE_E))

-- normalization invariant holds for a range of inputs
local inv_ok = true
for _, v in ipairs({1, 2, 3, 7, 100, -1, -2, -12345, 4294967296}) do
	local m, e = fx.from_int(v)
	if m ~= 0 then
		local a = m < 0 and -m or m
		-- `< 0x7FFFFFFFFFFFFFFFLL + 1` would overflow int64 and wrap to
		-- INT64_MIN, making this guard always false. Use <= on the max.
		if not (a >= 0x4000000000000000LL and a <= 0x7FFFFFFFFFFFFFFFLL) then
			inv_ok = false
		end
	end
end
ok(inv_ok, "from_int keeps 2^62 <= |m| < 2^63 for all sampled inputs")

-- zero is canonical
local zm, ze = fx.from_int(0)
ok(zm == 0LL and ze == 0, "zero is canonical (m=0, e=0)")

-- 2 * 3 == 6, exactly
local am, ae = fx.from_int(2)
local bm, be = fx.from_int(3)
local pm, pe = fx.mul(am, ae, bm, be)
local em, ee = fx.from_int(6)
ok(pm == em and pe == ee, "2 * 3 == 6 exactly",
   ("got m=%s e=%d want m=%s e=%d"):format(tostring(pm), pe, tostring(em), ee))

-- sign handling across all four quadrants
local cases = {{2,3,6},{-2,3,-6},{2,-3,-6},{-2,-3,6}}
local sign_ok = true
for _, c in ipairs(cases) do
	local x1,x2 = fx.from_int(c[1]); local y1,y2 = fx.from_int(c[2])
	local r1,r2 = fx.mul(x1,x2,y1,y2)
	local w1,w2 = fx.from_int(c[3])
	if not (r1 == w1 and r2 == w2) then sign_ok = false end
end
ok(sign_ok, "multiply handles all four sign combinations")

-- multiplying by zero yields canonical zero
local z1, z2 = fx.mul(am, ae, 0LL, 0)
ok(z1 == 0LL and z2 == 0, "x * 0 == canonical zero")

-- mul128 against known values: (2^63) * (2^63) = 2^126 -> hi = 2^62, lo = 0
local hi, lo = fx.mul128(0x8000000000000000ULL, 0x8000000000000000ULL)
ok(hi == 0x4000000000000000ULL and lo == 0ULL, "mul128(2^63, 2^63) == 2^126")

-- mul128 low-word carry: (2^64-1)^2 = 2^128 - 2^65 + 1
local hi2, lo2 = fx.mul128(0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL)
ok(hi2 == 0xFFFFFFFFFFFFFFFEULL and lo2 == 1ULL, "mul128(2^64-1, 2^64-1) carries correctly",
   ("got hi=%s lo=%s"):format(tostring(hi2), tostring(lo2)))

print("")
print("============================================")
if fails > 0 then
	io.stderr:write(("fixed test FAILED: %d of %d checks failed\n"):format(fails, checks))
	os.exit(fails)
end
print(("fixed test PASSED: All %d checks passed"):format(checks))
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./test fixed`
Expected: FAIL with `module 'fixed' not found`.

- [ ] **Step 3: Write the kernel core**

Create `lib/fixed.lua`:

```lua
--[[
Integer-only numeric kernel for `random`.

WHY THIS EXISTS
===============
Every function in here replaces a libm call that `bin/random` used to make
(math.log, math.cos, math.exp, math.pow). Those had to go, because THEY ARE
NOT PORTABLE. IEEE-754 pins down + - * / and sqrt, and says essentially
nothing about transcendental functions, so every libc is free to return a
different final ulp — and they do. Measured on one machine, glibc vs musl,
over the exact k/2^32 domain this program feeds them:

    sqrt   identical      (IEEE-754 mandates correct rounding)
    log    differs        0.006% of inputs
    cos    differs        3.06%  of inputs
    exp    differs        8.85%  of inputs

Box-Muller calls log AND cos per variate, so about 3% of seeded "normal"
values differed between a glibc build and a musl build OF THE SAME SOURCE AT
THE SAME SEED. For a tool whose entire purpose is reproducible streams — the
driving use case is deterministic fuzzing, where a corpus must replay a crash
on someone else's machine — that is not a rounding quirk, it is a broken
promise with no error message.

And it is worth saying plainly why this had to be written at all: the industry
tolerates this. The standard response to "your seeded RNG returns different
numbers on my machine" is a shrug and some line about how it's only the last
ulp and floating point is hard. That excuse is nonsense. It is only the last
ulp until it changes a comparison, and then it is a different branch, a
different variate, a different stream, and a bug report nobody can reproduce.
Reproducibility was the entire specification. Shipping math that quietly
depends on which libc got linked, and then calling the resulting
irreproducibility acceptable, is a choice — a lazy one — and everyone has
agreed to keep making it for decades rather than spend an afternoon on integer
arithmetic. This file is that afternoon.

DO NOT "SIMPLIFY" ANY OF THIS BACK INTO A math.* CALL. Doing so silently
destroys the cross-platform guarantee and no test that runs on a single
machine will notice.

REPRESENTATION
==============
Normalized binary soft-float, all integer ops:

    value = m * 2^(e - 62)      with  2^62 <= |m| < 2^63    (m is int64_t)
    zero  = (m = 0, e = 0)                                  (canonical)

Normalizing the mantissa gives ~62 bits of relative precision at EVERY
magnitude. A fixed-point format cannot: covering the range this program needs
(ln down to -22, variates to +/-6.6, user --mean into the thousands, and
log-normal exp() effectively unbounded) costs so many integer bits that the
fraction lands back at double precision having gained nothing.

Rounding is TRUNCATION TOWARD ZERO, everywhere, unconditionally. Not
round-to-nearest. Truncation is trivially reproducible and has no tie-break
rule to get subtly wrong in one of the two implementations.

Never use the `^` operator here: in LuaJIT `^` is floating-point
exponentiation even on integer cdata. Use the POW2 table.
]]

local ffi = require("ffi")

local M = {}

local i64 = ffi.typeof("int64_t")
local u64 = ffi.typeof("uint64_t")

local TWO62 = 0x4000000000000000ULL
local TWO61 = 0x2000000000000000ULL

-- POW2[n] = 2^n as int64, for n in [0, 62]. 2^63 overflows int64, so it stops
-- at 62 and every shift site must keep its shift count below 63.
local POW2 = {}
do
	local v = 1LL
	for n = 0, 62 do POW2[n] = v; v = v * 2LL end
end
M.POW2 = POW2

M.ZERO_M, M.ZERO_E = 0LL, 0

--- Full 64x64 -> 128 unsigned product, returned as (hi, lo).
--- Needed because LuaJIT cannot do __int128 arithmetic: ffi.cdef accepts the
--- typedef but construction fails ("cannot convert 'number' to 'int128_t'").
--- Mike Pall's "box it in the FFI" guidance covers storage; arithmetic tops
--- out at 64 bits. Zig's port of this uses native u128 and must agree exactly.
function M.mul128(a, b)
	local a0, a1 = a % 0x100000000ULL, a / 0x100000000ULL
	local b0, b1 = b % 0x100000000ULL, b / 0x100000000ULL
	local p00, p01, p10, p11 = a0 * b0, a0 * b1, a1 * b0, a1 * b1
	local mid = (p00 / 0x100000000ULL) + (p01 % 0x100000000ULL) + (p10 % 0x100000000ULL)
	local lo = (p00 % 0x100000000ULL) + (mid % 0x100000000ULL) * 0x100000000ULL
	local hi = p11 + (p01 / 0x100000000ULL) + (p10 / 0x100000000ULL) + (mid / 0x100000000ULL)
	return hi, lo
end

--- Renormalize an arbitrary (m, e) back to 2^62 <= |m| < 2^63.
--- Shifts are truncating, matching the global rounding rule.
function M.norm(m, e)
	if m == 0 then return 0LL, 0 end
	local neg = m < 0
	local u = ffi.cast(u64, neg and -m or m)
	while u < TWO62 do u = u * 2ULL; e = e - 1 end
	while u >= 0x8000000000000000ULL do u = u / 2ULL; e = e + 1 end
	local r = ffi.cast(i64, u)
	if neg then r = -r end
	return r, e
end

--- Soft-float multiply. Mantissa product lands in [2^124, 2^126); take 62 or
--- 63 bits off the top depending on which, so the result is normalized without
--- a renormalization loop.
---
--- PRECONDITION: both operands are already normalized (2^62 <= |m| < 2^63) or
--- canonical zero. The branch selection below is only valid under that premise
--- -- an unnormalized mantissa yields a silently wrong product rather than an
--- error -- so it is asserted rather than assumed. Tasks that build on this
--- must never hand `mul` an unrenormalized intermediate.
function M.mul(m1, e1, m2, e2)
	if m1 == 0 or m2 == 0 then return 0LL, 0 end
	-- Magnitudes are taken by UNSIGNED negation, never `-a`. Negating INT64_MIN
	-- in signed arithmetic is a wraparound coincidence in LuaJIT and a panic in
	-- Zig's safe build modes; `0 - x` in u64 is well-defined in both, so the
	-- eventual port stays bit-identical instead of trapping. (The assert below
	-- rejects INT64_MIN anyway -- |INT64_MIN| is 2^63, outside the invariant --
	-- but the port must not depend on which check fires first.)
	local neg = (m1 < 0) ~= (m2 < 0)
	local a = ffi.cast(u64, m1); if m1 < 0 then a = ffi.cast(u64, 0) - a end
	local b = ffi.cast(u64, m2); if m2 < 0 then b = ffi.cast(u64, 0) - b end
	assert(a >= TWO62 and a < 0x8000000000000000ULL, "fixed.mul: operand 1 not normalized")
	assert(b >= TWO62 and b < 0x8000000000000000ULL, "fixed.mul: operand 2 not normalized")
	local hi, lo = M.mul128(a, b)
	local m, e
	if hi >= TWO61 then           -- product >= 2^125: shift down 63
		m = hi * 2ULL + lo / 0x8000000000000000ULL
		e = e1 + e2 + 1
	else                          -- product in [2^124, 2^125): shift down 62
		m = hi * 4ULL + lo / TWO62
		e = e1 + e2
	end
	local r = ffi.cast(i64, m)
	if neg then r = -r end
	return r, e
end

--- Exact conversion from a Lua integer (|v| < 2^53 for safety) to soft-float.
function M.from_int(v)
	if v == 0 then return 0LL, 0 end
	return M.norm(ffi.cast(i64, v), 62)
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test fixed`
Expected: `fixed test PASSED: All 8 checks passed`.

- [ ] **Step 5: Verify nothing else regressed**

Run: `./test`
Expected: all suites pass.

- [ ] **Step 6: Commit**

```bash
git add lib/fixed.lua tests/fixed_test tests/fixed_test.lua
git commit -m "feat: integer-only soft-float kernel core (mul128, mul, norm)

Normalized binary soft-float, value = m * 2^(e-62) with 2^62 <= |m| < 2^63.
mul128 synthesizes the 64x64->128 product from 32-bit partials because
LuaJIT cannot do __int128 arithmetic: ffi.cdef accepts the typedef but
construction fails. Header comment records why libm was abandoned, with
the measured glibc-vs-musl divergence rates."
```

---

### Task 5: Kernel — addition and subtraction

The fiddliest operation, and the one most likely to lose accuracy through catastrophic cancellation in the alternating-sign Taylor series used by `cos`.

**Files:**
- Modify: `lib/fixed.lua`, `tests/fixed_test.lua`

**Interfaces:**
- Consumes: `M.norm`, `M.POW2` (Task 4)
- Produces:
  - `M.add(m1, e1, m2, e2) -> m, e`
  - `M.sub(m1, e1, m2, e2) -> m, e`
  - `M.cmp(m1, e1, m2, e2) -> -1 | 0 | 1`

- [ ] **Step 1: Write the failing tests**

Append to `tests/fixed_test.lua`, before the final summary block:

```lua
print("")
print("--- Section 2: addition, subtraction, comparison ---")

local function eqint(m, e, want)
	local wm, we = fx.from_int(want)
	return m == wm and e == we
end

-- exact small-integer arithmetic
local a1, a2 = fx.from_int(2)
local b1, b2 = fx.from_int(3)
local s1, s2 = fx.add(a1, a2, b1, b2)
ok(eqint(s1, s2, 5), "2 + 3 == 5 exactly")

local d1, d2 = fx.sub(b1, b2, a1, a2)
ok(eqint(d1, d2, 1), "3 - 2 == 1 exactly")

local n1, n2 = fx.sub(a1, a2, b1, b2)
ok(eqint(n1, n2, -1), "2 - 3 == -1 exactly")

-- identity: x + 0 == x, 0 + x == x
local i1, i2 = fx.add(a1, a2, 0LL, 0)
ok(i1 == a1 and i2 == a2, "x + 0 == x")
local j1, j2 = fx.add(0LL, 0, a1, a2)
ok(j1 == a1 and j2 == a2, "0 + x == x")

-- total cancellation must produce canonical zero, not a denormal
local c1, c2 = fx.sub(a1, a2, a1, a2)
ok(c1 == 0LL and c2 == 0, "x - x == canonical zero", ("got m=%s e=%d"):format(tostring(c1), c2))

-- adding a value far below the ulp must not change the larger operand
local big1, big2 = fx.from_int(1)
local tiny1, tiny2 = fx.norm(0x4000000000000000LL, -200)
local u1, u2 = fx.add(big1, big2, tiny1, tiny2)
ok(u1 == big1 and u2 == big2, "1 + 2^-200 == 1 (addend below the ulp)")

-- commutativity over a sampled set (add is order-independent by construction)
local comm_ok = true
for _, p in ipairs({{1,2},{7,-3},{-5,-9},{1000000,1},{3,-3}}) do
	local x1,x2 = fx.from_int(p[1]); local y1,y2 = fx.from_int(p[2])
	local r1,r2 = fx.add(x1,x2,y1,y2)
	local q1,q2 = fx.add(y1,y2,x1,x2)
	if not (r1 == q1 and r2 == q2) then comm_ok = false end
end
ok(comm_ok, "addition is commutative over the sampled set")

-- comparison
ok(fx.cmp(a1, a2, b1, b2) == -1, "cmp(2, 3) == -1")
ok(fx.cmp(b1, b2, a1, a2) == 1, "cmp(3, 2) == 1")
ok(fx.cmp(a1, a2, a1, a2) == 0, "cmp(2, 2) == 0")
ok(fx.cmp(n1, n2, 0LL, 0) == -1, "cmp(-1, 0) == -1")
ok(fx.cmp(0LL, 0, 0LL, 0) == 0, "cmp(0, 0) == 0")
```

- [ ] **Step 2: Run to verify failure**

Run: `./test fixed`
Expected: FAIL with `attempt to call field 'add' (a nil value)`.

- [ ] **Step 3: Implement add/sub/cmp**

Append to `lib/fixed.lua`, before `return M`:

```lua
--- Soft-float addition.
--- Both operands are shifted right one bit before summing so the sum cannot
--- overflow int64 (each |m| < 2^63, so the raw sum could reach 2^64). That
--- costs one bit of the 62-bit mantissa; norm() reclaims the rest.
--- Catastrophic cancellation is inherent to any floating representation: when
--- the operands are nearly equal and opposite, the surviving bits are the ones
--- that were already exact, and norm() shifts them back up. Section 3 of the
--- test suite measures the resulting series accuracy against bc rather than
--- assuming it.
function M.add(m1, e1, m2, e2)
	if m1 == 0 then return m2, e2 end
	if m2 == 0 then return m1, e1 end
	-- order so e1 is the larger exponent
	if e1 < e2 then m1, e1, m2, e2 = m2, e2, m1, e1 end
	local d = e1 - e2
	if d >= 63 then return m1, e1 end   -- second operand is below the ulp
	local shifted = m2 / POW2[d]
	if shifted == 0 then return m1, e1 end
	local sum = (m1 / 2LL) + (shifted / 2LL)
	if sum == 0 then return 0LL, 0 end
	return M.norm(sum, e1 + 1)
end

function M.sub(m1, e1, m2, e2)
	if m2 == 0 then return m1, e1 end
	return M.add(m1, e1, -m2, e2)
end

function M.neg(m, e)
	if m == 0 then return 0LL, 0 end
	return -m, e
end

--- Three-way comparison. Exponents only rank magnitudes once signs agree, so
--- sign is checked first.
function M.cmp(m1, e1, m2, e2)
	local s1 = (m1 > 0 and 1) or (m1 < 0 and -1) or 0
	local s2 = (m2 > 0 and 1) or (m2 < 0 and -1) or 0
	if s1 ~= s2 then return s1 < s2 and -1 or 1 end
	if s1 == 0 then return 0 end
	if e1 ~= e2 then
		local bigger = (e1 > e2) and 1 or -1
		return (s1 > 0) and bigger or -bigger
	end
	if m1 == m2 then return 0 end
	return (m1 < m2) and -1 or 1
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test fixed`
Expected: all checks pass, 21 total.

- [ ] **Step 5: Commit**

```bash
git add lib/fixed.lua tests/fixed_test.lua
git commit -m "feat: soft-float add, sub, neg, cmp

Operands are pre-shifted one bit before summing so the int64 sum cannot
overflow; norm() reclaims the precision. Total cancellation returns
canonical zero rather than a denormal, and addends below the ulp leave
the larger operand untouched."
```

---

### Task 6: Kernel — `ln`

**Files:**
- Modify: `lib/fixed.lua`, `tests/fixed_test.lua`

**Interfaces:**
- Consumes: `M.mul`, `M.add`, `M.sub`, `M.norm`, `M.from_int`
- Produces:
  - `M.LN2_M, M.LN2_E` — `ln 2` as a soft-float constant
  - `M.div(m1, e1, m2, e2) -> m, e`
  - `M.ln(m, e) -> m, e` (requires the argument to be positive)

- [ ] **Step 1: Write the failing tests**

Append to `tests/fixed_test.lua`:

```lua
print("")
print("--- Section 3: ln ---")

-- ln(1) == 0 exactly
local l1, l2 = fx.ln(fx.from_int(1))
ok(l1 == 0LL and l2 == 0, "ln(1) == 0 exactly")

-- ln(2) matches the stored constant exactly (same code path, same value)
local t1, t2 = fx.ln(fx.from_int(2))
ok(fx.cmp(t1, t2, fx.LN2_M, fx.LN2_E) == 0 or
   math_abs_rel(t1, t2, fx.LN2_M, fx.LN2_E) < 1e-17, "ln(2) == the ln2 constant")

-- ln is exact enough on powers of two: ln(2^k) == k * ln2
local pow_ok = true
for k = 1, 20 do
	local xm, xe = fx.norm(0x4000000000000000LL, k)   -- 2^k
	local rm, re = fx.ln(xm, xe)
	local wm, we = fx.mul(fx.LN2_M, fx.LN2_E, fx.from_int(k))
	if math_abs_rel(rm, re, wm, we) > 1e-16 then pow_ok = false end
end
ok(pow_ok, "ln(2^k) == k*ln2 for k in 1..20 (rel err < 1e-16)")
```

Add this helper near the top of `tests/fixed_test.lua`, after the `ok` function:

```lua
-- relative difference between two soft-floats, as a Lua number.
-- Test-only convenience; uses floats deliberately, and only to score error.
function math_abs_rel(m1, e1, m2, e2)
	local function tofloat(m, e)
		if m == 0 then return 0.0 end
		return tonumber(m) * 2 ^ (e - 62)
	end
	local a, b = tofloat(m1, e1), tofloat(m2, e2)
	if b == 0 then return math.abs(a) end
	return math.abs((a - b) / b)
end
```

- [ ] **Step 2: Run to verify failure**

Run: `./test fixed`
Expected: FAIL with `attempt to call field 'ln' (a nil value)`.

- [ ] **Step 3: Implement `div` and `ln`**

Append to `lib/fixed.lua`, before `return M`:

```lua
--- Soft-float divide. The mantissa quotient needs 62 fractional bits, obtained
--- by splitting the shift into two 31-bit steps. A single (m1 << 62) / m2 would
--- overflow u64 — that exact mistake produced 0.46 absolute error in cos during
--- design, and was caught by the bc sweep rather than by inspection.
function M.div(m1, e1, m2, e2)
	if m1 == 0 then return 0LL, 0 end
	assert(m2 ~= 0, "fixed.div: division by zero")
	local neg = false
	local a, b = m1, m2
	if a < 0 then neg = not neg; a = -a end
	if b < 0 then neg = not neg; b = -b end
	local ua, ub = ffi.cast(u64, a), ffi.cast(u64, b)
	local q0, r0 = ua / ub, ua % ub
	local t1, r1 = (r0 * 0x80000000ULL) / ub, (r0 * 0x80000000ULL) % ub
	local t2 = (r1 * 0x80000000ULL) / ub
	local q = q0 * 0x4000000000000000ULL + t1 * 0x80000000ULL + t2
	local r = ffi.cast(i64, q)
	if neg then r = -r end
	return M.norm(r, e1 - e2)
end

-- ln 2, generated by:  echo 'scale=40; l(2)' | bc -l  ->  .6931471805599453094172321214581765680755
-- times 2^62, truncated:  ln2 * 2^62 = 3196577161300663808
M.LN2_M, M.LN2_E = 3196577161300663808LL, 0

-- Reciprocals of the odd denominators 3, 5, 7, ... 25 used by the atanh series,
-- as soft-floats. Multiplying by a reciprocal keeps division out of the loop.
local ODD_RECIP = {}
do
	for k = 1, 12 do
		local dm, de = M.from_int(2 * k + 1)
		local om, oe = M.from_int(1)
		ODD_RECIP[k] = { M.div(om, oe, dm, de) }
	end
end

--- Natural log. The soft-float form IS the decomposition: x = m * 2^(e-62), so
--- ln x = (e-62+62)*ln2 + ln(mantissa-as-value-in-[1,2)), with no extra work.
--- ln of the [1,2) part uses 2*atanh((m-1)/(m+1)); t < 1/3 there, so 12 terms
--- converge well past the precision we carry.
function M.ln(m, e)
	assert(m > 0, "fixed.ln: argument must be positive")
	-- split into 2^k * f with f in [1,2): mantissa m already sits in
	-- [2^62, 2^63), which is exactly f in [1,2) scaled by 2^62.
	local k = e
	local fm, fe = m, 0
	local onem, onee = M.from_int(1)
	local num_m, num_e = M.sub(fm, fe, onem, onee)
	local den_m, den_e = M.add(fm, fe, onem, onee)
	local tm, te = M.div(num_m, num_e, den_m, den_e)
	local t2m, t2e = M.mul(tm, te, tm, te)
	local term_m, term_e = tm, te
	local acc_m, acc_e = tm, te
	for j = 1, 12 do
		term_m, term_e = M.mul(term_m, term_e, t2m, t2e)
		local rm, re = ODD_RECIP[j][1], ODD_RECIP[j][2]
		local cm, ce = M.mul(term_m, term_e, rm, re)
		acc_m, acc_e = M.add(acc_m, acc_e, cm, ce)
	end
	-- 2*acc + k*ln2
	local lm, le = M.add(acc_m, acc_e, acc_m, acc_e)
	if k ~= 0 then
		local km, ke = M.from_int(k)
		local sm, se = M.mul(M.LN2_M, M.LN2_E, km, ke)
		lm, le = M.add(lm, le, sm, se)
	end
	return lm, le
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test fixed`
Expected: the three `ln` checks pass. If `ln(2^k)` fails, the mantissa/exponent split in `ln` is off by one; verify `from_int(1)` really is `(2^62, 0)`.

- [ ] **Step 5: Commit**

```bash
git add lib/fixed.lua tests/fixed_test.lua
git commit -m "feat: soft-float ln via 2*atanh((m-1)/(m+1))

The soft-float form is already the decomposition x = m*2^e, so
ln x = e*ln2 + ln(m) needs no extra range reduction. div splits the
62-bit shift into two 31-bit steps; the naive single shift overflows u64
and was the source of a 0.46 absolute error in cos during design."
```

---

### Task 7: Kernel — `exp`

**Files:**
- Modify: `lib/fixed.lua`, `tests/fixed_test.lua`

**Interfaces:**
- Consumes: `M.mul`, `M.add`, `M.div`, `M.ln`, `M.LN2_M/E`
- Produces: `M.exp(m, e) -> m, e`

- [ ] **Step 1: Write the failing tests**

Append to `tests/fixed_test.lua`:

```lua
print("")
print("--- Section 4: exp ---")

-- exp(0) == 1
local e1m, e1e = fx.exp(0LL, 0)
ok(fx.cmp(e1m, e1e, fx.from_int(1)) == 0, "exp(0) == 1 exactly")

-- exp(ln(x)) == x round-trip, over a sampled set
local rt_ok, rt_worst = true, 0
for _, v in ipairs({2, 3, 5, 10, 100, 1000}) do
	local xm, xe = fx.from_int(v)
	local lm, le = fx.ln(xm, xe)
	local rm, re = fx.exp(lm, le)
	local err = math_abs_rel(rm, re, xm, xe)
	if err > rt_worst then rt_worst = err end
	if err > 1e-15 then rt_ok = false end
end
ok(rt_ok, "exp(ln(x)) == x for sampled x (rel err < 1e-15)", ("worst=%.3e"):format(rt_worst))

-- exp of a large argument must not overflow: exp(50) ~ 5.18e21, far beyond
-- any fixed-point format this program could have used.
local bm, be = fx.exp(fx.from_int(50))
ok(be > 62, "exp(50) uses the exponent rather than overflowing", ("e=%d"):format(be))
```

- [ ] **Step 2: Run to verify failure**

Run: `./test fixed`
Expected: FAIL with `attempt to call field 'exp' (a nil value)`.

- [ ] **Step 3: Implement `exp`**

Append to `lib/fixed.lua`, before `return M`:

```lua
-- Reciprocals of 1!..16! as soft-floats, for the exp Taylor series.
local FACT_RECIP = {}
do
	local f = M.from_int(1)
	local fm, fe = M.from_int(1)
	for n = 1, 16 do
		local nm, ne = M.from_int(n)
		fm, fe = M.mul(fm, fe, nm, ne)          -- fm = n!
		local om, oe = M.from_int(1)
		FACT_RECIP[n] = { M.div(om, oe, fm, fe) }
	end
end

--- Exponential. Range-reduce x = k*ln2 + r with |r| <= ln2/2, evaluate exp(r)
--- by Taylor, and return (exp(r), k) — which IS a soft-float already. Returning
--- the pair is strictly less work than folding 2^k back into the mantissa, and
--- that fold is exactly what overflows a fixed-point representation.
function M.exp(m, e)
	if m == 0 then return M.from_int(1) end
	-- k = round(x / ln2), computed by truncating division then correcting
	local qm, qe = M.div(m, e, M.LN2_M, M.LN2_E)
	local k = M.to_int_trunc(qm, qe)
	-- r = x - k*ln2
	local km, ke = M.from_int(k)
	local sm, se = M.mul(M.LN2_M, M.LN2_E, km, ke)
	local rm, re = M.sub(m, e, sm, se)
	-- if |r| > ln2/2, nudge k by one so the series stays in its best interval
	local halfm, halfe = M.div(M.LN2_M, M.LN2_E, M.from_int(2))
	while M.cmp(rm, re, halfm, halfe) > 0 do
		k = k + 1
		km, ke = M.from_int(k)
		sm, se = M.mul(M.LN2_M, M.LN2_E, km, ke)
		rm, re = M.sub(m, e, sm, se)
	end
	while M.cmp(rm, re, -halfm, halfe) < 0 do
		k = k - 1
		km, ke = M.from_int(k)
		sm, se = M.mul(M.LN2_M, M.LN2_E, km, ke)
		rm, re = M.sub(m, e, sm, se)
	end
	-- exp(r) = sum r^n / n!
	local acc_m, acc_e = M.from_int(1)
	local pow_m, pow_e = M.from_int(1)
	for n = 1, 16 do
		pow_m, pow_e = M.mul(pow_m, pow_e, rm, re)
		local cm, ce = M.mul(pow_m, pow_e, FACT_RECIP[n][1], FACT_RECIP[n][2])
		if cm == 0 then break end
		acc_m, acc_e = M.add(acc_m, acc_e, cm, ce)
	end
	-- multiply by 2^k purely in the exponent
	return acc_m, acc_e + k
end
```

Also append the integer-extraction helper (needed above) immediately after `M.from_int` in Task 4's block:

```lua
--- Truncate a soft-float toward zero into a Lua integer. Values whose
--- magnitude exceeds 2^53 are clamped, since beyond that a Lua number cannot
--- represent consecutive integers.
function M.to_int_trunc(m, e)
	if m == 0 then return 0 end
	local sh = e - 62
	if sh >= 0 then
		if sh > 62 then return (m < 0) and -9007199254740992 or 9007199254740992 end
		local v = m * POW2[sh]
		return tonumber(v)
	end
	local s = -sh
	if s > 62 then return 0 end
	return tonumber(m / POW2[s])
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test fixed`
Expected: the three `exp` checks pass, round-trip worst error printed and under 1e-15.

- [ ] **Step 5: Commit**

```bash
git add lib/fixed.lua tests/fixed_test.lua
git commit -m "feat: soft-float exp with the 2^k factor kept in the exponent

Range-reduce x = k*ln2 + r, Taylor the remainder, and return (exp(r), k)
directly. Folding 2^k into the mantissa is what a fixed-point design has
to do, and it is what overflows for log-normal with a large mu."
```

---

### Task 8: Kernel — `cos` evaluated in turns

**Files:**
- Modify: `lib/fixed.lua`, `tests/fixed_test.lua`

**Interfaces:**
- Consumes: `M.mul`, `M.add`, `M.sub`, `M.from_int`
- Produces: `M.cos_turns(m, e) -> m, e` where the argument is `u ∈ [0,1)` in *turns*, and the result is `cos(2πu)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/fixed_test.lua`:

```lua
print("")
print("--- Section 5: cos (in turns) ---")

local function turns(num, den)   -- num/den as a soft-float
	local nm, ne = fx.from_int(num)
	local dm, de = fx.from_int(den)
	return fx.div(nm, ne, dm, de)
end

-- exact quarter-turn values
local c0m, c0e = fx.cos_turns(0LL, 0)
ok(fx.cmp(c0m, c0e, fx.from_int(1)) == 0, "cos(0 turns) == 1")

local c2m, c2e = fx.cos_turns(turns(1, 2))
ok(math_abs_rel(c2m, c2e, fx.from_int(-1)) < 1e-16, "cos(1/2 turn) == -1")

local c4m, c4e = fx.cos_turns(turns(1, 4))
ok(math_abs_rel(c4m, c4e, fx.from_int(0)) < 1e-15, "cos(1/4 turn) == 0")

local c34m, c34e = fx.cos_turns(turns(3, 4))
ok(math_abs_rel(c34m, c34e, fx.from_int(0)) < 1e-15, "cos(3/4 turn) == 0")

-- result stays within [-1, 1] across a full turn
local bound_ok = true
for i = 0, 199 do
	local rm, re = fx.cos_turns(turns(i, 200))
	if fx.cmp(rm, re, fx.from_int(1)) > 0 or fx.cmp(rm, re, fx.from_int(-1)) < 0 then
		bound_ok = false
	end
end
ok(bound_ok, "cos stays within [-1,1] across 200 points of a full turn")

-- symmetry: cos(u) == cos(1-u)
local sym_ok, sym_worst = true, 0
for i = 1, 99 do
	local am, ae = fx.cos_turns(turns(i, 200))
	local bm, be = fx.cos_turns(turns(200 - i, 200))
	local err = math_abs_rel(am, ae, bm, be)
	if err > sym_worst then sym_worst = err end
	if err > 1e-15 then sym_ok = false end
end
ok(sym_ok, "cos(u) == cos(1-u) across the turn", ("worst=%.3e"):format(sym_worst))
```

- [ ] **Step 2: Run to verify failure**

Run: `./test fixed`
Expected: FAIL with `attempt to call field 'cos_turns' (a nil value)`.

- [ ] **Step 3: Implement `cos_turns`**

Append to `lib/fixed.lua`, before `return M`:

```lua
-- pi/2, generated by:  echo 'scale=40; 4*a(1)/2' | bc -l
--   -> 1.5707963267948966192313216916397514420986
-- times 2^62 / 2 (normalized: 1.5708 in [1,2) so exponent is 0):
M.PI_2_M, M.PI_2_E = 7244019458077122842LL, 0

-- Reciprocals of the Taylor denominators for cos and sin.
local COS_RECIP, SIN_RECIP = {}, {}
do
	for n = 1, 8 do
		local om, oe = M.from_int(1)
		COS_RECIP[n] = { M.div(om, oe, M.from_int((2*n-1) * (2*n))) }
		SIN_RECIP[n] = { M.div(om, oe, M.from_int((2*n) * (2*n+1))) }
	end
end

local function cos_rad(am, ae)
	local a2m, a2e = M.mul(am, ae, am, ae)
	local term_m, term_e = M.from_int(1)
	local acc_m, acc_e = M.from_int(1)
	for n = 1, 8 do
		term_m, term_e = M.mul(term_m, term_e, a2m, a2e)
		term_m, term_e = M.mul(term_m, term_e, COS_RECIP[n][1], COS_RECIP[n][2])
		term_m = -term_m
		acc_m, acc_e = M.add(acc_m, acc_e, term_m, term_e)
	end
	return acc_m, acc_e
end

local function sin_rad(am, ae)
	local a2m, a2e = M.mul(am, ae, am, ae)
	local term_m, term_e = am, ae
	local acc_m, acc_e = am, ae
	for n = 1, 8 do
		term_m, term_e = M.mul(term_m, term_e, a2m, a2e)
		term_m, term_e = M.mul(term_m, term_e, SIN_RECIP[n][1], SIN_RECIP[n][2])
		term_m = -term_m
		acc_m, acc_e = M.add(acc_m, acc_e, term_m, term_e)
	end
	return acc_m, acc_e
end

--- cos(2*pi*u), with u given in TURNS rather than radians.
--- The caller always wants cos of 2*pi*something, so quadrant reduction is done
--- on u directly and is therefore EXACT — no 2*pi multiply participates in the
--- reduction at all. That multiply was the single largest rounding source in the
--- float version. Only the within-quadrant remainder is converted to radians.
function M.cos_turns(m, e)
	if m == 0 then return M.from_int(1) end
	-- fractional part of u, in [0,1)
	local fm, fe = M.frac(m, e)
	if fm < 0 then fm, fe = M.add(fm, fe, M.from_int(1)) end
	-- quadrant = floor(4u); within = 4u - quadrant
	local q4m, q4e = M.mul(fm, fe, M.from_int(4))
	local q = M.to_int_trunc(q4m, q4e)
	local wm, we = M.sub(q4m, q4e, M.from_int(q))
	-- angle in [0, pi/2)
	local am, ae = M.mul(wm, we, M.PI_2_M, M.PI_2_E)
	if q == 0 then return cos_rad(am, ae) end
	if q == 1 then local sm, se = sin_rad(am, ae); return M.neg(sm, se) end
	if q == 2 then local cm, ce = cos_rad(am, ae); return M.neg(cm, ce) end
	return sin_rad(am, ae)
end
```

Also append `M.frac` next to `M.to_int_trunc`:

```lua
--- Fractional part, truncating toward zero (so frac(-1.25) == -0.25).
function M.frac(m, e)
	local ip = M.to_int_trunc(m, e)
	if ip == 0 then return m, e end
	return M.sub(m, e, M.from_int(ip))
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test fixed`
Expected: all six `cos` checks pass. If the quarter-turn values are wrong, check the quadrant mapping first: `0 → cos`, `1 → −sin`, `2 → −cos`, `3 → sin`.

- [ ] **Step 5: Commit**

```bash
git add lib/fixed.lua tests/fixed_test.lua
git commit -m "feat: soft-float cos evaluated in turns rather than radians

The argument is always 2*pi*u, so quadrant reduction runs on u directly
and is exact; no 2*pi multiply participates in the reduction. Only the
within-quadrant remainder is converted to radians for the Taylor series."
```

---

### Task 9: Kernel — `sqrt` and `pow`

**Files:**
- Modify: `lib/fixed.lua`, `tests/fixed_test.lua`

**Interfaces:**
- Consumes: `M.ln`, `M.exp`, `M.mul`, `M.norm`
- Produces: `M.sqrt(m, e) -> m, e`, `M.pow(bm, be, ym, ye) -> m, e`

- [ ] **Step 1: Write the failing tests**

Append to `tests/fixed_test.lua`:

```lua
print("")
print("--- Section 6: sqrt and pow ---")

local sq_ok, sq_worst = true, 0
for _, v in ipairs({1, 2, 4, 9, 16, 100, 12345}) do
	local xm, xe = fx.from_int(v)
	local rm, re = fx.sqrt(xm, xe)
	local backm, backe = fx.mul(rm, re, rm, re)
	local err = math_abs_rel(backm, backe, xm, xe)
	if err > sq_worst then sq_worst = err end
	if err > 1e-15 then sq_ok = false end
end
ok(sq_ok, "sqrt(x)^2 == x for sampled x", ("worst=%.3e"):format(sq_worst))

local em, ee = fx.sqrt(fx.from_int(4))
ok(math_abs_rel(em, ee, fx.from_int(2)) < 1e-16, "sqrt(4) == 2")

local base_m, base_e = fx.from_int(2)
local pm, pe = fx.pow(base_m, base_e, fx.from_int(10))
ok(math_abs_rel(pm, pe, fx.from_int(1024)) < 1e-14, "2^10 == 1024")
```

- [ ] **Step 2: Run to verify failure**

Run: `./test fixed`
Expected: FAIL with `attempt to call field 'sqrt' (a nil value)`.

- [ ] **Step 3: Implement `sqrt` and `pow`**

Append to `lib/fixed.lua`, before `return M`:

```lua
--- Square root. Halve the exponent (shifting the mantissa when the exponent is
--- odd so the halving is exact), then Newton-iterate on the mantissa. Integer
--- Newton converges in a fixed number of steps for a 62-bit mantissa, so the
--- iteration count is constant and carries no data-dependent branching.
function M.sqrt(m, e)
	assert(m >= 0, "fixed.sqrt: argument must be non-negative")
	if m == 0 then return 0LL, 0 end
	local mm, ee = m, e
	if (ee % 2) ~= 0 then
		mm = mm / 2LL
		ee = ee + 1
	end
	-- mantissa is in [2^62, 2^63); its square root is in [2^31, 2^31.5)
	local u = ffi.cast(u64, mm)
	local x = ffi.cast(u64, 0x100000000ULL)   -- 2^32, a safe starting point
	for _ = 1, 40 do
		local nx = (x + u / x) / 2ULL
		if nx == x then break end
		x = nx
	end
	-- sqrt(m * 2^(e-62)) = sqrt(m) * 2^((e-62)/2); renormalize from there
	local rm = ffi.cast(i64, x)
	return M.norm(rm, (ee - 62) / 2 + 62 - 31)
end

--- x^y via exp(y * ln x). Only defined for x > 0, which is all this program
--- needs (the gamma sampler's alpha<1 branch).
function M.pow(bm, be, ym, ye)
	assert(bm > 0, "fixed.pow: base must be positive")
	local lm, le = M.ln(bm, be)
	local pm, pe = M.mul(ym, ye, lm, le)
	return M.exp(pm, pe)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test fixed`
Expected: the three checks pass. If `sqrt` is off by a power of two, the exponent bookkeeping in the final `M.norm` call is wrong; verify against `sqrt(4) == 2` first since that case is exact.

- [ ] **Step 5: Commit**

```bash
git add lib/fixed.lua tests/fixed_test.lua
git commit -m "feat: soft-float sqrt (integer Newton) and pow via exp(y*ln x)"
```

---

### Task 10: Decimal parsing and formatting

Closes the two remaining float boundaries. A deterministic core fed by `strtod` is not deterministic.

**Files:**
- Modify: `lib/fixed.lua`, `tests/fixed_test.lua`

**Interfaces:**
- Consumes: `M.from_int`, `M.div`, `M.mul`, `M.add`, `M.to_int_trunc`
- Produces:
  - `M.parse(str) -> m, e | nil` — decimal string to soft-float; `nil` on malformed input
  - `M.tostring(m, e, places) -> string` — fixed-point decimal rendering
  - `M.parse_int(str) -> number | nil` — decimal string to a plain Lua integer, rejecting fractions

- [ ] **Step 1: Write the failing tests**

Append to `tests/fixed_test.lua`:

```lua
print("")
print("--- Section 7: decimal parse and format ---")

local p1m, p1e = fx.parse("1")
ok(fx.cmp(p1m, p1e, fx.from_int(1)) == 0, "parse('1') == 1")
local p2m, p2e = fx.parse("-42")
ok(fx.cmp(p2m, p2e, fx.from_int(-42)) == 0, "parse('-42') == -42")
local p3m, p3e = fx.parse("0.5")
local q1m, q1e = fx.from_int(1)
local q2m, q2e = fx.from_int(2)
local halfm, halfe = fx.div(q1m, q1e, q2m, q2e)
ok(math_abs_rel(p3m, p3e, halfm, halfe) < 1e-17, "parse('0.5') == 1/2")
ok(fx.parse("") == nil, "parse('') is nil")
ok(fx.parse("abc") == nil, "parse('abc') is nil")
ok(fx.parse("1.2.3") == nil, "parse('1.2.3') is nil")

local z0m, z0e = fx.from_int(0)
ok(fx.tostring(z0m, z0e, 6) == "0.000000", "tostring(0) == '0.000000'")
local f42m, f42e = fx.from_int(42)
ok(fx.tostring(f42m, f42e, 2) == "42.00", "tostring(42, 2) == '42.00'")
local n7m, n7e = fx.from_int(-7)
ok(fx.tostring(n7m, n7e, 3) == "-7.000", "tostring(-7, 3) == '-7.000'")
ok(fx.tostring(halfm, halfe, 6) == "0.500000", "tostring(1/2, 6) == '0.500000'",
   "got " .. fx.tostring(halfm, halfe, 6))

ok(fx.parse_int("42") == 42, "parse_int('42') == 42")
ok(fx.parse_int("-9") == -9, "parse_int('-9') == -9")
ok(fx.parse_int("1.5") == nil, "parse_int('1.5') is nil (fractional bound rejected)")
ok(fx.parse_int("x") == nil, "parse_int('x') is nil")

-- round-trip: parse(tostring(x)) recovers x to the printed precision
local rt2_ok = true
for _, s in ipairs({"1.5", "0.25", "-3.125", "100.0", "0.001"}) do
	local m, e = fx.parse(s)
	local back_m, back_e = fx.parse(fx.tostring(m, e, 10))
	if math_abs_rel(back_m, back_e, m, e) > 1e-9 then rt2_ok = false end
end
ok(rt2_ok, "parse(tostring(x)) round-trips to 1e-9")
```

- [ ] **Step 2: Run to verify failure**

Run: `./test fixed`
Expected: FAIL with `attempt to call field 'parse' (a nil value)`.

- [ ] **Step 3: Implement parse and format**

Append to `lib/fixed.lua`, before `return M`:

```lua
--- Parse a decimal string to soft-float by integer accumulation.
--- Deliberately NOT tonumber/strtod: those go through a hardware double, which
--- reintroduces exactly the platform dependence this file exists to remove.
--- Returns nil on malformed input rather than raising, so callers can produce
--- their own error message.
function M.parse(s)
	if type(s) ~= "string" then return nil end
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return nil end
	local sign = 1
	local i = 1
	local c = s:sub(1, 1)
	if c == "-" then sign = -1; i = 2 elseif c == "+" then i = 2 end
	local int_part, frac_part = 0LL, nil
	local digits, frac_digits = 0, 0
	local seen_dot = false
	while i <= #s do
		local ch = s:byte(i)
		if ch == 46 then                     -- '.'
			if seen_dot then return nil end
			seen_dot = true
			frac_part = 0LL
		elseif ch >= 48 and ch <= 57 then
			local d = ch - 48
			if seen_dot then
				if frac_digits < 18 then     -- 10^18 still fits int64
					frac_part = frac_part * 10LL + d
					frac_digits = frac_digits + 1
				end
			else
				if digits > 18 then return nil end
				int_part = int_part * 10LL + d
				digits = digits + 1
			end
		else
			return nil
		end
		i = i + 1
	end
	if digits == 0 and frac_digits == 0 then return nil end
	local m, e = M.from_int(tonumber(int_part))
	if frac_part and frac_digits > 0 then
		local den = 1LL
		for _ = 1, frac_digits do den = den * 10LL end
		local fm, fe = M.div(M.from_int(tonumber(frac_part)), M.from_int(tonumber(den)))
		m, e = M.add(m, e, fm, fe)
	end
	if sign < 0 then m, e = M.neg(m, e) end
	return m, e
end

--- Parse a decimal string to a plain integer. Fractional input is rejected
--- rather than silently floored: a fractional range bound has no meaning.
function M.parse_int(s)
	if type(s) ~= "string" then return nil end
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return nil end
	local sign, i = 1, 1
	local c = s:sub(1, 1)
	if c == "-" then sign = -1; i = 2 elseif c == "+" then i = 2 end
	if i > #s then return nil end
	local v = 0LL
	while i <= #s do
		local ch = s:byte(i)
		if ch < 48 or ch > 57 then return nil end
		v = v * 10LL + (ch - 48)
		i = i + 1
	end
	return sign * tonumber(v)
end

--- Render a soft-float as a fixed-point decimal string with `places` digits.
--- Integer-only: the fraction is advanced by repeated multiply-by-ten, never
--- by string.format("%f").
function M.tostring(m, e, places)
	places = places or 6
	if m == 0 then
		if places == 0 then return "0" end
		return "0." .. string.rep("0", places)
	end
	local neg = m < 0
	local am, ae = neg and -m or m, e
	local ip = M.to_int_trunc(am, ae)
	local fm, fe = M.sub(am, ae, M.from_int(ip))
	local out = {}
	for _ = 1, places do
		fm, fe = M.mul(fm, fe, M.from_int(10))
		local d = M.to_int_trunc(fm, fe)
		if d < 0 then d = 0 end
		if d > 9 then d = 9 end
		out[#out + 1] = tostring(d)
		fm, fe = M.sub(fm, fe, M.from_int(d))
	end
	local s = tostring(ip)
	if places > 0 then s = s .. "." .. table.concat(out) end
	if neg then s = "-" .. s end
	return s
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test fixed`
Expected: all 15 parse/format checks pass.

- [ ] **Step 5: Commit**

```bash
git add lib/fixed.lua tests/fixed_test.lua
git commit -m "feat: integer-only decimal parse and format

Closes the two remaining float boundaries. tonumber/strtod route through
a hardware double, which reintroduces the platform dependence this kernel
exists to remove, and %f does the same on the way out. parse_int rejects
fractional range bounds instead of silently flooring them."
```

---

### Task 11: The `bc` sweep control

The MFIC control for the whole kernel: an oracle written by someone else, swept mechanically over the real input domain, wired to fail the build.

**Files:**
- Create: `tests/kernel_bc_sweep`, `tests/kernel_vectors.lua`
- Modify: `flake.nix` (add `bc` to the check inputs; it is already in `testTools`)

**Interfaces:**
- Consumes: `M.ln`, `M.exp`, `M.cos_turns`, `M.sqrt`, `M.tostring`

- [ ] **Step 1: Write the vector generator**

Create `tests/kernel_vectors.lua`:

```lua
-- Emit kernel results over the exact domain the RNG produces: u = k / 2^32.
-- Output: one line per sample, "k ln exp cos sqrt" with 12 decimal places.
package.path = (arg[0] or ""):match("^(.*)/[^/]+$") .. "/../lib/?.lua;" .. package.path
local fx = require("fixed")

local count = tonumber(arg[1]) or 400
local out = io.open(arg[2], "w")
local TWO32_M, TWO32_E = fx.from_int(4294967296)

for i = 1, count do
	-- deterministic strided coverage of the whole 2^32 domain
	local k = (i * 2654435761) % 4294967296
	if k == 0 then k = 1 end
	local km, ke = fx.from_int(k)
	local um, ue = fx.div(km, ke, TWO32_M, TWO32_E)
	local lm, le = fx.ln(um, ue)
	local em, ee = fx.exp(um, ue)
	local cm, ce = fx.cos_turns(um, ue)
	local sm, se = fx.sqrt(um, ue)
	out:write(string.format("%d %s %s %s %s\n", k,
		fx.tostring(lm, le, 12), fx.tostring(em, ee, 12),
		fx.tostring(cm, ce, 12), fx.tostring(sm, se, 12)))
end
out:close()
```

- [ ] **Step 2: Write the sweep control**

Create `tests/kernel_bc_sweep`, `chmod +x`:

```bash
#!/usr/bin/env bash
# MFIC control: sweep the integer kernel against bc -l at scale=40.
#
# bc is an INDEPENDENT oracle. GNU bc 1.08.2 does not use GMP; it links only
# libc and carries its own arbitrary-precision decimal arithmetic in number.c,
# so it shares no lineage with anything in lib/fixed.lua. This control already
# caught a u64 overflow in div during design that produced 0.46 absolute error
# in cos and was invisible to inspection.
#
# Also cross-checks luajit's JIT against its interpreter: identical integer
# results are expected, and a divergence means a float path crept in.
#
# NOTE: no `set -e` — see ./test.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUNT="${KERNEL_SWEEP_COUNT:-400}"
if [ -n "${FAST-}" ]; then COUNT="${KERNEL_SWEEP_COUNT:-200}"; fi

# Tolerances. The kernel carries ~62 bits of mantissa; these are set well above
# the measured error so the control fails on real regressions, not on noise.
TOL_LN=1e-15
TOL_EXP=1e-15
TOL_COS=1e-15
TOL_SQRT=1e-15

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0

echo "Sweeping integer kernel against bc (scale=40, $COUNT samples)..."
echo "============================================"

luajit "$here/kernel_vectors.lua" "$COUNT" "$tmp/ours.txt" || {
	echo "✗ vector generation failed" >&2; exit 1; }

# bc computes the same four functions from k alone.
{
	echo "scale=40; pi = 4*a(1)"
	awk '{printf "u = %s / 2^32\nl(u)\ne(u)\nc(2*pi*u)\nsqrt(u)\n", $1}' "$tmp/ours.txt"
} | BC_LINE_LENGTH=0 bc -l > "$tmp/bc.txt"

expected=$(( COUNT * 4 ))
got=$(wc -l < "$tmp/bc.txt")
if [ "$got" -ne "$expected" ]; then
	echo "✗ bc produced $got lines, expected $expected" >&2
	exit 1
fi

paste -d' ' \
	<(awk '{print $2, $3, $4, $5}' "$tmp/ours.txt") \
	<(awk 'NR%4==1{a=$0} NR%4==2{b=$0} NR%4==3{c=$0} NR%4==0{print a, b, c, $0}' "$tmp/bc.txt") \
	> "$tmp/pairs.txt"

report=$(awk -v tl="$TOL_LN" -v te="$TOL_EXP" -v tc="$TOL_COS" -v ts="$TOL_SQRT" '
	function absv(x) { return x < 0 ? -x : x }
	function rel(a, b) { d = absv(a - b); return (absv(b) > 1) ? d / absv(b) : d }
	{
		r1 = rel($1, $5); if (r1 > m1) m1 = r1
		r2 = rel($2, $6); if (r2 > m2) m2 = r2
		r3 = rel($3, $7); if (r3 > m3) m3 = r3
		r4 = rel($4, $8); if (r4 > m4) m4 = r4
		n++
	}
	END {
		printf "n=%d ln=%.3e exp=%.3e cos=%.3e sqrt=%.3e\n", n, m1, m2, m3, m4
		bad = 0
		if (m1 > tl) { printf "FAIL ln %.3e > %s\n", m1, tl; bad = 1 }
		if (m2 > te) { printf "FAIL exp %.3e > %s\n", m2, te; bad = 1 }
		if (m3 > tc) { printf "FAIL cos %.3e > %s\n", m3, tc; bad = 1 }
		if (m4 > ts) { printf "FAIL sqrt %.3e > %s\n", m4, ts; bad = 1 }
		exit bad
	}' "$tmp/pairs.txt")
awk_status=$?

echo "  worst error: $(echo "$report" | head -1)"
if [ $awk_status -ne 0 ]; then
	echo "$report" | grep '^FAIL' >&2
	fails=$((fails + 1))
else
	echo "✓ kernel agrees with bc within tolerance"
fi

# JIT vs interpreter: integer-only code must produce identical bytes.
luajit -joff "$here/kernel_vectors.lua" "$COUNT" "$tmp/nojit.txt"
if cmp -s "$tmp/ours.txt" "$tmp/nojit.txt"; then
	echo "✓ JIT and interpreter produce identical output"
else
	echo "✗ JIT and interpreter DIVERGE — a float path has crept in" >&2
	diff "$tmp/ours.txt" "$tmp/nojit.txt" | head -5 >&2
	fails=$((fails + 1))
fi

echo "============================================"
if [ "$fails" -gt 0 ]; then
	echo "kernel bc sweep FAILED: $fails control(s) fired" >&2
	exit "$fails"
fi
echo "kernel bc sweep PASSED"
exit 0
```

- [ ] **Step 3: Run the control**

Run: `./test kernel`
Expected: PASS, with the worst per-function error printed. Record those numbers; they replace the Q32.32 figures in spec §4.6.

- [ ] **Step 4: Prove the control bites**

Corrupt a constant, confirm the sweep fires, revert:

```bash
sed -i 's/M.LN2_M, M.LN2_E = 3196577161300663808LL, 0/M.LN2_M, M.LN2_E = 3196577161300663000LL, 0/' lib/fixed.lua
./test kernel; echo "exit=$?"
git checkout -- lib/fixed.lua
./test kernel; echo "exit=$?"
```
Expected: first run FAILS on `ln` and/or `exp`; second passes.

- [ ] **Step 5: Update the spec with the measured numbers**

In `docs/specs/2026-07-31-deterministic-fixed-point-rng-design.md` §4.6, replace the Q32.32 table and the "lower bound" paragraph with the numbers just measured, and note they were taken from `tests/kernel_bc_sweep`.

- [ ] **Step 6: Commit**

```bash
git add tests/kernel_bc_sweep tests/kernel_vectors.lua docs/specs/2026-07-31-deterministic-fixed-point-rng-design.md
git commit -m "test: bc sweep control for the integer kernel

Sweeps ln/exp/cos/sqrt over the exact k/2^32 domain the RNG produces and
compares against bc -l at scale=40. bc is independent: GNU bc 1.08.2
links only libc and uses its own decimal arithmetic, sharing no lineage
with lib/fixed.lua. Also diffs luajit against luajit -joff, where any
divergence means a float path crept into integer-only code.

Spec 4.6 updated with measured error, replacing the Q32.32 prototype
figures that were marked as lower bounds."
```

---

### Task 12: Convert `bin/random` to the kernel

**Files:**
- Modify: `bin/random` (distribution functions at lines 240-322, arg parsing at 476-674, output at 870-931)

**Interfaces:**
- Consumes: the whole `lib/fixed.lua` surface
- Produces: `bin/random` with no `math.*` call on any deterministic path

- [ ] **Step 1: Write the failing test**

Add to `tests/random_test`, in Section 11:

```bash
	# Test 45: no floating-point math remains on the deterministic path
	(( tests++ ))
	echo "Testing bin/random contains no libm calls..."

	local libm_hits
	libm_hits=$(grep -nE 'math\.(log|cos|sin|exp|pow|sqrt|pi)|tonumber\(argv|string\.format\("%\.?[0-9]*f' \
		"$(command -v random)" | grep -v '^[0-9]*:--' || true)

	if [ -z "$libm_hits" ]; then
		echo "✓ No libm calls remain"
	else
		echo "✗ libm calls still present:" >&2
		echo "$libm_hits" >&2
		(( fails++ ))
	fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `./test 2>&1 | grep -A4 'no libm'`
Expected: FAIL, listing `math.sqrt`, `math.log`, `math.cos`, `math.pi`, `math.exp`, `math.pow` and the `tonumber(argv[i])` sites.

- [ ] **Step 3: Wire in the library**

At the top of `bin/random`, after the `ffi`/`bit` requires (line 13):

```lua
local here = (arg[0] or ""):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../lib/?.lua;" .. here .. "/lib/?.lua;" .. package.path
local fx = require("fixed")
```

- [ ] **Step 4: Convert the uniform-to-soft-float bridge**

Replace `pcg32_uniform` and `urandom_uniform` (lines 184-187 and 234-238) so they return soft-floats:

```lua
local TWO32_M, TWO32_E = fx.from_int(4294967296)

-- Uniform in [0,1) as a soft-float. The draw is an exact integer k, so k/2^32
-- is exact too; no rounding happens here at all.
local function pcg32_uniform()
	local km, ke = fx.from_int(pcg32_random())
	return fx.div(km, ke, TWO32_M, TWO32_E)
end

local function urandom_uniform()
	local bytes = get_random_bytes(4)
	local km, ke = fx.from_int(bytes_to_integer(bytes))
	return fx.div(km, ke, TWO32_M, TWO32_E)
end
```

The numerator must be bound to locals first. `fx.div(fx.from_int(x), TWO32_M, TWO32_E)` would pass **three** arguments, because Lua truncates a non-final multiple-return to its first value. See Global Constraints.

- [ ] **Step 5: Convert the distributions**

Replace lines 240-322 with:

```lua
-- ===== Distribution functions (integer-only, via lib/fixed.lua) =====

local ONE_M, ONE_E = fx.from_int(1)
local TWO_M, TWO_E = fx.from_int(2)
local NEG2_M, NEG2_E = fx.from_int(-2)

-- Normal (Box-Muller) with mean/stddev, returning a soft-float.
local function normal_random_float(mean_m, mean_e, sd_m, sd_e, uniform_func)
	local u1m, u1e = uniform_func()
	local u2m, u2e = uniform_func()
	if u1m == 0 then u1m, u1e = fx.div(ONE_M, ONE_E, fx.from_int(1000000)) end
	local lm, le = fx.ln(u1m, u1e)
	local pm, pe = fx.mul(NEG2_M, NEG2_E, lm, le)
	local rm, re = fx.sqrt(pm, pe)
	local cm, ce = fx.cos_turns(u2m, u2e)     -- cos(2*pi*u2), u2 already in turns
	local zm, ze = fx.mul(rm, re, cm, ce)
	local sm, se = fx.mul(zm, ze, sd_m, sd_e)
	return fx.add(mean_m, mean_e, sm, se)
end

-- Normal constrained to an integer range, resampling until it lands inside.
local function normal_random_int(start_val, end_val, rand_func)
	local range = end_val - start_val
	local million = 1000000
	while true do
		local mil_m, mil_e = fx.from_int(million)
		local n1m, n1e = fx.from_int(rand_func(1, million))
		local n2m, n2e = fx.from_int(rand_func(1, million))
		local u1m, u1e = fx.div(n1m, n1e, mil_m, mil_e)
		local u2m, u2e = fx.div(n2m, n2e, mil_m, mil_e)
		local lm, le = fx.ln(u1m, u1e)
		local pm, pe = fx.mul(NEG2_M, NEG2_E, lm, le)
		local rm, re = fx.sqrt(pm, pe)
		local cm, ce = fx.cos_turns(u2m, u2e)
		local zm, ze = fx.mul(rm, re, cm, ce)
		-- start + z*(range/6) + range/2
		local rng_m, rng_e = fx.from_int(range)
		local six_m, six_e = fx.from_int(6)
		local sixth_m, sixth_e = fx.div(rng_m, rng_e, six_m, six_e)
		local half_m, half_e = fx.div(rng_m, rng_e, TWO_M, TWO_E)
		local vm, ve = fx.mul(zm, ze, sixth_m, sixth_e)
		vm, ve = fx.add(vm, ve, half_m, half_e)
		vm, ve = fx.add(vm, ve, fx.from_int(start_val))
		-- round to nearest by adding 1/2 then truncating
		local hm, he = fx.div(ONE_M, ONE_E, TWO_M, TWO_E)
		vm, ve = fx.add(vm, ve, hm, he)
		local result = fx.to_int_trunc(vm, ve)
		if result >= start_val and result <= end_val then return result end
	end
end

-- Exponential with the given rate.
local function exponential_random(rate_m, rate_e, uniform_func)
	local um, ue = uniform_func()
	if um == 0 then um, ue = fx.div(ONE_M, ONE_E, fx.from_int(1000000)) end
	local lm, le = fx.ln(um, ue)
	local nm, ne = fx.neg(lm, le)
	return fx.div(nm, ne, rate_m, rate_e)
end

-- Poisson by SUM OF EXPONENTIALS rather than the product form.
-- The product form (multiply uniforms until p <= e^-lambda) underflows any
-- fixed-width fraction: at lambda=20 the threshold is 2e-9 and quality has
-- already collapsed well before that. Counting exponential inter-arrivals is
-- the same distribution and consumes the same number of uniforms per variate,
-- but stays well-conditioned across the whole useful lambda range.
local function poisson_random(lambda_m, lambda_e, uniform_func)
	local sum_m, sum_e = 0LL, 0
	local k = 0
	while true do
		local um, ue = uniform_func()
		if um == 0 then um, ue = fx.div(ONE_M, ONE_E, fx.from_int(1000000)) end
		local lm, le = fx.ln(um, ue)
		local nm, ne = fx.neg(lm, le)
		sum_m, sum_e = fx.add(sum_m, sum_e, nm, ne)
		if fx.cmp(sum_m, sum_e, lambda_m, lambda_e) > 0 then return k end
		k = k + 1
	end
end

local function lognormal_random(mu_m, mu_e, sigma_m, sigma_e, uniform_func)
	local nm, ne = normal_random_float(mu_m, mu_e, sigma_m, sigma_e, uniform_func)
	return fx.exp(nm, ne)
end

-- Gamma via Marsaglia-Tsang, with Ahrens-Dieter for alpha < 1.
local function gamma_random(alpha_m, alpha_e, uniform_func)
	if fx.cmp(alpha_m, alpha_e, ONE_M, ONE_E) < 0 then
		local um, ue = uniform_func()
		if um == 0 then um, ue = fx.div(ONE_M, ONE_E, fx.from_int(1000000)) end
		local am, ae = fx.add(ONE_M, ONE_E, alpha_m, alpha_e)
		local gm, ge = gamma_random(am, ae, uniform_func)
		local invm, inve = fx.div(ONE_M, ONE_E, alpha_m, alpha_e)
		local pm, pe = fx.pow(um, ue, invm, inve)
		return fx.mul(gm, ge, pm, pe)
	end
	local thirdm, thirde = fx.div(ONE_M, ONE_E, fx.from_int(3))
	local dm, de = fx.sub(alpha_m, alpha_e, thirdm, thirde)
	local nine_m, nine_e = fx.from_int(9)
	local nine_d_m, nine_d_e = fx.mul(nine_m, nine_e, dm, de)
	local sq_m, sq_e = fx.sqrt(nine_d_m, nine_d_e)
	local cm, ce = fx.div(ONE_M, ONE_E, sq_m, sq_e)
	local c0331_m, c0331_e = fx.parse("0.0331")
	local half_m, half_e = fx.div(ONE_M, ONE_E, TWO_M, TWO_E)
	while true do
		local xm, xe, vm, ve
		repeat
			xm, xe = normal_random_float(0LL, 0, ONE_M, ONE_E, uniform_func)
			local t1m, t1e = fx.mul(cm, ce, xm, xe)
			vm, ve = fx.add(ONE_M, ONE_E, t1m, t1e)
		until fx.cmp(vm, ve, 0LL, 0) > 0
		local v3m, v3e = fx.mul(vm, ve, vm, ve)
		v3m, v3e = fx.mul(v3m, v3e, vm, ve)
		local um, ue = uniform_func()
		local x2m, x2e = fx.mul(xm, xe, xm, xe)
		local x4m, x4e = fx.mul(x2m, x2e, x2m, x2e)
		local bm, be = fx.mul(c0331_m, c0331_e, x4m, x4e)
		local limm, lime = fx.sub(ONE_M, ONE_E, bm, be)
		if fx.cmp(um, ue, limm, lime) < 0 then
			return fx.mul(dm, de, v3m, v3e)
		end
		if um ~= 0 then
			local lum, lue = fx.ln(um, ue)
			local lvm, lve = fx.ln(v3m, v3e)
			local h1m, h1e = fx.mul(half_m, half_e, x2m, x2e)
			local t2m, t2e = fx.sub(ONE_M, ONE_E, v3m, v3e)
			t2m, t2e = fx.add(t2m, t2e, lvm, lve)
			local t3m, t3e = fx.mul(dm, de, t2m, t2e)
			local rhs_m, rhs_e = fx.add(h1m, h1e, t3m, t3e)
			if fx.cmp(lum, lue, rhs_m, rhs_e) < 0 then
				return fx.mul(dm, de, v3m, v3e)
			end
		end
	end
end

local function beta_random(alpha_m, alpha_e, beta_m, beta_e, uniform_func)
	local xm, xe = gamma_random(alpha_m, alpha_e, uniform_func)
	local ym, ye = gamma_random(beta_m, beta_e, uniform_func)
	local sm, se = fx.add(xm, xe, ym, ye)
	return fx.div(xm, xe, sm, se)
end
```

- [ ] **Step 6: Convert argument parsing**

In `parse_args`, replace each `tonumber(argv[i])` for `--mean`, `--stddev`, `--alpha`, `--beta-param` with `fx.parse(argv[i])` stored as an `{m, e}` pair, and each positional with `fx.parse_int`. For example, the `--mean` branch (lines 585-595) becomes:

```lua
		elseif arg_val == "--mean" then
			i = i + 1
			if i > #argv then
				stderr_write("Error: --mean requires a number\n")
				os.exit(1)
			end
			local mm, me = fx.parse(argv[i])
			if not mm then
				stderr_write("Error: --mean value must be a number\n")
				os.exit(1)
			end
			options.mean = { mm, me }
```

Apply the identical shape to `--stddev` (`options.stddev`), `--alpha` (`options.alpha`), and `--beta-param` (`options.beta_param`). `--count` keeps `fx.parse_int` since a count is an integer:

```lua
			options.count = fx.parse_int(argv[i])
			if not options.count then
				stderr_write("Error: --count value must be a number\n")
				os.exit(1)
			end
```

Positional bounds (lines 636-649) become:

```lua
	if #positionals >= 1 then
		options.start_val = fx.parse_int(positionals[1])
		if not options.start_val then
			stderr_write("Error: start value must be a whole number\n")
			os.exit(1)
		end
	end
	if #positionals >= 2 then
		options.end_val = fx.parse_int(positionals[2])
		if not options.end_val then
			stderr_write("Error: end value must be a whole number\n")
			os.exit(1)
		end
	end
```

- [ ] **Step 7: Convert the generation loop and output**

In `main`, the distribution dispatch (lines 839-861) passes soft-float pairs:

```lua
		if options.exponential then
			value = { exponential_random(ONE_M, ONE_E, uniform_func) }
		elseif options.poisson then
			local lm, le = ONE_M, ONE_E
			if options.mean then lm, le = options.mean[1], options.mean[2] end
			value = { fx.from_int(poisson_random(lm, le, uniform_func)) }
			is_int = true
		elseif options.log_normal then
			local mum, mue = 0LL, 0
			if options.mean then mum, mue = options.mean[1], options.mean[2] end
			local sm, se = ONE_M, ONE_E
			if options.stddev then sm, se = options.stddev[1], options.stddev[2] end
			value = { lognormal_random(mum, mue, sm, se, uniform_func) }
		elseif options.beta then
			local am, ae = fx.from_int(2)
			if options.alpha then am, ae = options.alpha[1], options.alpha[2] end
			local bm, be = fx.from_int(2)
			if options.beta_param then bm, be = options.beta_param[1], options.beta_param[2] end
			value = { beta_random(am, ae, bm, be, uniform_func) }
		elseif options.normalized then
			if options.mean and options.stddev then
				local vm, ve = normal_random_float(options.mean[1], options.mean[2],
					options.stddev[1], options.stddev[2], uniform_func)
				local hm, he = fx.div(ONE_M, ONE_E, TWO_M, TWO_E)
				vm, ve = fx.add(vm, ve, hm, he)
				value = fx.to_int_trunc(vm, ve)
				is_int = true
			else
				value = normal_random_int(start_val, end_val, rand_func)
				is_int = true
			end
		else
			value = rand_func(start_val, end_val)
			is_int = true
		end
```

Track `is_int` per value. In the output section, integers print via `tostring`, soft-floats via `fx.tostring(m, e, 6)`. Replace the `string.format("%.6f", v)` at line 916 with `fx.tostring(v[1], v[2], 6)`, and `string.format("%x", ...)` keeps working for integers.

- [ ] **Step 8: Run the full suite**

Run: `./test`
Expected:
- `random_test`: all pass, including the new no-libm check.
- `golden_test`: **all integer vectors still reproduce.** This is the control that proves the conversion left the integer paths alone. If it fails, the conversion touched something it should not have.
- `fixed_test`, `kernel_bc_sweep`: pass.

- [ ] **Step 9: Commit**

```bash
git add bin/random tests/random_test
git commit -m "feat: convert bin/random to the integer-only kernel

All distributions now run through lib/fixed.lua; no math.* call remains
on any deterministic path, and decimal parsing and formatting no longer
route through a hardware double.

Poisson switches from the product form to sum-of-exponentials: the same
distribution consuming the same uniforms per variate, but without the
underflow that caps the product form near lambda 20.

Golden vectors for the integer paths still reproduce byte-for-byte,
which is what proves the conversion left them untouched."
```

---

### Task 13: Bless the distribution golden vectors

Only now are the distribution outputs platform-independent, so only now can they be recorded (spec §8).

**Files:**
- Create: `tests/golden/dist.txt`

- [ ] **Step 1: Confirm the statistical suite still passes in full (not FAST) mode**

Run: `FAST= ./test`
Expected: every statistical assertion passes at full sample size. These bounds are what catch a kernel that is deterministic *and wrong*, which golden vectors cannot detect. If any fail, stop and fix the kernel before blessing anything.

- [ ] **Step 2: Bless the vectors**

```bash
tests/bless-goldens dist
wc -l tests/golden/dist.txt
head -3 tests/golden/dist.txt
```
Expected: 18 vectors (3 seeds × 6 distributions). Sanity-check by eye: normal values sit near the requested mean, beta values are inside [0,1], poisson values are non-negative integers.

- [ ] **Step 3: Verify the checker covers them**

Run: `./test golden`
Expected: `golden test PASSED: All 2 set(s) reproduce`.

- [ ] **Step 4: Prove determinism across process invocations**

```bash
for i in 1 2 3; do random -d --beta --alpha 2 --beta-param 5 --seed 42 -c 5; echo "---"; done
```
Expected: three identical blocks. Different values across runs mean state is leaking in from somewhere (check `DRANDOM_CONTEXT` and the state file).

- [ ] **Step 5: Commit**

```bash
git add tests/golden/dist.txt
git commit -m "test: bless golden vectors for the distributions

Blessed only after the kernel conversion, because before it these values
were platform-dependent libm output and recording them would have
laminated the defect into the suite."
```

---

### Task 14: Documentation and packaging

**Files:**
- Modify: `README.md`, `flake.nix`, `PLAN.md` (create), `docs/specs/...` (status)

- [ ] **Step 1: Update `flake.nix` to install `lib/`**

In `installPhase`, after the `cp bin/random` line:

```nix
            mkdir -p $out/lib
            cp lib/*.lua $out/lib/
```

And since `bin/random` resolves `../lib/?.lua` relative to itself, `$out/bin/random` finds `$out/lib/fixed.lua`. Verify:

```bash
nix build && ./result/bin/random -d --seed 42 0 99
```
Expected: `26`.

- [ ] **Step 2: Update the check derivation**

The `checks.random-test` derivation runs `bash tests/random_test` directly. Change it to run the full runner so the new suites are covered:

```nix
            FAST=1 bash ./test
```

Confirm `bc` is present in `testTools` (it already is) and add `patchShebangs lib` is unnecessary since `lib/*.lua` has no shebang.

Run: `nix flake check`
Expected: passes.

- [ ] **Step 3: Update `README.md`**

Add to the Features list: reproducible across machines, OSes and architectures, with the reason. Add a section:

```markdown
### Determinism

Seeded streams are **bit-identical across runs, machines, operating systems and
CPU architectures**. All math runs on an integer-only software float
(`lib/fixed.lua`) rather than the platform's libm, because libm transcendentals
are not portable: IEEE-754 pins down `+ - * / sqrt` and says nothing about
`log`, `cos` or `exp`. Measured glibc vs musl over this program's actual input
domain, `log` differs on 0.006% of inputs, `cos` on 3.06%, and `exp` on 8.85% —
which meant roughly 3% of seeded "normal" values differed between two builds of
the same source at the same seed.

The algorithm is PCG32 (XSH-RR 64/32), multiplier 6364136223846793005,
increment 1442695040888963407, seeded by `state = 0; advance; state += seed;
advance`. A stream is reproducible from that description alone.
```

Update the Layout block to include `lib/fixed.lua` and the new test files.

Add a CHANGELOG note that seeded values from `--normalized`, `--exponential`, `--poisson`, `--log-normal` and `--beta` changed once, deliberately, and that `random 1.5 6.5` is now an error.

- [ ] **Step 4: Create `PLAN.md`**

```markdown
# PLAN

## Done
- [x] Fix `pcg32_range` infinite loop for ranges > 2^32 (2026-08-01 EST)
- [x] Golden vectors for the integer paths, blessed pre-conversion (2026-08-01 EST)
- [x] Integer-only soft-float kernel: mul/add/div/ln/exp/cos/sqrt/pow (2026-08-01 EST)
- [x] Integer-only decimal parse and format (2026-08-01 EST)
- [x] `bc` sweep control + JIT/interpreter differential (2026-08-01 EST)
- [x] Convert `bin/random`; Poisson to sum-of-exponentials (2026-08-01 EST)
- [x] Golden vectors for the distributions (2026-08-01 EST)

## Next: Zig port (separate plan)
- [ ] `src/fixed.zig` mirroring `lib/fixed.lua`, verified against the same `bc` sweep
- [ ] Zig core (pure, no I/O) + `include/randomz.h` C FFI
- [ ] `randomz` C CLI + `drandomz`/`nrandomz` symlinks, argv[0] dispatch
- [ ] Differential harness: `randomz` vs `bin/random` over a seed x flag matrix
- [ ] Cross-target digest control: x86_64 / aarch64 / musl must agree
- [ ] Mechatron Prime CI via the `mechatron-ci` skill
```

- [ ] **Step 5: Record dirtree notes**

```bash
dirtree note lib/fixed.lua "Integer-only normalized soft-float kernel (mul/add/div/ln/exp/cos/sqrt/pow, decimal parse+format); replaces libm for cross-platform determinism"
dirtree note tests/fixed_test "Unit tests for lib/fixed.lua"
dirtree note tests/kernel_bc_sweep "MFIC control: sweeps the kernel against bc -l and diffs luajit vs luajit -joff"
dirtree note tests/golden_test "Verifies committed golden vectors still reproduce"
dirtree note tests/bless-goldens "Regenerates golden vectors; run deliberately, never from ./test"
dirtree note tests/golden "Committed golden vectors: integer.txt (pre-conversion), dist.txt (post-conversion)"
```

- [ ] **Step 6: Mark the spec implemented**

Change the spec header `**Status:**` to `steps 1-4 implemented 2026-08-01; step 5 (Zig port) pending`.

- [ ] **Step 7: Full verification**

```bash
./test && FAST= ./test && nix flake check
```
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add README.md flake.nix PLAN.md docs/specs/2026-07-31-deterministic-fixed-point-rng-design.md
git commit -m "docs: document the determinism guarantee and package lib/

README records the PRNG algorithm and parameters precisely enough to
reproduce a stream from the description alone, and the measured libm
divergence that motivated the integer kernel. flake installs lib/ and
runs the full suite in the check derivation."
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §2.1 required source commentary | Task 4 (header comment in `lib/fixed.lua`) |
| §4.2 normalized soft-float representation | Task 4 |
| §4.3 `mul128`, `sfmul`, `sfadd`, `normalize` | Tasks 4, 5 |
| §4.4 `ln`, `exp`, `cos` in turns, `sqrt`, `pow` | Tasks 6, 7, 8, 9 |
| §4.5 constants generated by `bc`, expression committed | Tasks 6, 8 (comments above `LN2_M`, `PI_2_M`) |
| §4.6 re-measure accuracy | Task 11 step 5 |
| §5 float-free input and output | Task 10, Task 12 steps 6-7 |
| §6 distributions, Poisson change | Task 12 step 5 |
| §7 `bc` control, golden vectors, statistical bounds | Tasks 3, 11, 13 |
| §8 sequencing, integer goldens before conversion | Tasks 3 → 12 → 13 ordering |
| §9 compatibility, tightened fractional bounds | Task 12 step 6, Task 14 step 3 |

**Known gaps, deliberately deferred to the Zig plan:** the cross-target digest control (spec §7) needs cross-compilation and has no meaning in a LuaJIT-only phase; the JIT-vs-interpreter diff in Task 11 is the closest available substitute. Scientific-notation formatting for values outside the plain-decimal window (spec §5) is not implemented, because no distribution in the current CLI produces one at default parameters; `fx.tostring` clamps instead. If Task 13's log-normal vectors show clamping, add it before blessing.

**Type consistency:** soft-floats are `(m, e)` multiple-return pairs throughout, never tables, except in `options.mean/stddev/alpha/beta_param` where they are stored as two-element arrays because Lua tables cannot hold multiple returns in a field. Every call site unpacks with `[1], [2]`. `M.tostring(m, e, places)` and `M.to_int_trunc(m, e)` take unpacked pairs.
