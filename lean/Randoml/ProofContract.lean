import Randoml.Proofs

namespace Randoml

/-!
These examples deliberately restate the release-critical theorem types. They
make a weakened or accidentally generalized theorem fail the ordinary Lean
build instead of continuing to satisfy a name-only dependency audit.
-/

example (state : Drbg) (count : Nat) (result : ByteArray × Drbg)
    (h : state.fill count = some result) :
    result.2.position = state.position + count :=
  fill_advances_position state count result h

example (state : Drbg) (count : Nat) (result : ByteArray × Drbg)
    (h : state.fill count = some result) : result.2.key = state.key :=
  fill_preserves_key state count result h

example (state : Drbg) (count : Nat) (result : ByteArray × Drbg)
    (h : state.fill count = some result) : result.2.position ≤ maxExactPosition :=
  fill_respects_position_limit state count result h

example (state next : Drbg) (sample : Canonical)
    (h : uniform state = some (sample, next)) :
    next.position = state.position + 4 :=
  uniform_advances_position state next sample h

example (state next : Drbg) (sample : Canonical)
    (h : uniform state = some (sample, next)) : next.key = state.key :=
  uniform_preserves_key state next sample h

example (state : Drbg) (start stop : Int) (result : Int × Drbg)
    (h : state.range start stop = some result) :
    start ≤ result.1 ∧ result.1 ≤ stop :=
  range_result_bounds state start stop result h

example (items : Array α) (remaining choice : Nat) :
    (Shuffle.swapChoice items remaining choice).Perm items :=
  production_shuffle_step_preserves_population items remaining choice

example (items : Array α) (schedule : List (Nat × Nat)) :
    (Shuffle.applyChoices items schedule).Perm items :=
  production_shuffle_schedule_preserves_population items schedule

example (relative : Fixed.Value) (h : relative.m ≤ 0) :
    Curve.height relative = 0 :=
  curve_height_is_zero_when_nonpositive relative h

example (relative : Fixed.Value) (positive : ¬ relative.m ≤ 0)
    (atLeastOne : Fixed.compare relative (Fixed.fromInt 1) ≥ 0) :
    Curve.height relative = UInt16.ofNat 65535 :=
  curve_height_saturates_at_one relative positive atLeastOne

end Randoml
