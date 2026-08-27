import Randoml.Drbg
import Randoml.Distribution
import Randoml.Chart
import Randoml.Shuffle
import Init.Data.UInt.Lemmas

namespace Randoml

theorem seek_sets_position (state next : Drbg) (position : Nat)
  (h : state.seek position = some next) : next.position = position := by
  simp [Drbg.seek] at h
  rcases h with ⟨_, rfl⟩
  rfl

theorem nextU32_advances_position (state next : Drbg) (draw : UInt32)
    (h : state.nextU32 = some (draw, next)) :
    next.position = state.position + 4 := by
  unfold Drbg.nextU32 at h
  generalize fillResult : state.fill 4 = result at h
  cases result with
  | none => simp at h
  | some result =>
      rcases result with ⟨bytes, filled⟩
      simp at h
      rcases h with ⟨_, rfl⟩
      exact fill_advances_position state 4 (bytes, filled) fillResult

theorem nextU32_preserves_key (state next : Drbg) (draw : UInt32)
    (h : state.nextU32 = some (draw, next)) : next.key = state.key := by
  unfold Drbg.nextU32 at h
  generalize fillResult : state.fill 4 = result at h
  cases result with
  | none => simp at h
  | some result =>
      rcases result with ⟨bytes, filled⟩
      simp at h
      rcases h with ⟨_, rfl⟩
      exact fill_preserves_key state 4 (bytes, filled) fillResult

theorem uniform_advances_position (state next : Drbg) (sample : Canonical)
    (h : uniform state = some (sample, next)) :
    next.position = state.position + 4 := by
  unfold uniform at h
  rcases Option.bind_eq_some_iff.mp h with ⟨drawn, drawResult, remainder⟩
  rcases drawn with ⟨draw, drawnState⟩
  rcases Option.bind_eq_some_iff.mp remainder with ⟨canonical, _, equality⟩
  have pairEquality : (canonical, drawnState) = (sample, next) := Option.some.inj equality
  have stateEquality : drawnState = next :=
    congrArg (fun pair : Canonical × Drbg => pair.2) pairEquality
  rw [← stateEquality]
  exact nextU32_advances_position state drawnState draw drawResult

theorem uniform_preserves_key (state next : Drbg) (sample : Canonical)
    (h : uniform state = some (sample, next)) : next.key = state.key := by
  unfold uniform at h
  rcases Option.bind_eq_some_iff.mp h with ⟨drawn, drawResult, remainder⟩
  rcases drawn with ⟨draw, drawnState⟩
  rcases Option.bind_eq_some_iff.mp remainder with ⟨canonical, _, equality⟩
  have pairEquality : (canonical, drawnState) = (sample, next) := Option.some.inj equality
  have stateEquality : drawnState = next :=
    congrArg (fun pair : Canonical × Drbg => pair.2) pairEquality
  rw [← stateEquality]
  exact nextU32_preserves_key state drawnState draw drawResult

theorem nextU64_advances_position (state next : Drbg) (draw : UInt64)
    (h : state.nextU64 = some (draw, next)) :
    next.position = state.position + 8 := by
  unfold Drbg.nextU64 at h
  generalize fillResult : state.fill 8 = result at h
  cases result with
  | none => simp at h
  | some result =>
      rcases result with ⟨bytes, filled⟩
      simp at h
      rcases h with ⟨_, rfl⟩
      exact fill_advances_position state 8 (bytes, filled) fillResult

theorem nextU64_preserves_key (state next : Drbg) (draw : UInt64)
    (h : state.nextU64 = some (draw, next)) : next.key = state.key := by
  unfold Drbg.nextU64 at h
  generalize fillResult : state.fill 8 = result at h
  cases result with
  | none => simp at h
  | some result =>
      rcases result with ⟨bytes, filled⟩
      simp at h
      rcases h with ⟨_, rfl⟩
      exact fill_preserves_key state 8 (bytes, filled) fillResult

