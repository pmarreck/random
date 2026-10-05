-- LuaJIT cannot enter a Lua callback from a JIT-compiled FFI call. Calls
-- that initially skip their callback can evade its automatic blacklist.
-- Isolate only the foreign-call boundary; keep oracle calculations JIT-able.
-- https://luajit.org/ext_ffi_semantics.html#callback
local function invoke(library, symbol, ...)
	return library[symbol](...)
end
jit.off(invoke)
return invoke
