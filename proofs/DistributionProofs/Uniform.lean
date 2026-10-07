import Mathlib.Probability.Distributions.Uniform
import Mathlib.Tactic
import DistributionProofs.Fixed
import Randoml.Distribution

namespace DistributionProofs.Uniform

/-- Exact finite-source CDF, computed by counting preimages, not enumerating
the production word domain. The production arithmetic refinement is separate. -/
noncomputable def gridCdf (size : ℕ) (x : ℝ) : ℝ :=
  ((Finset.range size).filter fun (k : ℕ) => (k : ℝ) / size ≤ x).card / (size : ℝ)

noncomputable def idealCdf (x : ℝ) : ℝ := max 0 (min x 1)

theorem prefix_count (size : ℕ) (hs : 0 < size) (x : ℝ) (hx : 0 ≤ x) :
  ((Finset.range size).filter fun (k : ℕ) => (k : ℝ) / size ≤ x).card =
    min size (⌊(size : ℝ) * x⌋₊ + 1) := by
  have hs' : (0 : ℝ) < size := by exact_mod_cast hs
  have hset : (Finset.range size).filter (fun (k : ℕ) => (k : ℝ) / size ≤ x) =
    Finset.range (min size (⌊(size : ℝ) * x⌋₊ + 1)) := by
    ext k
    simp only [Finset.mem_filter, Finset.mem_range]
    rw [div_le_iff₀ hs', mul_comm x (size : ℝ),
      ← Nat.le_floor_iff (mul_nonneg hs'.le hx)]
    rw [lt_min_iff]
    simp only [Nat.lt_add_one_iff, mul_comm]
  rw [hset, Finset.card_range]

/-- Kolmogorov/CDF distance to U[0,1] is at most one grid atom. -/
theorem grid_cdf_bound (size : ℕ) (hs : 0 < size) (x : ℝ) :
  |gridCdf size x - idealCdf x| ≤ 1 / (size : ℝ) := by
  have hs' : (0 : ℝ) < size := by exact_mod_cast hs
  by_cases hx : x < 0
  · have he : (Finset.range size).filter (fun (k : ℕ) => (k : ℝ) / size ≤ x) = ∅ := by
      ext k
      simp only [Finset.mem_filter, Finset.notMem_empty, iff_false, not_and]
      intro _ h
      exact (not_le_of_gt hx) ((div_nonneg (Nat.cast_nonneg _) hs'.le).trans h)
    simp [gridCdf, idealCdf, he, min_eq_left (by linarith : x ≤ 1),
      max_eq_left hx.le, hs'.le]
  · have hx : 0 ≤ x := le_of_not_gt hx
    by_cases h1 : 1 ≤ x
    · have he : (Finset.range size).filter (fun (k : ℕ) => (k : ℝ) / size ≤ x) =
        Finset.range size := by
        ext k
        simp only [Finset.mem_filter, Finset.mem_range, and_iff_left_iff_imp]
        intro hk
        exact ((div_le_one hs').2
          (le_of_lt (by exact_mod_cast hk : (k : ℝ) < size))).trans h1
      simp [gridCdf, idealCdf, he, min_eq_right h1, hs'.ne', hs'.le]
    · have h1 : x < 1 := lt_of_not_ge h1
      have hprod : (size : ℝ) * x < size := by nlinarith
      have hfloor : ⌊(size : ℝ) * x⌋₊ < size :=
        (Nat.floor_lt (mul_nonneg hs'.le hx)).2 hprod
      have hlo := Nat.floor_le (mul_nonneg hs'.le hx)
      have hhi := Nat.lt_floor_add_one ((size : ℝ) * x)
      rw [gridCdf, prefix_count size hs x hx,
        Nat.min_eq_right (by omega : ⌊(size : ℝ) * x⌋₊ + 1 ≤ size)]
      simp only [Nat.cast_add, Nat.cast_one]
      rw [idealCdf, min_eq_left h1.le, max_eq_right hx]
      have hlow : x ≤ ((⌊(size : ℝ) * x⌋₊ : ℝ) + 1) / size := by
        apply (le_div_iff₀ hs').2
        nlinarith
      have hupp : ((⌊(size : ℝ) * x⌋₊ : ℝ) + 1) / size ≤ x + 1 / size := by
        apply (div_le_iff₀ hs').2
        have he : (x + 1 / (size : ℝ)) * size = x * size + 1 := by
          field_simp
        rw [he]
        nlinarith
      rw [abs_of_nonneg (sub_nonneg.mpr hlow)]
      linarith

theorem grid_bound_at_zero (size : ℕ) (hs : 0 < size) :
  |gridCdf size 0 - idealCdf 0| = 1 / (size : ℝ) := by
  rw [gridCdf, prefix_count size hs 0 (by norm_num)]
  simp [idealCdf, Nat.min_eq_right hs]

/-- Source-counting CDF of the actual arithmetic expression in uniform. -/
noncomputable def productionCdf (x : ℝ) : ℝ :=
  ((Finset.range (2 ^ 32)).filter fun (n : ℕ) =>
    Fixed.toReal (Randoml.Fixed.div (Randoml.Fixed.fromInt (n : ℤ))
      (Randoml.Fixed.fromInt 4294967296)) ≤ x).card / (4294967296 : ℝ)

theorem production_cdf_eq (x : ℝ) : productionCdf x = gridCdf (2 ^ 32) x := by
  have he : (Finset.range (2 ^ 32)).filter (fun (n : ℕ) =>
      Fixed.toReal (Randoml.Fixed.div (Randoml.Fixed.fromInt (n : ℤ))
        (Randoml.Fixed.fromInt 4294967296)) ≤ x) =
      (Finset.range (2 ^ 32)).filter (fun (n : ℕ) => (n : ℝ) / 4294967296 ≤ x) := by
    ext n
    simp only [Finset.mem_filter, Finset.mem_range]
    constructor
    · rintro ⟨hn, hx⟩
      exact ⟨hn, by rwa [Fixed.uniform_word_real n hn] at hx⟩
    · rintro ⟨hn, hx⟩
      exact ⟨hn, by rwa [Fixed.uniform_word_real n hn]⟩
  unfold productionCdf gridCdf
  rw [he]
  have hd : ((2 ^ 32 : ℕ) : ℝ) = 4294967296 := by norm_num
  rw [hd]

/-- Nontrivial production arithmetic certificate under a uniform U32 input
word. Input availability, DRBG security and display formatting are separate. -/
theorem production_cdf_bound (x : ℝ) :
    |productionCdf x - idealCdf x| ≤ 1 / 4294967296 := by
  rw [production_cdf_eq]
  exact grid_cdf_bound (2 ^ 32) (by norm_num) x

/-- The CDF calculation is tied to the actual sampler output, not merely a
second expression with a similar name. -/
theorem uniform_output_refines_word (state next : Randoml.Drbg)
    (sample : Randoml.Canonical) (draw : UInt32)
    (read : state.nextU32 = some (draw, next))
    (output : Randoml.uniform state = some (sample, next)) :
    sample.value = Randoml.Fixed.div (Randoml.Fixed.fromInt (Int.ofNat draw.toNat))
      (Randoml.Fixed.fromInt 4294967296) := by
  unfold Randoml.uniform at output
  rw [read] at output
  change (Randoml.Canonical.ofValue?
    (Randoml.Fixed.div (Randoml.Fixed.fromInt (Int.ofNat draw.toNat))
      (Randoml.Fixed.fromInt 4294967296))).bind
    (fun canonical => some (canonical, next)) = some (sample, next) at output
  rcases Option.bind_eq_some_iff.mp output with ⟨canonical, valid, returned⟩
  have hc : canonical = sample := congrArg Prod.fst (Option.some.inj returned)
  subst canonical
  unfold Randoml.Canonical.ofValue? at valid
  split at valid
  · simp only [Option.some.injEq] at valid
    subst sample
    rfl
  · contradiction

/-- Available words always yield a sample at the returned source state. This
rules out a hidden validation failure or a vacuous success-only refinement. -/
theorem uniform_of_read (state next : Randoml.Drbg) (draw : UInt32)
    (read : state.nextU32 = some (draw, next)) :
    ∃ sample, Randoml.uniform state = some (sample, next) ∧
      Fixed.toReal sample.value = (draw.toNat : ℝ) / 4294967296 := by
  let value := Randoml.Fixed.div (Randoml.Fixed.fromInt (Int.ofNat draw.toNat))
    (Randoml.Fixed.fromInt 4294967296)
  have valid : Randoml.Fixed.Valid value := Fixed.uniform_word_valid draw.toNat draw.toNat_lt
  let sample : Randoml.Canonical := ⟨value, valid⟩
  refine ⟨sample, ?_, ?_⟩
  · unfold Randoml.uniform
    rw [read]
    change (Randoml.Canonical.ofValue? value).bind
      (fun canonical => some (canonical, next)) = some (sample, next)
    simp [Randoml.Canonical.ofValue?, valid, sample]
  · exact Fixed.uniform_word_real draw.toNat draw.toNat_lt

/-- The zero word is substituted, not rejected: both words zero and one
produce 1/2^32. This distinction matters in logarithmic transforms. -/
noncomputable def positiveGridCdf (size : ℕ) (x : ℝ) : ℝ :=
  ((Finset.range size).filter fun (k : ℕ) => ((max 1 k : ℕ) : ℝ) / size ≤ x).card /
    (size : ℝ)

theorem positive_grid_cdf_bound (size : ℕ) (hs : 1 < size) (x : ℝ) :
    |positiveGridCdf size x - idealCdf x| ≤ 1 / (size : ℝ) := by
  have hs' : (0 : ℝ) < size := by exact_mod_cast (by omega : 0 < size)
  by_cases hx : x < 1 / (size : ℝ)
  · have he : (Finset.range size).filter
        (fun (k : ℕ) => ((max 1 k : ℕ) : ℝ) / size ≤ x) = ∅ := by
      ext k
      simp only [Finset.mem_filter, Finset.notMem_empty, iff_false, not_and]
      intro _ hk
      have hl : (1 : ℝ) ≤ (max 1 k : ℕ) := by exact_mod_cast (le_max_left 1 k)
      have := div_le_div_of_nonneg_right hl hs'.le
      linarith
    rw [positiveGridCdf, he]
    simp only [Finset.card_empty, Nat.cast_zero, zero_div, zero_sub, abs_neg]
    rw [abs_of_nonneg (le_max_left 0 _)]
    by_cases hz : x < 0
    · rw [idealCdf, min_eq_left (by linarith : x ≤ 1), max_eq_left hz.le]
      positivity
    · rw [idealCdf, max_eq_right (le_min (by linarith) (by norm_num))]
      exact (min_le_left x 1).trans hx.le
  · have hx : 1 / (size : ℝ) ≤ x := le_of_not_gt hx
    have he : positiveGridCdf size x = gridCdf size x := by
      unfold positiveGridCdf gridCdf
      congr 1
      apply congrArg (fun s : Finset ℕ => (s.card : ℝ))
      ext k
      simp only [Finset.mem_filter]
      constructor
      · rintro ⟨hk, hxk⟩
        refine ⟨hk, ?_⟩
        have := div_le_div_of_nonneg_right
          (by exact_mod_cast (le_max_right 1 k) : (k : ℝ) ≤ (max 1 k : ℕ)) hs'.le
        linarith
      · rintro ⟨hk, hxk⟩
        refine ⟨hk, ?_⟩
        by_cases hz : k = 0
        · subst k
          simpa using hx
        · have hm : max 1 k = k := max_eq_right (by omega)
          rwa [hm]
    rw [he]
    exact grid_cdf_bound size (by omega) x

theorem nonzero_of_read (state next : Randoml.Drbg) (draw : UInt32)
    (read : state.nextU32 = some (draw, next)) :
    ∃ sample, Randoml.nonzeroUniform state = some (sample, next) ∧
      Fixed.toReal sample.value = ((max 1 draw.toNat : ℕ) : ℝ) / 4294967296 := by
  rcases uniform_of_read state next draw read with ⟨sample, output, _⟩
  have expression := uniform_output_refines_word state next sample draw read output
  simp only [Int.ofNat_eq_natCast] at expression
  by_cases hz : draw.toNat = 0
  · have zero : sample.value = Randoml.Fixed.Value.zero := by
      rw [expression, hz]
      exact Fixed.uniform_word_zero
    let value := Randoml.Fixed.div (Randoml.Fixed.fromInt 1)
      (Randoml.Fixed.fromInt 4294967296)
    have valid : Randoml.Fixed.Valid value := Fixed.uniform_word_valid 1 (by norm_num)
    let replacement : Randoml.Canonical := ⟨value, valid⟩
    refine ⟨replacement, ?_, ?_⟩
    · unfold Randoml.nonzeroUniform
      rw [output]
      change (if sample.value.m = 0 then
        (Randoml.Canonical.ofValue? value).bind (fun c => some (c, next))
        else some (sample, next)) = some (replacement, next)
      simp [zero, Randoml.Fixed.Value.zero, Randoml.Canonical.ofValue?, valid, replacement]
    · dsimp only [replacement]
      rw [hz]
      simp only [max_eq_left (by omega : (0 : ℕ) ≤ 1), Nat.cast_one]
      simpa only [Nat.cast_one] using Fixed.uniform_word_real 1 (by norm_num)
  · have nonzero : sample.value.m ≠ 0 := by
      rw [expression, Fixed.uniform_word_exact draw.toNat hz draw.toNat_lt]
      simp only [Nat.cast_eq_zero, ne_eq]
      positivity
    refine ⟨sample, ?_, ?_⟩
    · unfold Randoml.nonzeroUniform
      rw [output]
      change (if sample.value.m = 0 then _ else some (sample, next)) = _
      simp [nonzero]
    · rw [expression, Fixed.uniform_word_real draw.toNat draw.toNat_lt,
        max_eq_right (by omega : 1 ≤ draw.toNat)]

noncomputable def nonzeroProductionCdf (x : ℝ) : ℝ :=
  ((Finset.range (2 ^ 32)).filter fun (n : ℕ) =>
    Fixed.toReal (Randoml.Fixed.div (Randoml.Fixed.fromInt (max 1 n : ℕ))
      (Randoml.Fixed.fromInt 4294967296)) ≤ x).card / (4294967296 : ℝ)

theorem nonzero_production_cdf_eq (x : ℝ) :
    nonzeroProductionCdf x = positiveGridCdf (2 ^ 32) x := by
  have he : (Finset.range (2 ^ 32)).filter (fun (n : ℕ) =>
      Fixed.toReal (Randoml.Fixed.div (Randoml.Fixed.fromInt (max 1 n : ℕ))
        (Randoml.Fixed.fromInt 4294967296)) ≤ x) =
      (Finset.range (2 ^ 32)).filter
        (fun (n : ℕ) => ((max 1 n : ℕ) : ℝ) / 4294967296 ≤ x) := by
    ext n
    simp only [Finset.mem_filter, Finset.mem_range]
    constructor
    · rintro ⟨hn, hx⟩
      have hm : max 1 n < 2 ^ 32 := max_lt_iff.mpr ⟨by norm_num, hn⟩
      exact ⟨hn, by rwa [Fixed.uniform_word_real (max 1 n) hm] at hx⟩
    · rintro ⟨hn, hx⟩
      have hm : max 1 n < 2 ^ 32 := max_lt_iff.mpr ⟨by norm_num, hn⟩
      exact ⟨hn, by rwa [Fixed.uniform_word_real (max 1 n) hm]⟩
  unfold nonzeroProductionCdf positiveGridCdf
  rw [he]
  have hd : ((2 ^ 32 : ℕ) : ℝ) = 4294967296 := by norm_num
  rw [hd]

theorem nonzero_production_cdf_bound (x : ℝ) :
    |nonzeroProductionCdf x - idealCdf x| ≤ 1 / 4294967296 := by
  rw [nonzero_production_cdf_eq]
  exact positive_grid_cdf_bound (2 ^ 32) (by norm_num) x

end DistributionProofs.Uniform
