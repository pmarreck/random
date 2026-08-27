import Randoml.Chart
import Randoml.Decimal
import Randoml.CliOptions
import Randoml.CliSource
import Randoml.State
import Randoml.Shuffle

namespace Randoml.Cli

open Randoml
open Randoml.Fixed
open Randoml.CliOptions

def version := "0.3.0"
def streamChunk : Nat := 65535

inductive Generated
  | integer (value : Int)
  | fixed (value : Value)

def writeBytes (stream : IO.FS.Stream) (bytes : ByteArray) : IO Unit :=
  stream.write bytes

def jsonQuote (value : String) : String := Id.run do
  let hex := "0123456789abcdef".toUTF8
  let mut output := ByteArray.empty.push 34
  for byte in value.toUTF8.data do
    match byte with
    | 34 => output := output.push 92 |>.push 34
    | 92 => output := output.push 92 |>.push 92
    | 8 => output := output.push 92 |>.push 98
    | 9 => output := output.push 92 |>.push 116
    | 10 => output := output.push 92 |>.push 110
    | 12 => output := output.push 92 |>.push 102
    | 13 => output := output.push 92 |>.push 114
    | byte =>
        if byte.toNat < 32 then
          output := output.push 92 |>.push 117 |>.push 48 |>.push 48
            |>.push (hex.data.getD (byte.toNat / 16) 48)
            |>.push (hex.data.getD (byte.toNat % 16) 48)
        else
          output := output.push byte
  output := output.push 34
  pure ((String.fromUTF8? output).getD "")

def errorJson (message : String) : String :=
  "{\"sv\":2,\"rv\":" ++ jsonQuote version ++
    ",\"error\":{\"code\":\"usage\",\"message\":" ++ jsonQuote message ++
    "},\"notices\":[],\"warnings\":[]}\n"

def byteHex (bytes : ByteArray) : String := Id.run do
  let alphabet := "0123456789abcdef".toUTF8
  let mut output := ""
  for byte in bytes.data do
    output := output.push (Char.ofNat (alphabet.data.getD (byte.toNat / 16) 48).toNat)
    output := output.push (Char.ofNat (alphabet.data.getD (byte.toNat % 16) 48).toNat)
  pure output

def intHex (value : Int) : String :=
  if value < 0 then "-" ++ String.ofList (Nat.toDigits 16 value.natAbs)
  else String.ofList (Nat.toDigits 16 value.toNat)

def envPresent (name : String) : BaseIO Bool := do
  pure ((← IO.getEnv name).any fun value => !value.isEmpty)

def envEquals (name expected : String) : BaseIO Bool := do
  pure ((← IO.getEnv name).any fun value => value.toLower = expected.toLower)

def explicitRenderer (arguments : Array ByteArray) : Option Chart.Renderer := Id.run do
  let mut result := none
  for raw in arguments do
    if let some argument := String.fromUTF8? raw then
      match argument with
      | "--kitty" => result := some .kitty
      | "--sixel" => result := some .sixel
      | "--utf8" | "--utf8-graphics" => result := some .utf8
      | _ => pure ()
  pure result

def selectRenderer (arguments : Array ByteArray) : IO (Except String Chart.Renderer) := do
  if let some renderer := explicitRenderer arguments then return .ok renderer
  if let some requested := ← IO.getEnv "RANDOMZ_CHART_TYPE" then
    if !requested.isEmpty then
      return match requested.toLower with
        | "utf8" => .ok .utf8
        | "kitty" => .ok .kitty
        | "sixel" => .ok .sixel
        | _ => .error "RANDOMZ_CHART_TYPE must be utf8, kitty, or sixel"
  if !(← (← IO.getStdout).isTty) ∨ (← envPresent "TMUX") then return .ok .utf8
  if (← envPresent "WEZTERM_PANE") ∨ (← envPresent "WEZTERM_EXECUTABLE") ∨
      (← envEquals "TERM_PROGRAM" "WezTerm") then return .ok .sixel
  if (← envEquals "TERM" "xterm-kitty") ∨ (← envPresent "KITTY_WINDOW_ID") ∨
      (← envPresent "GHOSTTY_RESOURCES_DIR") ∨ (← envEquals "TERM_PROGRAM" "ghostty") ∨
      (← envEquals "TERM_PROGRAM" "kitty") then return .ok .kitty
  pure (.ok .utf8)

