namespace Randoml.Fixed

/-!
An executable, integer-only software-number kernel. The value represented by `{m,e}` is
`m * 2^(e-62)`. Arbitrary-precision `Int` is deliberate: the executable
implementation cannot silently inherit a host machine's overflow semantics.
The `Valid` predicate below states the canonical representation invariant.
Typed distribution boundaries validate it; current proof coverage is listed
explicitly in the evaluation report and does not claim that every arithmetic
operation preserves the invariant.
-/

def two61 : Nat := 0x2000000000000000
def two62 : Nat := 0x4000000000000000
def two63 : Nat := 0x8000000000000000
def clamp : Int := 9007199254740992

structure Value where
  m : Int
  e : Int
deriving BEq, Repr

def Value.zero : Value := { m := 0, e := 0 }

def Valid (x : Value) : Prop :=
  (x.m = 0 ∧ x.e = 0) ∨
    (two62 ≤ x.m.natAbs ∧ x.m.natAbs < two63)

instance validDecidable (x : Value) : Decidable (Valid x) := by
  unfold Valid
  infer_instance


def pow2 (n : Nat) : Nat := 2 ^ n

def signedMagnitude (negative : Bool) (magnitude : Nat) : Int :=
  if negative then -(Int.ofNat magnitude) else Int.ofNat magnitude

def truncDiv (value : Int) (divisor : Nat) : Int :=
  if value < 0 then
    -(Int.ofNat (value.natAbs / divisor))
  else
    Int.ofNat (value.natAbs / divisor)

def norm (mantissa exponent : Int) : Value :=
  if mantissa = 0 then
    Value.zero
  else
    let negative := mantissa < 0
    let magnitude := mantissa.natAbs
    let bits := Nat.log2 magnitude + 1
    if bits < 63 then
      let shift := 63 - bits
      { m := signedMagnitude negative (magnitude * pow2 shift)
        e := exponent - Int.ofNat shift }
    else if 63 < bits then
      let shift := bits - 63
      { m := signedMagnitude negative (magnitude / pow2 shift)
        e := exponent + Int.ofNat shift }
    else
      { m := signedMagnitude negative magnitude, e := exponent }

def fromInt (value : Int) : Value :=
  if value = 0 then Value.zero else norm value 62

def neg (x : Value) : Value :=
  if x.m = 0 then Value.zero else { x with m := -x.m }

def mul (a b : Value) : Value :=
  if a.m = 0 ∨ b.m = 0 then
    Value.zero
  else
    let negative := (a.m < 0) != (b.m < 0)
    let product := a.m.natAbs * b.m.natAbs
    if pow2 125 ≤ product then
      { m := signedMagnitude negative (product / pow2 63)
        e := a.e + b.e + 1 }
    else
      { m := signedMagnitude negative (product / pow2 62)
        e := a.e + b.e }

def toIntTrunc (x : Value) : Int :=
  if x.m = 0 then
    0
  else
    let shift := x.e - 62
    if 0 ≤ shift then
      if x.m < 0 then -clamp else clamp
    else
      let amount := (-shift).toNat
      if 62 < amount then
        0
      else
        let quotient := truncDiv x.m (pow2 amount)
        if clamp < quotient then clamp
        else if quotient < -clamp then -clamp
        else quotient

def exponentIn (x : Value) (minimum maximum : Int) : Bool :=
  decide (Valid x) && (x.m = 0 || (minimum ≤ x.e && x.e ≤ maximum))

def half : Value := { m := Int.ofNat two62, e := -1 }


def add (a b : Value) : Value :=
  if a.m = 0 then b
  else if b.m = 0 then a
  else
    let pair := if a.e < b.e then (b, a) else (a, b)
    let x := pair.1
    let y := pair.2
    let difference := x.e - y.e
    if 63 ≤ difference then
      x
    else
      let shifted := truncDiv y.m (pow2 difference.toNat)
      if shifted = 0 then
        x
      else if (x.m < 0) = (shifted < 0) then
        norm (truncDiv x.m 2 + truncDiv shifted 2) (x.e + 1)
      else
        norm (x.m + shifted) x.e

def sub (a b : Value) : Value := add a (neg b)

def roundToInt (x : Value) : Int :=
  if x.m < 0 then toIntTrunc (sub x half) else toIntTrunc (add x half)

def compare (a b : Value) : Int :=
  let signA : Int := if a.m > 0 then 1 else if a.m < 0 then -1 else 0
  let signB : Int := if b.m > 0 then 1 else if b.m < 0 then -1 else 0
  if signA != signB then
    if signA < signB then -1 else 1
  else if signA = 0 then
    0
  else if a.e != b.e then
    let bigger : Int := if a.e > b.e then 1 else -1
    if signA > 0 then bigger else -bigger
  else if a.m = b.m then
    0
  else if a.m < b.m then -1 else 1

def frac (x : Value) : Value :=
  let integer := toIntTrunc x
  if integer = 0 then x else sub x (fromInt integer)

def divMagnitude (a b : Nat) : Nat :=
  let quotient := a / b
  let remainder := a % b
  let result := (List.range 62).foldl (fun state _ =>
    let doubledRemainder := state.1 * 2
    let doubledBits := state.2 * 2
    if b ≤ doubledRemainder then
      (doubledRemainder - b, doubledBits + 1)
    else
      (doubledRemainder, doubledBits)) (remainder, 0)
  quotient * two62 + result.2

