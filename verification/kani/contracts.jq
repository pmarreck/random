# The manifest is reviewed independently; result JSON never supplies expectations.
def contracts($m):
	$m.harnesses[] as $h | ($m.templates[$h.template // ""] // {}) as $t |
	($t * $h) | .covers = (($t.covers // $h.covers // []) + ($h.covers_extra // [])) |
	.stubs = (.stubs // []) | .guards = (.guards // []) |
	.unreachable_covers = (.unreachable_covers // []);

def normalized_stubs:
	map({original: (.original | gsub("\\s"; "")), replacement: (.replacement | gsub("\\s"; ""))}) | sort_by(.original, .replacement);
