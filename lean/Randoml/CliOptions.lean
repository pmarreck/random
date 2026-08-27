import Randoml.Decimal
import Randoml.Chart

namespace Randoml.CliOptions

open Randoml.Fixed

inductive Mode
  | uniform
  | normal
  | exponential
  | poisson
  | logNormal
  | beta
deriving BEq, Repr

inductive Operation
  | generate
  | choose
  | shuffle
  | weighted
deriving BEq, Repr

inductive Encoding
  | text
  | hex
  | base64
deriving BEq, Repr

inductive StateRequest
  | stdin
  | inline (json : String)
deriving BEq, Repr

inductive Action
  | about
  | help
  | test
deriving BEq, Repr

structure NamedFixed where
  value : Value
  text : String
deriving BEq, Repr

structure Options where
  program : String := "randoml"
  deterministic : Bool := false
  forceTrueRandom : Bool := false
  mode : Mode := .uniform
  modeCount : Nat := 0
  modeCli : Bool := false
  operation : Operation := .generate
  operationCount : Nat := 0
  binary : Bool := false
  encoding : Encoding := .text
  encodingCount : Nat := 0
  count : Option Nat := none
  countSet : Bool := false
  precision : Nat := 18
  precisionSet : Bool := false
  delimiter : ByteArray := "\n".toUTF8
  delimiterSet : Bool := false
  randomSource : Option ByteArray := none
  noWait : Bool := false
  seed : Option ByteArray := none
  state : Option StateRequest := none
  stateStdout : Bool := false
  position : Nat := 0
  range : Option (Int × Int) := none
  mean : Option NamedFixed := none
  stddev : Option NamedFixed := none
  rate : Option NamedFixed := none
  lambda : Option NamedFixed := none
  alpha : Option NamedFixed := none
  beta : Option NamedFixed := none
  view : Bool := false
  renderer : Option Chart.Renderer := none
  action : Option Action := none
  generationSeen : Bool := false

def bytePrefix (bytes beginning : ByteArray) : Bool :=
  beginning.size ≤ bytes.size ∧
    (List.range beginning.size).all fun index =>
      bytes.data.getD index 0 == beginning.data.getD index 0

def byteEqualAscii (bytes : ByteArray) (text : String) : Bool :=
  bytes == text.toUTF8

def text? (bytes : ByteArray) : Option String :=
  String.fromUTF8? bytes

def basename (path : String) : String :=
  let name := path.toList.reverse.takeWhile fun character =>
    character != '/' ∧ character != '\\'
  if name.isEmpty then "randoml" else String.ofList name.reverse

def stripExe (name : String) : String :=
  if name.endsWith ".exe" ∨ name.endsWith ".EXE" then
    (name.dropEnd 4).toString
  else
    name

def normalInvocation (program : String) : Bool :=
  let name := stripExe program
  name = "nrandom" ∨ name = "nrandomz" ∨ name = "nrandomr" ∨ name = "nrandoml"

def deterministicInvocation (program : String) : Bool :=
  let name := stripExe program
  name = "drandom" ∨ name = "drandomz" ∨ name = "drandomr" ∨ name = "drandoml"

def initial (program : String) : Options :=
  let normal := normalInvocation program
  { program
    deterministic := deterministicInvocation program
    mode := if normal then .normal else .uniform
    modeCount := if normal then 1 else 0
    modeCli := normal }

def hexDigit? (byte : UInt8) : Option UInt8 :=
  let value := byte.toNat
  if 48 ≤ value ∧ value ≤ 57 then some (UInt8.ofNat (value - 48))
  else if 97 ≤ value ∧ value ≤ 102 then some (UInt8.ofNat (value - 97 + 10))
  else if 65 ≤ value ∧ value ≤ 70 then some (UInt8.ofNat (value - 65 + 10))
  else none