def chooseParameter (defaults : Bool) (value : Option NamedFixed) : Option NamedFixed :=
  if defaults then none else value

def firstSome (first second : Option α) : Option α :=
  match first with
  | some value => some value
  | none => second

def chartSpec (mode : Mode) (mean stddev rate lambda alpha beta : Option NamedFixed)
    (defaults : Bool) : Chart.Spec :=
  let zero := fromInt 0
  let one := fromInt 1
  let two := fromInt 2
  match mode with
  | .normal =>
      let mean := chooseParameter defaults mean
      let stddev := chooseParameter defaults stddev
      { kind := .normal
        first := mean.map (·.value) |>.getD zero
        second := stddev.map (·.value) |>.getD one
        title := "Normal (Gaussian)"
        parameters := s!"Parameters: mean={mean.map (·.text) |>.getD "0"}, stddev={stddev.map (·.text) |>.getD "1"}."
        axis := "Horizontal axis: mean +/- 4 standard deviations; vertical axis: relative probability density." }
  | .exponential =>
      let rate := chooseParameter defaults rate
      { kind := .exponential, first := rate.map (·.value) |>.getD one, second := zero
        title := "Exponential"
        parameters := s!"Parameters: rate={rate.map (·.text) |>.getD "1"}."
        axis := "Horizontal axis: 0 to 6/rate; vertical axis: relative probability density." }
  | .poisson =>
      let parameter := if defaults then none else firstSome lambda mean
      { kind := .poisson, first := parameter.map (·.value) |>.getD one, second := zero
        title := "Poisson"
        parameters := s!"Parameters: lambda={parameter.map (·.text) |>.getD "1"}."
        axis := "Horizontal axis: lambda +/- 6*sqrt(lambda), clipped at zero; vertical axis: probability mass." }
  | .logNormal =>
      let mean := chooseParameter defaults mean
      let stddev := chooseParameter defaults stddev
      { kind := .logNormal
        first := mean.map (·.value) |>.getD zero
        second := stddev.map (·.value) |>.getD one
        title := "Log-normal"
        parameters := s!"Parameters: mean={mean.map (·.text) |>.getD "0"}, stddev={stddev.map (·.text) |>.getD "1"}."
        axis := "Horizontal axis: 0 to exp(mean + min(1.625*stddev, 20)); vertical axis: relative probability density." }
  | .beta =>
      let alpha := chooseParameter defaults alpha
      let beta := chooseParameter defaults beta
      { kind := .beta
        first := alpha.map (·.value) |>.getD two
        second := beta.map (·.value) |>.getD two
        title := "Beta"
        parameters := s!"Parameters: alpha={alpha.map (·.text) |>.getD "2"}, beta={beta.map (·.text) |>.getD "2"}."
        axis := "Horizontal axis: value from 0 to 1; vertical axis: relative probability density." }
  | .uniform =>
      { kind := .normal, first := zero, second := one, title := "", parameters := "", axis := "" }

def selectedHelpMode (arguments : Array ByteArray) (program : String) : Mode := Id.run do
  let mut selected := if normalInvocation program then Mode.normal else .uniform
  for raw in arguments.extract 1 arguments.size do
    if let some argument := String.fromUTF8? raw then
      let candidate : Option Mode := match argument with
        | "--normalized" | "-n" => some .normal
        | "--exponential" => some .exponential
        | "--poisson" => some .poisson
        | "--log-normal" => some .logNormal
        | "--beta" => some .beta
        | _ => if argument.startsWith "--beta=" then some .beta else none
      if let some candidate := candidate then
        if selected != .uniform ∧ selected != candidate then return .uniform
        selected := candidate
  pure selected

def printChart (arguments : Array ByteArray) (spec : Chart.Spec) (help : Bool) :
    IO (Except String Unit) := do
  let rendererResult ← selectRenderer arguments
  let .ok renderer := rendererResult |
    return .error (match rendererResult with | .error message => message | _ => "renderer failed")
  let tmux ← envPresent "TMUX"
  let rendered := match renderer with
    | .kitty => Chart.makeRaster spec |>.map fun raster =>
        Chart.encodeKittyPayload raster (Native.base64 (Chart.rawRgb raster)) tmux
    | _ => Chart.render spec renderer tmux
  let some bytes := rendered |
    return .error "supplied distribution parameters cannot be charted"
  let stdout ← IO.getStdout
  if help then writeBytes stdout "\n".toUTF8
  writeBytes stdout s!"Distribution: {spec.title}\n{spec.parameters}\n\n".toUTF8
  writeBytes stdout bytes
  writeBytes stdout (spec.axis ++ "\n").toUTF8
  pure (.ok ())

