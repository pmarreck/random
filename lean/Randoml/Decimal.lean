import Randoml.Fixed

namespace Randoml.Decimal

open Randoml.Fixed

def maxIntegerDigits : Nat := 2000
def maxFractionDigits : Nat := 18
def int64Max : Nat := 9223372036854775807

def asciiSpace (character : Char) : Bool :=
  character = ' ' || character = '\t' || character = '\n' ||
    character = '\r' || character.toNat = 11 || character.toNat = 12

def trimAscii (characters : List Char) : List Char :=
  (characters.dropWhile asciiSpace).reverse.dropWhile asciiSpace |>.reverse

def digit? (character : Char) : Option Nat :=
  let code := character.toNat
  if '0'.toNat ≤ code ∧ code ≤ '9'.toNat then
    some (code - '0'.toNat)
  else
    none

def takeDigits : List Char → List Nat × List Char
  | character :: rest =>
      match digit? character with
      | some digit =>
          let result := takeDigits rest
          (digit :: result.1, result.2)
      | none => ([], character :: rest)
  | [] => ([], [])

def digitsToNat (digits : List Nat) : Nat :=
  digits.foldl (fun value digit => value * 10 + digit) 0

def fixedFromDigits (digits : List Nat) : Value :=
  if digitsToNat digits ≤ int64Max then
    fromInt (Int.ofNat (digitsToNat digits))
  else
    digits.foldl (fun value digit =>
      add (mul value (fromInt 10)) (fromInt (Int.ofNat digit))) Value.zero

/--
Parse the project's pinned decimal grammar without a host floating-point parser.
Only the first eighteen fractional digits affect the value; later digits are
accepted and deliberately discarded, matching the other implementations.
-/
def parse (input : String) : Option Value := do
  let characters := trimAscii input.toList
  if characters.isEmpty then none else pure ()
  let (negative, unsigned) :=
    match characters with
    | '-' :: rest => (true, rest)
    | '+' :: rest => (false, rest)
    | rest => (false, rest)
  let integerResult := takeDigits unsigned
  let integerDigits := integerResult.1
  if maxIntegerDigits < integerDigits.length then none else pure ()
  let (fractionDigits, trailing) :=
    match integerResult.2 with
    | '.' :: rest =>
        let result := takeDigits rest
        (result.1, result.2)
    | rest => ([], rest)
  if !trailing.isEmpty then none else pure ()
  if integerDigits.isEmpty ∧ fractionDigits.isEmpty then none else pure ()
  let integerPart := fixedFromDigits integerDigits
  let usedFraction := fractionDigits.take maxFractionDigits
  let result :=
    if usedFraction.isEmpty then
      integerPart
    else
      let numerator := fromInt (Int.ofNat (digitsToNat usedFraction))
      let denominator := fromInt (Int.ofNat (10 ^ usedFraction.length))
      add integerPart (div numerator denominator)
  pure (if negative then neg result else result)

def parseInt (input : String) : Option Int := do
  let characters := trimAscii input.toList
  if characters.isEmpty then none else pure ()
  let (negative, unsigned) :=
    match characters with
    | '-' :: rest => (true, rest)
    | '+' :: rest => (false, rest)
    | rest => (false, rest)
  let result := takeDigits unsigned
  if result.1.isEmpty ∨ !result.2.isEmpty then none else pure ()
  let magnitude := digitsToNat result.1
  if Int.ofNat magnitude > Fixed.clamp then none else pure ()
  pure (if negative then -(Int.ofNat magnitude) else Int.ofNat magnitude)

def natDecimal (value : Nat) : String :=
  toString value

def fractionCharacters (fraction : Value) (places : Nat) : List Char :=
  let result := (List.range places).foldl (fun state _ =>
    let scaled := mul state.1 (fromInt 10)
    let rawDigit := toIntTrunc scaled
    let digit : Nat :=
      if rawDigit < 0 then 0
      else if 9 < rawDigit then 9
      else rawDigit.toNat
    (sub scaled (fromInt rawDigit), state.2 ++ [Char.ofNat ('0'.toNat + digit)]))
    (fraction, [])
  result.2

/-- Render with truncation, never rounding, using integer-only arithmetic. -/
def render (value : Value) (places : Nat) : Option String := do
  if maxFractionDigits < places then none else pure ()
  if value.m = 0 then
    if places = 0 then
      pure "0"
    else
      pure ("0." ++ String.ofList (List.replicate places '0'))
  else
    let negative := value.m < 0
    let absolute := if negative then neg value else value
    let shift := absolute.e - 62
    let (integerPart, fraction) ←
      if 0 ≤ shift then
        if Int.ofNat (maxIntegerDigits - 19) < shift then none
        else
          let integer := absolute.m.natAbs * pow2 shift.toNat
          if maxIntegerDigits < (natDecimal integer).length then none
          else some (natDecimal integer, Value.zero)
      else
        let amount := (-shift).toNat
        let integer := if 62 < amount then 0 else absolute.m.natAbs / pow2 amount
        some (natDecimal integer, sub absolute (fromInt (Int.ofNat integer)))
    let sign := if negative then "-" else ""
    if places = 0 then
      pure (sign ++ integerPart)
    else
      pure (sign ++ integerPart ++ "." ++ String.ofList (fractionCharacters fraction places))

end Randoml.Decimal