def adjacentSwap : List α → Nat → List α
  | [], _ => []
  | [item], _ => [item]
  | first :: second :: rest, 0 => second :: first :: rest
  | first :: second :: rest, index + 1 =>
      first :: adjacentSwap (second :: rest) index

theorem adjacentSwap_perm (items : List α) (index : Nat) :
    (adjacentSwap items index).Perm items := by
  induction items generalizing index with
  | nil => simp [adjacentSwap]
  | cons first rest induction =>
      cases rest with
      | nil => simp [adjacentSwap]
      | cons second tail =>
          cases index with
          | zero => exact List.Perm.swap first second tail
          | succ index =>
              exact List.Perm.cons first (induction index)

def applySwapSchedule (items : List α) (schedule : List Nat) : List α :=
  schedule.foldl adjacentSwap items

theorem swap_schedule_preserves_population (items : List α) (schedule : List Nat) :
    (applySwapSchedule items schedule).Perm items := by
  induction schedule generalizing items with
  | nil => exact List.Perm.refl items
  | cons index rest induction =>
      exact (induction (adjacentSwap items index)).trans (adjacentSwap_perm items index)

def mapDraw (start span draw : Nat) : Nat := start + draw % span

theorem mapped_draw_is_in_range (start span draw : Nat) (positive : 0 < span) :
    start ≤ mapDraw start span draw ∧ mapDraw start span draw < start + span := by
  unfold mapDraw
  constructor
  · exact Nat.le_add_right start (draw % span)
  · have remainder := Nat.mod_lt draw positive
    exact Nat.add_lt_add_left remainder start

theorem rangeWithFuel_result_bounds (fuel : Nat) (state : Drbg) (start : Int)
    (span : Nat) (positive : 0 < span) (result : Int × Drbg)
    (h : Drbg.rangeWithFuel fuel state start span = some result) :
    start ≤ result.1 ∧ result.1 < start + Int.ofNat span := by
  induction fuel generalizing state with
  | zero => simp [Drbg.rangeWithFuel] at h
  | succ fuel induction =>
      rw [Drbg.rangeWithFuel] at h
      split at h
      · generalize drawResult : state.nextU32 = drawn at h
        cases drawn with
        | none => simp at h
        | some drawn =>
            rcases drawn with ⟨draw, next⟩
            simp at h
            split at h
            · simp only [Option.some.injEq] at h
              subst result
              have remainder := Nat.mod_lt draw.toNat positive
              exact ⟨Int.le_add_of_nonneg_right (Int.natCast_nonneg _),
                Int.add_lt_add_left (Int.ofNat_lt.mpr remainder) start⟩
            · exact induction next h
      · generalize drawResult : state.nextU64 = drawn at h
        cases drawn with
        | none => simp at h
        | some drawn =>
            rcases drawn with ⟨draw, next⟩
            simp at h
            split at h
            · simp only [Option.some.injEq] at h
              subst result
              have remainder := Nat.mod_lt draw.toNat positive
              exact ⟨Int.le_add_of_nonneg_right (Int.natCast_nonneg _),
                Int.add_lt_add_left (Int.ofNat_lt.mpr remainder) start⟩
            · exact induction next h

theorem range_result_bounds (state : Drbg) (start stop : Int) (result : Int × Drbg)
    (h : state.range start stop = some result) :
    start ≤ result.1 ∧ result.1 ≤ stop := by
  unfold Drbg.range at h
  split at h
  · change (none : Option (Int × Drbg)) = some result at h
    cases h
  · rename_i ordered
    dsimp only at h
    split at h
    · change (none : Option (Int × Drbg)) = some result at h
      cases h
    · rename_i valid
      split at h
      · change some (start, state) = some result at h
        have equal : (start, state) = result := Option.some.inj h
        rw [← equal]
        exact ⟨Int.le_refl start, Int.le_of_not_gt ordered⟩
      · have positive : 0 < (stop - start + 1).toNat := by omega
        have bounded := rangeWithFuel_result_bounds
          ((maxExactPosition - state.position) / 4 + 1) state start
          (stop - start + 1).toNat positive result h
        have spanPositive : 0 < stop - start + 1 := by omega
        have restored : Int.ofNat (stop - start + 1).toNat = stop - start + 1 :=
          Int.toNat_of_nonneg (Int.le_of_lt spanPositive)
        rw [restored] at bounded
        have normalized : start + (stop - start + 1) = stop + 1 := by omega
        rw [normalized] at bounded
        exact ⟨bounded.1, Int.lt_add_one_iff.mp bounded.2⟩