def printAbout (program : String) : IO Unit := do
  let description := if normalInvocation program then
    "CSPRNG for normal variates with OS entropy or cross-platform-identical deterministic streams"
  else if deterministicInvocation program then
    "Cross-platform-identical deterministic CSPRNG using a seeded BLAKE3 keyed XOF"
  else
    "CSPRNG with OS entropy, cross-platform-identical deterministic streams, and alternate distributions"
  writeBytes (← IO.getStdout)
    s!"{program} v{version} ({← Native.platformName}/{← Native.architectureName}): {description}\n".toUTF8

def helpText (program : String) : String :=
  s!"Usage: {program} [options] [dN|M-N|M..N|M...N]\n\n\
Cryptographically secure random generator with alternate distributions.\n\
Seeded mode provides cross-platform-identical deterministic streams.\n\
True-random mode uses fresh OS CSPRNG entropy; deterministic mode uses a seeded BLAKE3 keyed XOF.\n\
A positional dN rolls an N-sided die by selecting uniformly from 1..N.\n\n\
Distributions: --normalized, --exponential, --poisson, --log-normal, --beta[=B]\n\
Stdin operations: --choose, --shuffle, --weighted\n\n\
Options:\n\
  -a, --about         Show a short description\n\
  -b, --binaryoutput  Output binary bytes\n\
  -c, --count N       Output N numbers (default: 1, or 1024 with -b)\n\
  -d, --deterministic Use the cross-platform-identical BLAKE3 keyed XOF\n\
      --true-random   Force fresh OS/source CSPRNG entropy; ignore DRANDOML_SEED\n\
      --delimiter S   Set delimiter; empty means individual input bytes\n\
      --precision N   Truncate fractional output to 0..18 places (default: 18)\n\
      --truncate N    Alias for --precision\n\
  -h, --help          Show this help message\n\
      --hex           Output as hexadecimal\n\
      --base64        Output as base64 (for binary)\n\
      --seed N|0xHEX  Set unsigned 256-bit integer seed (implies -d)\n\
      --state [JSON|-] / --resume [JSON|-]  Resume a deterministic stream\n\
      --state-stdout  Append resumable state as the final stdout line\n\
      --random-source PATH  Read entropy from PATH instead of the OS\n\
      --no-wait       Use nonblocking getrandom\n\
      --kitty / --sixel / --utf8  Select distribution chart encoding\n\
      --view          Show only the selected distribution with supplied parameters\n\
      --mean M --stddev S --rate R --lambda L --alpha A\n\n\
Symlinks: nrandoml implies --normalized; drandoml implies --deterministic.\n\
Environment: DRANDOML_SEED; RANDOMZ_CHART_TYPE=utf8|kitty|sixel.\n\
Deterministic success metadata and all diagnostics are JSON.\n\
Seeded output, including alternate distributions, is byte-identical across supported operating systems and CPU architectures.\n"

def printHelp (arguments : Array ByteArray) (program : String) : IO (Except String Unit) := do
  writeBytes (← IO.getStdout) (helpText program).toUTF8
  let mode := selectedHelpMode arguments program
  if mode == .uniform then return .ok ()
  printChart arguments (chartSpec mode none none none none none none true) true

def updateEnvironmentSeed (options : Options) : IO (Except String Options) := do
  if options.forceTrueRandom ∨ options.seed.isSome then return .ok options
  let some text := ← IO.getEnv "DRANDOML_SEED" | return .ok options
  if text.isEmpty then return .ok options
  let some seed := parseSeed text |
    return .error s!"DRANDOML_SEED must be an unsigned decimal or 0x-prefixed hexadecimal integer smaller than 2^256, got: {text}"
  pure (.ok { options with seed := some seed, deterministic := true })

def openEntropy (options : Options) : IO Native.EntropySource :=
  Native.sourceOpen (options.randomSource.getD ByteArray.empty) options.noWait

