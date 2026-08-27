import Randoml.Distribution
import Randoml.Native

namespace Randoml.CliSource

open Randoml
open Randoml.Fixed

structure Deterministic where
  seed : ByteArray
  state : Drbg

inductive Source
  | deterministic (value : Deterministic)
  | entropy (value : Native.EntropySource)

abbrev Result (α : Type) := Except String (α × Source)

private def liftDeterministic (deterministic : Deterministic) :
    Option (α × Drbg) → Result α
  | some (value, state) =>
      .ok (value, .deterministic { deterministic with state := state })
  | none => .error "RNG core failed: position overflow"

private def liftCanonical (deterministic : Deterministic) :
    Option (Canonical × Drbg) → Result Value
  | some (value, state) =>
      .ok (value.value, .deterministic { deterministic with state := state })
  | none => .error "RNG core failed: numeric or position failure"

def fill (source : Source) (count : Nat) : IO (Result ByteArray) :=
  match source with
  | .deterministic value =>
      match value.state.fill count with
      | some (bytes, state) =>
          pure (.ok (bytes, .deterministic { value with state := state }))
      | none => pure (.error "RNG core failed: position overflow")
  | .entropy value => do
      let bytes ← Native.sourceFill value (USize.ofNat count)
      if bytes.size != count then
        pure (.error "entropy source returned an incomplete read")
      else
        pure (.ok (bytes, source))

def readU32 (source : Source) : IO (Result UInt32) := do
  match ← fill source 4 with
  | .error message => pure (.error message)
  | .ok (bytes, source) => pure (.ok (Randoml.u32be bytes, source))

def readU64 (source : Source) : IO (Result UInt64) := do
  match ← fill source 8 with
  | .error message => pure (.error message)
  | .ok (bytes, source) => pure (.ok (Randoml.u64be bytes, source))

def availableFuel (source : Source) (bytesPerAttempt : Nat) : Nat :=
  match source with
  | .deterministic value => (maxExactPosition - value.state.position) / bytesPerAttempt + 1
  | .entropy _ => maxExactPosition / bytesPerAttempt + 1

private def rangeLoop : Nat → Source → Int → Nat → IO (Result Int)
  | 0, _, _, _ => pure (.error "RNG core failed: position overflow")
  | fuel + 1, source, start, span =>
      if span ≤ 0x100000000 then do
        match ← readU32 source with
        | .error message => pure (.error message)
        | .ok (draw, source) =>
            let sampleSpace : Nat := 0x100000000
            let bound := sampleSpace - sampleSpace % span
            if draw.toNat < bound then
              pure (.ok (start + Int.ofNat (draw.toNat % span), source))
            else
              rangeLoop fuel source start span
      else do
        match ← readU64 source with
        | .error message => pure (.error message)
        | .ok (draw, source) =>
            let sampleSpace : Nat := 0x10000000000000000
            let candidate := draw.toNat % sampleSpace
            let remainder := sampleSpace % span
            let bound := sampleSpace - remainder
            if remainder = 0 ∨ candidate < bound then
              pure (.ok (start + Int.ofNat (candidate % span), source))
            else
              rangeLoop fuel source start span

def range (source : Source) (start stop : Int) : IO (Result Int) := do
  if stop < start then return .error "RNG core failed: invalid range"
  let width := stop - start
  if width ≥ Fixed.clamp then
    return .error "RNG core failed: inclusive range contains more than 2^53 values"
  let span := (width + 1).toNat
  match source with
  | .deterministic deterministic =>
      match deterministic.state.range start stop with
      | some (value, state) =>
          pure (.ok (value, .deterministic { deterministic with state := state }))
      | none => pure (.error "RNG core failed: position overflow")
  | .entropy _ =>
      rangeLoop (availableFuel source (if span ≤ 0x100000000 then 4 else 8)) source start span

def uniform (source : Source) : IO (Result Value) := do
  match source with
  | .deterministic deterministic =>
      pure (liftCanonical deterministic (Randoml.uniform deterministic.state))
  | .entropy _ =>
      match ← readU32 source with
      | .error message => pure (.error message)
      | .ok (draw, source) =>
          pure (.ok (div (fromInt (Int.ofNat draw.toNat)) (fromInt 0x100000000), source))

