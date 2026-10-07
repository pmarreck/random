import Mathlib.Tactic
import Randoml.Fixed

namespace DistributionProofs.Fixed

set_option maxRecDepth 4096
private def divisionStep (b : ℕ) (state : ℕ × ℕ) (_ : ℕ) : ℕ × ℕ :=
  if b ≤ state.1 * 2 then
    (state.1 * 2 - b, state.2 * 2 + 1)
  else
    (state.1 * 2, state.2 * 2)

/-- Loop invariant for the production long-division calculation. Both the
quotient and remainder are accounted for; there is no empirical error budget. -/
private theorem division_invariant (a b : ℕ) (hb : 0 < b) (n : ℕ) :
  let state := (List.range n).foldl (divisionStep b) (a % b, 0)
  (a / b * 2 ^ n + state.2) * b + state.1 = a * 2 ^ n ∧ state.1 < b := by
  induction n with
  | zero =>
    simp only [List.range_zero, List.foldl_nil, pow_zero, mul_one, add_zero]
    exact ⟨by simpa [Nat.mul_comm, Nat.add_comm] using Nat.mod_add_div a b,
      Nat.mod_lt a hb⟩
  | succ n ih =>
    let state := (List.range n).foldl (divisionStep b) (a % b, 0)
    change (a / b * 2 ^ n + state.2) * b + state.1 = a * 2 ^ n ∧ state.1 < b at ih
    rw [List.range_succ, List.foldl_append]
    change (a / b * 2 ^ (n + 1) + (divisionStep b state n).2) * b +
      (divisionStep b state n).1 = a * 2 ^ (n + 1) ∧ (divisionStep b state n).1 < b
    rw [pow_succ]
    unfold divisionStep
    split
    · rename_i h
      constructor
      · nlinarith [Nat.sub_add_cancel h]
      · omega
    · rename_i h
      constructor
      · nlinarith [ih.1]
      · simpa only [Prod.fst] using Nat.lt_of_not_ge h

/-- The actual executable division loop equals exact integer division of the
scaled numerator, for every positive denominator and arbitrary numerator. -/
theorem divMagnitude_exact (a b : ℕ) (hb : 0 < b) :
  Randoml.Fixed.divMagnitude a b = a * 2 ^ 62 / b := by
  have hi := division_invariant a b hb 62
  let state := (List.range 62).foldl (divisionStep b) (a % b, 0)
  change (a / b * 2 ^ 62 + state.2) * b + state.1 = a * 2 ^ 62 ∧ state.1 < b at hi
  have he : a * 2 ^ 62 / b = a / b * 2 ^ 62 + state.2 := by
    apply Nat.div_eq_of_lt_le
    · omega
    · nlinarith [hi.1, hi.2]
  rw [he]
  rfl

