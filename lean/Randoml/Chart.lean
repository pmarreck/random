import Randoml.Curve

namespace Randoml.Chart

open Randoml.Fixed

inductive Renderer
  | utf8
  | kitty
  | sixel
deriving BEq, Repr

/-- Semantic chart request. It deliberately contains no terminal or pixel concepts. -/
structure Spec where
  kind : Curve.Kind
  first : Value
  second : Value
  title : String
  parameters : String
  axis : String
deriving BEq, Repr

/-- Canonical normalized chart geometry, independent of an output encoding. -/
structure Model where
  spec : Spec
  curve : Curve.Samples
  discrete : Bool
deriving BEq, Repr

/-- Palette-indexed pixels consumed independently by Kitty and Sixel codecs. -/
structure Raster where
  width : Nat
  height : Nat
  pixels : Array UInt8
deriving BEq, Repr

/-- Binary dot surface consumed by the UTF-8 Braille codec. -/
structure DotGrid where
  width : Nat
  height : Nat
  dots : Array UInt8
deriving BEq, Repr

def viewWidth : Nat := 336
def viewHeight : Nat := 144
def viewLeft : Int := 17
def viewRight : Int := Int.ofNat viewWidth - 10
def viewTop : Int := 7
def viewBottom : Int := Int.ofNat viewHeight - 19
def brailleWidth : Nat := 96
def brailleHeight : Nat := 32

def palette : Array (Array UInt8) := #[
  #[12, 16, 24], #[37, 50, 71], #[28, 93, 103], #[100, 213, 210]
]

def base64Alphabet : ByteArray :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toUTF8

def mapX (index count : Nat) (left right : Int) : Int :=
  let denominator := count - 1
  let numerator := index * (right - left).toNat + denominator / 2
  left + Int.ofNat (numerator / denominator)

def mapY (value : UInt16) (top bottom : Int) : Int :=
  let numerator := value.toNat * (bottom - top).toNat + 65535 / 2
  bottom - Int.ofNat (numerator / 65535)

def setPixel (canvas : Array UInt8) (width height : Nat)
    (x y : Int) (color : UInt8) : Array UInt8 :=
  if 0 ≤ x ∧ 0 ≤ y ∧ x.toNat < width ∧ y.toNat < height then
    canvas.setIfInBounds (y.toNat * width + x.toNat) color
  else
    canvas

private def drawLineLoop : Nat → Array UInt8 → Nat → Nat →
    Int → Int → Int → Int → Int → Int → Int → UInt8 → Array UInt8
  | 0, canvas, _, _, _, _, _, _, _, _, _, _ => canvas
  | fuel + 1, canvas, width, height, x0, y0, x1, y1, dx, dy, error, color =>
      let canvas := setPixel canvas width height x0 y0 color
      if x0 = x1 ∧ y0 = y1 then
        canvas
      else
        let twice := 2 * error
        let stepX := twice ≥ dy
        let stepY := twice ≤ dx
        let nextError := error + (if stepX then dy else 0) + (if stepY then dx else 0)
        let nextX := x0 + (if stepX then (if x0 < x1 then 1 else -1) else 0)
        let nextY := y0 + (if stepY then (if y0 < y1 then 1 else -1) else 0)
        drawLineLoop fuel canvas width height nextX nextY x1 y1 dx dy nextError color

def drawLine (canvas : Array UInt8) (width height : Nat)
    (x0 y0 x1 y1 : Int) (color : UInt8) : Array UInt8 :=
  let dx := Int.ofNat (x1 - x0).natAbs
  let dy := -Int.ofNat (y1 - y0).natAbs
  let fuel := (x1 - x0).natAbs + (y1 - y0).natAbs + 2
  drawLineLoop fuel canvas width height x0 y0 x1 y1 dx dy (dx + dy) color

def model (spec : Spec) (capacity : Nat) : Option Model := do
  let curve ← Curve.sample spec.kind spec.first spec.second capacity
  let discrete := spec.kind == .poisson ∧
    (toIntTrunc curve.xMax - toIntTrunc curve.xMin).toNat < capacity
  pure { spec, curve, discrete }

