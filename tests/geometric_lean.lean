import Randoml.Geometric
import Randoml.Curve

open Randoml

-- A new theorem must fail to elaborate before the executable helper exists.
theorem geometric_reconstruction (n : Nat) (bit : Fin 2) :
    Geometric.reconstruct n bit / 2 = n := by
  unfold Geometric.reconstruct
  omega

#print axioms geometric_reconstruction
#print axioms Geometric.certain_zero

def main : IO Unit := do
  for exponent in [-30,-62,-63,-100,-1000] do
    let some chart := Curve.sample .geometric { m := 4611686018427387904, e := exponent }
        Fixed.Value.zero 9 | throw (IO.userError "geometric chart rejected")
    let expected : Array Int := #[65535,30956,14623,6907,3262,1541,728,344,162]
    for index in [:9] do
      if (Int.ofNat chart.heights[index]!.toNat - expected[index]!).natAbs > 1 then
        throw (IO.userError "geometric chart cancellation regression")
  for (number, bytes) in [
      (0, #[0]), (127, #[127]), (128, #[129,128]), (256, #[130,0,1]),
      (18446744073709551616, #[137,0,0,0,0,0,0,0,0,1])] do
    if (Geometric.unsignedBlip number).data != bytes then
      throw (IO.userError "unsigned BLIP golden mismatch")
  if (Geometric.parseProbability "5e-1").map (fun value => (value.m, value.e)) !=
      some (4611686018427387904, -1) then
    throw (IO.userError "scientific probability parsing mismatch")
  let seed := ByteArray.mk ((Array.replicate 31 (0 : UInt8)).push 42)
  let some half := Geometric.prepare { m := 4611686018427387904, e := -1 }
    | throw (IO.userError "half probability rejected")
  let some initial := Drbg.init seed | throw (IO.userError "seed rejected")
  let mut state := initial
  let mut values : Array Nat := #[]
  for _ in [:8] do
    let some (value, next) := Geometric.sample state half
      | throw (IO.userError "geometric sampling failed")
    values := values.push value
    state := next
  if values != #[0,4,1,4,0,0,3,1] || state.position != 168 then
    throw (IO.userError "geometric golden/cursor mismatch")
  let some certain := Geometric.prepare { m := 4611686018427387904, e := 0 }
    | throw (IO.userError "unit probability rejected")
  if Geometric.sample state certain != some (0,state) then
    throw (IO.userError "p=1 consumed bytes")
  let some tiny := Geometric.prepare { m := 4611686018427387904, e := -100 }
    | throw (IO.userError "tiny probability rejected")
  let some (large, next) := Geometric.sample initial tiny
    | throw (IO.userError "tiny sampling failed")
  if large != 50065276213116078233391743926 || next.position != 509 then
    throw (IO.userError "arbitrary gap/cursor mismatch")
  IO.println "Lean geometric executable controls passed"