def makeSource (options : Options) : IO (Except String (Options × CliSource.Source)) := do
  if options.deterministic then
    let seed ← match options.seed with
      | some seed => pure seed
      | none => do
          let entropy ← openEntropy options
          Native.sourceFill entropy 32
    let some state := Drbg.init seed | return .error "RNG core failed: invalid seed"
    let some state := state.seek options.position | return .error "RNG core failed: invalid position"
    pure (.ok ({ options with seed := some seed }, .deterministic { seed, state }))
  else
    pure (.ok (options, .entropy (← openEntropy options)))

def generationBounds (options : Options) : Except String (Int × Int × Nat × Bool) := do
  let (start, stop) := options.range.getD (if options.binary then (0, 255) else (0, 99))
  let count := options.count.getD (if options.binary then 1024 else 1)
  if options.binary ∧ start < 0 then throw "start value must be >= 0 for binary output"
  if options.binary ∧ stop > 255 then throw "end value must be <= 255 for binary output"
  if (options.mode == .uniform ∨ options.mode == .normal) ∧ start > stop then
    throw "start value must be less than or equal to end value"
  if stop - start ≥ Fixed.clamp then
    throw "an inclusive integer range may contain at most 2^53 values"
  let rangeScaled := (options.mode == .uniform ∨ options.mode == .normal) ∧
    !(options.mode == .normal ∧ (options.mean.isSome ∨ options.stddev.isSome))
  pure (start, stop, count, !options.binary ∧ options.range.isNone ∧ rangeScaled)

def generate (options : Options) (source : CliSource.Source)
    (start stop : Int) : IO (Except String (Generated × CliSource.Source)) := do
  let one := fromInt 1
  let two := fromInt 2
  match options.mode with
  | .uniform =>
      match ← CliSource.range source start stop with
      | .error message => pure (.error message)
      | .ok (value, source) => pure (.ok (.integer value, source))
  | .normal =>
      if options.mean.isNone ∧ options.stddev.isNone then
        match ← CliSource.normalInt source start stop with
        | .error message => pure (.error message)
        | .ok (value, source) => pure (.ok (.integer value, source))
      else
        match ← CliSource.normal source (options.mean.map (·.value) |>.getD Value.zero)
            (options.stddev.map (·.value) |>.getD one) with
        | .error message => pure (.error message)
        | .ok (value, source) => pure (.ok (.integer (roundToInt value), source))
  | .exponential =>
      match ← CliSource.exponential source (options.rate.map (·.value) |>.getD one) with
      | .error message => pure (.error message)
      | .ok (value, source) => pure (.ok (.fixed value, source))
  | .poisson =>
      let lambda := (firstSome options.lambda options.mean).map (·.value) |>.getD one
      match ← CliSource.poisson source lambda with
      | .error message => pure (.error message)
      | .ok (value, source) => pure (.ok (.integer value, source))
  | .logNormal =>
      match ← CliSource.logNormal source (options.mean.map (·.value) |>.getD Value.zero)
          (options.stddev.map (·.value) |>.getD one) with
      | .error message => pure (.error message)
      | .ok (value, source) => pure (.ok (.fixed value, source))
  | .beta =>
      match ← CliSource.beta source (options.alpha.map (·.value) |>.getD two)
          (options.beta.map (·.value) |>.getD two) with
      | .error message => pure (.error message)
      | .ok (value, source) => pure (.ok (.fixed value, source))

def generatedText (options : Options) : Generated → Except String String
  | .integer value => pure (if options.encoding == .hex then intHex value else toString value)
  | .fixed value =>
      match Decimal.render value options.precision with
      | some text => pure text
      | none => throw "numeric formatting failed"

def emitText (options : Options) (initialSource : CliSource.Source)
    (start stop : Int) (count : Nat) : IO (Except String CliSource.Source) := do
  let stdout ← IO.getStdout
  let mut source := initialSource
  for index in [0:count] do
    if index > 0 ∧ options.delimiter != "\n".toUTF8 then writeBytes stdout options.delimiter
    match ← generate options source start stop with
    | .error message => return .error message
    | .ok (value, next) =>
        source := next
        match generatedText options value with
        | .error message => return .error message
        | .ok text =>
            writeBytes stdout text.toUTF8
            if options.delimiter == "\n".toUTF8 then writeBytes stdout "\n".toUTF8
  if options.delimiter != "\n".toUTF8 then writeBytes stdout "\n".toUTF8
  stdout.flush
  pure (.ok source)

