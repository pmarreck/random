import Randoml.CliOptions

namespace Randoml.State

open Randoml
open Randoml.CliOptions

def maxBytes : Nat := 1_048_576
def maxDepth : Nat := 64
def maxObjectMembers : Nat := 32
def maxArrayItems : Nat := 1024

def inputSizeAllowed (size : Nat) : Bool := size ≤ maxBytes

inductive Json where
  | string (value : String)
  | number (text : String)
  | boolean (value : Bool)
  | array (values : Array Json)
  | object (values : Array (String × Json))
deriving Repr

structure Cursor where
  input : ByteArray
  index : Nat := 0

def byteAt? (cursor : Cursor) : Option UInt8 :=
  if cursor.index < cursor.input.size then some (cursor.input.data.getD cursor.index 0) else none

def advance (cursor : Cursor) (count : Nat := 1) : Cursor :=
  { cursor with index := cursor.index + count }

def jsonSpace (byte : UInt8) : Bool :=
  byte = 9 ∨ byte = 10 ∨ byte = 13 ∨ byte = 32

def skipSpace (initial : Cursor) : Cursor := Id.run do
  let mut cursor := initial
  while (byteAt? cursor).any jsonSpace do
    cursor := advance cursor
  pure cursor

def consume (cursor : Cursor) (byte : UInt8) : Bool × Cursor :=
  if byteAt? cursor == some byte then (true, advance cursor) else (false, cursor)

def literal (cursor : Cursor) (text : String) : Option Cursor :=
  let bytes := text.toUTF8
  if cursor.index + bytes.size ≤ cursor.input.size ∧
      (List.range bytes.size).all (fun offset =>
        cursor.input.data.getD (cursor.index + offset) 0 = bytes.data.getD offset 0) then
    some (advance cursor bytes.size)
  else
    none

def hexDigit? (byte : UInt8) : Option Nat :=
  let code := byte.toNat
  if 48 ≤ code ∧ code ≤ 57 then some (code - 48)
  else if 65 ≤ code ∧ code ≤ 70 then some (code - 65 + 10)
  else if 97 ≤ code ∧ code ≤ 102 then some (code - 97 + 10)
  else none

def parseHexQuad (initial : Cursor) : Except String (Nat × Cursor) := do
  if initial.index + 4 > initial.input.size then
    throw "invalid state JSON: incomplete Unicode escape"
  let mut value := 0
  let mut cursor := initial
  for _ in [0:4] do
    let digit ← match byteAt? cursor >>= hexDigit? with
      | some digit => pure digit
      | none => throw "invalid state JSON: invalid Unicode escape"
    value := value * 16 + digit
    cursor := advance cursor
  pure (value, cursor)

def pushScalar (output : ByteArray) (scalar : Nat) : Except String ByteArray := do
  if scalar = 0 then throw "invalid state JSON: NUL is not supported in state strings"
  if 0x10ffff < scalar ∨ (0xd800 ≤ scalar ∧ scalar ≤ 0xdfff) then
    throw "invalid state JSON: invalid Unicode scalar"
  if scalar ≤ 0x7f then
    pure (output.push (UInt8.ofNat scalar))
  else if scalar ≤ 0x7ff then
    pure (output.push (UInt8.ofNat (0xc0 + scalar / 64))
      |>.push (UInt8.ofNat (0x80 + scalar % 64)))
  else if scalar ≤ 0xffff then
    pure (output.push (UInt8.ofNat (0xe0 + scalar / 4096))
      |>.push (UInt8.ofNat (0x80 + (scalar / 64) % 64))
      |>.push (UInt8.ofNat (0x80 + scalar % 64)))
  else
    pure (output.push (UInt8.ofNat (0xf0 + scalar / 262144))
      |>.push (UInt8.ofNat (0x80 + (scalar / 4096) % 64))
      |>.push (UInt8.ofNat (0x80 + (scalar / 64) % 64))
      |>.push (UInt8.ofNat (0x80 + scalar % 64)))

