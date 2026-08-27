import Randoml.Blake3

namespace Randoml

def kdfContext : String := "random drbg 2026-08-04 v1"
def maxExactPosition : Nat := 9007199254740992
def maxFillCount : Nat := 1048576

structure Drbg where
  private mk ::
  key : ByteArray
  position : Nat
deriving BEq

def Drbg.init (seed : ByteArray) : Option Drbg :=
  if seed.size != 32 then none else do
    let key ← Blake3.deriveKey kdfContext seed
    pure { key, position := 0 }

def Drbg.seek (state : Drbg) (position : Nat) : Option Drbg :=
  if position ≤ maxExactPosition then some { state with position } else none

def Drbg.restore (key : ByteArray) (position : Nat) : Option Drbg :=
  if key.size = 32 ∧ position ≤ maxExactPosition then some { key, position } else none

def Drbg.fill (state : Drbg) (count : Nat) : Option (ByteArray × Drbg) :=
  if state.position ≤ maxExactPosition ∧
      count ≤ maxExactPosition - state.position ∧ count ≤ maxFillCount then do
    let bytes ← Blake3.xofAt state.key state.position count
    pure (bytes, { state with position := state.position + count })
  else none

def u32be (bytes : ByteArray) : UInt32 :=
  (bytes.get! 0).toUInt32 <<< 24 |||
    (bytes.get! 1).toUInt32 <<< 16 |||
    (bytes.get! 2).toUInt32 <<< 8 |||
    (bytes.get! 3).toUInt32

def Drbg.nextU32 (state : Drbg) : Option (UInt32 × Drbg) := do
  let (bytes, next) ← state.fill 4
  pure (u32be bytes, next)

def u64be (bytes : ByteArray) : UInt64 :=
  (List.range 8).foldl (fun value index =>
    (value <<< 8) ||| (bytes.get! index).toUInt64) 0

def Drbg.nextU64 (state : Drbg) : Option (UInt64 × Drbg) := do
  let (bytes, next) ← state.fill 8
  pure (u64be bytes, next)

def Drbg.rangeWithFuel : Nat → Drbg → Int → Nat → Option (Int × Drbg)
  | 0, _, _, _ => none
  | fuel + 1, state, start, span =>
      if span ≤ 0x100000000 then do
        let sampleSpace : Nat := 0x100000000
        let bound := sampleSpace - sampleSpace % span
        let (draw, next) ← state.nextU32
        if draw.toNat < bound then
          pure (start + Int.ofNat (draw.toNat % span), next)
        else
          rangeWithFuel fuel next start span
      else do
        let sampleSpace : Nat := 0x10000000000000000
        let remainder := sampleSpace % span
        let bound := sampleSpace - remainder
        let (draw, next) ← state.nextU64
        if remainder = 0 || draw.toNat < bound then
          pure (start + Int.ofNat (draw.toNat % span), next)
        else
          rangeWithFuel fuel next start span

/--
Draw an unbiased integer. Rejection is structurally bounded by the maximum
DRBG cursor: an adversarial stream therefore returns none instead of making
termination an unproved assumption.
-/
def Drbg.range (state : Drbg) (start stop : Int) : Option (Int × Drbg) :=
  if stop < start then
    none
  else
    let spanInt := stop - start + 1
    if spanInt ≤ 0 ∨ spanInt > maxExactPosition then
      none
    else
      let span := spanInt.toNat
      if span = 1 then
        some (start, state)
      else
        rangeWithFuel ((maxExactPosition - state.position) / 4 + 1) state start span

theorem fill_advances_position (state : Drbg) (count : Nat)
    (result : ByteArray × Drbg) (h : state.fill count = some result) :
    result.2.position = state.position + count := by
  unfold Drbg.fill at h
  split at h
  · rcases Option.bind_eq_some_iff.mp h with ⟨bytes, _, equality⟩
    have pairEquality : (bytes, { state with position := state.position + count }) = result :=
      Option.some.inj equality
    rw [← pairEquality]
  · contradiction

theorem fill_preserves_key (state : Drbg) (count : Nat)
    (result : ByteArray × Drbg) (h : state.fill count = some result) :
    result.2.key = state.key := by
  unfold Drbg.fill at h
  split at h
  · rcases Option.bind_eq_some_iff.mp h with ⟨bytes, _, equality⟩
    have pairEquality : (bytes, { state with position := state.position + count }) = result :=
      Option.some.inj equality
    rw [← pairEquality]
  · contradiction

theorem fill_respects_position_limit (state : Drbg) (count : Nat)
    (result : ByteArray × Drbg) (h : state.fill count = some result) :
    result.2.position ≤ maxExactPosition := by
  unfold Drbg.fill at h
  split at h
  · rename_i valid
    rcases Option.bind_eq_some_iff.mp h with ⟨bytes, _, equality⟩
    have pairEquality : (bytes, { state with position := state.position + count }) = result :=
      Option.some.inj equality
    rw [← pairEquality]
    rcases valid with ⟨within, countBound, _⟩
    calc
      state.position + count ≤ state.position +
          (maxExactPosition - state.position) := Nat.add_le_add_left countBound _
      _ = maxExactPosition := Nat.add_sub_of_le within
  · contradiction

end Randoml
