import Randoml

#check Randoml.Drbg.init
#check Randoml.normal
example : Randoml.maxExactPosition = 9007199254740992 := rfl

def seed42 : ByteArray := Id.run do
  let mut seed := ByteArray.empty
  for _ in [0:31] do
    seed := seed.push 0
  return seed.push 42

-- Execute through the installed modules, without CLI code or project sources.
#eval do
  let some state := Randoml.Drbg.init seed42 | throw (IO.userError "init failed")
  let some (bytes, next) := state.fill 64 | throw (IO.userError "fill failed")
  let hex := bytes.data.foldl (fun (acc : String) (byte : UInt8) =>
    acc ++ String.singleton ("0123456789abcdef".toList[byte.toNat / 16]!) ++
    String.singleton ("0123456789abcdef".toList[byte.toNat % 16]!)) ""
  unless hex == "69dfe2e9b579cf6dfe3d71b11024db6eb49d5b9861505b3ecfc3d379a6dc8f04b6900db333d20760661226da010db589c5080aaf5f6068fc0874ce62aca36f60" do
    throw (IO.userError "frozen byte mismatch")
  unless next.position == 64 do throw (IO.userError "cursor mismatch")
  let some resumed := Randoml.Drbg.restore next.key next.position
    | throw (IO.userError "restore failed")
  unless next.nextU64 == resumed.nextU64 do throw (IO.userError "resumption mismatch")
  let some prepared := Randoml.Geometric.prepare { m := 4611686018427387904, e := -100 }
    | throw (IO.userError "geometric prepare failed")
  let some (gap, next) := Randoml.Geometric.sample state prepared
    | throw (IO.userError "geometric sample failed")
  unless gap == 50065276213116078233391743926 && next.position == 509 do
    throw (IO.userError "geometric wide gap/cursor mismatch")