def parseString (initial : Cursor) : Except String (String × Cursor) := do
  let (opened, initial) := consume initial 34
  if !opened then throw "invalid state JSON: expected string"
  let mut cursor := initial
  let mut output := ByteArray.empty
  while cursor.index < cursor.input.size do
    let byte := cursor.input.data.getD cursor.index 0
    cursor := advance cursor
    if byte = 34 then
      let text ← match String.fromUTF8? output with
        | some text => pure text
        | none => throw "invalid state JSON: string is not UTF-8"
      return (text, cursor)
    else if byte = 92 then
      let escaped ← match byteAt? cursor with
        | some escaped => pure escaped
        | none => throw "invalid state JSON: incomplete escape"
      cursor := advance cursor
      match escaped with
      | 34 | 47 | 92 => output := output.push escaped
      | 98 => output := output.push 8
      | 102 => output := output.push 12
      | 110 => output := output.push 10
      | 114 => output := output.push 13
      | 116 => output := output.push 9
      | 117 =>
          let (high, next) ← parseHexQuad cursor
          cursor := next
          let scalar ← if 0xd800 ≤ high ∧ high ≤ 0xdbff then do
              let (slash, next) := consume cursor 92
              let (letter, next) := consume next 117
              if !slash ∨ !letter then throw "invalid state JSON: unpaired high surrogate"
              let (low, next) ← parseHexQuad next
              if low < 0xdc00 ∨ 0xdfff < low then
                throw "invalid state JSON: invalid low surrogate"
              cursor := next
              pure (0x10000 + (high - 0xd800) * 1024 + low - 0xdc00)
            else if 0xdc00 ≤ high ∧ high ≤ 0xdfff then
              throw "invalid state JSON: unpaired low surrogate"
            else
              pure high
          output ← pushScalar output scalar
      | _ => throw "invalid state JSON: invalid escape"
    else if byte.toNat ≤ 0x1f then
      throw "invalid state JSON: unescaped control byte"
    else
      output := output.push byte
  throw "invalid state JSON: unterminated string"

def parseNumber (initial : Cursor) : Except String (String × Cursor) := do
  let start := initial.index
  let mut cursor := initial
  let (negative, next) := consume cursor 45
  cursor := next
  if negative ∧ !(byteAt? cursor).any (fun byte => 48 ≤ byte.toNat ∧ byte.toNat ≤ 57) then
    throw "invalid state JSON: malformed number"
  let (zero, next) := consume cursor 48
  cursor := next
  if zero then
    if (byteAt? cursor).any (fun byte => 48 ≤ byte.toNat ∧ byte.toNat ≤ 57) then
      throw "invalid state JSON: leading zero"
  else
    let digitStart := cursor.index
    while (byteAt? cursor).any (fun byte => 48 ≤ byte.toNat ∧ byte.toNat ≤ 57) do
      cursor := advance cursor
    if cursor.index = digitStart then throw "invalid state JSON: malformed number"
  let bytes := initial.input.extract start cursor.index
  let text ← match String.fromUTF8? bytes with
    | some text => pure text
    | none => throw "invalid state JSON: malformed number"
  pure (text, cursor)

mutual
  def parseValue (initial : Cursor) (remainingDepth : Nat) : Except String (Json × Cursor) := do
    let cursor := skipSpace initial
    match byteAt? cursor with
    | some 34 =>
        let (value, cursor) ← parseString cursor
        pure (.string value, cursor)
    | some 123 =>
        match remainingDepth with
        | 0 => throw "state JSON nesting exceeds 64 levels"
        | remainingDepth + 1 => parseObject cursor remainingDepth
    | some 91 =>
        match remainingDepth with
        | 0 => throw "state JSON nesting exceeds 64 levels"
        | remainingDepth + 1 => parseArray cursor remainingDepth
    | some 116 =>
        let cursor ← match literal cursor "true" with
          | some cursor => pure cursor
          | none => throw "invalid state JSON: malformed value"
        pure (.boolean true, cursor)
    | some 102 =>
        let cursor ← match literal cursor "false" with
          | some cursor => pure cursor
          | none => throw "invalid state JSON: malformed value"
        pure (.boolean false, cursor)
    | some byte =>
        if byte = 45 ∨ (48 ≤ byte.toNat ∧ byte.toNat ≤ 57) then
          let (text, cursor) ← parseNumber cursor
          pure (.number text, cursor)
        else
          throw "invalid state JSON: malformed value"
    | none => throw "invalid state JSON: malformed value"

  def parseObject (initial : Cursor) (remainingDepth : Nat) : Except String (Json × Cursor) := do
    let (_, afterOpen) := consume initial 123
    let mut cursor := skipSpace afterOpen
    let mut values : Array (String × Json) := #[]
    let (closed, next) := consume cursor 125
    if closed then return (.object values, next)
    for _ in [0:maxObjectMembers + 1] do
      if values.size ≥ maxObjectMembers then throw "state JSON object exceeds 32 members"
      let (key, next) ← parseString cursor
      if values.any fun entry => entry.1 = key then
        throw s!"invalid state JSON: duplicate object key: {key}"
      cursor := skipSpace next
      let (colon, next) := consume cursor 58
      if !colon then throw "invalid state JSON: expected colon"
      let (value, next) ← parseValue next remainingDepth
      values := values.push (key, value)
      cursor := skipSpace next
      let (closed, next) := consume cursor 125
      if closed then return (.object values, next)
      let (comma, next) := consume cursor 44
      if !comma then throw "invalid state JSON: expected comma or closing brace"
      cursor := skipSpace next
    throw "invalid state JSON: malformed object"

  def parseArray (initial : Cursor) (remainingDepth : Nat) : Except String (Json × Cursor) := do
    let (_, afterOpen) := consume initial 91
    let mut cursor := skipSpace afterOpen
    let mut values : Array Json := #[]
    let (closed, next) := consume cursor 93
    if closed then return (.array values, next)
    for _ in [0:maxArrayItems + 1] do
      if values.size ≥ maxArrayItems then throw "state JSON array exceeds 1024 items"
      let (value, next) ← parseValue cursor remainingDepth
      values := values.push value
      cursor := skipSpace next
      let (closed, next) := consume cursor 93
      if closed then return (.array values, next)
      let (comma, next) := consume cursor 44
      if !comma then throw "invalid state JSON: expected comma or closing bracket"
      cursor := skipSpace next
    throw "invalid state JSON: malformed array"
