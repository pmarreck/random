-- Standalone statistical sanity checks for ./stats.
-- Samples are streamed from the selected CLI; no sample files are created.

local cli = assert(arg[1], "CLI path required")
local fast = os.getenv("FAST") == "1"
local raw_count = tonumber(os.getenv("RANDOM_STATS_BYTES")) or (fast and 262144 or 4194304)
local sample_count = tonumber(os.getenv("RANDOM_STATS_SAMPLES")) or (fast and 10000 or 50000)
local skip_true = os.getenv("RANDOM_STATS_SKIP_TRUE") == "1"

assert(raw_count >= 65536 and raw_count == math.floor(raw_count),
  "RANDOM_STATS_BYTES must be an integer >= 65536")
assert(sample_count >= 5000 and sample_count == math.floor(sample_count),
  "RANDOM_STATS_SAMPLES must be an integer >= 5000")

local function quote(text)
  return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local cli_q = quote(cli)

local function command(arguments)
  return cli_q .. " " .. arguments .. " 2>/dev/null"
end

local failures = 0
local checks = 0

local function check(ok, label, detail, quiet)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    if not quiet then
      io.stderr:write(string.format("  FAIL %-28s %s\n", label, detail or ""))
    end
  end
  return ok
end

local popcount, bit_transitions, first_bit, last_bit = {}, {}, {}, {}
for byte = 0, 255 do
  local bits = {}
  local ones = 0
  for shift = 7, 0, -1 do
    local bit = math.floor(byte / 2 ^ shift) % 2
    bits[#bits + 1] = bit
    ones = ones + bit
  end
  local transitions = 0
  for i = 2, 8 do
    if bits[i] ~= bits[i - 1] then transitions = transitions + 1 end
  end
  popcount[byte] = ones
  bit_transitions[byte] = transitions
  first_bit[byte] = bits[1]
  last_bit[byte] = bits[8]
end

local function raw_accumulator()
  local hist = {}
  for i = 0, 255 do hist[i] = 0 end
  return {
    n = 0, hist = hist, ones = 0, transitions = 0,
    previous_byte = nil, previous_bit = nil,
    pair_n = 0, sum_x = 0, sum_y = 0,
    sum_x2 = 0, sum_y2 = 0, sum_xy = 0,
  }
end

local function consume_bytes(state, data)
  for i = 1, #data do
    local byte = data:byte(i)
    state.n = state.n + 1
    state.hist[byte] = state.hist[byte] + 1
    state.ones = state.ones + popcount[byte]
    state.transitions = state.transitions + bit_transitions[byte]
    if state.previous_bit ~= nil and state.previous_bit ~= first_bit[byte] then
      state.transitions = state.transitions + 1
    end
    state.previous_bit = last_bit[byte]
    if state.previous_byte ~= nil then
      local x, y = state.previous_byte, byte
      state.pair_n = state.pair_n + 1
      state.sum_x = state.sum_x + x
      state.sum_y = state.sum_y + y
      state.sum_x2 = state.sum_x2 + x * x
      state.sum_y2 = state.sum_y2 + y * y
      state.sum_xy = state.sum_xy + x * y
    end
    state.previous_byte = byte
  end
end

local function evaluate_raw(name, state, quiet)
  local expected = state.n / 256
  local chi = 0
  local entropy = 0
  for byte = 0, 255 do
    local observed = state.hist[byte]
    local delta = observed - expected
    chi = chi + delta * delta / expected
    if observed > 0 then
      local p = observed / state.n
      entropy = entropy - p * (math.log(p) / math.log(2))
    end
  end
  local chi_z = (chi - 255) / math.sqrt(510)
  local total_bits = state.n * 8
  local ones_z = (state.ones - total_bits / 2) / math.sqrt(total_bits / 4)
  local transition_total = total_bits - 1
  local transition_z = (state.transitions - transition_total / 2) /
    math.sqrt(transition_total / 4)
  local pairs = state.pair_n
  local numerator = pairs * state.sum_xy - state.sum_x * state.sum_y
  local denom_x = pairs * state.sum_x2 - state.sum_x * state.sum_x
  local denom_y = pairs * state.sum_y2 - state.sum_y * state.sum_y
  local serial = numerator / math.sqrt(denom_x * denom_y)
  local serial_limit = 6 / math.sqrt(pairs)

  local before = failures
  check(math.abs(chi_z) <= 6, name .. " byte chi-square",
    string.format("chi2=%.2f z=%.2f", chi, chi_z), quiet)
  check(math.abs(ones_z) <= 6, name .. " monobit",
    string.format("ones-z=%.2f", ones_z), quiet)
  check(math.abs(transition_z) <= 6, name .. " bit transitions",
    string.format("transition-z=%.2f", transition_z), quiet)
  check(math.abs(serial) <= serial_limit, name .. " serial correlation",
    string.format("r=%.6f limit=%.6f", serial, serial_limit), quiet)
  check(entropy >= 7.99, name .. " byte entropy",
    string.format("H=%.6f bits", entropy), quiet)
  if not quiet then
    print(string.format("  %-18s n=%d  chi-z=%+.2f  ones-z=%+.2f  runs-z=%+.2f  r=%+.6f  H=%.6f  %s",
      name, state.n, chi_z, ones_z, transition_z, serial, entropy,
      failures == before and "PASS" or "FAIL"))
  end
  return failures == before
end

local function read_raw(name, arguments)
  local pipe = assert(io.popen(command(arguments), "r"))
  local state = raw_accumulator()
  while state.n < raw_count do
    local data = pipe:read(math.min(65536, raw_count - state.n))
    if not data or #data == 0 then break end
    consume_bytes(state, data)
  end
  local ok = pipe:close()
  check(ok and state.n == raw_count, name .. " exact byte count",
    string.format("expected=%d actual=%d", raw_count, state.n))
  if state.n ~= raw_count then return false end
  return evaluate_raw(name, state, false)
end

local function read_numbers(arguments)
  local pipe = assert(io.popen(command(arguments), "r"))
  local values = {}
  for line in pipe:lines() do
    local value = tonumber(line)
    if not value then
      pipe:close()
      error("non-numeric distribution output: " .. line)
    end
    values[#values + 1] = value
  end
  local ok = pipe:close()
  check(ok and #values == sample_count, "distribution exact count",
    string.format("expected=%d actual=%d", sample_count, #values))
  return values
end

local function moments(values, transform)
  local n, sum = #values, 0
  local mapped = {}
  local support_ok = true
  for i, value in ipairs(values) do
    local transformed, valid
    if transform then
      transformed, valid = transform(value)
    else
      transformed, valid = value, true
    end
    if valid == false or transformed ~= transformed then support_ok = false end
    mapped[i] = transformed
    sum = sum + transformed
  end
  local mean = sum / n
  local m2, m3, m4 = 0, 0, 0
  for _, value in ipairs(mapped) do
    local d = value - mean
    local d2 = d * d
    m2 = m2 + d2
    m3 = m3 + d2 * d
    m4 = m4 + d2 * d2
  end
  local variance = m2 / n
  local skew = m3 / n / variance ^ 1.5
  local kurtosis = m4 / n / (variance * variance) - 3
  return mean, variance, skew, kurtosis, support_ok
end

local function evaluate_normal(name, values, mean_expected, sd_expected, transform, quiet)
  local mean, variance, skew, kurtosis, support = moments(values, transform)
  local n = #values
  local mean_limit = 6 * sd_expected / math.sqrt(n) + 0.000002
  local variance_relative = math.abs(variance - sd_expected ^ 2) / (sd_expected ^ 2)
  local before = failures
  check(support, name .. " support", "invalid transformed value", quiet)
  check(math.abs(mean - mean_expected) <= mean_limit, name .. " mean",
    string.format("mean=%.6f expected=%.6f limit=%.6f", mean, mean_expected, mean_limit), quiet)
  check(variance_relative <= 0.08, name .. " variance",
    string.format("variance=%.6f relative-error=%.4f", variance, variance_relative), quiet)
  check(math.abs(skew) <= 0.20, name .. " skewness", string.format("skew=%.4f", skew), quiet)
  check(math.abs(kurtosis) <= 0.40, name .. " kurtosis", string.format("excess=%.4f", kurtosis), quiet)
  if not quiet then
    print(string.format("  %-18s n=%d  mean=%.5f  sd=%.5f  skew=%+.3f  excess=%+.3f  %s",
      name, n, mean, math.sqrt(variance), skew, kurtosis,
      failures == before and "PASS" or "FAIL"))
  end
  return failures == before
end

local function evaluate_uniform(values, quiet)
  local hist = {}
  for i = 0, 99 do hist[i] = 0 end
  local support = true
  for _, value in ipairs(values) do
    if value < 0 or value > 99 or value ~= math.floor(value) then
      support = false
    else
      hist[value] = hist[value] + 1
    end
  end
  local expected = #values / 100
  local chi = 0
  for i = 0, 99 do
    local delta = hist[i] - expected
    chi = chi + delta * delta / expected
  end
  local z = (chi - 99) / math.sqrt(198)
  local before = failures
  check(support, "uniform support", "value outside integer [0,99]", quiet)
  check(math.abs(z) <= 6, "uniform chi-square",
    string.format("chi2=%.2f z=%.2f", chi, z), quiet)
  if not quiet then
    print(string.format("  %-18s n=%d  chi2=%.2f  z=%+.2f  %s", "uniform [0,99]",
      #values, chi, z, failures == before and "PASS" or "FAIL"))
  end
  return failures == before
end

local function evaluate_exponential(values, quiet)
  local mean, variance = moments(values)
  local bins = {}
  for i = 1, 10 do bins[i] = 0 end
  local support = true
  for _, value in ipairs(values) do
    if value < 0 then support = false end
    local cdf = 1 - math.exp(-value)
    local bin = math.floor(cdf * 10) + 1
    if bin < 1 then bin = 1 elseif bin > 10 then bin = 10 end
    bins[bin] = bins[bin] + 1
  end
  local expected = #values / 10
  local chi = 0
  for i = 1, 10 do
    local delta = bins[i] - expected
    chi = chi + delta * delta / expected
  end
  local chi_z = (chi - 9) / math.sqrt(18)
  local before = failures
  check(support, "exponential support", "negative value", quiet)
  check(math.abs(mean - 1) <= 6 / math.sqrt(#values), "exponential mean",
    string.format("mean=%.6f", mean), quiet)
  check(math.abs(variance - 1) <= 0.15, "exponential variance",
    string.format("variance=%.6f", variance), quiet)
  check(math.abs(chi_z) <= 6, "exponential CDF deciles",
    string.format("chi2=%.2f z=%.2f", chi, chi_z), quiet)
  if not quiet then
    print(string.format("  %-18s n=%d  mean=%.5f  var=%.5f  decile-z=%+.2f  %s",
      "exponential(1)", #values, mean, variance, chi_z,
      failures == before and "PASS" or "FAIL"))
  end
  return failures == before
end

local function evaluate_poisson(values, quiet)
  local mean, variance = moments(values)
  local support = true
  for _, value in ipairs(values) do
    if value < 0 or value ~= math.floor(value) then support = false end
  end
  local before = failures
  check(support, "poisson support", "negative or non-integer value", quiet)
  check(math.abs(mean - 5) <= 6 * math.sqrt(5 / #values), "poisson mean",
    string.format("mean=%.6f", mean), quiet)
  check(math.abs(variance - 5) <= 0.12 * 5, "poisson variance",
    string.format("variance=%.6f", variance), quiet)
  if not quiet then
    print(string.format("  %-18s n=%d  mean=%.5f  var=%.5f  %s", "poisson(5)",
      #values, mean, variance, failures == before and "PASS" or "FAIL"))
  end
  return failures == before
end

local function evaluate_beta(values, alpha, beta_parameter, label, quiet)
  local expected_mean = alpha / (alpha + beta_parameter)
  local expected_variance = alpha * beta_parameter /
    ((alpha + beta_parameter) ^ 2 * (alpha + beta_parameter + 1))
  local mean, variance = moments(values)
  local support = true
  for _, value in ipairs(values) do
    if value < 0 or value > 1 then support = false end
  end
  local before = failures
  check(support, "beta support", "value outside [0,1]", quiet)
  check(math.abs(mean - expected_mean) <= 6 * math.sqrt(expected_variance / #values),
    "beta mean", string.format("mean=%.6f expected=%.6f", mean, expected_mean), quiet)
  check(math.abs(variance - expected_variance) <= expected_variance * 0.12,
    "beta variance", string.format("variance=%.6f expected=%.6f", variance, expected_variance), quiet)
  if not quiet then
    print(string.format("  %-18s n=%d  mean=%.5f  var=%.5f  %s", label,
      #values, mean, variance, failures == before and "PASS" or "FAIL"))
  end
  return failures == before
end

print(string.format("sample sizes: raw=%d bytes/stream, distributions=%d values", raw_count, sample_count))
print("raw streams:")
read_raw("BLAKE3 seed 42", string.format("-d --seed 42 -b -c %d", raw_count))
if not skip_true then
  read_raw("OS CSPRNG", string.format("-b -c %d", raw_count))
end

print("distribution shapes (fixed seeds):")
local uniform = read_numbers(string.format("-d --seed 81001 -c %d 0 99", sample_count))
evaluate_uniform(uniform, false)
local normal = read_numbers(string.format(
  "-d --seed 81002 -n --mean 5 --stddev 2 -c %d", sample_count))
evaluate_normal("normal(5,2)", normal, 5, 2, nil, false)
local exponential = read_numbers(string.format(
  "-d --seed 81003 --exponential -c %d", sample_count))
evaluate_exponential(exponential, false)
local poisson = read_numbers(string.format(
  "-d --seed 81004 --poisson --mean 5 -c %d", sample_count))
evaluate_poisson(poisson, false)
local lognormal = read_numbers(string.format(
  "-d --seed 81005 --log-normal --mean 0 --stddev 1 -c %d", sample_count))
evaluate_normal("log-normal logs", lognormal, 0, 1, function(value)
  if value <= 0 then return 0 / 0, false end
  return math.log(value), true
end, false)
local beta = read_numbers(string.format(
  "-d --seed 81006 --beta --alpha 2 --beta-param 5 -c %d", sample_count))
evaluate_beta(beta, 2, 5, "beta(2,5)", false)
local beta_u = read_numbers(string.format(
  "-d --seed 81007 --beta --alpha 0.5 --beta-param 0.75 -c %d", sample_count))
evaluate_beta(beta_u, 0.5, 0.75, "beta(0.5,0.75)", false)

-- Mechanically falsifiable controls: each synthetic defect is chosen so its
-- mean can look plausible while its missing entropy/variance must be caught.
local controls_before = failures
local control_checks_before = checks
local control_failures = 0
local function expect_rejected(ok)
  if ok then control_failures = control_failures + 1 end
end
local zero_state = raw_accumulator()
consume_bytes(zero_state, string.rep("\0", 65536))
local before = failures
expect_rejected(evaluate_raw("all-zero control", zero_state, true))
failures = before
local constant_uniform, constant_normal, constant_exp, constant_poisson = {}, {}, {}, {}
local constant_lognormal, constant_beta = {}, {}
for i = 1, 5000 do
  constant_uniform[i] = 0
  constant_normal[i] = 5
  constant_exp[i] = 1
  constant_poisson[i] = 5
  constant_lognormal[i] = 1
  constant_beta[i] = 2 / 7
end
before = failures; expect_rejected(evaluate_uniform(constant_uniform, true)); failures = before
before = failures; expect_rejected(evaluate_normal("constant normal", constant_normal, 5, 2, nil, true)); failures = before
before = failures; expect_rejected(evaluate_exponential(constant_exp, true)); failures = before
before = failures; expect_rejected(evaluate_poisson(constant_poisson, true)); failures = before
before = failures; expect_rejected(evaluate_normal("constant log-normal logs", constant_lognormal, 0, 1,
  function(value) return math.log(value), value > 0 end, true)); failures = before
before = failures; expect_rejected(evaluate_beta(constant_beta, 2, 5, "constant beta", true)); failures = before
checks = control_checks_before + 7
failures = controls_before
check(control_failures == 0, "known-bad sensitivity controls",
  string.format("%d/7 bad generators escaped", control_failures))
print(string.format("  %-18s all-zero raw + six constant-shaped distributions rejected  %s",
  "sensitivity", control_failures == 0 and "PASS" or "FAIL"))

if failures > 0 then
  io.stderr:write(string.format("stats FAILED: %d of %d checks failed\n", failures, checks))
  os.exit(1)
end
print(string.format("stats PASSED: %d sanity/sensitivity checks", checks))
