# Frozen requirements. Base predicates are supplied by the pinned compiler.
# These are implementation invariants, not BLAKE3/security/distribution proofs.
import Base
import ./Core.bend as Core

law word_encoding_size:
	for word: U32
	{List.length(&1, U32, Core.word_bytes(word)) == 4n : Nat}

law block_encoding_size:
	for block: Core.Words
	{List.length(&1, U32, Core.words_bytes(block)) == 64n : Nat}

law zero_output:
	for key: Core.CV
	for hi: U32
	for lo: U32
	{Core.xof_at(key, hi, lo, 0n) == Nil{} : List<U32>}

law singleton_branch:
	for state: Core.Stream
	for +value: Core.Wide
	{Core.range_single(True{}, state, value, value) == Done{Core.Sample{state, value}} : Result<&2, &2, Core.Failure, Core.Sample>}