end

def parse (input : ByteArray) : Except String Json := do
  if !inputSizeAllowed input.size then throw "state JSON exceeds 1048576 bytes"
  let (value, cursor) ← parseValue { input } maxDepth
  if (skipSpace cursor).index != input.size then throw "invalid state JSON: trailing data"
  pure value

def objectValue? (values : Array (String × Json)) (key : String) : Option Json :=
  (values.find? fun entry => entry.1 = key).map (fun entry => entry.2)

def allowedKeys (values : Array (String × Json)) (allowed : Array String)
    (messagePrefix : String) : Except String Unit := do
  for entry in values do
    if !allowed.contains entry.1 then throw s!"{messagePrefix}{entry.1}"

def requiredString (values : Array (String × Json)) (key : String) : Except String String :=
  match objectValue? values key with
  | some (.string value) => pure value
  | _ => throw s!"state {key} must be a string"

def optionalString (values : Array (String × Json)) (key : String) : Except String (Option String) :=
  match objectValue? values key with
  | some (.string value) => pure (some value)
  | some _ => throw s!"state {key} must be a string"
  | none => pure none

def stringArray (values : Array (String × Json)) (key : String) : Except String Unit :=
  match objectValue? values key with
  | none => pure ()
  | some (.array items) =>
      if items.all (fun item => match item with | .string _ => true | _ => false) then pure ()
      else throw s!"state {key} must contain strings"
  | some _ => throw s!"state {key} must be an array"

def inheritFixed (target : Option NamedFixed) (args : Array (String × Json))
    (key : String) : Except String (Option NamedFixed) := do
  let some text ← optionalString args key | return target
  if target.isSome then return target
  let value ← match Decimal.parse text with
    | some value => pure value
    | none => throw s!"state {key} is invalid"
  pure (some { value, text })

def canonicalRange (text : String) : Option (Int × Int) := do
  let [first, last] := text.splitOn ".." | none
  if first.isEmpty ∨ last.isEmpty then none else pure ()
  let firstValue ← Decimal.parseInt first
  let lastValue ← Decimal.parseInt last
  pure (firstValue, lastValue)