def generatedByte : Generated → UInt8
  | .integer value => UInt8.ofNat (value % 256).toNat
  | .fixed value => UInt8.ofNat (toIntTrunc value % 256).toNat

def generatedBytes (options : Options) (initialSource : CliSource.Source)
    (start stop : Int) (count : Nat) : IO (Except String (ByteArray × CliSource.Source)) := do
  if options.mode == .uniform ∧ start = 0 ∧ stop = 255 then
    return ← CliSource.fill initialSource count
  let mut source := initialSource
  let mut bytes := ByteArray.empty
  for _ in [0:count] do
    match ← generate options source start stop with
    | .error message => return .error message
    | .ok (value, next) =>
        source := next
        bytes := bytes.push (generatedByte value)
  pure (.ok (bytes, source))

def emitBinary (options : Options) (initialSource : CliSource.Source)
    (start stop : Int) (count : Nat) : IO (Except String CliSource.Source) := do
  let stdout ← IO.getStdout
  let mut source := initialSource
  let mut remaining := count
  while remaining > 0 do
    let amount := min remaining streamChunk
    match ← generatedBytes options source start stop amount with
    | .error message => return .error message
    | .ok (bytes, next) =>
        source := next
        if options.encoding == .hex then writeBytes stdout (byteHex bytes).toUTF8
        else if options.encoding == .base64 then writeBytes stdout (Native.base64 bytes)
        else writeBytes stdout bytes
        remaining := remaining - amount
  if options.encoding != .text then writeBytes stdout "\n".toUTF8
  stdout.flush
  pure (.ok source)

def modeName : Mode → String
  | .uniform => "uniform"
  | .normal => "normal"
  | .exponential => "exponential"
  | .poisson => "poisson"
  | .logNormal => "log-normal"
  | .beta => "beta"

def asciiWhitespace (byte : UInt8) : Bool :=
  byte = 9 ∨ byte = 10 ∨ byte = 11 ∨ byte = 12 ∨ byte = 13 ∨ byte = 32

def trimBytes (bytes : ByteArray) : ByteArray :=
  Id.run do
    let mut first := 0
    while first < bytes.size ∧ asciiWhitespace (bytes.data.getD first 0) do
      first := first + 1
    let mut ending := bytes.size
    while first < ending ∧ asciiWhitespace (bytes.data.getD (ending - 1) 0) do
      ending := ending - 1
    pure (bytes.extract first ending)

def splitByteSet (bytes delimiters : ByteArray) (trimItems : Bool) : Array ByteArray := Id.run do
  let mut output := #[]
  let mut start := 0
  for index in [0:bytes.size + 1] do
    let separated := index = bytes.size ∨
      delimiters.data.any fun delimiter => delimiter == bytes.data.getD index 0
    if separated then
      let raw := bytes.extract start index
      let item := if trimItems then trimBytes raw else raw
      if item.size > 0 then output := output.push item
      start := index + 1
  pure output

def stripCarriageReturn (bytes : ByteArray) : ByteArray :=
  if bytes.size > 0 ∧ bytes.data.getD (bytes.size - 1) 0 = 13 then
    bytes.extract 0 (bytes.size - 1)
  else
    bytes

def readAllStdin : IO ByteArray := do
  let input ← IO.getStdin
  let mut chunks : Array ByteArray := #[]
  let mut finished := false
  while !finished do
    let chunk ← input.read (USize.ofNat streamChunk)
    if chunk.size = 0 then finished := true
    else chunks := chunks.push chunk
  pure (ByteArray.mk (chunks.map ByteArray.data).flatten)

def readStateStdin : IO (Except String ByteArray) := do
  let input ← IO.getStdin
  let mut chunks : Array ByteArray := #[]
  let mut size := 0
  let mut finished := false
  while !finished ∧ size ≤ State.maxBytes do
    let remaining := State.maxBytes + 1 - size
    let chunk ← input.read (USize.ofNat (min streamChunk remaining))
    if chunk.size = 0 then finished := true
    else
      chunks := chunks.push chunk
      size := size + chunk.size
  if size > State.maxBytes then
    pure (.error "state JSON exceeds 1048576 bytes")
  else if size = 0 then
    pure (.error "--state expected one JSON object on stdin")
  else
    pure (.ok (ByteArray.mk (chunks.map ByteArray.data).flatten))

