import Randoml.Distribution
import Randoml.Decimal

namespace Randoml.Geometric

open Fixed

/-- Validated success probability. The proofs are erased in compiled code. -/
structure Probability where
  value : Value
  canonical : Valid value
  positive : 0 < value.m
  exponent : (-1000000 : Int) ≤ value.e ∧ value.e ≤ 0
  bounded : compare value (fromInt 1) ≤ 0

def Probability.create (value : Value) : Option Probability := do
  if hc : Valid value then
    if hp : 0 < value.m then
      if he : (-1000000 : Int) ≤ value.e ∧ value.e ≤ 0 then
        if hb : compare value (fromInt 1) ≤ 0 then
          some { value, canonical := hc, positive := hp, exponent := he, bounded := hb }
        else none
      else none
    else none
  else none

structure Prepared where
  probability : Probability
  base : UInt64
  levels : Array UInt64
  tailBits : Nat
  certain : Bool

private def threshold (value : Value) : Option UInt64 :=
  if 0 < value.m ∧ -2 ≤ value.e ∧ value.e ≤ -1 then
    some (UInt64.ofNat (value.m.toNat * 2 ^ (value.e + 2).toNat))
  else none

private def prepareLoop : Nat → Value → Array UInt64 → Option (UInt64 × Array UInt64)
  | 0, _, _ => none
  | fuel + 1, p, levels => do
      if compare p { m := two62, e := -1 } ≥ 0 then
        pure (← threshold p, levels)
      else
        let bit ← threshold (div (sub (fromInt 1) p) (sub (fromInt 2) p))
        -- Changing the exponent doubles exactly even for an odd mantissa.
        let doubled : Value := { m := p.m, e := p.e + 1 }
        prepareLoop fuel (sub doubled (mul p p)) (levels.push bit)

