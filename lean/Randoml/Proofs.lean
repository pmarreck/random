import Randoml.Drbg

namespace Randoml

theorem fill_advances_position (state : Drbg) (count : Nat)
  (result : ByteArray × Drbg) (h : state.fill count = some result) :
  result.2.position = state.position + count := by
  simp [Drbg.fill] at h
  rcases h with ⟨_, rfl⟩
  rfl

theorem seek_sets_position (state next : Drbg) (position : Nat)
  (h : state.seek position = some next) : next.position = position := by
  simp [Drbg.seek] at h
  rcases h with ⟨_, rfl⟩
  rfl

theorem fill_preserves_key (state : Drbg) (count : Nat)
  (result : ByteArray × Drbg) (h : state.fill count = some result) :
  result.2.key = state.key := by
  simp [Drbg.fill] at h
  rcases h with ⟨_, rfl⟩
  rfl

theorem fill_respects_position_limit (state : Drbg) (count : Nat)
  (result : ByteArray × Drbg) (h : state.fill count = some result) :
  result.2.position ≤ maxExactPosition := by
  simp [Drbg.fill] at h
  rcases h with ⟨⟨within, countBound⟩, rfl⟩
  calc
    state.position + count ≤ state.position +
        (maxExactPosition - state.position) := Nat.add_le_add_left countBound _
    _ = maxExactPosition := Nat.add_sub_of_le within

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

end Randoml