def readItems (delimiter : ByteArray) : IO (Array ByteArray) := do
  let input ← readAllStdin
  if delimiter.size = 0 then
    pure (input.data.map fun byte => ByteArray.empty.push byte)
  else
    let content := trimBytes input
    if delimiter == "\n".toUTF8 then
      pure ((splitByteSet content "\n".toUTF8 false).map stripCarriageReturn)
    else
      pure (splitByteSet content delimiter true)

def lastColon (bytes : ByteArray) : Option Nat :=
  (List.range bytes.size).foldl (fun found index =>
    if bytes.data.getD index 0 = 58 then some index else found) none

def weightedItem (bytes : ByteArray) : Except String (ByteArray × Nat) := do
  let separator ← optionToExcept
    "weighted item must be in format 'value:weight'" (lastColon bytes)
  let name := bytes.extract 0 separator
  let weightBytes := bytes.extract (separator + 1) bytes.size
  if name.size = 0 ∨ weightBytes.size = 0 then
    throw "weighted item must be in format 'value:weight'"
  if !weightBytes.data.all fun byte => 48 ≤ byte.toNat ∧ byte.toNat ≤ 57 then
    throw "weighted item must be in format 'value:weight'"
  let weightText ← optionToExcept "weighted item weight must contain ASCII digits"
    (String.fromUTF8? weightBytes)
  let weight ← optionToExcept
    "weighted item weight is out of range (must be a whole number no larger than 2^53)"
    (Decimal.parseInt weightText)
  pure (name, weight.toNat)

def stdinOperation (options : Options) (initialSource : CliSource.Source) :
    IO (Except String CliSource.Source) := do
  let mut items ← readItems options.delimiter
  if items.isEmpty then
    return .error (match options.operation with
      | .choose => "no items to choose from"
      | .shuffle => "no items to shuffle"
      | .weighted => "no items for weighted selection"
      | .generate => "stdin operation was not selected")
  let stdout ← IO.getStdout
  match options.operation with
  | .choose =>
      match ← CliSource.range initialSource 1 (Int.ofNat items.size) with
      | .error message => pure (.error message)
      | .ok (choice, source) =>
          writeBytes stdout items[(choice - 1).toNat]!
          writeBytes stdout "\n".toUTF8
          stdout.flush
          pure (.ok source)
  | .shuffle =>
      let mut source := initialSource
      for offset in [0:items.size - 1] do
        let count := items.size - offset
        match ← CliSource.range source 1 (Int.ofNat count) with
        | .error message => return .error message
        | .ok (choice, next) =>
            source := next
            items := Shuffle.swapChoice items count choice.toNat
      for index in [0:items.size] do
        if index > 0 then writeBytes stdout options.delimiter
        writeBytes stdout items[index]!
      writeBytes stdout "\n".toUTF8
      stdout.flush
      pure (.ok source)
  | .weighted =>
      let mut weighted : Array (ByteArray × Nat) := #[]
      let mut total := 0
      for item in items do
        let .ok parsed := weightedItem item |
          return .error (match weightedItem item with | .error message => message | _ => "weighted item failed")
        if Fixed.clamp.toNat - total < parsed.2 then
          return .error "total weighted-item weight must be no larger than 2^53"
        total := total + parsed.2
        weighted := weighted.push parsed
      if total = 0 then return .error "total weighted-item weight must be positive"
      match ← CliSource.range initialSource 1 (Int.ofNat total) with
      | .error message => pure (.error message)
      | .ok (choice, source) =>
          let mut cumulative := 0
          let mut selected := ByteArray.empty
          for item in weighted do
            cumulative := cumulative + item.2
            if selected.size = 0 ∧ choice.toNat ≤ cumulative then selected := item.1
          writeBytes stdout selected
          writeBytes stdout "\n".toUTF8
          stdout.flush
          pure (.ok source)
  | .generate => pure (.error "stdin operation was not selected")

def pushStringField (fields : Array String) (key value : String) : Array String :=
  fields.push (jsonQuote key ++ ":" ++ jsonQuote value)

