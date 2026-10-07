import Mathlib.Probability.Distributions.Uniform
import Mathlib.Tactic
import Randoml.Geometric

open private baseLoop from Randoml.Geometric

private def zeros : ByteArray := ⟨#[0, 0, 0, 0, 0, 0, 0, 0]⟩

/- A certain success on the first valid word means zero failures, not one.
This pins both the count convention and the first-trial fuel boundary. -/
example (count : Nat) :
    baseLoop (fun _ => PMF.pure zeros) 1 1 count = PMF.pure (some count) := by
  unfold baseLoop
  change (PMF.pure zeros).bind _ = _
  rw [PMF.pure_bind]
  have word : Randoml.u64be zeros = 0 := by decide
  have size : zeros.size = 8 := rfl
  simp [size, word]
  rfl

/- Exhaustion is failure, never a saturated or fabricated success. -/
example (count : Nat) :
    baseLoop (fun _ => PMF.pure zeros) 1 0 count = PMF.pure none := by rfl

/- A malformed source read must fail, even with available trial fuel. -/
example (count : Nat) :
    baseLoop (fun _ => PMF.pure ByteArray.empty) 1 1 count = PMF.pure none := by
  unfold baseLoop
  change (PMF.pure ByteArray.empty).bind _ = _
  rw [PMF.pure_bind]
  simp
  rfl