def streamSlice (stream : Nat → α) : Nat → Nat → List α
  | _, 0 => []
  | position, count + 1 => stream position :: streamSlice stream (position + 1) count

theorem stream_slice_chunking (stream : Nat → α) (position first second : Nat) :
    streamSlice stream position (first + second) =
      streamSlice stream position first ++ streamSlice stream (position + first) second := by
  induction first generalizing position with
  | zero => simp [streamSlice]
  | succ first induction =>
      rw [Nat.succ_add]
      simp only [streamSlice, List.cons_append]
      rw [induction (position + 1)]
      simp [Nat.add_comm, Nat.add_left_comm]

theorem canonical_invariant (value : Canonical) : Fixed.Valid value.value :=
  value.invariant

theorem canonical_ofValue_sound (value : Fixed.Value) (canonical : Canonical)
    (_h : Canonical.ofValue? value = some canonical) : Fixed.Valid canonical.value := by
  exact canonical.invariant

theorem canonical_ofValue_preserves_value (value : Fixed.Value) (canonical : Canonical)
    (h : Canonical.ofValue? value = some canonical) : canonical.value = value := by
  unfold Canonical.ofValue? at h
  split at h
  · simp only [Option.some.injEq] at h
    subst canonical
    rfl
  · contradiction

theorem positive_is_canonical_and_positive (value : Positive) :
    Fixed.Valid value.value ∧ 0 < value.value.m := by
  exact ⟨value.canonical.invariant, value.positive⟩

theorem normal_parameters_well_formed (parameters : NormalParameters) :
    Fixed.Valid parameters.mean.value ∧ Fixed.Valid parameters.stddev.value ∧
      0 < parameters.stddev.value.m := by
  exact ⟨parameters.mean.invariant, parameters.stddev.canonical.invariant,
    parameters.stddev.positive⟩

theorem beta_parameters_well_formed (parameters : BetaParameters) :
    Fixed.Valid parameters.alpha.value ∧ 0 < parameters.alpha.value.m ∧
      Fixed.Valid parameters.beta.value ∧ 0 < parameters.beta.value.m := by
  exact ⟨parameters.alpha.canonical.invariant, parameters.alpha.positive,
    parameters.beta.canonical.invariant, parameters.beta.positive⟩

theorem chart_height_is_normalized (geometry : Chart.Model) (index : Nat)
    (within : index < geometry.curve.heights.size) :
    geometry.curve.heights[index].toNat ≤ 65535 := by
  have bounded := UInt16.toNat_lt geometry.curve.heights[index]
  omega

theorem curve_height_is_zero_when_nonpositive (relative : Fixed.Value)
    (h : relative.m ≤ 0) : Curve.height relative = 0 := by
  simp [Curve.height, h]

theorem curve_height_saturates_at_one (relative : Fixed.Value)
    (positive : ¬ relative.m ≤ 0)
    (atLeastOne : Fixed.compare relative (Fixed.fromInt 1) ≥ 0) :
    Curve.height relative = UInt16.ofNat 65535 := by
  simp [Curve.height, positive, atLeastOne]

theorem production_shuffle_step_preserves_population (items : Array α)
    (remaining choice : Nat) :
    (Shuffle.swapChoice items remaining choice).Perm items :=
  Shuffle.swapChoice_perm items remaining choice

theorem production_shuffle_schedule_preserves_population (items : Array α)
    (schedule : List (Nat × Nat)) :
    (Shuffle.applyChoices items schedule).Perm items :=
  Shuffle.applyChoices_perm items schedule

end Randoml