def canonicalArgs (options : Options) (bounds : Option (Int × Int × Nat)) :
    Except String String := do
  let delimiter ← match String.fromUTF8? options.delimiter with
    | some delimiter => pure delimiter
    | none => throw "delimiter must be valid UTF-8 when continuation metadata is emitted"
  let mut fields : Array String := #[]
  if options.operation != .generate then
    let operation := match options.operation with
      | .choose => "choose"
      | .shuffle => "shuffle"
      | .weighted => "weighted"
      | .generate => "generate"
    fields := pushStringField fields "op" operation
    fields := pushStringField fields "delim" delimiter
    return "{" ++ String.intercalate "," fields.toList ++ "}"
  let some (start, stop, count) := bounds | throw "generation bounds are absent"
  fields := pushStringField fields "distribution" (modeName options.mode)
  let rangeScaled := (options.mode == .uniform ∨ options.mode == .normal) ∧
    !(options.mode == .normal ∧ (options.mean.isSome ∨ options.stddev.isSome))
  if rangeScaled then fields := pushStringField fields "range" s!"{start}..{stop}"
  fields := pushStringField fields "count" (toString count)
  match options.mode with
  | .normal =>
      if !rangeScaled then
        fields := pushStringField fields "mean" (options.mean.map (·.text) |>.getD "0")
        fields := pushStringField fields "stddev" (options.stddev.map (·.text) |>.getD "1")
  | .exponential =>
      fields := pushStringField fields "rate" (options.rate.map (·.text) |>.getD "1")
  | .poisson =>
      fields := pushStringField fields "lambda"
        ((firstSome options.lambda options.mean).map (·.text) |>.getD "1")
  | .logNormal =>
      fields := pushStringField fields "mean" (options.mean.map (·.text) |>.getD "0")
      fields := pushStringField fields "stddev" (options.stddev.map (·.text) |>.getD "1")
  | .beta =>
      fields := pushStringField fields "alpha" (options.alpha.map (·.text) |>.getD "2")
      fields := pushStringField fields "beta" (options.beta.map (·.text) |>.getD "2")
  | .uniform => pure ()
  if options.mode == .exponential ∨ options.mode == .logNormal ∨ options.mode == .beta then
    fields := pushStringField fields "precision" (toString options.precision)
  if options.binary then fields := fields.push "\"binary\":true"
  let encoding := if options.binary then
      if options.encoding == .base64 then "base64"
      else if options.encoding == .hex then "binary-hex"
      else "raw"
    else if options.encoding == .hex then "hex"
    else "text"
  fields := pushStringField fields "encoding" encoding
  if !options.binary then fields := pushStringField fields "delim" delimiter
  pure ("{" ++ String.intercalate "," fields.toList ++ "}")

def metadata (options : Options) (source : CliSource.Source)
    (bounds : Option (Int × Int × Nat)) (notices : Array String) : Except String (Option String) := do
  let noticeJson := String.intercalate "," (notices.toList.map jsonQuote)
  match CliSource.seed? source, CliSource.position? source with
  | some seed, some position =>
      let args ← canonicalArgs options bounds
      pure (some ("{\"sv\":2,\"rv\":" ++ jsonQuote version ++ ",\"seed\":\"0x" ++ byteHex seed ++
        "\",\"next_pos\":" ++ jsonQuote (toString position) ++
        ",\"args\":" ++ args ++
        ",\"notices\":[" ++ noticeJson ++ "],\"warnings\":[]}\n"))
  | _, _ =>
      if notices.isEmpty then pure none
      else pure (some ("{\"sv\":2,\"rv\":" ++ jsonQuote version ++
        ",\"notices\":[" ++ noticeJson ++ "],\"warnings\":[]}\n"))

def runGeneration (options : Options) : IO (Except String Unit) := do
  let sourceResult ← makeSource options
  let .ok (options, source) := sourceResult |
    return .error (match sourceResult with | .error message => message | _ => "source failed")
  if options.operation != .generate then
    let operationResult ← stdinOperation options source
    let .ok source := operationResult |
      return .error (match operationResult with | .error message => message | _ => "stdin operation failed")
    let stateResult := metadata options source none #[]
    let .ok state := stateResult |
      return .error (match stateResult with | .error message => message | _ => "state formatting failed")
    if let some state := state then
      let stream ← if options.stateStdout then IO.getStdout else IO.getStderr
      writeBytes stream state.toUTF8
    return .ok ()
  let boundsResult := generationBounds options
  let .ok (start, stop, count, showDefault) := boundsResult |
    return .error (match boundsResult with | .error message => message | _ => "bounds failed")
  let result ← if options.binary then emitBinary options source start stop count
    else emitText options source start stop count
  let .ok source := result |
    return .error (match result with | .error message => message | _ => "generation failed")
  let notices := if showDefault then #["with the default range 0..99"] else #[]
  let stateResult := metadata options source (some (start, stop, count)) notices
  let .ok state := stateResult |
    return .error (match stateResult with | .error message => message | _ => "state formatting failed")
  if let some state := state then
    let stream ← if options.stateStdout then IO.getStdout else IO.getStderr
    writeBytes stream state.toUTF8
  pure (.ok ())