def nonzeroUniform (source : Source) : IO (Result Value) := do
  match source with
  | .deterministic deterministic =>
      pure (liftCanonical deterministic (Randoml.nonzeroUniform deterministic.state))
  | .entropy _ =>
      match ← uniform source with
      | .error message => pure (.error message)
      | .ok (value, source) =>
          let value := if value.m = 0 then div (fromInt 1) (fromInt 0x100000000) else value
          pure (.ok (value, source))

def normal (source : Source) (mean stddev : Value) : IO (Result Value) := do
  let some parameters := NormalParameters.create mean stddev |
    return .error "RNG core failed: invalid normal parameters"
  match source with
  | .deterministic deterministic =>
      pure (liftCanonical deterministic (Randoml.normal deterministic.state parameters))
  | .entropy _ =>
      match ← nonzeroUniform source with
      | .error message => pure (.error message)
      | .ok (u1, source) =>
          match ← uniform source with
          | .error message => pure (.error message)
          | .ok (u2, source) =>
              let some logarithm := ln? u1 | return .error "RNG core failed: numeric failure"
              let some radius := sqrt? (mul (fromInt (-2)) logarithm) |
                return .error "RNG core failed: numeric failure"
              let z := mul radius (cosTurns u2)
              pure (.ok (add parameters.mean.value (mul z parameters.stddev.value), source))

private def normalIntLoop : Nat → Source → Int → Int → Value → Value → IO (Result Int)
  | 0, _, _, _, _, _ => pure (.error "RNG core failed: position overflow")
  | fuel + 1, source, start, stop, sixth, half => do
      match ← range source 1 1000000 with
      | .error message => pure (.error message)
      | .ok (first, source) =>
          match ← range source 1 1000000 with
          | .error message => pure (.error message)
          | .ok (second, source) =>
              let million := fromInt 1000000
              let u1 := div (fromInt first) million
              let u2 := div (fromInt second) million
              let some logarithm := ln? u1 | return .error "RNG core failed: numeric failure"
              let some radius := sqrt? (mul (fromInt (-2)) logarithm) |
                return .error "RNG core failed: numeric failure"
              let z := mul radius (cosTurns u2)
              let value := add (add (mul z sixth) half) (fromInt start)
              let rounded := roundToInt value
              if start ≤ rounded ∧ rounded ≤ stop then
                pure (.ok (rounded, source))
              else
                normalIntLoop fuel source start stop sixth half

def normalInt (source : Source) (start stop : Int) : IO (Result Int) := do
  if stop < start then return .error "RNG core failed: invalid range"
  let width := stop - start
  if width ≥ Fixed.clamp then return .error "RNG core failed: range is too wide"
  match source with
  | .deterministic deterministic =>
      pure (liftDeterministic deterministic (Randoml.normalInt deterministic.state start stop))
  | .entropy _ =>
      normalIntLoop (availableFuel source 8) source start stop
        (div (fromInt width) (fromInt 6)) (div (fromInt width) (fromInt 2))

def exponential (source : Source) (rate : Value) : IO (Result Value) := do
  let some parameters := ExponentialParameters.create rate |
    return .error "RNG core failed: invalid exponential parameters"
  match source with
  | .deterministic deterministic =>
      pure (liftCanonical deterministic (Randoml.exponential deterministic.state parameters))
  | .entropy _ =>
      match ← nonzeroUniform source with
      | .error message => pure (.error message)
      | .ok (u, source) =>
          let some logarithm := ln? u | return .error "RNG core failed: numeric failure"
          pure (.ok (div (neg logarithm) parameters.rate.value, source))

private def poissonLoop : Nat → Source → Value → Value → Int → IO (Result Int)
  | 0, _, _, _, _ => pure (.error "RNG core failed: position overflow")
  | fuel + 1, source, lambda, sum, count => do
      match ← nonzeroUniform source with
      | .error message => pure (.error message)
      | .ok (u, source) =>
          let some logarithm := ln? u | return .error "RNG core failed: numeric failure"
          let sum := add sum (neg logarithm)
          if compare sum lambda > 0 then
            pure (.ok (count, source))
          else
            poissonLoop fuel source lambda sum (count + 1)