/-- Universal arithmetic error of the production division loop, in units
of the scaled mantissa. This derives the error from the actual remainder. -/
theorem divMagnitude_rounding (a b : ℕ) (hb : 0 < b) :
    0 ≤ (a : ℝ) * 2 ^ 62 / (b : ℝ) - (Randoml.Fixed.divMagnitude a b : ℝ) ∧
      (a : ℝ) * 2 ^ 62 / (b : ℝ) - (Randoml.Fixed.divMagnitude a b : ℝ) < 1 := by
  rw [divMagnitude_exact a b hb]
  have hb' : (0 : ℝ) < b := by exact_mod_cast hb
  have equation : (((a * 2 ^ 62 / b : ℕ) : ℝ) * (b : ℝ)) +
      ((a * 2 ^ 62 % b : ℕ) : ℝ) = (a : ℝ) * 2 ^ 62 := by
    have natural : (a * 2 ^ 62 / b) * b + a * 2 ^ 62 % b = a * 2 ^ 62 := by
      simpa only [Nat.mul_comm] using (Nat.div_add_mod (a * 2 ^ 62) b)
    exact_mod_cast natural
  have error : (a : ℝ) * 2 ^ 62 / b - ((a * 2 ^ 62 / b : ℕ) : ℝ) =
      ((a * 2 ^ 62 % b : ℕ) : ℝ) / b := by
    field_simp
    nlinarith [equation]
  rw [error]
  refine ⟨div_nonneg (Nat.cast_nonneg _) hb'.le, ?_⟩
  apply (div_lt_one hb').2
  exact_mod_cast Nat.mod_lt (a * 2 ^ 62) hb

/-- Canonical positive mantissas are unchanged by the actual normalizer. -/
theorem norm_nat_id (mantissa : ℕ) (exponent : ℤ)
    (hl : 2 ^ 62 ≤ mantissa) (hh : mantissa < 2 ^ 63) :
    Randoml.Fixed.norm (mantissa : ℤ) exponent = { m := mantissa, e := exponent } := by
  have hn : mantissa ≠ 0 := by omega
  have hlog : mantissa.log2 = 62 := by
    have hl' := (Nat.le_log2 hn).2 hl
    have hh' := (Nat.log2_lt hn).2 hh
    omega
  simp [Randoml.Fixed.norm, Randoml.Fixed.signedMagnitude, hlog, hn]

/-- An input word is normalized without loss before distribution arithmetic. -/
theorem fromInt_nat_exact (n : ℕ) (hn : n ≠ 0) (hh : n < 2 ^ 63) :
    Randoml.Fixed.fromInt (n : ℤ) =
      { m := (n * 2 ^ (62 - n.log2) : ℕ), e := n.log2 } := by
  have hlog : n.log2 ≤ 62 := by
    have := (Nat.log2_lt hn).2 hh
    omega
  unfold Randoml.Fixed.fromInt Randoml.Fixed.norm
  simp only [Nat.cast_eq_zero, hn, ↓reduceIte,
    not_lt_of_ge (Int.natCast_nonneg n), Int.natAbs_natCast]
  by_cases hb : n.log2 + 1 < 63
  · have hs : 63 - (n.log2 + 1) = 62 - n.log2 := by omega
    simp only [hb, ↓reduceIte, hs, Randoml.Fixed.signedMagnitude,
      Randoml.Fixed.pow2]
    congr 1
    change (62 : ℤ) - ((62 - n.log2 : ℕ) : ℤ) = (n.log2 : ℤ)
    omega
  · have he : n.log2 = 62 := by omega
    simp [he, Randoml.Fixed.signedMagnitude]

/-- Bounds on the mantissa constructed without loss from a bounded integer. -/
theorem normalized_nat_bounds (n : ℕ) (hn : n ≠ 0) (hh : n < 2 ^ 63) :
    2 ^ 62 ≤ n * 2 ^ (62 - n.log2) ∧ n * 2 ^ (62 - n.log2) < 2 ^ 63 := by
  have hlog : n.log2 ≤ 62 := by
    have := (Nat.log2_lt hn).2 hh
    omega
  have hl := Nat.mul_le_mul_right (2 ^ (62 - n.log2))
    ((Nat.le_log2 hn).1 (Nat.le_refl n.log2))
  have hu := mul_lt_mul_of_pos_right (Nat.lt_log2_self (n := n))
    (by positivity : 0 < (2 : ℕ) ^ (62 - n.log2))
  have hlExp : n.log2 + (62 - n.log2) = 62 := by omega
  have huExp : n.log2 + 1 + (62 - n.log2) = 63 := by omega
  rw [← pow_add, hlExp] at hl
  rw [← pow_add, huExp] at hu
  exact ⟨hl, hu⟩

/-- Binary powers up to 2^62 enter the arithmetic kernel exactly. -/
theorem fromInt_pow2 (k : ℕ) (hk : k ≤ 62) :
    Randoml.Fixed.fromInt ((2 ^ k : ℕ) : ℤ) = { m := (2 ^ 62 : ℕ), e := k } := by
  have hh : (2 : ℕ) ^ k < 2 ^ 63 :=
    Nat.pow_lt_pow_right (by norm_num) (by omega)
  rw [fromInt_nat_exact _ (by positivity) hh, Nat.log2_two_pow]
  have he : (2 : ℕ) ^ k * 2 ^ (62 - k) = 2 ^ 62 := by
    rw [← pow_add, Nat.add_sub_of_le hk]
  rw [he]

/-- Exact real interpretation of the portable integer mantissa/exponent pair. -/
noncomputable def toReal (value : Randoml.Fixed.Value) : ℝ :=
  (value.m : ℝ) * (2 : ℝ) ^ (value.e - 62)

/-- The zero input word remains the canonical zero. -/
theorem uniform_word_zero :
    Randoml.Fixed.div (Randoml.Fixed.fromInt 0) (Randoml.Fixed.fromInt 4294967296) =
      Randoml.Fixed.Value.zero := by
  have hd := fromInt_pow2 32 (by omega)
  norm_num only [Nat.reducePow] at hd
  rw [Randoml.Fixed.div, hd]
  simp [Randoml.Fixed.div?, Randoml.Fixed.fromInt, Randoml.Fixed.Value.zero]

/-- The production uniform-word expression does not incur a division error:
division by 2^32 changes only the exponent of the exact normalized word. -/
theorem uniform_word_exact (n : ℕ) (hn : n ≠ 0) (hh : n < 2 ^ 32) :
    Randoml.Fixed.div (Randoml.Fixed.fromInt (n : ℤ)) (Randoml.Fixed.fromInt 4294967296) =
      { m := (n * 2 ^ (62 - n.log2) : ℕ), e := (n.log2 : ℤ) - 32 } := by
  have hh' : n < 2 ^ 63 := by omega
  have bounds := normalized_nat_bounds n hn hh'
  have hm : 0 < n * 2 ^ (62 - n.log2) := by omega
  have hd : Randoml.Fixed.fromInt 4294967296 =
      { m := (2 ^ 62 : ℕ), e := 32 } := by
    change Randoml.Fixed.fromInt ((2 ^ (32 : ℕ) : ℕ) : ℤ) = _
    rw [fromInt_nat_exact (2 ^ (32 : ℕ)) (by norm_num) (by norm_num), Nat.log2_two_pow]
    norm_num
  rw [fromInt_nat_exact n hn hh', hd]
  simp only [Randoml.Fixed.div, Randoml.Fixed.div?, Nat.cast_eq_zero,
    hm.ne', Int.natAbs_natCast]
  have nz : (2 : ℕ) ^ 62 ≠ 0 := by positivity
  have ha : decide (((n * 2 ^ (62 - n.log2) : ℕ) : ℤ) < 0) = false := by simp
  have hb : decide (((2 ^ (62 : ℕ) : ℕ) : ℤ) < 0) = false := by simp
  simp only [nz, if_false, ha, hb]
  have hfalse : (false != false) = false := rfl
  rw [hfalse, Option.getD_some]
  rw [divMagnitude_exact _ (2 ^ (62 : ℕ)) (by norm_num),
    Nat.mul_div_cancel _ (by norm_num)]
  simp only [Randoml.Fixed.signedMagnitude]
  exact norm_nat_id _ _ bounds.1 bounds.2

/-- Canonical validation cannot reject any available U32 input word. -/
theorem uniform_word_valid (n : ℕ) (hh : n < 2 ^ 32) :
    Randoml.Fixed.Valid (Randoml.Fixed.div (Randoml.Fixed.fromInt (n : ℤ))
      (Randoml.Fixed.fromInt 4294967296)) := by
  by_cases hn : n = 0
  · subst n
    simp only [Nat.cast_zero]
    rw [uniform_word_zero]
    exact Or.inl ⟨rfl, rfl⟩
  · rw [uniform_word_exact n hn hh]
    apply Or.inr
    change 2 ^ 62 ≤ n * 2 ^ (62 - n.log2) ∧ n * 2 ^ (62 - n.log2) < 2 ^ 63
    exact normalized_nat_bounds n hn (by omega)

/-- Every actual uniform word has the expected dyadic real value, including
zero. This is a universal production-arithmetic refinement, not a sample test. -/
theorem uniform_word_real (n : ℕ) (hh : n < 2 ^ 32) :
    toReal (Randoml.Fixed.div (Randoml.Fixed.fromInt (n : ℤ))
      (Randoml.Fixed.fromInt 4294967296)) = (n : ℝ) / 4294967296 := by
  by_cases hn : n = 0
  · subst n
    simp only [Nat.cast_zero]
    rw [uniform_word_zero]
    simp [toReal, Randoml.Fixed.Value.zero]
  · rw [uniform_word_exact n hn hh]
    simp only [toReal]
    change ((n * 2 ^ (62 - n.log2) : ℕ) : ℝ) *
      (2 : ℝ) ^ ((n.log2 : ℤ) - 32 - 62) = _
    rw [Nat.cast_mul, Nat.cast_pow, Nat.cast_ofNat]
    have hl : n.log2 ≤ 62 := by
      have hlog := (Nat.log2_lt hn).2 hh
      omega
    rw [← zpow_natCast, mul_assoc, ← zpow_add₀ (by norm_num : (2 : ℝ) ≠ 0)]
    have he : ((62 - n.log2 : ℕ) : ℤ) + ((n.log2 : ℤ) - 32 - 62) = -32 := by omega
    rw [he]
    norm_num [div_eq_mul_inv]

end DistributionProofs.Fixed
