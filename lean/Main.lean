import Randoml

private def backendPath : IO String := do
  if let some configured ← IO.getEnv "RANDOML_BACKEND" then
    pure configured
  else
    let application ← IO.appPath
    if let some directory := application.parent then
      let sibling := directory / "randomz"
      if ← sibling.pathExists then pure sibling.toString else pure "randomz"
    else pure "randomz"

private def invocationFlags : IO (Array String) := do
  let selected ← IO.getEnv "RANDOML_INVOKED_AS"
  let application ← IO.appPath
  let name := selected.getD (application.fileName.getD "randoml")
  if name.startsWith "drandoml" then pure #["--deterministic"]
  else if name.startsWith "nrandoml" then pure #["--normalized"]
  else pure #[]

/--
The compatibility frontend currently delegates parsing, entropy I/O, fixed-point
distribution arithmetic, formatting, and terminal charts to the Zig-backed C
frontend. The separately importable `Randoml` library contains the independent
pure Lean BLAKE3 DRBG model and the proved state invariants. This boundary is
deliberate and is audited in the Lean evaluation report; it is not represented
as though Lean had proved the foreign implementation.
-/
def main (arguments : List String) : IO UInt32 := do
  if arguments.any (fun argument => argument.contains '�') then
    IO.eprintln "{\"sv\":2,\"rv\":\"0.3.0\",\"error\":{\"code\":\"usage\",\"message\":\"argument is not valid UTF-8\"},\"notices\":[],\"warnings\":[]}"
    return 1
  let backend ← backendPath
  let flags ← invocationFlags
  let seed ← IO.getEnv "DRANDOML_SEED"
  let spawn : IO.Process.SpawnArgs := {
    cmd := backend
    args := flags ++ arguments.toArray
    env := #[("DRANDOMZ_SEED", seed)]
  }
  if arguments.any (fun argument =>
      argument = "--help" || argument = "-h" || argument = "--about" || argument = "-a") then
    let output ← IO.Process.output spawn
    let adapt := fun text => text.replace "DRANDOMZ_SEED" "DRANDOML_SEED"
      |>.replace "randomz" "randoml"
    IO.print (adapt output.stdout)
    IO.eprint (adapt output.stderr)
    pure output.exitCode
  else
    let child ← IO.Process.spawn spawn
    child.wait
