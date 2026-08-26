namespace Randoml.Blake3

/-!
This is deliberately the single-block BLAKE3 subset used by random's DRBG,
not a general-purpose BLAKE3 API. The project context and canonical seed
material are each shorter than one 64-byte block; the XOF hashes the empty
message. General multi-block hashing and tree reduction are outside this
model's claim boundary.
-/

abbrev Words := Array UInt32

def iv : Words := #[
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
]

def msgPermutation : Array Nat :=
  #[2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

def chunkStart : UInt32 := 1
def chunkEnd : UInt32 := 2
def root : UInt32 := 8
def keyedHash : UInt32 := 16
def deriveKeyContext : UInt32 := 32
def deriveKeyMaterial : UInt32 := 64

@[inline] def rotr (value : UInt32) (count : Nat) : UInt32 :=
  (value >>> UInt32.ofNat count) ||| (value <<< UInt32.ofNat (32 - count))

def mix (state : Words) (a b c d : Nat) (mx my : UInt32) : Words :=
  let state := state.set! a (state[a]! + state[b]! + mx)
  let state := state.set! d (rotr (state[d]! ^^^ state[a]!) 16)
  let state := state.set! c (state[c]! + state[d]!)
  let state := state.set! b (rotr (state[b]! ^^^ state[c]!) 12)
  let state := state.set! a (state[a]! + state[b]! + my)
  let state := state.set! d (rotr (state[d]! ^^^ state[a]!) 8)
  let state := state.set! c (state[c]! + state[d]!)
  state.set! b (rotr (state[b]! ^^^ state[c]!) 7)

def round (state message : Words) : Words :=
  let state := mix state 0 4 8 12 message[0]! message[1]!
  let state := mix state 1 5 9 13 message[2]! message[3]!
  let state := mix state 2 6 10 14 message[4]! message[5]!
  let state := mix state 3 7 11 15 message[6]! message[7]!
  let state := mix state 0 5 10 15 message[8]! message[9]!
  let state := mix state 1 6 11 12 message[10]! message[11]!
  let state := mix state 2 7 8 13 message[12]! message[13]!
  mix state 3 4 9 14 message[14]! message[15]!

def permute (message : Words) : Words :=
  msgPermutation.map fun index => message[index]!

def compress (cv block : Words) (counter : UInt64) (blockLength flags : UInt32) : Words :=
  let initial := cv ++ iv.extract 0 4 ++ #[
    UInt32.ofNat counter.toNat,
    UInt32.ofNat (counter >>> 32).toNat,
    blockLength,
    flags
  ]
  let result := (List.range 7).foldl (fun (pair : Words × Words) _ =>
    (round pair.1 pair.2, permute pair.2)) (initial, block)
  let state := result.1
  (List.range 8).foldl (fun output index =>
    let output := output.set! index (state[index]! ^^^ state[index + 8]!)
    output.set! (index + 8) (state[index + 8]! ^^^ cv[index]!)) state

def wordAt (bytes : ByteArray) (offset : Nat) : UInt32 :=
  (bytes.get! offset).toUInt32 |||
    ((bytes.get! (offset + 1)).toUInt32 <<< 8) |||
    ((bytes.get! (offset + 2)).toUInt32 <<< 16) |||
    ((bytes.get! (offset + 3)).toUInt32 <<< 24)

def blockWords (bytes : ByteArray) : Words :=
  let padded := (List.range (64 - bytes.size)).foldl (fun out _ => out.push 0) bytes
  (List.range 16).foldl (fun words index => words.push (wordAt padded (index * 4))) #[]

def wordsToBytes (words : Words) : ByteArray :=
  words.foldl (fun bytes (word : UInt32) =>
    bytes.push word.toUInt8
      |>.push (word >>> 8).toUInt8
      |>.push (word >>> 16).toUInt8
      |>.push (word >>> 24).toUInt8) ByteArray.empty

structure Output where
  cv : Words
  block : Words
  counter : UInt64
  blockLength : UInt32
  flags : UInt32

def Output.rootBlock (output : Output) (outputCounter : UInt64) : ByteArray :=
  wordsToBytes (compress output.cv output.block outputCounter output.blockLength
    (output.flags ||| root))

def singleBlockOutput (bytes : ByteArray) (key : Words) (flags : UInt32) : Output :=
  {
    cv := key
    block := blockWords bytes
    counter := 0
    blockLength := UInt32.ofNat bytes.size
    flags := flags ||| chunkStart ||| chunkEnd
  }

def hash32 (bytes : ByteArray) (key : Words := iv) (flags : UInt32 := 0) : ByteArray :=
  (singleBlockOutput bytes key flags).rootBlock 0 |>.extract 0 32

def keyWords (bytes : ByteArray) : Words :=
  (List.range 8).foldl (fun words index => words.push (wordAt bytes (index * 4))) #[]

def deriveKey (context : String) (material : ByteArray) : ByteArray :=
  let contextKey := hash32 context.toUTF8 iv deriveKeyContext
  hash32 material (keyWords contextKey) deriveKeyMaterial

def keyedEmptyOutput (key : ByteArray) : Output :=
  singleBlockOutput ByteArray.empty (keyWords key) keyedHash

def xofAt (key : ByteArray) (position count : Nat) : ByteArray :=
  let firstBlock := position / 64
  let offset := position % 64
  let blockCount := (offset + count + 63) / 64
  let bytes := (List.range blockCount).foldl (fun out index =>
    out ++ (keyedEmptyOutput key).rootBlock (UInt64.ofNat (firstBlock + index))) ByteArray.empty
  bytes.extract offset (offset + count)

end Randoml.Blake3
