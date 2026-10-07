import Mathlib.Probability.Distributions.Geometric
import Mathlib.Probability.ProbabilityMassFunction.Constructions
import Mathlib.Probability.Distributions.Uniform
import Mathlib.Tactic
import DistributionProofs.Fixed
import Randoml.Geometric

namespace DistributionProofs.Geometric

open scoped NNReal ENNReal

open private baseLoop threshold prepareLoop from Randoml.Geometric

noncomputable def uniformWords : PMF ℕ :=
  PMF.uniformOfFinset (Finset.range (2 ^ 64))
    (Finset.nonempty_range_iff.mpr (by positivity))

noncomputable def thresholdProbability (base : UInt64) : ℝ≥0 :=
  (base.toNat : ℝ≥0) / (2 ^ 64 : ℝ≥0)

theorem threshold_probability_le_one (base : UInt64) : thresholdProbability base ≤ 1 := by
  unfold thresholdProbability
  apply (div_le_one (by positivity : (0 : ℝ≥0) < 2 ^ 64)).2
  exact_mod_cast base.toNat_lt.le

/-- The strict UInt64 threshold compares against exactly `base` of the
2^64 possible words. This proof counts symbolically, without sampling. -/
theorem uniform_word_threshold (base : UInt64) :
    uniformWords.map (fun word => decide (word < base.toNat)) =
      PMF.bernoulli (thresholdProbability base) (threshold_probability_le_one base) := by
  ext bit : 1
  rw [← PMF.toOuterMeasure_apply_singleton,
    PMF.toOuterMeasure_map_apply, uniformWords,
    PMF.toOuterMeasure_uniformOfFinset_apply]
  simp only [Set.mem_preimage]
  have hb := base.toNat_lt
  have prob_cast : (thresholdProbability base : ℝ≥0∞) =
      (base.toNat : ℝ≥0∞) / (2 ^ 64 : ℝ≥0∞) := by
    unfold thresholdProbability
    rw [ENNReal.coe_div (by positivity), ENNReal.coe_pow,
      ENNReal.coe_ofNat, ENNReal.coe_natCast]
  cases bit
  · have filtered : (Finset.range (2 ^ 64)).filter
        (fun word => decide (word < base.toNat) ∈ ({false} : Set Bool)) =
        Finset.Ico base.toNat (2 ^ 64) := by
      ext word
      simp only [Finset.mem_filter, Finset.mem_range, Set.mem_singleton_iff,
        decide_eq_false_iff_not, not_lt, Finset.mem_Ico]
      exact and_comm
    rw [filtered, Nat.card_Ico, PMF.bernoulli_apply]
    simp only [Bool.cond_false, Finset.card_range, ENNReal.coe_sub, ENNReal.coe_one]
    rw [prob_cast]
    rw [ENNReal.natCast_sub, Nat.cast_pow, Nat.cast_ofNat]
    have hd : (2 ^ 64 : ℝ≥0∞) ≠ 0 := by positivity
    have ht : (2 ^ 64 : ℝ≥0∞) ≠ ⊤ := by finiteness
    rw [ENNReal.sub_div (by intros; exact hd), ENNReal.div_self hd ht]
  · have filtered : (Finset.range (2 ^ 64)).filter
        (fun word => decide (word < base.toNat) ∈ ({true} : Set Bool)) =
        Finset.range base.toNat := by
      ext word
      simp only [Finset.mem_filter, Finset.mem_range, Set.mem_singleton_iff,
        decide_eq_true_eq]
      exact ⟨fun h => h.2, fun h => ⟨h.trans hb, h⟩⟩
    rw [filtered, Finset.card_range, PMF.bernoulli_apply]
    simp only [Bool.cond_true, Finset.card_range]
    rw [prob_cast, Nat.cast_pow, Nat.cast_ofNat]

/-- The probabilistic interpretation executes the production loop. `read`
is a fresh independent source on each bind, not a fixed seeded run. -/
noncomputable def baseLaw (read : ℕ → PMF ByteArray) (base : UInt64)
    (fuel count : ℕ) : PMF (Option ℕ) :=
  baseLoop read base fuel count

noncomputable def observation (base : UInt64) (bytes : ByteArray) : Option Bool :=
  if bytes.size = 8 then some (decide (Randoml.u64be bytes < base)) else none