/-- Prepare significant levels; tiny exponents are assembled as fair low bits. -/
def prepare (value : Value) : Option Prepared := do
  let probability ← Probability.create value
  if compare value (fromInt 1) = 0 then
    pure { probability, base := 0, levels := #[], tailBits := 0, certain := true }
  else
    let tailBits := (-62 - value.e).toNat
    let p := if value.e < -62 then { value with e := -62 } else value
    let (base, levels) ← prepareLoop 129 p #[]
    pure { probability, base, levels, tailBits, certain := false }

private def power10Loop : Nat → Nat → Value → Value → Option Value
  | 0, _, _, _ => none
  | fuel + 1, remaining, factor, multiplier =>
      if remaining = 0 then some multiplier else
        let multiplier := if remaining % 2 = 1 then mul multiplier factor else multiplier
        let next := remaining / 2
        power10Loop fuel next (if next = 0 then factor else mul factor factor) multiplier

/-- Probability-only syntax; scientific scaling never passes through a float. -/
private def integerSyntax (text : String) : Bool :=
  let digits := if text.startsWith "+" ∨ text.startsWith "-" then
    (text.drop 1).toString else text
  !digits.isEmpty ∧ digits.toUTF8.data.all (fun byte => 48 ≤ byte.toNat ∧ byte.toNat ≤ 57)

def parseProbability (text : String) : Option Value := do
  let value ← if text.startsWith "2^" then do
      if !integerSyntax (text.drop 2).toString then none else pure ()
      let exponent ← Decimal.parseInt (text.drop 2).toString
      if exponent < -1000000 ∨ exponent > 0 then none else
        pure { m := two62, e := exponent }
    else
      let parts := (text.replace "E" "e").splitOn "e"
      match parts with
      | [mantissa, exponentText] => do
          if !integerSyntax exponentText then none else pure ()
          if !(mantissa.toList.all fun character => character.isDigit ∨ character = '.') then none else pure ()
          let value ← Decimal.parse mantissa
          let exponent ← Decimal.parseInt exponentText
          if exponent.natAbs > 1000000 then none else pure ()
          let multiplier ← power10Loop 22 exponent.natAbs (fromInt 10) (fromInt 1)
          pure (if exponent < 0 then div value multiplier else mul value multiplier)
      | [_] => Decimal.parse text
      | _ => none
  let _ ← prepare value
  pure value

/-- Canonical unsigned little-endian BLIP, with an arbitrary-width payload. -/
def unsignedBlip (value : Nat) : ByteArray := Id.run do
  if value < 128 then return ByteArray.empty.push (UInt8.ofNat value)
  let length := value.log2 / 8 + 1
  let mut header := ByteArray.empty.push (UInt8.ofNat (128 + length % 32 + if length ≥ 32 then 32 else 0))
  let mut continuation := length / 32
  for _ in [0:continuation.log2 / 7 + 1] do
    if continuation != 0 then
      let next := continuation / 128
      header := header.push (UInt8.ofNat (continuation % 128 + if next != 0 then 128 else 0))
      continuation := next
  let mut payload := value
  for _ in [0:length] do
    header := header.push (UInt8.ofNat (payload % 256))
    payload := payload / 256
  return header

/-- The actual executable reconstruction accepts only a proved binary digit. -/
def reconstruct (count : Nat) (bit : Fin 2) : Nat := 2 * count + bit.val

theorem reconstruct_quotient (count : Nat) (bit : Fin 2) :
    reconstruct count bit / 2 = count := by
  unfold reconstruct
  omega

theorem reconstruct_remainder (count : Nat) (bit : Fin 2) :
    reconstruct count bit % 2 = bit.val := by
  unfold reconstruct
  omega

private def bitOfBool (value : Bool) : Fin 2 :=
  if value then ⟨1, by decide⟩ else ⟨0, by decide⟩

private def baseLoop [Monad m] (read : Nat → m ByteArray) (base : UInt64) :
    Nat → Nat → m (Option Nat)
  | 0, _ => pure none
  | fuel + 1, count => do
      let bytes ← read 8
      if bytes.size != 8 then return none
      if Randoml.u64be bytes < base then
        pure (some count)
      else
        baseLoop read base fuel (count + 1)

private def littleEndian (bytes : ByteArray) : Nat :=
  bytes.data.toList.reverse.foldl (fun value byte => value * 256 + byte.toNat) 0

/-- One distribution program, interpreted by either a pure DRBG state source
or an I/O edge. The passed source owns failures; no implicit reservoir exists. -/
def sampleWith [Monad m] (read : Nat → m ByteArray) (fuel : Nat)
    (prepared : Prepared) : m (Option Nat) := do
  if prepared.certain then return some 0
  let some base ← baseLoop read prepared.base fuel 0 | return none
  let mut count := base
  for threshold in prepared.levels.toList.reverse do
    let bytes ← read 8
    if bytes.size != 8 then return none
    count := reconstruct count (bitOfBool (Randoml.u64be bytes < threshold))
  if prepared.tailBits != 0 then
    let length := (prepared.tailBits + 7) / 8
    let low ← read length
    if low.size != length then return none
    let scale := 2 ^ prepared.tailBits
    count := count * scale + littleEndian low % scale
  return some count

/-- Pure caller-owned DRBG interpretation; failure returns no replacement state. -/
def sample (state : Drbg) (prepared : Prepared) : Option (Nat × Drbg) := do
  let read : Nat → StateT Drbg Option ByteArray := fun count => do
    let current ← get
    let (bytes, next) ← current.fill count
    set next
    pure bytes
  let (some result, next) ←
    (sampleWith read ((maxExactPosition - state.position) / 8 + 1) prepared).run state
    | none
  pure (result, next)

theorem certain_zero (state : Drbg) (prepared : Prepared)
    (h : prepared.certain = true) : sample state prepared = some (0, state) := by
  simp [sample, sampleWith, h, StateT.run, StateT.pure, pure]

end Randoml.Geometric
