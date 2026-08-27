import Randoml

/--
Lake's executable target is an explicit build diagnostic, not an installed
frontend: linking the byte-preserving native adapter requires
`lean/build-owned-cli`. The Nix package and project build both invoke that
linker and install its single binary. Keeping this target effect-free also
prevents a UTF-8-only argv path from masquerading as the production CLI.
-/
def main (_arguments : List String) : IO UInt32 := do
  IO.eprintln "{\"sv\":2,\"rv\":\"0.3.0\",\"error\":{\"code\":\"build\",\"message\":\"build the production CLI with lean/build-owned-cli\"},\"notices\":[],\"warnings\":[]}"
  pure 1