/-- Explicit source model at the same byte/word boundary used by production.
The source contract supplies iid uniform decoded words and no malformed reads. -/
noncomputable def decodedWord (bytes : ByteArray) : Option ℕ :=
  if bytes.size = 8 then some (Randoml.u64be bytes).toNat else none

theorem observation_of_decoded (base : UInt64) (bytes : ByteArray) :
    observation base bytes = (decodedWord bytes).map
      (fun word => decide (word < base.toNat)) := by
  by_cases size : bytes.size = 8
  · simp [observation, decodedWord, size, UInt64.lt_iff_toNat_lt]
  · simp [observation, decodedWord, size]

theorem uniform_source_observer (read : ℕ → PMF ByteArray) (base : UInt64)
    (source : (read 8).map decodedWord = uniformWords.map some) :
    (read 8).map (observation base) =
      (PMF.bernoulli (thresholdProbability base) (threshold_probability_le_one base)).map some := by
  have observation_eq : observation base =
      Option.map (fun word => decide (word < base.toNat)) ∘ decodedWord := by
    funext bytes
    exact observation_of_decoded base bytes
  rw [observation_eq, ← PMF.map_comp, source, PMF.map_comp]
  have compose : Option.map (fun word => decide (word < base.toNat)) ∘ some =
      some ∘ (fun word => decide (word < base.toNat)) := rfl
  rw [compose, ← PMF.map_comp, uniform_word_threshold]

/-- One production step depends only on byte-count validity and the threshold
comparison. No distributional conclusion is assumed by this refinement. -/
theorem base_law_step (read : ℕ → PMF ByteArray) (base : UInt64) (fuel count : ℕ) :
    baseLaw read base (fuel + 1) count =
      ((read 8).map (observation base)).bind (fun observed =>
        match observed with
        | none => PMF.pure none
        | some true => PMF.pure (some count)
        | some false => baseLaw read base fuel (count + 1)) := by
  rw [PMF.bind_map]
  unfold baseLaw baseLoop observation
  congr 1
  funext bytes
  by_cases size : bytes.size = 8
  · by_cases success : Randoml.u64be bytes < base
    · simp [size, success]
      rfl
    · simp [size, success]
      cases fuel <;> simp [baseLoop]
  · simp [size]
    rfl

/-- The source obligation is about input trials, not about the output law:
every available eight-byte draw has the stated threshold probability. -/
theorem base_law_bernoulli_step (read : ℕ → PMF ByteArray) (base : UInt64)
    (p : ℝ≥0) (hp : p ≤ 1)
    (source : (read 8).map (observation base) = (PMF.bernoulli p hp).map some)
    (fuel count : ℕ) (result : Option ℕ) :
    baseLaw read base (fuel + 1) count result =
      (p : ℝ≥0∞) * PMF.pure (some count) result +
      (1 - (p : ℝ≥0∞)) * baseLaw read base fuel (count + 1) result := by
  rw [base_law_step, source, PMF.bind_map, PMF.bind_apply, tsum_bool]
  simp [PMF.bernoulli_apply, ENNReal.coe_sub, add_comm]