def div? (a b : Value) : Option Value :=
  if b.m = 0 then
    none
  else if a.m = 0 then
    some Value.zero
  else
    let negative := (a.m < 0) != (b.m < 0)
    let magnitude := divMagnitude a.m.natAbs b.m.natAbs
    some (norm (signedMagnitude negative magnitude) (a.e - b.e))

def div (a b : Value) : Value :=
  (div? a b).getD Value.zero

def ln2 : Value := { m := 6393154322601327829, e := -1 }
def piOverTwo : Value := { m := 7244019458077122842, e := 0 }

def oddReciprocals : List Value :=
  (List.range 20).map fun index =>
    div (fromInt 1) (fromInt (Int.ofNat (2 * (index + 1) + 1)))

def factorialReciprocals : List Value :=
  let result := (List.range 16).foldl (fun state index =>
    let factorial := mul state.1 (fromInt (Int.ofNat (index + 1)))
    (factorial, state.2 ++ [div (fromInt 1) factorial])) (fromInt 1, [])
  result.2

def ln? (x : Value) : Option Value :=
  if x.m ≤ 0 then
    none
  else
    let fraction := { m := x.m, e := 0 }
    let one := fromInt 1
    let t := div (sub fraction one) (add fraction one)
    let t2 := mul t t
    let pair := oddReciprocals.foldl (fun state reciprocal =>
      let term := mul state.1 t2
      (term, add state.2 (mul term reciprocal))) (t, t)
    let logarithm := add pair.2 pair.2
    some (if x.e = 0 then logarithm else add logarithm (mul ln2 (fromInt x.e)))

def halfLn2 : Value := div ln2 (fromInt 2)
def negativeHalfLn2 : Value := neg halfLn2

def reduceExp (x : Value) (candidate : Int) : Value :=
  sub x (mul ln2 (fromInt candidate))

def correctExpRange (x : Value) (candidate : Int) : Option (Int × Value) :=
  let rec loop (candidate : Int) (fuel : Nat) : Option (Int × Value) :=
    let remainder := reduceExp x candidate
    if compare remainder halfLn2 > 0 then
      match fuel with
      | 0 => none
      | fuel + 1 => loop (candidate + 1) fuel
    else if compare remainder negativeHalfLn2 < 0 then
      match fuel with
      | 0 => none
      | fuel + 1 => loop (candidate - 1) fuel
    else
      some (candidate, remainder)
  loop candidate 4

def exp? (x : Value) : Option Value :=
  if x.m = 0 then
    some (fromInt 1)
  else do
    let initial := toIntTrunc (div x ln2)
    let (candidate, remainder) ← correctExpRange x initial
    let pair := factorialReciprocals.foldl (fun state reciprocal =>
      if state.2.2 then state
      else
        let power := mul state.1 remainder
        let contribution := mul power reciprocal
        (power,
          if contribution.m = 0 then state.2.1 else add state.2.1 contribution,
          contribution.m = 0)) (fromInt 1, fromInt 1, false)
    pure (norm pair.2.1.m (pair.2.1.e + candidate))

def cosineReciprocals : List Value :=
  (List.range 14).map fun index =>
    let n := index + 1
    div (fromInt 1) (fromInt (Int.ofNat ((2 * n - 1) * (2 * n))))

def sineReciprocals : List Value :=
  (List.range 14).map fun index =>
    let n := index + 1
    div (fromInt 1) (fromInt (Int.ofNat ((2 * n) * (2 * n + 1))))

def cosineRadians (angle : Value) : Value :=
  let squared := mul angle angle
  let pair := cosineReciprocals.foldl (fun state reciprocal =>
    let term := neg (mul (mul state.1 squared) reciprocal)
    (term, add state.2 term)) (fromInt 1, fromInt 1)
  pair.2

def sineRadians (angle : Value) : Value :=
  let squared := mul angle angle
  let pair := sineReciprocals.foldl (fun state reciprocal =>
    let term := neg (mul (mul state.1 squared) reciprocal)
    (term, add state.2 term)) (angle, angle)
  pair.2

def cosTurns (x : Value) : Value :=
  if x.m = 0 then
    fromInt 1
  else
    let fraction := frac x
    let fraction := if fraction.m < 0 then add fraction (fromInt 1) else fraction
    let quadrantValue := mul fraction (fromInt 4)
    let quadrant := toIntTrunc quadrantValue
    let within := sub quadrantValue (fromInt quadrant)
    let angle := mul within piOverTwo
    if quadrant = 0 then cosineRadians angle
    else if quadrant = 1 then neg (sineRadians angle)
    else if quadrant = 2 then neg (cosineRadians angle)
    else sineRadians angle

def integerSqrtSeed (magnitude : Nat) : Nat :=
  (List.range 40).foldl (fun estimate _ =>
    let next := (estimate + magnitude / estimate) / 2
    if next = estimate then estimate else next) 0x100000000

def sqrt? (x : Value) : Option Value :=
  if x.m < 0 then
    none
  else if x.m = 0 then
    some Value.zero
  else
    let odd := x.e % 2 != 0
    let magnitude := if odd then x.m.natAbs / 2 else x.m.natAbs
    let exponent := if odd then x.e + 1 else x.e
    let seed := integerSqrtSeed magnitude
    let initial := norm (Int.ofNat seed) (exponent / 2 + 31)
    let refined := (List.range 3).foldl (fun estimate _ =>
      let sum := add estimate (div x estimate)
      norm sum.m (sum.e - 1)) initial
    some refined

def pow? (base exponent : Value) : Option Value := do
  let logarithm ← ln? base
  exp? (mul exponent logarithm)

end Randoml.Fixed