def apply (initial : Options) (input : ByteArray) : Except String Options := do
  let root ← parse input
  let .object root := root | throw "state JSON must be an object"
  allowedKeys root #["sv", "rv", "seed", "next_pos", "args", "notices", "warnings"]
    "unknown state key: "
  match objectValue? root "sv" with
  | some (.number "2") => pure ()
  | some (.number _) | none => throw "unsupported state schema version"
  | some _ => throw "state sv must be a number"
  let _ ← requiredString root "rv"
  let seedText ← requiredString root "seed"
  if seedText.length != 66 ∨ !seedText.startsWith "0x" then
    throw "state seed must be exactly 32 bytes of 0x-prefixed hexadecimal"
  let seed ← match parseSeed seedText with
    | some seed => pure seed
    | none => throw "state seed must be exactly 32 bytes of 0x-prefixed hexadecimal"
  let positionText ← requiredString root "next_pos"
  let positionValue ← match Decimal.parseInt positionText with
    | some value => pure value
    | none => throw "state next_pos must be a decimal string no larger than 2^53"
  if positionValue < 0 then throw "state next_pos must be a decimal string no larger than 2^53"
  let args ← match objectValue? root "args" with
    | some (.object args) => pure args
    | _ => throw "state args must be an object"
  stringArray root "notices"
  stringArray root "warnings"
  allowedKeys args #["op", "distribution", "range", "count", "mean", "stddev",
    "rate", "lambda", "alpha", "beta", "precision", "binary", "encoding", "delim"]
    "unknown state args key: "

  let cliStdin := initial.operationCount > 0
  let cliDistribution := initial.modeCli ∨ initial.range.isSome
  let mut options := initial
  if !cliStdin ∧ !cliDistribution then
    if let some operation ← optionalString args "op" then
      options := match operation with
        | "choose" => { options with operation := .choose, operationCount := 1 }
        | "shuffle" => { options with operation := .shuffle, operationCount := 1 }
        | "weighted" => { options with operation := .weighted, operationCount := 1 }
        | _ => options
      if operation != "choose" ∧ operation != "shuffle" ∧ operation != "weighted" then
        throw "state operation is unsupported"
    if let some distribution ← optionalString args "distribution" then
      let mode ← match distribution with
        | "uniform" => pure Mode.uniform
        | "normal" => pure Mode.normal
        | "exponential" => pure Mode.exponential
        | "poisson" => pure Mode.poisson
        | "log-normal" => pure Mode.logNormal
        | "beta" => pure Mode.beta
        | _ => throw "state distribution is unsupported"
      options := { options with mode, modeCount := if mode == .uniform then 0 else 1 }

  if !options.countSet then
    if let some text ← optionalString args "count" then
      let value ← match Decimal.parseInt text with
        | some value => pure value
        | none => throw "state count is invalid"
      if value < 0 then throw "state count is invalid"
      options := { options with count := some value.toNat }
  if options.range.isNone then
    if let some text ← optionalString args "range" then
      let range ← match canonicalRange text with
        | some range => pure range
        | none => throw "state range must be canonical M..N"
      options := { options with range := some range }
  if !options.delimiterSet then
    if let some text ← optionalString args "delim" then
      options := { options with delimiter := text.toUTF8 }
  if options.encodingCount = 0 then
    if let some encoding ← optionalString args "encoding" then
      options := match encoding with
        | "text" => { options with binary := false, encoding := .text }
        | "hex" => { options with binary := false, encoding := .hex }
        | "raw" => { options with binary := true, encoding := .text }
        | "binary-hex" => { options with binary := true, encoding := .hex }
        | "base64" => { options with binary := true, encoding := .base64 }
        | _ => options
      if !#["text", "hex", "raw", "binary-hex", "base64"].contains encoding then
        throw "state encoding is unsupported"
  if let some binary := objectValue? args "binary" then
    match binary with
    | .boolean _ => pure ()
    | _ => throw "state binary must be boolean"

  if options.operation == .generate then
    match options.mode with
    | .normal | .logNormal =>
        let mean ← inheritFixed options.mean args "mean"
        let stddev ← inheritFixed options.stddev args "stddev"
        options := { options with mean, stddev }
    | .exponential =>
        let rate ← inheritFixed options.rate args "rate"
        options := { options with rate }
    | .poisson =>
        let mean ← inheritFixed options.mean args "mean"
        let lambda ← inheritFixed options.lambda args "lambda"
        options := { options with mean, lambda }
    | .beta =>
        let alpha ← inheritFixed options.alpha args "alpha"
        let beta ← inheritFixed options.beta args "beta"
        options := { options with alpha, beta }
    | .uniform => pure ()
  for entry in [("stddev", options.stddev), ("rate", options.rate),
      ("lambda", options.lambda), ("alpha", options.alpha), ("beta", options.beta)] do
    if entry.2.any (fun value => value.value.m ≤ 0) then throw s!"state {entry.1} must be positive"
  if !options.precisionSet then
    if let some text ← optionalString args "precision" then
      let precision ← match Decimal.parseInt text with
        | some value => pure value
        | none => throw "state precision is invalid"
      if precision < 0 ∨ 18 < precision then throw "state precision is invalid"
      options := { options with precision := precision.toNat, precisionSet := true }

  let position := positionValue.toNat
  options := { options with seed := some seed }
  options := { options with position := position }
  pure { options with deterministic := true, state := none }

end Randoml.State