def rasterize (geometry : Model) : Raster := Id.run do
  let mut canvas := Array.replicate (viewWidth * viewHeight) 0
  for division in [1, 2, 3] do
    let y := viewTop + ((viewBottom - viewTop) * division + 2) / 4
    canvas := drawLine canvas viewWidth viewHeight viewLeft y viewRight y 1
  for division in [1, 2, 3, 4, 5] do
    let x := viewLeft + ((viewRight - viewLeft) * division + 3) / 6
    canvas := drawLine canvas viewWidth viewHeight x viewTop x viewBottom 1
  canvas := drawLine canvas viewWidth viewHeight
    viewLeft viewTop viewLeft viewBottom 3
  canvas := drawLine canvas viewWidth viewHeight
    viewLeft viewBottom viewRight viewBottom 3
  let curve := geometry.curve
  if geometry.discrete then
    for index in [0:curve.heights.size] do
      let value := curve.heights[index]!
      let x := mapX index curve.heights.size viewLeft viewRight
      let y := mapY value viewTop viewBottom
      canvas := drawLine canvas viewWidth viewHeight x (viewBottom - 1) x y 3
      for oy in [-2, -1, 0, 1, 2] do
        for ox in [-2, -1, 0, 1, 2] do
          if ox * ox + oy * oy ≤ 4 then
            canvas := setPixel canvas viewWidth viewHeight (x + ox) (y + oy) 3
  else
    let mut previous : Option (Int × Int) := none
    for index in [0:curve.heights.size] do
      let value := curve.heights[index]!
      let x := mapX index curve.heights.size viewLeft viewRight
      let y := mapY value viewTop viewBottom
      for fillY in [(y + 1).toNat:viewBottom.toNat] do
        canvas := setPixel canvas viewWidth viewHeight x (Int.ofNat fillY) 2
      if let some (px, py) := previous then
        canvas := drawLine canvas viewWidth viewHeight px py x y 3
      previous := some (x, y)
  pure { width := viewWidth, height := viewHeight, pixels := canvas }

def makeRaster (spec : Spec) : Option Raster := do
  let geometry ← model spec (viewRight - viewLeft + 1).toNat
  pure (rasterize geometry)

def layoutDots (geometry : Model) : DotGrid := Id.run do
  let mut dots := Array.replicate (brailleWidth * brailleHeight) 0
  dots := drawLine dots brailleWidth brailleHeight
    0 0 0 (Int.ofNat brailleHeight - 1) 1
  dots := drawLine dots brailleWidth brailleHeight
    0 (Int.ofNat brailleHeight - 1) (Int.ofNat brailleWidth - 1)
    (Int.ofNat brailleHeight - 1) 1
  let curve := geometry.curve
  if geometry.discrete then
    for index in [0:curve.heights.size] do
      let x := mapX index curve.heights.size 0 (Int.ofNat brailleWidth - 1)
      let y := mapY curve.heights[index]! 0 (Int.ofNat brailleHeight - 1)
      dots := drawLine dots brailleWidth brailleHeight
        x (Int.ofNat brailleHeight - 2) x y 1
  else
    let mut previous : Option (Int × Int) := none
    for index in [0:curve.heights.size] do
      let x := mapX index curve.heights.size 0 (Int.ofNat brailleWidth - 1)
      let y := mapY curve.heights[index]! 0 (Int.ofNat brailleHeight - 1)
      if let some (px, py) := previous then
        dots := drawLine dots brailleWidth brailleHeight px py x y 1
      previous := some (x, y)
  pure { width := brailleWidth, height := brailleHeight, dots }

def makeDotGrid (spec : Spec) : Option DotGrid := do
  let geometry ← model spec brailleWidth
  pure (layoutDots geometry)

def encodeBraille (grid : DotGrid) : ByteArray := Id.run do
  let masks : Array (Array Nat) := #[#[1, 2, 4, 64], #[8, 16, 32, 128]]
  let mut output := ""
  for cellY in [0:grid.height / 4] do
    for cellX in [0:grid.width / 2] do
      let mut mask := 0
      for dx in [0:2] do
        for dy in [0:4] do
          let x := cellX * 2 + dx
          let y := cellY * 4 + dy
          if grid.dots.getD (y * grid.width + x) 0 != 0 then
            mask := mask + (masks[dx]!).getD dy 0
      output := output.push (Char.ofNat (0x2800 + mask))
    output := output.push '\n'
  pure output.toUTF8

def renderBraille (spec : Spec) : Option ByteArray := do
  pure (encodeBraille (← makeDotGrid spec))

