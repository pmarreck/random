import Randoml.Drbg
import Randoml.Fixed

namespace Randoml

open Fixed

/--
A canonical fixed-point value. The proof field is erased by code generation;
callers cannot manufacture an out-of-invariant value through the public API.
-/
structure Canonical where
  value : Value
  invariant : Valid value

def Canonical.ofValue? (value : Value) : Option Canonical :=
  if proof : Valid value then some { value, invariant := proof } else none

def Canonical.zero : Canonical :=
  { value := Value.zero, invariant := Or.inl ⟨rfl, rfl⟩ }

def Canonical.fromInt (value : Int) : Option Canonical :=
  Canonical.ofValue? (Fixed.fromInt value)

structure Positive where
  canonical : Canonical
  positive : 0 < canonical.value.m

def Positive.ofValue? (value : Value) : Option Positive := do
  let canonical ← Canonical.ofValue? value
  if proof : 0 < canonical.value.m then
    some { canonical, positive := proof }
  else
    none

def Positive.value (positive : Positive) : Value := positive.canonical.value

structure NormalParameters where
  mean : Canonical
  stddev : Positive
  meanExponent : mean.value.m = 0 ∨ (-1000000 : Int) ≤ mean.value.e ∧ mean.value.e ≤ 1000000
  stddevExponent : (-1000000 : Int) ≤ stddev.value.e ∧ stddev.value.e ≤ 1000000

def NormalParameters.create (mean stddev : Value) : Option NormalParameters := do
  let mean ← Canonical.ofValue? mean
  let stddev ← Positive.ofValue? stddev
  if hm : mean.value.m = 0 ∨ (-1000000 : Int) ≤ mean.value.e ∧ mean.value.e ≤ 1000000 then
    if hs : (-1000000 : Int) ≤ stddev.value.e ∧ stddev.value.e ≤ 1000000 then
      some { mean, stddev, meanExponent := hm, stddevExponent := hs }
    else none
  else none

structure ExponentialParameters where
  rate : Positive
  exponent : (-1000000 : Int) ≤ rate.value.e ∧ rate.value.e ≤ 1000000

def ExponentialParameters.create (rate : Value) : Option ExponentialParameters := do
  let rate ← Positive.ofValue? rate
  if proof : (-1000000 : Int) ≤ rate.value.e ∧ rate.value.e ≤ 1000000 then
    some { rate, exponent := proof }
  else none

structure PoissonParameters where
  lambda : Positive
  exponent : (-1000000 : Int) ≤ lambda.value.e ∧ lambda.value.e ≤ 19

def PoissonParameters.create (lambda : Value) : Option PoissonParameters := do
  let lambda ← Positive.ofValue? lambda
  if proof : (-1000000 : Int) ≤ lambda.value.e ∧ lambda.value.e ≤ 19 then
    some { lambda, exponent := proof }
  else none

structure LogNormalParameters where
  mean : Canonical
  stddev : Positive
  meanExponent : mean.value.m = 0 ∨ (-1000000 : Int) ≤ mean.value.e ∧ mean.value.e ≤ 27
  stddevExponent : (-1000000 : Int) ≤ stddev.value.e ∧ stddev.value.e ≤ 23

def LogNormalParameters.create (mean stddev : Value) : Option LogNormalParameters := do
  let mean ← Canonical.ofValue? mean
  let stddev ← Positive.ofValue? stddev
  if hm : mean.value.m = 0 ∨ (-1000000 : Int) ≤ mean.value.e ∧ mean.value.e ≤ 27 then
    if hs : (-1000000 : Int) ≤ stddev.value.e ∧ stddev.value.e ≤ 23 then
      some { mean, stddev, meanExponent := hm, stddevExponent := hs }
    else none
  else none

structure BetaParameters where
  alpha : Positive
  beta : Positive
  alphaExponent : (-20 : Int) ≤ alpha.value.e ∧ alpha.value.e ≤ 20
  betaExponent : (-20 : Int) ≤ beta.value.e ∧ beta.value.e ≤ 20

def BetaParameters.create (alpha beta : Value) : Option BetaParameters := do
  let alpha ← Positive.ofValue? alpha
  let beta ← Positive.ofValue? beta
  if ha : (-20 : Int) ≤ alpha.value.e ∧ alpha.value.e ≤ 20 then
    if hb : (-20 : Int) ≤ beta.value.e ∧ beta.value.e ≤ 20 then
      some { alpha, beta, alphaExponent := ha, betaExponent := hb }
    else none
  else none

def uniform (state : Drbg) : Option (Canonical × Drbg) := do
  let (draw, next) ← state.nextU32
  let value := div (fromInt (Int.ofNat draw.toNat)) (fromInt 0x100000000)
  let canonical ← Canonical.ofValue? value
  pure (canonical, next)

def nonzeroUniform (state : Drbg) : Option (Canonical × Drbg) := do
  let (value, next) ← uniform state
  if value.value.m = 0 then
    let replacement ← Canonical.ofValue? (div (fromInt 1) (fromInt 0x100000000))
    pure (replacement, next)
  else
    pure (value, next)