def parseSeed (text : String) : Option ByteArray := do
  let bytes := text.toUTF8
  if bytes.size = 0 then none else pure ()
  let hexadecimal := bytePrefix bytes "0x".toUTF8 ∨ bytePrefix bytes "0X".toUTF8
  if hexadecimal then
    let digits := bytes.extract 2 bytes.size
    if digits.size = 0 ∨ 64 < digits.size then none else pure ()
    let mut output := Array.replicate 32 0
    let mut source := 0
    let mut target := 32 - (digits.size + 1) / 2
    if digits.size % 2 = 1 then
      let digit ← hexDigit? (digits.data.getD 0 255)
      output := output.setIfInBounds target digit
      source := 1
      target := target + 1
    for pair in [0:(digits.size - source) / 2] do
      let high ← hexDigit? (digits.data.getD (source + pair * 2) 255)
      let low ← hexDigit? (digits.data.getD (source + pair * 2 + 1) 255)
      output := output.setIfInBounds (target + pair)
        (UInt8.ofNat (high.toNat * 16 + low.toNat))
    pure ⟨output⟩
  else
    let mut output := Array.replicate 32 0
    for byte in bytes.data do
      if byte.toNat < 48 ∨ 57 < byte.toNat then none else pure ()
      let mut carry := byte.toNat - 48
      for reverseIndex in [0:32] do
        let index := 31 - reverseIndex
        let value := (output.getD index 0).toNat * 10 + carry
        output := output.setIfInBounds index (UInt8.ofNat value)
        carry := value / 256
      if carry != 0 then none else pure ()
    pure ⟨output⟩

def splitDash (text : String) : Option (String × String) := do
  let characters := text.toList
  let signLength := match characters with
    | '+' :: _ | '-' :: _ => 1
    | _ => 0
  let head := characters.take signLength
  let result := (characters.drop signLength).span fun character => character != '-'
  match result.2 with
  | '-' :: tail => some (String.ofList (head ++ result.1), String.ofList tail)
  | _ => none

def twoParts (text separator : String) : Option (String × String) :=
  match text.splitOn separator with
  | [first, second] => some (first, second)
  | _ => none

def rangeSyntaxError : String :=
  "range must be dN, M-N, M..N, or M...N using positive dN and whole-number bounds no larger than 2^53 in magnitude"

def parseRange (text : String) : Except String (Int × Int) := do
  if text.startsWith "d" then
    let some faces := Decimal.parseInt (text.drop 1).toString | throw rangeSyntaxError
    if faces < 1 then throw rangeSyntaxError else pure (1, faces)
  else if let some (firstText, lastText) := twoParts text "..." then
    let some first := Decimal.parseInt firstText | throw rangeSyntaxError
    let some last := Decimal.parseInt lastText | throw rangeSyntaxError
    if first ≥ last then throw "an end-exclusive range must have M < N" else pure (first, last - 1)
  else if let some (firstText, lastText) := twoParts text ".." then
    let some first := Decimal.parseInt firstText | throw rangeSyntaxError
    let some last := Decimal.parseInt lastText | throw rangeSyntaxError
    pure (first, last)
  else
    let some (firstText, lastText) := splitDash text | throw rangeSyntaxError
    let some first := Decimal.parseInt firstText | throw rangeSyntaxError
    let some last := Decimal.parseInt lastText | throw rangeSyntaxError
    pure (first, last)

def rangeRejected (text : String) : Bool :=
  match parseRange text with
  | .ok _ => false
  | .error _ => true

def selectMode (options : Options) (mode : Mode) : Options :=
  if options.modeCount > 0 ∧ options.mode == mode then options
  else { options with mode := mode, modeCount := options.modeCount + 1, modeCli := true }

def selectOperation (options : Options) (operation : Operation) : Options :=
  if options.operation == operation ∧ options.operationCount > 0 then options
  else { options with operation := operation, operationCount := options.operationCount + 1, generationSeen := true }

def selectEncoding (options : Options) (encoding : Encoding) : Options :=
  if options.encoding == encoding ∧ options.encodingCount > 0 then options
  else { options with encoding := encoding, encodingCount := options.encodingCount + 1, generationSeen := true }

def optionToExcept (message : ε) : Option α → Except ε α
  | some value => pure value
  | none => throw message