/-- Exact success masses of the actual finite-fuel loop. A cap does not
secretly return a saturated integer or turn a source failure into success. -/
theorem base_success_mass (read : ℕ → PMF ByteArray) (base : UInt64)
    (p : ℝ≥0) (hp : p ≤ 1)
    (source : (read 8).map (observation base) = (PMF.bernoulli p hp).map some)
    (fuel count k : ℕ) :
    baseLaw read base fuel count (some k) =
      if count ≤ k ∧ k < count + fuel then
        (1 - (p : ℝ≥0∞)) ^ (k - count) * (p : ℝ≥0∞) else 0 := by
  induction fuel generalizing count with
  | zero =>
    change PMF.pure none (some k) = _
    simp [PMF.pure_apply]
  | succ fuel ih =>
    rw [base_law_bernoulli_step read base p hp source, ih]
    by_cases hk : k = count
    · subst k
      simp [PMF.pure_apply]
    · by_cases hl : count < k
      · have hl' : count + 1 ≤ k := by omega
        have he : k - count = (k - (count + 1)) + 1 := by omega
        by_cases hf : k < count + (fuel + 1)
        · have hf' : k < count + 1 + fuel := by omega
          simp only [PMF.pure_apply, Option.some.injEq, hk, if_false, mul_zero,
            zero_add, hl', hf', and_self, if_true, hl.le, hf, he, pow_succ]
          ring
        · have hf' : ¬ k < count + 1 + fuel := by omega
          simp [PMF.pure_apply, hk, hf, hf']
      · have hl' : ¬ count ≤ k := by omega
        have hl'' : ¬ count + 1 ≤ k := by omega
        simp [PMF.pure_apply, hk, hl', hl'']

/-- Resource exhaustion has exactly the ideal geometric tail mass; this is
separate from arbitrary external I/O errors, which need a fault model. -/
theorem base_failure_mass (read : ℕ → PMF ByteArray) (base : UInt64)
    (p : ℝ≥0) (hp : p ≤ 1)
    (source : (read 8).map (observation base) = (PMF.bernoulli p hp).map some)
    (fuel count : ℕ) :
    baseLaw read base fuel count none = (1 - (p : ℝ≥0∞)) ^ fuel := by
  induction fuel generalizing count with
  | zero =>
    change PMF.pure none none = _
    simp [PMF.pure_apply]
  | succ fuel ih =>
    rw [base_law_bernoulli_step read base p hp source, ih]
    simp [PMF.pure_apply, pow_succ, mul_comm]

/-- When no parity or tiny-rate levels are needed, the public sampler is
exactly the base loop, not a separate probabilistic replacement. -/
theorem sample_with_base_only (read : ℕ → PMF ByteArray) (fuel : ℕ)
    (prepared : Randoml.Geometric.Prepared)
    (certain : prepared.certain = false) (levels : prepared.levels = #[])
    (tail : prepared.tailBits = 0) :
    Randoml.Geometric.sampleWith read fuel prepared =
      baseLaw read prepared.base fuel 0 := by
  simp [Randoml.Geometric.sampleWith, certain, levels, tail, baseLaw]
  convert bind_pure (baseLoop read prepared.base fuel 0) using 1
  congr 1
  funext result
  cases result <;> rfl

/-- The full preparation path succeeds without recursive parity or tail
levels for every canonical probability in [1/2,1). -/
theorem direct_preparation (mantissa : ℕ)
    (lower : 2 ^ 62 ≤ mantissa) (upper : mantissa < 2 ^ 63) :
    ∃ prepared, Randoml.Geometric.prepare { m := mantissa, e := -1 } = some prepared ∧
      prepared.base = UInt64.ofNat (2 * mantissa) ∧ prepared.certain = false ∧
      prepared.levels = #[] ∧ prepared.tailBits = 0 := by
  let value : Randoml.Fixed.Value := { m := mantissa, e := -1 }
  have positiveNat : 0 < mantissa := by omega
  have positive : 0 < value.m := by
    change (0 : ℤ) < mantissa
    exact_mod_cast positiveNat
  have canonical : Randoml.Fixed.Valid value := by
    apply Or.inr
    change Randoml.Fixed.two62 ≤ (mantissa : ℤ).natAbs ∧
      (mantissa : ℤ).natAbs < Randoml.Fixed.two63
    simpa [Randoml.Fixed.two62, Randoml.Fixed.two63] using And.intro lower upper
  have one : Randoml.Fixed.fromInt 1 = { m := (2 ^ 62 : ℕ), e := 0 } := by
    simpa only [Nat.pow_zero, Nat.cast_one, Nat.cast_zero] using
      Fixed.fromInt_pow2 0 (by omega)
  have comparison : Randoml.Fixed.compare value (Randoml.Fixed.fromInt 1) = -1 := by
    rw [one]
    simp [Randoml.Fixed.compare, value, positiveNat]
  have bounded : Randoml.Fixed.compare value (Randoml.Fixed.fromInt 1) ≤ 0 := by
    rw [comparison]
    omega
  have exponent : (-1000000 : ℤ) ≤ value.e ∧ value.e ≤ 0 := by
    change (-1000000 : ℤ) ≤ -1 ∧ (-1 : ℤ) ≤ 0
    omega
  let probability : Randoml.Geometric.Probability :=
    ⟨value, canonical, positive, exponent, bounded⟩
  have created : Randoml.Geometric.Probability.create value = some probability := by
    simp [Randoml.Geometric.Probability.create, canonical, positive, exponent, bounded,
      probability]
  have comparisonHalf : 0 ≤ Randoml.Fixed.compare value
      { m := Randoml.Fixed.two62, e := -1 } := by
    simp [Randoml.Fixed.compare, value, positiveNat, Randoml.Fixed.two62]
    split <;> omega
  let prepared : Randoml.Geometric.Prepared :=
    ⟨probability, UInt64.ofNat (2 * mantissa), #[], 0, false⟩
  refine ⟨prepared, ?_, rfl, rfl, rfl, rfl⟩
  unfold Randoml.Geometric.prepare
  rw [created]
  simp [comparison, value, prepareLoop, comparisonHalf, threshold,
    positiveNat, prepared, mul_comm]

/-- The direct UInt64 threshold represents the original portable probability
exactly. In this domain there is no preparation-rounding error. -/
theorem direct_threshold_exact (mantissa : ℕ) (upper : mantissa < 2 ^ 63) :
    (thresholdProbability (UInt64.ofNat (2 * mantissa)) : ℝ) =
      Fixed.toReal { m := mantissa, e := -1 } := by
  have hm : 2 * mantissa < 2 ^ 64 := by omega
  have word : (UInt64.ofNat (2 * mantissa)).toNat = 2 * mantissa := by
    change (2 * mantissa) % (2 ^ 64) = 2 * mantissa
    exact Nat.mod_eq_of_lt hm
  rw [thresholdProbability, word]
  simp only [NNReal.coe_div, NNReal.coe_pow, NNReal.coe_ofNat,
    Nat.cast_mul, Nat.cast_ofNat, Fixed.toReal]
  norm_num [div_eq_mul_inv]
  ring

/-- The public prepared sampler's exact finite success and failure laws for
the complete direct-probability domain. No success conditioning is hidden. -/
theorem direct_sampler_law (mantissa : ℕ)
    (lower : 2 ^ 62 ≤ mantissa) (upper : mantissa < 2 ^ 63)
    (read : ℕ → PMF ByteArray)
    (source : (read 8).map decodedWord = uniformWords.map some) (fuel : ℕ) :
    ∃ prepared, Randoml.Geometric.prepare { m := mantissa, e := -1 } = some prepared ∧
      (thresholdProbability prepared.base : ℝ) =
        Fixed.toReal { m := mantissa, e := -1 } ∧
      (∀ k, Randoml.Geometric.sampleWith read fuel prepared (some k) =
        if k < fuel then (1 - (thresholdProbability prepared.base : ℝ≥0∞)) ^ k *
          (thresholdProbability prepared.base : ℝ≥0∞) else 0) ∧
      Randoml.Geometric.sampleWith read fuel prepared none =
        (1 - (thresholdProbability prepared.base : ℝ≥0∞)) ^ fuel := by
  rcases direct_preparation mantissa lower upper with
    ⟨prepared, preparation, base, certain, levels, tail⟩
  have sampler := sample_with_base_only read fuel prepared certain levels tail
  have observed := uniform_source_observer read prepared.base source
  refine ⟨prepared, preparation, ?_, ?_, ?_⟩
  · rw [base]
    exact direct_threshold_exact mantissa upper
  · intro k
    rw [sampler]
    simpa only [zero_le, true_and, zero_add, Nat.sub_zero] using
      base_success_mass read prepared.base (thresholdProbability prepared.base)
        (threshold_probability_le_one prepared.base) observed fuel 0 k
  · rw [sampler]
    exact base_failure_mass read prepared.base (thresholdProbability prepared.base)
      (threshold_probability_le_one prepared.base) observed fuel 0

private theorem geometric_sum (p : ℝ) (n : ℕ) :
    ∑ k ∈ Finset.range n, (1 - p) ^ k * p = 1 - (1 - p) ^ n := by
  induction n with
  | zero => simp
  | succ n ih => rw [Finset.sum_range_succ, ih, pow_succ]; ring

/-- CDF of successful results: failures remain missing mass, not a silent
renormalization. The event is `result < n`. -/
noncomputable def baseCdf (read : ℕ → PMF ByteArray) (base : UInt64)
    (fuel n : ℕ) : ℝ :=
  ∑ k ∈ Finset.range n, (baseLaw read base fuel 0 (some k)).toReal

theorem base_success_real (read : ℕ → PMF ByteArray) (base : UInt64)
    (p : ℝ≥0) (hp : p ≤ 1)
    (source : (read 8).map (observation base) = (PMF.bernoulli p hp).map some)
    (fuel k : ℕ) :
    (baseLaw read base fuel 0 (some k)).toReal =
      if k < fuel then (1 - (p : ℝ)) ^ k * (p : ℝ) else 0 := by
  rw [base_success_mass read base p hp source]
  have complement : (1 - (p : ℝ≥0∞)).toReal = 1 - (p : ℝ) := by
    rw [ENNReal.toReal_sub_of_le (by exact_mod_cast hp) (by simp)]
    simp
  by_cases hk : k < fuel
  · simp [hk, ENNReal.toReal_mul, ENNReal.toReal_pow, complement]
  · simp [hk]

theorem base_cdf_exact (read : ℕ → PMF ByteArray) (base : UInt64)
    (p : ℝ≥0) (hp : p ≤ 1)
    (source : (read 8).map (observation base) = (PMF.bernoulli p hp).map some)
    (fuel n : ℕ) :
    baseCdf read base fuel n = 1 - (1 - (p : ℝ)) ^ (min n fuel) := by
  unfold baseCdf
  simp_rw [base_success_real read base p hp source]
  rw [← Finset.sum_filter]
  have filtered : (Finset.range n).filter (fun k => k < fuel) =
      Finset.range (min n fuel) := by
    ext k
    simp only [Finset.mem_filter, Finset.mem_range, lt_min_iff]
  rw [filtered, geometric_sum]

/-- Uniform CDF discrepancy from the ideal geometric law is bounded by the
explicit exhaustion tail, with no arithmetic error in the base sampler. -/
theorem base_cdf_bound (read : ℕ → PMF ByteArray) (base : UInt64)
    (p : ℝ≥0) (hp : p ≤ 1)
    (source : (read 8).map (observation base) = (PMF.bernoulli p hp).map some)
    (fuel n : ℕ) :
    |baseCdf read base fuel n - (1 - (1 - (p : ℝ)) ^ n)| ≤
      (1 - (p : ℝ)) ^ fuel := by
  rw [base_cdf_exact read base p hp source]
  have hp' : (p : ℝ) ≤ 1 := by exact_mod_cast hp
  have hq : 0 ≤ 1 - (p : ℝ) := by linarith
  have hq' : 1 - (p : ℝ) ≤ 1 := by linarith [p.property]
  by_cases hn : n ≤ fuel
  · rw [Nat.min_eq_left hn, sub_self, abs_zero]
    positivity
  · have hn : fuel ≤ n := by omega
    rw [Nat.min_eq_right hn]
    have hpowers : (1 - (p : ℝ)) ^ n ≤ (1 - (p : ℝ)) ^ fuel :=
      pow_le_pow_of_le_one hq hq' hn
    rw [show 1 - (1 - (p : ℝ)) ^ fuel - (1 - (1 - (p : ℝ)) ^ n) =
      (1 - (p : ℝ)) ^ n - (1 - (p : ℝ)) ^ fuel by ring,
      abs_of_nonpos (sub_nonpos.mpr hpowers)]
    linarith [pow_nonneg hq n]

theorem direct_probability_bounds (mantissa : ℕ)
    (lower : 2 ^ 62 ≤ mantissa) (upper : mantissa < 2 ^ 63) :
    (1 / 2 : ℝ) ≤ Fixed.toReal { m := mantissa, e := -1 } ∧
      Fixed.toReal { m := mantissa, e := -1 } < 1 := by
  have hl : (2 : ℝ) ^ 62 ≤ mantissa := by exact_mod_cast lower
  have hu : (mantissa : ℝ) < 2 ^ 63 := by exact_mod_cast upper
  norm_num [Fixed.toReal]
  constructor <;> nlinarith

noncomputable def samplerCdf (read : ℕ → PMF ByteArray)
    (prepared : Randoml.Geometric.Prepared) (fuel n : ℕ) : ℝ :=
  ∑ k ∈ Finset.range n, (Randoml.Geometric.sampleWith read fuel prepared (some k)).toReal

/-- Production deviation certificate, not just an ideal factorization:
for every direct probability, the only discrepancy is the explicit finite
trial cap. Its worst-case CDF error and failure probability are at most 2^-R. -/
theorem direct_sampler_bound (mantissa : ℕ)
    (lower : 2 ^ 62 ≤ mantissa) (upper : mantissa < 2 ^ 63)
    (read : ℕ → PMF ByteArray)
    (source : (read 8).map decodedWord = uniformWords.map some) (fuel : ℕ) :
    ∃ prepared, Randoml.Geometric.prepare { m := mantissa, e := -1 } = some prepared ∧
      (∀ n, |samplerCdf read prepared fuel n -
        (1 - (1 - Fixed.toReal { m := mantissa, e := -1 }) ^ n)| ≤
          (1 - Fixed.toReal { m := mantissa, e := -1 }) ^ fuel) ∧
      (Randoml.Geometric.sampleWith read fuel prepared none).toReal =
        (1 - Fixed.toReal { m := mantissa, e := -1 }) ^ fuel ∧
      (1 - Fixed.toReal { m := mantissa, e := -1 }) ^ fuel ≤ (1 / 2 : ℝ) ^ fuel := by
  rcases direct_preparation mantissa lower upper with
    ⟨prepared, preparation, base, certain, levels, tail⟩
  have sampler := sample_with_base_only read fuel prepared certain levels tail
  have observed := uniform_source_observer read prepared.base source
  have exactProbability : (thresholdProbability prepared.base : ℝ) =
      Fixed.toReal { m := mantissa, e := -1 } := by
    rw [base]
    exact direct_threshold_exact mantissa upper
  refine ⟨prepared, preparation, ?_, ?_, ?_⟩
  · intro n
    have cdf : samplerCdf read prepared fuel n = baseCdf read prepared.base fuel n := by
      unfold samplerCdf baseCdf
      rw [sampler]
    rw [cdf, ← exactProbability]
    exact base_cdf_bound read prepared.base (thresholdProbability prepared.base)
      (threshold_probability_le_one prepared.base) observed fuel n
  · rw [sampler, base_failure_mass read prepared.base
      (thresholdProbability prepared.base) (threshold_probability_le_one prepared.base)
      observed, ENNReal.toReal_pow]
    rw [ENNReal.toReal_sub_of_le
      (by exact_mod_cast threshold_probability_le_one prepared.base) (by simp)]
    simp only [ENNReal.toReal_one, ENNReal.coe_toReal, exactProbability]
  · have bounds := direct_probability_bounds mantissa lower upper
    exact pow_le_pow_left₀ (by linarith) (by linarith) fuel

/-- An explicit numerical demonstration derived from the universal
production certificate, not from a statistical sample. -/
theorem direct_sampler_64 (mantissa : ℕ)
    (lower : 2 ^ 62 ≤ mantissa) (upper : mantissa < 2 ^ 63)
    (read : ℕ → PMF ByteArray)
    (source : (read 8).map decodedWord = uniformWords.map some) :
    ∃ prepared, Randoml.Geometric.prepare { m := mantissa, e := -1 } = some prepared ∧
      (∀ n, |samplerCdf read prepared 64 n -
        (1 - (1 - Fixed.toReal { m := mantissa, e := -1 }) ^ n)| ≤
          1 / 18446744073709551616) ∧
      (Randoml.Geometric.sampleWith read 64 prepared none).toReal ≤
        1 / 18446744073709551616 := by
  rcases direct_sampler_bound mantissa lower upper read source 64 with
    ⟨prepared, preparation, deviation, failure, bound⟩
  have numeric : (1 / 2 : ℝ) ^ 64 = 1 / 18446744073709551616 := by norm_num
  rw [numeric] at bound
  refine ⟨prepared, preparation, fun n => (deviation n).trans bound, ?_⟩
  rwa [failure]

/-- Exact even output mass of the quotient/parity decomposition. This is an
ideal-law identity; recurrence rounding is not assumed away. -/
theorem even_mass (p : ℝ) (h : 0 < p ∧ p ≤ 1) (n : ℕ) :
  (1 - (2 * p - p ^ 2)) ^ n * (2 * p - p ^ 2) *
    (1 / (2 - p)) = (1 - p) ^ (2 * n) * p := by
  have hd : 2 - p ≠ 0 := by linarith [h.2]
  have hf : 1 - (2 * p - p ^ 2) = (1 - p) ^ 2 := by ring
  rw [hf, ← pow_mul]
  field_simp

/-- Exact odd output mass in the ideal quotient/parity factorization. These
algebraic identities do not establish independence of production draws. -/
theorem odd_mass (p : ℝ) (h : 0 < p ∧ p ≤ 1) (n : ℕ) :
  (1 - (2 * p - p ^ 2)) ^ n * (2 * p - p ^ 2) *
    ((1 - p) / (2 - p)) = (1 - p) ^ (2 * n + 1) * p := by
  have hd : 2 - p ≠ 0 := by linarith [h.2]
  have hf : 1 - (2 * p - p ^ 2) = (1 - p) ^ 2 := by ring
  rw [hf, ← pow_mul, pow_add, pow_one]
  field_simp

end DistributionProofs.Geometric
