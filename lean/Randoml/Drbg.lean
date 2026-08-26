import Randoml.Blake3

namespace Randoml

def kdfContext : String := "random drbg 2026-08-04 v1"
def maxExactPosition : Nat := 9007199254740992

structure Drbg where
  key : ByteArray
  position : Nat
deriving BEq

def Drbg.init (seed : ByteArray) : Option Drbg :=
  if seed.size = 32 then
    some { key := Blake3.deriveKey kdfContext seed, position := 0 }
  else none

def Drbg.seek (state : Drbg) (position : Nat) : Option Drbg :=
  if position ≤ maxExactPosition then some { state with position } else none

def Drbg.fill (state : Drbg) (count : Nat) : Option (ByteArray × Drbg) :=
  if state.position ≤ maxExactPosition ∧
      count ≤ maxExactPosition - state.position then
    some (Blake3.xofAt state.key state.position count,
      { state with position := state.position + count })
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

partial def Drbg.range (state : Drbg) (start stop : Int) : Option (Int × Drbg) := do
  if stop < start then none else pure ()
  let spanInt := stop - start + 1
  if spanInt ≤ 0 ∨ spanInt > maxExactPosition then none else pure ()
  let span := spanInt.toNat
  if span = 1 then pure (start, state) else
      if span ≤ 0x100000000 then
      let sampleSpace : Nat := 0x100000000
      let bound := sampleSpace - sampleSpace % span
      let (draw, next) ← state.nextU32
        if draw.toNat < bound then
          pure (start + Int.ofNat (draw.toNat % span), next)
        else next.range start stop
      else
        let sampleSpace : Nat := 0x10000000000000000
        let remainder := sampleSpace % span
        let bound := sampleSpace - remainder
        let (draw, next) ← state.nextU64
        if remainder = 0 || draw.toNat < bound then
          pure (start + Int.ofNat (draw.toNat % span), next)
        else next.range start stop

end Randoml