def setFixed (options : Options) (name text : String) : Except String Options := do
  if text.isEmpty then throw s!"{name} requires a number"
  let value ← optionToExcept s!"{name} value must be a number" (Decimal.parse text)
  let named := { value, text }
  match name with
  | "--mean" => pure { options with mean := some named }
  | "--stddev" =>
      if value.m ≤ 0 then throw "--stddev must be positive"
      pure { options with stddev := some named }
  | "--rate" =>
      if value.m ≤ 0 then throw "--rate must be positive"
      pure { options with rate := some named }
  | "--lambda" =>
      if value.m ≤ 0 then throw "--lambda must be positive"
      pure { options with lambda := some named }
  | "--alpha" =>
      if value.m ≤ 0 then throw "--alpha must be positive"
      pure { options with alpha := some named }
  | _ => throw s!"unknown numeric option: {name}"

def setBeta (options : Options) (text : String) : Except String Options := do
  let value ← optionToExcept "--beta value must be a number" (Decimal.parse text)
  if value.m ≤ 0 then throw "--beta parameter must be positive"
  pure { options with beta := some { value, text } }

def setPrecision (options : Options) (name text : String) : Except String Options := do
  let value ← optionToExcept s!"{name} must be a whole number from 0 to 18"
    (Decimal.parseInt text)
  if value < 0 ∨ value > 18 then throw s!"{name} must be a whole number from 0 to 18"
  pure { options with precision := value.toNat, precisionSet := true, generationSeen := true }

def attached (argument name : String) : Option String :=
  let beginning := name ++ "="
  if argument.startsWith beginning then
    some (argument.drop beginning.length).toString
  else
    none

def startsJson (text : String) : Bool :=
  match Decimal.trimAscii text.toList with
  | '{' :: _ => true
  | _ => false

def requireText (bytes : ByteArray) : Except String String :=
  optionToExcept "arguments other than --random-source paths must be valid UTF-8" (text? bytes)

def validate (options : Options) : Except String Options := do
  if options.modeCount > 1 then throw "only one distribution type can be specified"
  if options.operationCount > 1 then throw "only one stdin operation can be specified"
  if options.encodingCount > 1 then throw "output encodings are mutually exclusive"
  if options.view ∧ options.range.isSome then throw "--view does not accept a range"
  if options.view ∧ options.modeCount != 1 then
    throw "--view requires exactly one alternate distribution"
  if options.view ∧ options.generationSeen then
    throw "--view cannot be combined with generation, stdin, range, or output options"
  if options.renderer.isSome ∧ !options.view then
    throw "--kitty, --sixel, --utf8, and --utf8-graphics require --help or --view"
  if options.encoding == .base64 ∧ !options.binary then
    throw "--base64 requires --binaryoutput"
  if options.stateStdout ∧ options.binary ∧ options.encoding == .text then
    throw "--state-stdout requires --hex or --base64 with binary output"
  if options.stateStdout ∧ options.forceTrueRandom then
    throw "--state-stdout cannot be combined with --true-random"
  if options.binary ∧ options.precisionSet then
    throw "--precision/--truncate do not apply to binary output"
  if options.mean.isSome ∧
      !(options.mode == .normal ∨ options.mode == .poisson ∨ options.mode == .logNormal) then
    throw "--mean is not used by the selected distribution"
  if options.stddev.isSome ∧ !(options.mode == .normal ∨ options.mode == .logNormal) then
    throw "--stddev is not used by the selected distribution"
  if options.rate.isSome ∧ options.mode != .exponential then
    throw "--rate requires --exponential"
  if options.lambda.isSome ∧ options.mode != .poisson then
    throw "--lambda requires --poisson"
  if options.mode == .poisson ∧ options.lambda.isSome ∧ options.mean.isSome then
    throw "--lambda and --mean are aliases; specify only one"
  if options.alpha.isSome ∧ options.mode != .beta then
    throw "--alpha requires --beta"
  if options.forceTrueRandom ∧ options.deterministic then
    throw "--true-random cannot be combined with --deterministic, --seed, or drandoml"
  if options.mode == .poisson ∧ options.mean.any (fun value => value.value.m ≤ 0) then
    throw "--mean must be positive for --poisson (it is the rate parameter)"
  if options.state.isSome ∧ options.seed.isSome then
    throw "--state/--resume and --seed are mutually exclusive"
  if options.state.isSome ∧ options.randomSource.isSome then
    throw "--state/--resume cannot be combined with --random-source"
  if options.state.isSome ∧ options.noWait then
    throw "--state/--resume cannot be combined with --no-wait"
  if options.operation == .weighted ∧ options.delimiter.size = 0 then
    throw "--weighted does not support an empty delimiter"
  if options.delimiterSet ∧ (text? options.delimiter).isNone then
    throw "--delimiter must be valid UTF-8"
  pure options

