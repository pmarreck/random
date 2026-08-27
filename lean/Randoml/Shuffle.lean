import Init.Data.Array.Perm

namespace Randoml.Shuffle

/-- The exact pure swap step used by the CLI's Fisher–Yates loop. -/
def swapChoice (items : Array α) (remaining choice : Nat) : Array α :=
  items.swapIfInBounds (remaining - 1) (choice - 1)

theorem swapIfInBounds_perm (items : Array α) (first second : Nat) :
    (items.swapIfInBounds first second).Perm items := by
  rw [Array.swapIfInBounds_def]
  split
  · split
    · exact Array.swap_perm (by assumption) (by assumption)
    · exact Array.Perm.rfl
  · exact Array.Perm.rfl

theorem swapChoice_perm (items : Array α) (remaining choice : Nat) :
    (swapChoice items remaining choice).Perm items := by
  exact swapIfInBounds_perm items (remaining - 1) (choice - 1)

def applyChoices (items : Array α) (schedule : List (Nat × Nat)) : Array α :=
  schedule.foldl (fun items step => swapChoice items step.1 step.2) items

theorem applyChoices_perm (items : Array α) (schedule : List (Nat × Nat)) :
    (applyChoices items schedule).Perm items := by
  induction schedule generalizing items with
  | nil => exact Array.Perm.rfl
  | cons step schedule induction =>
      exact (induction (swapChoice items step.1 step.2)).trans
        (swapChoice_perm items step.1 step.2)

end Randoml.Shuffle
