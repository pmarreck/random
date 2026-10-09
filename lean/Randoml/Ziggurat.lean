import Randoml.Drbg
import Randoml.ZigguratTables

namespace Randoml.Ziggurat
open Fixed

/-- Exact 55-bit fraction; Int arithmetic preserves every coordinate bit. -/
def unit (n : Nat) : Value := norm (Int.ofNat n) 7

def signed (negative : Bool) (x : Value) : Value := if negative then neg x else x

private def tailWith [Monad m] (read : Nat → m ByteArray) :
    Nat → Bool → m (Option Value)
  | 0, _ => pure none
  | fuel + 1, negative => do
      let first ← read 8
      if first.size != 8 then return none
      let second ← read 8
      if second.size != 8 then return none
      let some base := strips[1]? | return none
      let r := base.x
      let some l1 := ln? (unit ((u64be first >>> 9).toNat + 1)) | return none
      let some l2 := ln? (unit ((u64be second >>> 9).toNat + 1)) | return none
      let t := div (neg l1) r
      let y := neg l2
      if compare (add y y) (mul t t) ≥ 0 then
        return some (signed negative (add r t))
      tailWith read fuel negative

/-- One pure byte-request program for deterministic and entropy interpreters.
Strip, sign and coordinate occupy disjoint fields. Wedge rejection selects a
fresh header; tail rejection retains the original sign. Fuel bounds rejection
without assuming termination for an adversarial source. -/
def sampleWith [Monad m] (read : Nat → m ByteArray) : Nat → m (Option Value)
  | 0 => pure none
  | fuel + 1 => do
      let bytes ← read 8
      if bytes.size != 8 then return none
      let word := u64be bytes
      let index := (word &&& 255).toNat
      let negative := word &&& 256 != 0
      let coordinate := (word >>> 9).toNat
      let some strip := strips[index]? | return none
      let x := mul (unit coordinate) strip.x
      if coordinate < strip.k then return some (signed negative x)
      if index = 0 then return ← tailWith read (fuel + 1) negative
      let second ← read 8
      if second.size != 8 then return none
      let some upper := if index = 255 then some (fromInt 1)
        else (strips[index + 1]?).map Strip.y | return none
      let y := add strip.y (mul (unit ((u64be second >>> 9).toNat)) (sub upper strip.y))
      let square := neg (mul x x)
      let exponent := if square.m = 0 then square else { square with e := square.e - 1 }
      let some density := exp? exponent | return none
      if compare y density < 0 then return some (signed negative x)
      sampleWith read fuel

/-- Pure caller-owned DRBG interpreter; a failed draw never returns a new state. -/
def sample (state : Drbg) : Option (Value × Drbg) := do
  let read : Nat → StateT Drbg Option ByteArray := fun count => do
    let current ← get
    let (bytes, next) ← current.fill count
    set next
    pure bytes
  let (some value, next) ←
    (sampleWith read ((maxExactPosition - state.position) / 8 + 1)).run state | none
  pure (value, next)

end Randoml.Ziggurat