def parse (arguments : Array ByteArray) : Except String Options := do
  let program := arguments[0]?.bind text? |>.map basename |>.getD "randoml"
  let mut options := initial program
  let mut positional : Array String := #[]
  let mut nextIndex := 1
  for cursor in [1:arguments.size] do
    if cursor < nextIndex then continue
    nextIndex := cursor + 1
    let raw := arguments[cursor]!
    if byteEqualAscii raw "--random-source" then
      if arguments.size ≤ cursor + 1 then throw "--random-source requires a path"
      let value := arguments[cursor + 1]!
      if value.size = 0 then throw "--random-source requires a path"
      options := { options with randomSource := some value, generationSeen := true }
      nextIndex := cursor + 2
      continue
    let randomPrefix := "--random-source=".toUTF8
    if bytePrefix raw randomPrefix then
      let value := raw.extract randomPrefix.size raw.size
      if value.size = 0 then throw "--random-source requires a path"
      options := { options with randomSource := some value, generationSeen := true }
      continue
    if byteEqualAscii raw "--delimiter" ∨ byteEqualAscii raw "--delim" then
      if arguments.size ≤ cursor + 1 then throw "--delimiter requires a value"
      options := { options with delimiter := (arguments[cursor + 1]!), delimiterSet := true, generationSeen := true }
      nextIndex := cursor + 2
      continue
    let delimiterPrefix := "--delimiter=".toUTF8
    let delimPrefix := "--delim=".toUTF8
    if bytePrefix raw delimiterPrefix ∨ bytePrefix raw delimPrefix then
      let size := if bytePrefix raw delimiterPrefix then delimiterPrefix.size else delimPrefix.size
      options := { options with delimiter := raw.extract size raw.size, delimiterSet := true, generationSeen := true }
      continue
    let argument ← requireText raw
    match argument with
    | "--about" | "-a" =>
        options := { options with action := some .about }
        nextIndex := arguments.size
    | "--help" | "-h" =>
        options := { options with action := some .help }
        nextIndex := arguments.size
    | "--test" =>
        options := { options with action := some .test }
        nextIndex := arguments.size
    | "--deterministic" | "-d" =>
        options := { options with deterministic := true, generationSeen := true }
    | "--true-random" =>
        options := { options with forceTrueRandom := true, generationSeen := true }
    | "--normalized" | "-n" => options := selectMode options .normal
    | "--exponential" => options := selectMode options .exponential
    | "--poisson" => options := selectMode options .poisson
    | "--log-normal" => options := selectMode options .logNormal
    | "--choose" => options := selectOperation options .choose
    | "--shuffle" => options := selectOperation options .shuffle
    | "--weighted" => options := selectOperation options .weighted
    | "--binaryoutput" | "-b" =>
        options := { options with binary := true, generationSeen := true }
    | "--hex" => options := selectEncoding options .hex
    | "--base64" => options := selectEncoding options .base64
    | "--state-stdout" =>
        options := { options with stateStdout := true, deterministic := true, generationSeen := true }
    | "--no-wait" => options := { options with noWait := true, generationSeen := true }
    | "--view" => options := { options with view := true }
    | "--kitty" => options := { options with renderer := some .kitty }
    | "--sixel" => options := { options with renderer := some .sixel }
    | "--utf8" | "--utf8-graphics" => options := { options with renderer := some .utf8 }
    | "--count" | "-c" =>
        if arguments.size ≤ cursor + 1 then throw "--count requires a number"
        let valueText ← requireText arguments[cursor + 1]!
        let value ← optionToExcept
          "--count must be a nonnegative whole number no larger than 2^53"
          (Decimal.parseInt valueText)
        if value < 0 then throw "--count must be a nonnegative whole number no larger than 2^53"
        options := { options with count := some value.toNat, countSet := true, generationSeen := true }
        nextIndex := cursor + 2
    | "--precision" | "--truncate" =>
        if arguments.size ≤ cursor + 1 then throw s!"{argument} requires a number"
        let value ← requireText arguments[cursor + 1]!
        options ← setPrecision options argument value
        nextIndex := cursor + 2
    | "--seed" =>
        if arguments.size ≤ cursor + 1 then throw "--seed requires a value"
        let value ← requireText arguments[cursor + 1]!
        let seed ← optionToExcept
          s!"--seed must be an unsigned decimal or 0x-prefixed hexadecimal integer smaller than 2^256, got: {value}"
          (parseSeed value)
        options := { options with seed := some seed, deterministic := true, generationSeen := true }
        nextIndex := cursor + 2
    | "--state" | "--resume" =>
        if options.state.isSome then throw "only one --state/--resume may be specified"
        let mut request := StateRequest.stdin
        if cursor + 1 < arguments.size then
          let candidateRaw := arguments[cursor + 1]!
          if let some candidate := text? candidateRaw then
            if candidate = "-" then
              nextIndex := cursor + 2
            else if startsJson candidate then
              request := .inline candidate
              nextIndex := cursor + 2
        options := { options with state := some request, deterministic := true, generationSeen := true }
    | "--mean" | "--stddev" | "--rate" | "--lambda" | "--alpha" =>
        if arguments.size ≤ cursor + 1 then throw s!"{argument} requires a number"
        let value ← requireText arguments[cursor + 1]!
        options ← setFixed options argument value
        nextIndex := cursor + 2
    | "--beta" =>
        options := selectMode options .beta
        if cursor + 1 < arguments.size then
          if let some candidate := text? arguments[cursor + 1]! then
            if (Decimal.parse candidate).isSome ∨
                (!candidate.startsWith "-" ∧ rangeRejected candidate) then
              options ← setBeta options candidate
              nextIndex := cursor + 2
    | _ =>
        if let some value := attached argument "--beta" then
          options := selectMode options .beta
          options ← setBeta options value
        else if let some value := attached argument "--count" then
          let parsed ← optionToExcept
            "--count must be a nonnegative whole number no larger than 2^53"
            (Decimal.parseInt value)
          if parsed < 0 then throw "--count must be a nonnegative whole number no larger than 2^53"
          options := { options with count := some parsed.toNat, countSet := true, generationSeen := true }
        else if let some value := attached argument "--precision" then
          options ← setPrecision options "--precision" value
        else if let some value := attached argument "--truncate" then
          options ← setPrecision options "--truncate" value
        else if let some value := attached argument "--seed" then
          let seed ← optionToExcept
            s!"--seed must be an unsigned decimal or 0x-prefixed hexadecimal integer smaller than 2^256, got: {value}"
            (parseSeed value)
          options := { options with seed := some seed, deterministic := true, generationSeen := true }
        else if let some value := attached argument "--state" then
          if options.state.isSome then throw "only one --state/--resume may be specified"
          if value.isEmpty then throw "--state/--resume= requires inline JSON or '-'"
          options := { options with state := some (if value = "-" then .stdin else .inline value), deterministic := true, generationSeen := true }
        else if let some value := attached argument "--resume" then
          if options.state.isSome then throw "only one --state/--resume may be specified"
          if value.isEmpty then throw "--state/--resume= requires inline JSON or '-'"
          options := { options with state := some (if value = "-" then .stdin else .inline value), deterministic := true, generationSeen := true }
        else
          let mut matched := false
          for name in ["--mean", "--stddev", "--rate", "--lambda", "--alpha"] do
            if let some value := attached argument name then
              options ← setFixed options name value
              matched := true
          if !matched then
            if argument.startsWith "--" then throw s!"unknown option: {argument}"
            positional := positional.push argument
  if options.action.isSome then return options
  if options.view ∧ !positional.isEmpty then throw "--view does not accept a range"
  if positional.size > 1 then
    throw "expected at most one range (dN, M-N, M..N, or M...N)"
  if let some literal := positional[0]? then
    if !(options.mode == .uniform ∨ options.mode == .normal) then
      throw "ranges do not apply to the selected distribution"
    if options.mode == .normal ∧ (options.mean.isSome ∨ options.stddev.isSome) then
      throw "a range cannot be combined with custom normal parameters"
    let range ← parseRange literal
    options := { options with range := some range, generationSeen := true }
  validate options

end Randoml.CliOptions