def base64 (bytes : ByteArray) : ByteArray := Id.run do
  let mut output := ByteArray.empty
  let mut offset := 0
  while offset < bytes.size do
    let remaining := bytes.size - offset
    let a := (bytes.data.getD offset 0).toNat
    let b := (bytes.data.getD (offset + 1) 0).toNat
    let c := (bytes.data.getD (offset + 2) 0).toNat
    let value := a * 65536 + b * 256 + c
    output := output.push (base64Alphabet.data.getD ((value / 262144) % 64) 0)
    output := output.push (base64Alphabet.data.getD ((value / 4096) % 64) 0)
    output := output.push (if remaining > 1 then
      base64Alphabet.data.getD ((value / 64) % 64) 0 else 61)
    output := output.push (if remaining > 2 then
      base64Alphabet.data.getD (value % 64) 0 else 61)
    offset := offset + 3
  pure output

def rawRgb (raster : Raster) : ByteArray := Id.run do
  let mut output := ByteArray.empty
  for pixel in raster.pixels do
    for component in palette.getD pixel.toNat #[] do
      output := output.push component
  pure output

def kittySequence (control payload : ByteArray) (tmux : Bool) : ByteArray :=
  let opening := if tmux then "\u001bPtmux;\u001b\u001b_G" else "\u001b_G"
  let closing := if tmux then "\u001b\u001b\\\u001b\\" else "\u001b\\"
  opening.toUTF8 ++ control ++ ";".toUTF8 ++ payload ++ closing.toUTF8

def encodeKittyPayload (raster : Raster) (encoded : ByteArray) (tmux : Bool) : ByteArray := Id.run do
  let mut output := ByteArray.empty
  let mut offset := 0
  while offset < encoded.size do
    let ending := min (offset + 4096) encoded.size
    let finalChunk := ending == encoded.size
    let control := if offset == 0 then
      s!"a=T,f=24,s={raster.width},v={raster.height},c=56,r=12,C=1,q=2,m={if finalChunk then 0 else 1}"
    else
      s!"m={if finalChunk then 0 else 1}"
    output := output ++ kittySequence control.toUTF8 (encoded.extract offset ending) tmux
    offset := ending
  for _ in [0:12] do
    output := output ++ "\r\n".toUTF8
  pure output

def encodeKitty (raster : Raster) (tmux : Bool) : ByteArray :=
  encodeKittyPayload raster (base64 (rawRgb raster)) tmux

private def sixelRun (mask count : Nat) : ByteArray :=
  let pixel := Char.ofNat (63 + mask)
  if count ≥ 4 then
    s!"!{count}{pixel}".toUTF8
  else
    (String.ofList (List.replicate count pixel)).toUTF8

def encodeSixel (raster : Raster) : ByteArray := Id.run do
  let mut output := ByteArray.empty.push 27 |>.push 55 |>.push 27 |>.push 80
  output := output ++ s!"0;1;0q\"1;1;{raster.width};{raster.height}".toUTF8
  for color in [0:palette.size] do
    let rgb := palette[color]!
    let red := (rgb.getD 0 0).toNat * 100 + 127
    let green := (rgb.getD 1 0).toNat * 100 + 127
    let blue := (rgb.getD 2 0).toNat * 100 + 127
    output := output ++ s!"#{color};2;{red / 255};{green / 255};{blue / 255}".toUTF8
  for bandY in [0:raster.height / 6] do
    for color in [0:4] do
      output := output ++ s!"#{color}".toUTF8
      let mut previous := 0
      let mut run := 0
      for x in [0:raster.width] do
        let mut mask := 0
        for bit in [0:6] do
          let y := bandY * 6 + bit
          if y < raster.height ∧
              raster.pixels.getD (y * raster.width + x) 0 == UInt8.ofNat color then
            mask := mask + 2 ^ bit
        if run == 0 then
          previous := mask
          run := 1
        else if mask == previous then
          run := run + 1
        else
          output := output ++ sixelRun previous run
          previous := mask
          run := 1
      output := output ++ sixelRun previous run
      if color < 3 then
        output := output.push 36
      else if (bandY + 1) * 6 < raster.height then
        output := output.push 45
  output := output.push 27 |>.push 92 |>.push 27 |>.push 56
  for _ in [0:12] do
    output := output ++ "\r\n".toUTF8
  pure output

def render (spec : Spec) (renderer : Renderer) (tmux : Bool := false) : Option ByteArray :=
  match renderer with
  | .utf8 => renderBraille spec
  | .kitty => return encodeKitty (← makeRaster spec) tmux
  | .sixel => return encodeSixel (← makeRaster spec)

def anonymousSpec (kind : Curve.Kind) (first second : Value) : Spec :=
  { kind, first, second, title := "", parameters := "", axis := "" }

end Randoml.Chart
