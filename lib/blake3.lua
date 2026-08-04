--[[
Vendored BLAKE3 for LuaJIT by Egor Skriptunoff.

Source:
  https://gist.github.com/Egor-Skriptunoff/50683d024cf6acdb89100564dc819b05
  commit 23765397477e84ab1dc51a964fca186f4bf8d65d (2022-03-15)

Provenance and licensing:
  Direct source comparison and repository chronology show this LuaJIT-specific
  implementation derives from the same author's earlier BLAKE3 implementation
  in pure_lua_SHA:
  https://github.com/Egor-Skriptunoff/pure_lua_SHA
  BLAKE3 added in commit 9d8317da28436e2d645c0ac2106c8a3a55378f5f
  (2022-01-10), before the gist was created on 2022-03-05.

  pure_lua_SHA carries the MIT grant reproduced below. The gist itself carries
  no visible license. Reuse here is a documented best-effort inference from
  authorship, chronology, and direct derivation while clarification from the
  author is unavailable. This notice does not represent the gist as containing
  an explicit license of its own.

MIT License

Copyright (c) 2018-2022 Egor Skriptunoff

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

--------------------------------------------------------------------------------------------------------------------------
-- BLAKE3 for LuaJIT
--------------------------------------------------------------------------------------------------------------------------
--    Compatible with:
--       LuaJIT 2.x (FFI must be enabled, both little-endian and big-endian systems are supported)
--    This module contains functions:
--       blake3 (message, key, digest_size_in_bytes)
--       blake3_derive_key (key_material, context_string, derived_key_size_in_bytes)
--       hex_to_bin (hex_string)
--       bin_to_hex (binary_string)
--    Usage examples:
--       See "Tutorial" section in the file "blake3_for_luajit.test.lua"
-----------------------------------------------------------------------------

local table_concat, byte, char, rep, sub, gsub, format, floor, ceil, math_min, tonumber, type, math_huge =
   table.concat, string.byte, string.char, string.rep, string.sub, string.gsub, string.format, math.floor, math.ceil, math.min, tonumber, type, math.huge

local ffi = require("ffi")

local AND   = bit.band
local OR    = bit.bor
local XOR   = bit.bxor
local SHL   = bit.lshift
local SHR   = bit.rshift
local ROL   = bit.rol
local ROR   = bit.ror
local NOT   = bit.bnot
local NORM  = bit.tobit
local HEX   = bit.tohex
local BSWAP = bit.bswap

local sha2_H = {
   NORM(0x6a09e667),
   NORM(0xbb67ae85),
   NORM(0x3c6ef372),
   NORM(0xa54ff53a),
   NORM(0x510e527f),
   NORM(0x9b05688c),
   NORM(0x1f83d9ab),
   NORM(0x5be0cd19),
}
local perm_blake3 = ffi.new("uint8_t[?]", 28,
   0, 2, 3, 10, 12, 9, 11, 5,
   0, 2, 3, 10, 12, 9,
   1, 6, 4, 7, 13, 14, 15, 8,
   1, 6, 4, 7, 13, 14
)
local W = ffi.new("int32_t[?]", 16)
local v = ffi.new("int32_t[?]", 16)

local function G(a, b, c, d, k1, k2)
   local va, vb, vc, vd = v[a], v[b], v[c], v[d]
   va = NORM(W[k1] + (va + vb))
   vd = ROR(XOR(vd, va), 16)
   vc = NORM(vc + vd)
   vb = ROR(XOR(vb, vc), 12)
   va = NORM(W[k2] + (va + vb))
   vd = ROR(XOR(vd, va), 8)
   vc = NORM(vc + vd)
   vb = ROR(XOR(vb, vc), 7)
   v[a], v[b], v[c], v[d] = va, vb, vc, vd
end

local function blake3_feed_64(str, offs, size, flags, chunk_index, H_in, H_out, wide_output, block_length)
   -- offs >= 0, size >= 0, size is multiple of 64
   block_length = block_length or 64
   local h1, h2, h3, h4, h5, h6, h7, h8 = H_in[1], H_in[2], H_in[3], H_in[4], H_in[5], H_in[6], H_in[7], H_in[8]
   H_out = H_out or H_in
   for pos = offs, offs + size - 1, 64 do
      if str then
         for j = 0, 15 do
            pos = pos + 4
            local a, b, c, d = byte(str, pos-3, pos)
            W[j] = OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a)
         end
      end
      v[0x0], v[0x1], v[0x2], v[0x3], v[0x4], v[0x5], v[0x6], v[0x7] = h1, h2, h3, h4, h5, h6, h7, h8
      v[0x8], v[0x9], v[0xA], v[0xB] = sha2_H[1], sha2_H[2], sha2_H[3], sha2_H[4]
      v[0xC] = NORM(chunk_index % 2^32)   -- t0 = low_4_bytes(chunk_index)
      v[0xD] = floor(chunk_index / 2^32)  -- t1 = high_4_bytes(chunk_index)
      v[0xE], v[0xF] = block_length, flags
      for j = 0, 6 do
         G(0, 4,  8, 12, perm_blake3[j],      perm_blake3[j + 14])
         G(1, 5,  9, 13, perm_blake3[j + 1],  perm_blake3[j + 2])
         G(2, 6, 10, 14, perm_blake3[j + 16], perm_blake3[j + 7])
         G(3, 7, 11, 15, perm_blake3[j + 15], perm_blake3[j + 17])
         G(0, 5, 10, 15, perm_blake3[j + 21], perm_blake3[j + 5])
         G(1, 6, 11, 12, perm_blake3[j + 3],  perm_blake3[j + 6])
         G(2, 7,  8, 13, perm_blake3[j + 4],  perm_blake3[j + 18])
         G(3, 4,  9, 14, perm_blake3[j + 19], perm_blake3[j + 20])
      end
      if wide_output then
         H_out[ 9] = XOR(h1, v[0x8])
         H_out[10] = XOR(h2, v[0x9])
         H_out[11] = XOR(h3, v[0xA])
         H_out[12] = XOR(h4, v[0xB])
         H_out[13] = XOR(h5, v[0xC])
         H_out[14] = XOR(h6, v[0xD])
         H_out[15] = XOR(h7, v[0xE])
         H_out[16] = XOR(h8, v[0xF])
      end
      h1 = XOR(v[0x0], v[0x8])
      h2 = XOR(v[0x1], v[0x9])
      h3 = XOR(v[0x2], v[0xA])
      h4 = XOR(v[0x3], v[0xB])
      h5 = XOR(v[0x4], v[0xC])
      h6 = XOR(v[0x5], v[0xD])
      h7 = XOR(v[0x6], v[0xE])
      h8 = XOR(v[0x7], v[0xF])
   end
   H_out[1], H_out[2], H_out[3], H_out[4], H_out[5], H_out[6], H_out[7], H_out[8] = h1, h2, h3, h4, h5, h6, h7, h8
end

local function blake3(message, key, digest_size_in_bytes, message_flags, K, return_array)
   -- message:  binary string to be hashed (or nil for "chunk-by-chunk" input mode)
   -- key:      (optional) binary string up to 32 bytes, by default empty string
   -- digest_size_in_bytes: (optional) by default 32
   --    0,1,2,3,4,...  = get finite digest as single Lua string
   --    (-1)           = get infinite digest in "chunk-by-chunk" output mode
   --    -2,-3,-4,...   = get finite digest in "chunk-by-chunk" output mode
   -- The last three parameters "message_flags", "K" and "return_array" are for internal use only, user must omit them (or pass nil)
   key = key or ""
   digest_size_in_bytes = digest_size_in_bytes or 32
   message_flags = message_flags or 0
   if key == "" then
      K = K or sha2_H
   else
      local key_length = #key
      if key_length > 32 then
         error("BLAKE3 key length must not exceed 32 bytes", 2)
      end
      key = key..rep("\0", 32 - key_length)
      K = {}
      for j = 1, 8 do
         local a, b, c, d = byte(key, 4*j-3, 4*j)
         K[j] = OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a)
      end
      message_flags = message_flags + 16  -- flag:KEYED_HASH
   end
   local tail, H, chunk_index, blocks_in_chunk, stack_size, stack = "", {}, 0, 0, 0, {}
   local final_H_in, final_block_length, chunk_by_chunk_output, result, wide_output = K
   local final_compression_flags = 3      -- flags:CHUNK_START,CHUNK_END

   local function feed_blocks(str, offs, size)
      -- size >= 0, size is multiple of 64
      while size > 0 do
         local part_size_in_blocks, block_flags, H_in = 1, 0, H
         if blocks_in_chunk == 0 then
            block_flags = 1               -- flag:CHUNK_START
            H_in, final_H_in = K, H
            final_compression_flags = 2   -- flag:CHUNK_END
         elseif blocks_in_chunk == 15 then
            block_flags = 2               -- flag:CHUNK_END
            final_compression_flags = 3   -- flags:CHUNK_START,CHUNK_END
            final_H_in = K
         else
            part_size_in_blocks = math_min(size / 64, 15 - blocks_in_chunk)
         end
         local part_size = part_size_in_blocks * 64
         blake3_feed_64(str, offs, part_size, message_flags + block_flags, chunk_index, H_in, H)
         offs, size = offs + part_size, size - part_size
         blocks_in_chunk = (blocks_in_chunk + part_size_in_blocks) % 16
         if blocks_in_chunk == 0 then
            -- completing the currect chunk
            chunk_index = chunk_index + 1
            local divider = 2
            while chunk_index % divider == 0 do
               divider = divider * 2
               stack_size = stack_size - 8
               for j = 0, 7 do
                  W[j] = stack[stack_size + j + 1]
               end
               for j = 0, 7 do
                  W[j + 8] = H[j + 1]
               end
               blake3_feed_64(nil, 0, 64, message_flags + 4, 0, K, H)  -- flag:PARENT
            end
            for j = 1, 8 do
               stack[stack_size + j] = H[j]
            end
            stack_size = stack_size + 8
         end
      end
   end

   local function get_hash_block(block_no)
      local size = math_min(64, digest_size_in_bytes - block_no * 64)
      if block_no < 0 or size <= 0 then
         return ""
      end
      if chunk_by_chunk_output then
         for j = 0, 15 do
            W[j] = stack[j + 17]
         end
      end
      blake3_feed_64(nil, 0, 64, final_compression_flags, block_no, final_H_in, stack, wide_output, final_block_length)
      if return_array then
         return stack
      end
      local max_reg = ceil(size / 4)
      for j = 1, max_reg do
         stack[j] = HEX(BSWAP(stack[j]))
      end
      return sub(table_concat(stack, "", 1, max_reg), 1, size * 2)
   end

   local function partial(message_part)
      if message_part then
         if tail then
            local offs = 0
            if tail ~= "" and #tail + #message_part > 64 then
               offs = 64 - #tail
               feed_blocks(tail..sub(message_part, 1, offs), 0, 64)
               tail = ""
            end
            local size = #message_part - offs
            local size_tail = size > 0 and (size - 1) % 64 + 1 or 0
            feed_blocks(message_part, offs, size - size_tail)
            tail = tail..sub(message_part, #message_part + 1 - size_tail)
            return partial
         else
            error("Adding more chunks is not allowed after receiving the result", 2)
         end
      else
         if tail then
            final_block_length = #tail
            tail = tail..rep("\0", 64 - #tail)
            for j = 0, 15 do
               local a, b, c, d = byte(tail, 4*j+1, 4*j+4)
               W[j] = OR(SHL(d, 24), SHL(c, 16), SHL(b, 8), a)
            end
            tail = nil
            for stack_size = stack_size - 8, 0, -8 do
               blake3_feed_64(nil, 0, 64, message_flags + final_compression_flags, chunk_index, final_H_in, H, nil, final_block_length)
               chunk_index, final_block_length, final_H_in, final_compression_flags = 0, 64, K, 4  -- flag:PARENT
               for j = 0, 7 do
                  W[j] = stack[stack_size + j + 1]
               end
               for j = 0, 7 do
                  W[j + 8] = H[j + 1]
               end
            end
            final_compression_flags = message_flags + final_compression_flags + 8  -- flag:ROOT
            if digest_size_in_bytes < 0 then
               if digest_size_in_bytes == -1 then  -- infinite digest
                  digest_size_in_bytes = math_huge
               else
                  digest_size_in_bytes = -digest_size_in_bytes
               end
               chunk_by_chunk_output = true
               for j = 0, 15 do
                  stack[j + 17] = W[j]
               end
            end
            digest_size_in_bytes = math_min(2^53, digest_size_in_bytes)
            wide_output = digest_size_in_bytes > 32
            if chunk_by_chunk_output then
               local pos, cached_block_no, cached_block = 0

               local function get_next_part_of_digest(arg1, arg2)
                  if arg1 == "seek" then
                     -- Usage #1:  get_next_part_of_digest("seek", new_pos)
                     pos = arg2
                  else
                     -- Usage #2:  hex_string = get_next_part_of_digest(size)
                     local size, index = arg1 or 1, 32
                     while size > 0 do
                        local block_offset = pos % 64
                        local block_no = floor(pos / 64)
                        local part_size = math_min(size, 64 - block_offset)
                        if cached_block_no ~= block_no then
                           cached_block_no = block_no
                           cached_block = get_hash_block(block_no)
                        end
                        index = index + 1
                        stack[index] = sub(cached_block, block_offset * 2 + 1, (block_offset + part_size) * 2)
                        size = size - part_size
                        pos = pos + part_size
                     end
                     return table_concat(stack, "", 33, index)
                  end
               end

               result = get_next_part_of_digest
            elseif digest_size_in_bytes <= 64 then
               result = get_hash_block(0)
            else
               local last_block_no = ceil(digest_size_in_bytes / 64) - 1
               for block_no = 0, last_block_no do
                  stack[33 + block_no] = get_hash_block(block_no)
               end
               result = table_concat(stack, "", 33, 33 + last_block_no)
            end
         end
         return result
      end
   end

   if message then
      -- Actually perform calculations and return the BLAKE3 digest of a message
      return partial(message)()
   else
      -- Return function for chunk-by-chunk loading
      -- User should feed every chunk of input data as single argument to this function and finally get BLAKE3 digest by invoking this function without an argument
      return partial
   end
end

local function blake3_derive_key(key_material, context_string, derived_key_size_in_bytes)
   -- key_material: (string) your source of entropy to derive a key from (for example, it can be a master password)
   --               set to nil for feeding the key material in "chunk-by-chunk" input mode
   -- context_string: (string) unique description of the derived key
   -- digest_size_in_bytes: (optional) by default 32
   --    0,1,2,3,4,...  = get finite derived key as single Lua string
   --    (-1)           = get infinite derived key in "chunk-by-chunk" output mode
   --    -2,-3,-4,...   = get finite derived key in "chunk-by-chunk" output mode
   if type(context_string) ~= "string" then
      error("'context_string' parameter must be a Lua string", 2)
   end
   local K = blake3(context_string, nil, nil, 32, nil, true)           -- flag:DERIVE_KEY_CONTEXT
   return blake3(key_material, nil, derived_key_size_in_bytes, 64, K)  -- flag:DERIVE_KEY_MATERIAL
end

local function hex_to_bin(hex_string)
   return (gsub(hex_string, "%x%x",
      function (hh)
         return char(tonumber(hh, 16))
      end
   ))
end

local function bin_to_hex(binary_string)
   return (gsub(binary_string, ".",
      function (c)
         return format("%02x", byte(c))
      end
   ))
end


return {
   -- BLAKE3 hash function
   blake3            = blake3,             -- BLAKE3
   blake3_derive_key = blake3_derive_key,  -- BLAKE3_KDF
   -- misc utilities
   hex_to_bin = hex_to_bin,  -- converts hexadecimal representation to binary string
   bin_to_hex = bin_to_hex,  -- converts binary string to hexadecimal representation
}
