import Randoml.Distribution

namespace Randoml.Curve

open Randoml.Fixed

def maxSamples : Nat := 4096
def heightMaximum : Int := 65535

inductive Kind
  | normal
  | exponential
  | poisson
  | logNormal
  | beta
deriving BEq, Repr

structure Samples where
  heights : Array UInt16
  xMin : Value
  xMax : Value
deriving BEq, Repr

private def fraction (index denominator : Nat) : Value :=
  div (fromInt (Int.ofNat index)) (fromInt (Int.ofNat denominator))

def height (relative : Value) : UInt16 :=
  if relative.m ≤ 0 then
    0
  else if compare relative (fromInt 1) ≥ 0 then
    UInt16.ofNat 65535
  else
    UInt16.ofNat (toIntTrunc (mul relative (fromInt heightMaximum))).toNat

private def relative (score maximum : Value) : Option Value := do
  let difference := sub score maximum
  if difference.m ≥ 0 then
    pure (fromInt 1)
  else if compare difference (fromInt (-64)) < 0 then
    pure Value.zero
  else
    exp? difference

private def maximum? : List Value → Option Value
  | [] => none
  | first :: rest =>
      some (rest.foldl (fun maximum value =>
        if compare value maximum > 0 then value else maximum) first)

private def normal (mean stddev : Value) (count : Nat) : Option Samples := do
  if stddev.m ≤ 0 ∨ !exponentIn stddev (-1000000) 1000000 ∨
      !exponentIn mean (-1000000) 1000000 then none else pure ()
  let four := fromInt 4
  let eight := fromInt 8
  let two := fromInt 2
  let spread := mul four stddev
  let heights ← (List.range count).mapM fun index => do
    let z := sub (mul eight (fraction index (count - 1))) four
    let score := neg (div (mul z z) two)
    let value ← exp? score
    pure (height value)
  pure {
    heights := heights.toArray
    xMin := sub mean spread
    xMax := add mean spread
  }

private def exponential (rate : Value) (count : Nat) : Option Samples := do
  if rate.m ≤ 0 ∨ !exponentIn rate (-1000000) 1000000 then none else pure ()
  let six := fromInt 6
  let heights ← (List.range count).mapM fun index => do
    let score := neg (mul six (fraction index (count - 1)))
    let value ← exp? score
    pure (height value)
  pure {
    heights := heights.toArray
    xMin := Value.zero
    xMax := div six rate
  }

private def poissonInitial (lambda : Value) (current minimum : Int) : Value :=
  (List.range (current - minimum).toNat).foldl (fun probability offset =>
    let divisor := fromInt (current - Int.ofNat offset)
    mul probability (div divisor lambda)) (fromInt 1)

private def poissonStep (lambda : Value) (state : Int × Value) (target : Int) : Int × Value :=
  (List.range (target - state.1).toNat).foldl (fun state _ =>
    let current := state.1 + 1
    (current, mul state.2 (div lambda (fromInt current)))) state

private def poisson (lambda : Value) (capacity : Nat) : Option Samples := do
  if lambda.m ≤ 0 ∨ !exponentIn lambda (-1000000) 19 then none else pure ()
  let mode := toIntTrunc lambda
  let root ← sqrt? lambda
  let radius := toIntTrunc (mul (fromInt 6) root) + 1
  let minimum := max 0 (mode - radius)
  let maximum := mode + radius
  let integerCount := (maximum - minimum + 1).toNat
  let count := min integerCount capacity
  if count < 2 then none else pure ()
  let probability := poissonInitial lambda mode minimum
  let span := (maximum - minimum).toNat
  let denominator := count - 1
  let result := (List.range count).foldl (fun state index =>
    let numerator := index * span + denominator / 2
    let target := minimum + Int.ofNat (numerator / denominator)
    let next := poissonStep lambda state.1 target
    (next, state.2.push (height next.2))) ((minimum, probability), #[])
  pure {
    heights := result.2
    xMin := fromInt minimum
    xMax := fromInt maximum
  }

private def logNormalScore (sigmaSquared xMaxScaled : Value)
    (index denominator : Nat) : Option Value := do
  let x := mul xMaxScaled (fraction index denominator)
  let logarithm ← ln? x
  let shifted := add logarithm sigmaSquared
  pure (neg (div (mul shifted shifted) (mul (fromInt 2) sigmaSquared)))

private def logNormal (mean stddev : Value) (count : Nat) : Option Samples := do
  if stddev.m ≤ 0 ∨ !exponentIn stddev (-1000000) 23 ∨
      !exponentIn mean (-1000000) 27 then none else pure ()
  let spanUnbounded := div (mul stddev (fromInt 13)) (fromInt 8)
  let twenty := fromInt 20
  let span := if compare spanUnbounded twenty < 0 then spanUnbounded else twenty
  let xMaxScaled ← exp? span
  let sigmaSquared := mul stddev stddev
  let scores ← (List.range (count - 1)).mapM fun offset =>
    logNormalScore sigmaSquared xMaxScaled (offset + 1) (count - 1)
  let maximum ← maximum? scores
  let heights ← scores.mapM fun score => do
    let value ← relative score maximum
    pure (height value)
  let endpoint ← exp? (add mean span)
  pure {
    heights := (#[0] ++ heights.toArray)
    xMin := Value.zero
    xMax := endpoint
  }

private def betaScore (alphaMinusOne betaMinusOne : Value)
    (index count : Nat) : Option Value := do
  let numerator := fromInt (Int.ofNat (index * 2 + 1))
  let denominator := fromInt (Int.ofNat (count * 2))
  let x := div numerator denominator
  let oneMinusX := sub (fromInt 1) x
  let first ← ln? x
  let second ← ln? oneMinusX
  pure (add (mul alphaMinusOne first) (mul betaMinusOne second))

private def beta (alpha beta : Value) (count : Nat) : Option Samples := do
  if alpha.m ≤ 0 ∨ beta.m ≤ 0 ∨ !exponentIn alpha (-20) 20 ∨
      !exponentIn beta (-20) 20 then none else pure ()
  let alphaMinusOne := sub alpha (fromInt 1)
  let betaMinusOne := sub beta (fromInt 1)
  let scores ← (List.range count).mapM fun index =>
    betaScore alphaMinusOne betaMinusOne index count
  let maximum ← maximum? scores
  let heights ← scores.mapM fun score => do
    let value ← relative score maximum
    pure (height value)
  pure {
    heights := heights.toArray
    xMin := Value.zero
    xMax := fromInt 1
  }

def sample (kind : Kind) (first second : Value) (count : Nat) : Option Samples := do
  if count < 2 ∨ maxSamples < count then none else pure ()
  match kind with
  | .normal => normal first second count
  | .exponential =>
      if second.m != 0 then none else exponential first count
  | .poisson =>
      if second.m != 0 then none else poisson first count
  | .logNormal => logNormal first second count
  | .beta => beta first second count

end Randoml.Curve