def effectiveArguments (arguments : Array ByteArray) : IO (Array ByteArray) := do
  let some invokedAs := ← IO.getEnv "RANDOML_INVOKED_AS" | return arguments
  if invokedAs.isEmpty then return arguments
  pure (arguments.setIfInBounds 0 invokedAs.toUTF8)

def runTests (executable : String) : IO (Except String Unit) := do
  if (← IO.getEnv "RANDOM_TEST_DEPTH") == some "1" then return .ok ()
  let some path := ← IO.getEnv "RANDOM_TEST_FILE" |
    return .error "could not locate test suite (set RANDOM_TEST_FILE)"
  if path.isEmpty then return .error "could not locate test suite (RANDOM_TEST_FILE is empty)"
  let child ← IO.Process.spawn {
    cmd := path
    env := #[
      ("FAST", some "1"),
      ("RANDOM_TEST_DEPTH", some "0"),
      ("RANDOM_TEST_CLI", some executable),
      ("RANDOM_TEST_CLI_KIND", some "lean")
    ]
  }
  let status ← child.wait
  if status = 0 then pure (.ok ())
  else pure (.error s!"test suite failed with status {status}")

def applyRequestedState (options : Options) : IO (Except String Options) := do
  let some request := options.state | return .ok options
  let fromStdin : Bool := match request with | .stdin => true | .inline _ => false
  if fromStdin ∧ options.operation != .generate then
    return .error "--choose, --shuffle, and --weighted require inline --state JSON"
  let inputResult ← match request with
    | .inline json => pure (.ok json.toUTF8)
    | .stdin => readStateStdin
  let .ok input := inputResult |
    return .error (match inputResult with | .error message => message | _ => "could not read state JSON")
  let appliedResult := State.apply options input
  let .ok applied := appliedResult |
    return .error (match appliedResult with | .error message => message | _ => "state could not be applied")
  if fromStdin ∧ applied.operation != .generate then
    return .error "--choose, --shuffle, and --weighted require inline --state JSON"
  pure (CliOptions.validate applied)

def run (arguments : Array ByteArray) : IO (Except String Unit) := do
  let arguments ← effectiveArguments arguments
  let program := arguments[0]?.bind String.fromUTF8? |>.map basename |>.getD "randoml"
  let parseResult := CliOptions.parse arguments
  let .ok parsed := parseResult |
    return .error (match parseResult with | .error message => message | _ => "option parsing failed")
  if let some action := parsed.action then
    match action with
    | .about =>
        printAbout program
        return .ok ()
    | .help => return ← printHelp arguments program
    | .test =>
        let executable := arguments[0]?.bind String.fromUTF8? |>.getD program
        return ← runTests executable
  let stateResult ← applyRequestedState parsed
  let .ok stateOptions := stateResult |
    return .error (match stateResult with | .error message => message | _ => "state failed")
  let environmentResult ← updateEnvironmentSeed stateOptions
  let .ok options := environmentResult |
    return .error (match environmentResult with | .error message => message | _ => "environment failed")
  if options.view then
    return ← printChart arguments
      (chartSpec options.mode options.mean options.stddev options.rate options.lambda
        options.alpha options.beta false) false
  runGeneration options

@[export randoml_cli_run]
def runRaw (arguments : Array ByteArray) : IO UInt32 := do
  try
    match ← run arguments with
    | .ok () => pure 0
    | .error message =>
        writeBytes (← IO.getStderr) (errorJson message).toUTF8
        pure 1
  catch error =>
    writeBytes (← IO.getStderr) (errorJson error.toString).toUTF8
    pure 1

end Randoml.Cli