def normal (state : Drbg) (parameters : NormalParameters) : Option (Canonical × Drbg) := do
  let (u1, state) ← nonzeroUniform state
  let (u2, state) ← uniform state
  let logarithm ← ln? u1.value
  let radius ← sqrt? (mul (fromInt (-2)) logarithm)
  let z := mul radius (cosTurns u2.value)
  let value := add parameters.mean.value (mul z parameters.stddev.value)
  let canonical ← Canonical.ofValue? value
  pure (canonical, state)

private def normalIntLoop : Nat → Drbg → Int → Int → Value → Value → Option (Int × Drbg)
  | 0, _, _, _, _, _ => none
  | fuel + 1, state, start, stop, sixth, half => do
      let (first, state) ← state.range 1 1000000
      let (second, state) ← state.range 1 1000000
      let million := fromInt 1000000
      let u1 := div (fromInt first) million
      let u2 := div (fromInt second) million
      let logarithm ← ln? u1
      let radius ← sqrt? (mul (fromInt (-2)) logarithm)
      let z := mul radius (cosTurns u2)
      let value := add (add (mul z sixth) half) (fromInt start)
      let rounded := roundToInt value
      if start ≤ rounded ∧ rounded ≤ stop then
        pure (rounded, state)
      else
        normalIntLoop fuel state start stop sixth half

def normalInt (state : Drbg) (start stop : Int) : Option (Int × Drbg) := do
  if stop < start then none else pure ()
  let width := stop - start
  if width > clamp ∨ width < -clamp then none else pure ()
  let sixth := div (fromInt width) (fromInt 6)
  let half := div (fromInt width) (fromInt 2)
  normalIntLoop ((maxExactPosition - state.position) / 8 + 1)
    state start stop sixth half

def exponential (state : Drbg)
    (parameters : ExponentialParameters) : Option (Canonical × Drbg) := do
  let (u, state) ← nonzeroUniform state
  let logarithm ← ln? u.value
  let canonical ← Canonical.ofValue? (div (neg logarithm) parameters.rate.value)
  pure (canonical, state)

private def poissonLoop : Nat → Drbg → Value → Value → Int → Option (Int × Drbg)
  | 0, _, _, _, _ => none
  | fuel + 1, state, lambda, sum, count => do
      let (u, state) ← nonzeroUniform state
      let logarithm ← ln? u.value
      let sum := add sum (neg logarithm)
      if compare sum lambda > 0 then
        pure (count, state)
      else
        poissonLoop fuel state lambda sum (count + 1)

def poisson (state : Drbg) (parameters : PoissonParameters) : Option (Int × Drbg) :=
  poissonLoop ((maxExactPosition - state.position) / 4 + 1)
    state parameters.lambda.value Value.zero 0

def logNormal (state : Drbg)
    (parameters : LogNormalParameters) : Option (Canonical × Drbg) := do
  let normalParameters ← NormalParameters.create parameters.mean.value parameters.stddev.value
  let (sample, state) ← normal state normalParameters
  if sample.value.m != 0 ∧ sample.value.e > 28 then none else pure ()
  let value ← exp? sample.value
  let canonical ← Canonical.ofValue? value
  pure (canonical, state)

private def gamma : Nat → Drbg → Value → Option (Canonical × Drbg)
  | 0, _, _ => none
  | fuel + 1, state, alpha => do
      let one := fromInt 1
      if compare alpha one < 0 then
        let (u, state) ← nonzeroUniform state
        let recursive ← gamma fuel state (add one alpha)
        let exponent := div one alpha
        let powered ← pow? u.value exponent
        let canonical ← Canonical.ofValue? (mul recursive.1.value powered)
        pure (canonical, recursive.2)
      else
        let third := div one (fromInt 3)
        let d := sub alpha third
        let root ← sqrt? (mul (fromInt 9) d)
        let scale := div one root
        let normalParameters ← NormalParameters.create Value.zero one
        let (x, state) ← normal state normalParameters
        let v := add one (mul scale x.value)
        if v.m ≤ 0 then
          gamma fuel state alpha
        else
          let v3 := mul (mul v v) v
          let (u, state) ← uniform state
          let x2 := mul x.value x.value
          let x4 := mul x2 x2
          let coefficient := div (fromInt 331) (fromInt 10000)
          let quick := sub one (mul coefficient x4)
          if compare u.value quick < 0 then
            let canonical ← Canonical.ofValue? (mul d v3)
            pure (canonical, state)
          else if u.value.m = 0 then
            gamma fuel state alpha
          else
            let logarithm ← ln? u.value
            let halfX2 := mul (div one (fromInt 2)) x2
            let logV3 ← ln? v3
            let correction := add (sub one v3) logV3
            let rhs := add halfX2 (mul d correction)
            if compare logarithm rhs < 0 then
              let canonical ← Canonical.ofValue? (mul d v3)
              pure (canonical, state)
            else
              gamma fuel state alpha

def beta (state : Drbg) (parameters : BetaParameters) : Option (Canonical × Drbg) := do
  let fuel := (maxExactPosition - state.position) / 4 + 1
  let (x, state) ← gamma fuel state parameters.alpha.value
  let (y, state) ← gamma fuel state parameters.beta.value
  let canonical ← Canonical.ofValue? (div x.value (add x.value y.value))
  pure (canonical, state)

end Randoml