def poisson (source : Source) (lambda : Value) : IO (Result Int) := do
  let some parameters := PoissonParameters.create lambda |
    return .error "RNG core failed: invalid Poisson parameters"
  match source with
  | .deterministic deterministic =>
      pure (liftDeterministic deterministic (Randoml.poisson deterministic.state parameters))
  | .entropy _ =>
      poissonLoop (availableFuel source 4) source parameters.lambda.value Value.zero 0

def logNormal (source : Source) (mean stddev : Value) : IO (Result Value) := do
  let some parameters := LogNormalParameters.create mean stddev |
    return .error "RNG core failed: invalid log-normal parameters"
  match source with
  | .deterministic deterministic =>
      pure (liftCanonical deterministic (Randoml.logNormal deterministic.state parameters))
  | .entropy _ =>
      match ← normal source parameters.mean.value parameters.stddev.value with
      | .error message => pure (.error message)
      | .ok (sample, source) =>
          if sample.m != 0 ∧ sample.e > 28 then return .error "RNG core failed: numeric failure"
          let some value := exp? sample | return .error "RNG core failed: numeric failure"
          pure (.ok (value, source))

private def gamma : Nat → Source → Value → IO (Result Value)
  | 0, _, _ => pure (.error "RNG core failed: position overflow")
  | fuel + 1, source, alpha => do
      let one := fromInt 1
      if compare alpha one < 0 then
        match ← nonzeroUniform source with
        | .error message => pure (.error message)
        | .ok (u, source) =>
            match ← gamma fuel source (add one alpha) with
            | .error message => pure (.error message)
            | .ok (recursive, source) =>
                let some powered := pow? u (div one alpha) |
                  return .error "RNG core failed: numeric failure"
                pure (.ok (mul recursive powered, source))
      else
        let third := div one (fromInt 3)
        let d := sub alpha third
        let some root := sqrt? (mul (fromInt 9) d) |
          return .error "RNG core failed: numeric failure"
        let scale := div one root
        match ← normal source Value.zero one with
        | .error message => pure (.error message)
        | .ok (x, source) =>
            let v := add one (mul scale x)
            if v.m ≤ 0 then
              gamma fuel source alpha
            else
              let v3 := mul (mul v v) v
              match ← uniform source with
              | .error message => pure (.error message)
              | .ok (u, source) =>
                  let x2 := mul x x
                  let x4 := mul x2 x2
                  let quick := sub one (mul (div (fromInt 331) (fromInt 10000)) x4)
                  if compare u quick < 0 then
                    pure (.ok (mul d v3, source))
                  else if u.m = 0 then
                    gamma fuel source alpha
                  else
                    let some logarithm := ln? u |
                      return .error "RNG core failed: numeric failure"
                    let some logV3 := ln? v3 |
                      return .error "RNG core failed: numeric failure"
                    let rhs := add (mul (div one (fromInt 2)) x2)
                      (mul d (add (sub one v3) logV3))
                    if compare logarithm rhs < 0 then
                      pure (.ok (mul d v3, source))
                    else
                      gamma fuel source alpha

def beta (source : Source) (alpha beta : Value) : IO (Result Value) := do
  let some parameters := BetaParameters.create alpha beta |
    return .error "RNG core failed: invalid beta parameters"
  match source with
  | .deterministic deterministic =>
      pure (liftCanonical deterministic (Randoml.beta deterministic.state parameters))
  | .entropy _ =>
      let fuel := availableFuel source 4
      match ← gamma fuel source parameters.alpha.value with
      | .error message => pure (.error message)
      | .ok (x, source) =>
          match ← gamma fuel source parameters.beta.value with
          | .error message => pure (.error message)
          | .ok (y, source) => pure (.ok (div x (add x y), source))

def position? : Source → Option Nat
  | .deterministic value => some value.state.position
  | .entropy _ => none

def seed? : Source → Option ByteArray
  | .deterministic value => some value.seed
  | .entropy _ => none

end Randoml.CliSource
