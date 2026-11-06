-- UTF-8 for LuaJIT, read and written a machine word at a time.
--
-- The hot paths keep the string in hand as a byte pointer, skip ASCII eight bytes at a time, and
-- decode a multi-byte character without taking a substring: no allocation, no per-byte Lua string
-- indexing. On Windows the UTF-16 writer and reader hand long strings to the kernel32 codec, which
-- is SIMD tuned; validation and decoding stay portable so every platform gives the same answer.
local bit = require("bit")
local ffi = require("ffi")

local band = bit.band
local bor = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local floor = math.floor
local unpack = unpack
local min = math.min

local ByteArray = ffi.typeof("uint8_t[?]")
local bytePointer = ffi.typeof("const uint8_t*")
local wordPointer = ffi.typeof("const uint64_t*")
local addressOf = ffi.typeof("uintptr_t")
local widePointer = ffi.typeof("const uint16_t*")

local ASCII_MASK = 0x8080808080808080ULL
local REPLACEMENT = 0xFFFD

-- A Windows codec call is only worth its FFI crossing on a string that can pay for it. Below this
-- the portable loop wins.
local NATIVE_THRESHOLD = 256

---@class utf8.raw
---@field toWide fun(text: string): ffi.cdata*?, number
---@field fromWide fun(wide: ffi.cdata*, count: number?): string?

---@type utf8.raw?
local backend
if jit.os == "Windows" then
	backend = require("utf8.raw.windows")
end

-- The last string examined keeps its pointer and length, so a caller that walks one string one
-- character at a time does not cast and measure it again on every call.
local lastText
local lastPointer
local lastLength

---@param text string
---@return ffi.cdata* pointer
---@return number length
local function textInfo(text)
	if rawequal(text, lastText) then
		return lastPointer, lastLength
	end

	local pointer = ffi.cast(bytePointer, text)
	local length = #text
	lastText, lastPointer, lastLength = text, pointer, length
	return pointer, length
end

-- Output buffers are reused across calls. Each call copies its result into a Lua string before it
-- returns, so a later call can take the buffer back without changing an earlier result.
local outputBuffer = ByteArray(256)
local outputCapacity = 256

---@param size number
---@return ffi.cdata* buffer
local function ensureOutput(size)
	if size > outputCapacity then
		local capacity = outputCapacity
		while capacity < size do
			capacity = capacity * 2
		end
		outputBuffer, outputCapacity = ByteArray(capacity), capacity
	end
	return outputBuffer
end

--- The index of the first byte with the high bit set, or `limit`.
---
--- Eight bytes at a time once the address is aligned; the head and the tail are read byte by byte,
--- so no read crosses the end of the string. Called once per range: a mixed string falls back to
--- the scalar loop at the first non-ASCII byte, which is faster than setting a word scan up again
--- after every accent.
---@param pointer ffi.cdata* # const uint8_t*
---@param index number # where to start, from zero
---@param limit number # one past the last byte
local function asciiEnd(pointer, index, limit)
	while index < limit do
		if band(ffi.cast(addressOf, pointer + index), 7) == 0 then
			break
		end
		if pointer[index] >= 0x80 then
			return index
		end
		index = index + 1
	end

	local last = limit - 8
	local words = ffi.cast(wordPointer, pointer + index)
	while index <= last do
		if band(words[0], ASCII_MASK) ~= 0 then
			break
		end
		index = index + 8
		words = words + 1
	end

	while index < limit do
		if pointer[index] >= 0x80 then
			break
		end
		index = index + 1
	end

	return index
end

--- One character at or after `at`, which must not be ASCII.
---
--- A malformed byte sequence returns `nil` and moves one byte, so a caller that wants a
--- replacement character consumes no more than the single byte that is wrong.
---@param pointer ffi.cdata* # const uint8_t*
---@param at number # from zero
---@param limit number # one past the last byte
---@return number? codepoint
---@return number nextAt
local function decodeMultibyte(pointer, at, limit)
	local first = pointer[at]

	if first < 0xC2 then
		return nil, at + 1
	end

	if first < 0xE0 then
		if at + 1 >= limit then
			return nil, at + 1
		end

		local second = pointer[at + 1]
		if second < 0x80 or second > 0xBF then
			return nil, at + 1
		end

		return bor(lshift(band(first, 0x1F), 6), band(second, 0x3F)), at + 2
	end

	if first < 0xF0 then
		if at + 2 >= limit then
			return nil, at + 1
		end

		local second = pointer[at + 1]
		local third = pointer[at + 2]
		if second < 0x80 or second > 0xBF or third < 0x80 or third > 0xBF then
			return nil, at + 1
		end

		-- E0 80..9F is an overlong form of a two-byte character; ED A0..BF is a surrogate, which
		-- UTF-8 does not encode.
		if (first == 0xE0 and second < 0xA0) or (first == 0xED and second > 0x9F) then
			return nil, at + 1
		end

		return bor(
			lshift(band(first, 0x0F), 12),
			lshift(band(second, 0x3F), 6),
			band(third, 0x3F)
		), at + 3
	end

	if first > 0xF4 then
		return nil, at + 1
	end

	if at + 3 >= limit then
		return nil, at + 1
	end

	local second = pointer[at + 1]
	local third = pointer[at + 2]
	local fourth = pointer[at + 3]
	if second < 0x80 or second > 0xBF
		or third < 0x80 or third > 0xBF
		or fourth < 0x80 or fourth > 0xBF then
		return nil, at + 1
	end

	-- F0 80..8F is an overlong form of a three-byte character; F4 90..BF lies beyond U+10FFFF.
	if (first == 0xF0 and second < 0x90) or (first == 0xF4 and second > 0x8F) then
		return nil, at + 1
	end

	return bor(
		lshift(band(first, 0x07), 18),
		lshift(band(second, 0x3F), 12),
		lshift(band(third, 0x3F), 6),
		band(fourth, 0x3F)
	), at + 4
end

--- Normalises the byte range a standard `utf8.len`/`utf8.codepoint` call names.
---@param length number
---@param i number?
---@param j number?
---@return number first # one-based, inclusive
---@return number last # one-based, inclusive; zero when empty
local function normaliseRange(length, i, j)
	i = i or 1
	j = j or length

	if i < 0 then
		i = length + i + 1
	end
	if j < 0 then
		j = length + j + 1
	end

	if i < 1 or i > length + 1 then
		error("initial position out of bounds", 3)
	end
	if j > length then
		error("final position out of bounds", 3)
	end

	if j < 1 then
		return 1, 0
	end

	return i, j
end

local utf8 = {}

--- One character of a string, and where the one after it starts.
---
--- Malformed input decodes to U+FFFD and consumes the one byte that could not start a character.
--- That keeps a caller that walks a string from ever looping or losing its place, whatever bytes
--- the string holds.
---@param text string
---@param at number? # first byte to read, from one
---@return number codepoint
---@return number nextAt # one past the last byte of the character
function utf8.decode(text, at)
	at = at or 1
	local pointer, limit = textInfo(text)

	if at < 1 or at > limit then
		return REPLACEMENT, at + 1
	end

	local index = at - 1
	local first = pointer[index]
	if first < 0x80 then
		return first, at + 1
	end

	local codepoint, nextAt = decodeMultibyte(pointer, index, limit)
	if codepoint == nil then
		return REPLACEMENT, nextAt + 1
	end
	return codepoint, nextAt + 1
end

--- The first character of a string, as its codepoint.
---@param char string
---@return number codepoint
---@return number nextAt
function utf8.one(char)
	return utf8.decode(char, 1)
end

--- How many bytes come before a caret one character back of `at`.
---
--- A byte that starts no character counts as a character of one byte, so a caret in a string that
--- is not text still moves.
---@param text string
---@param at number # bytes before the caret, from zero
---@return number # bytes before the caret one character back; `at` at the start
function utf8.back(text, at)
	local before, position = 0, 1

	while position <= at do
		local _, after = utf8.decode(text, position)

		-- The character the caret is inside of, or at the end of, is the one before it.
		if after > at then
			return position - 1
		end

		before, position = position, after
	end

	return before
end

--- How many bytes come before a caret one character on from `at`.
---@param text string
---@param at number # bytes before the caret, from zero
---@return number # bytes before the caret one character on; the end of the string at its end
function utf8.forward(text, at)
	local _, after = utf8.decode(text, at + 1)

	return min(after - 1, #text)
end

--- The number of characters whose first byte lies between `i` and `j`.
---
--- Invalid input returns `nil` and the position of the offending byte, like Lua's `utf8.len`.
--- A character that starts inside the range is counted even when its later bytes lie past `j`.
---@param text string
---@param i number? # first byte, default 1
---@param j number? # last byte, default -1
---@return number? count
---@return number? badPosition
function utf8.len(text, i, j)
	local pointer, length = textInfo(text)
	local first, last = normaliseRange(length, i, j)

	local index = first - 1
	local stop = last

	-- A range that is all ASCII has one character per byte. The scan pays for itself on a long ASCII
	-- string and stops at the first non-ASCII byte on a mixed one, before the scalar loop starts.
	local ascii = asciiEnd(pointer, index, stop)
	if ascii == stop then
		return stop - index
	end

	local count = ascii - index
	index = ascii

	while index < length and index < stop do
		if pointer[index] < 0x80 then
			count = count + 1
			index = index + 1
		else
			local codepoint, nextAt = decodeMultibyte(pointer, index, length)
			if codepoint == nil then
				return nil, index + 1
			end
			count = count + 1
			index = nextAt
		end
	end

	return count
end

--- Whether every character whose first byte lies between `i` and `j` is well formed.
---
--- On malformed input the second result is the position of the offending byte.
---@param text string
---@param i number? # first byte, default 1
---@param j number? # last byte, default -1
---@return boolean valid
---@return number? badPosition
function utf8.valid(text, i, j)
	local count, position = utf8.len(text, i, j)
	if count == nil then
		return false, position
	end
	return true
end

--- The codepoints whose first byte lies between `i` and `j`, as multiple return values.
---@param text string
---@param i number? # first byte, default 1
---@param j number? # last byte, default -1
---@return number ...
function utf8.codepoint(text, i, j)
	local pointer, length = textInfo(text)
	local first, last = normaliseRange(length, i, j)

	local values = {}
	local count = 0
	local index = first - 1

	while index < length and index < last do
		local codepoint, nextAt
		if pointer[index] < 0x80 then
			codepoint, nextAt = pointer[index], index + 1
		else
			codepoint, nextAt = decodeMultibyte(pointer, index, length)
			if codepoint == nil then
				error("invalid UTF-8 code", 2)
			end
		end

		count = count + 1
		values[count] = codepoint
		index = nextAt
	end

	return unpack(values, 1, count)
end

---@alias utf8.CodesIterator fun(text: string, position: number): number?, number?

--- The iterator behind `utf8.codes`.
---@type utf8.CodesIterator
---@param text string
---@param position number # the previous position, or zero to start
---@return number? position # one-based byte of the character
---@return number? codepoint
local function codesIterator(text, position)
	local pointer, limit = textInfo(text)

	local at
	if position == 0 then
		at = 0
	else
		at = position
		while at < limit and band(pointer[at], 0xC0) == 0x80 do
			at = at + 1
		end
	end

	if at >= limit then
		return nil
	end

	local first = pointer[at]
	local codepoint
	if first < 0x80 then
		codepoint = first
	else
		codepoint = decodeMultibyte(pointer, at, limit)
		if codepoint == nil then
			error("invalid UTF-8 code", 2)
		end
	end

	return at + 1, codepoint
end

--- An iterator over a string's characters, in the shape Lua's `utf8.codes` returns.
---
--- The loop variables are the byte position and the codepoint. An invalid byte raises.
---@param text string
---@return utf8.CodesIterator iterator
---@return string text
---@return number position
function utf8.codes(text)
	return codesIterator, text, 0
end

--- Encodes Unicode scalar values as UTF-8.
---@param ... number codepoints
---@return string
function utf8.char(...)
	local count = select("#", ...)
	if count == 0 then
		return ""
	end

	if count == 1 then
		local codepoint = ...
		if type(codepoint) ~= "number"
			or codepoint % 1 ~= 0
			or codepoint < 0
			or codepoint > 0x10FFFF
			or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
			error("bad codepoint #1", 2)
		end

		if codepoint < 0x80 then
			return string.char(codepoint)
		elseif codepoint < 0x800 then
			return string.char(0xC0 + floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
		elseif codepoint < 0x10000 then
			return string.char(
				0xE0 + floor(codepoint / 0x1000),
				0x80 + floor(codepoint / 0x40) % 0x40,
				0x80 + codepoint % 0x40
			)
		end

		return string.char(
			0xF0 + floor(codepoint / 0x40000),
			0x80 + floor(codepoint / 0x1000) % 0x40,
			0x80 + floor(codepoint / 0x40) % 0x40,
			0x80 + codepoint % 0x40
		)
	end

	local buffer = ensureOutput(count * 4)
	local at = 0

	for index = 1, count do
		local codepoint = select(index, ...)
		if type(codepoint) ~= "number"
			or codepoint % 1 ~= 0
			or codepoint < 0
			or codepoint > 0x10FFFF
			or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
			error("bad codepoint #" .. index, 2)
		end

		if codepoint < 0x80 then
			buffer[at] = codepoint
			at = at + 1
		elseif codepoint < 0x800 then
			buffer[at] = 0xC0 + floor(codepoint / 0x40)
			buffer[at + 1] = 0x80 + codepoint % 0x40
			at = at + 2
		elseif codepoint < 0x10000 then
			buffer[at] = 0xE0 + floor(codepoint / 0x1000)
			buffer[at + 1] = 0x80 + floor(codepoint / 0x40) % 0x40
			buffer[at + 2] = 0x80 + codepoint % 0x40
			at = at + 3
		else
			buffer[at] = 0xF0 + floor(codepoint / 0x40000)
			buffer[at + 1] = 0x80 + floor(codepoint / 0x1000) % 0x40
			buffer[at + 2] = 0x80 + floor(codepoint / 0x40) % 0x40
			buffer[at + 3] = 0x80 + codepoint % 0x40
			at = at + 4
		end
	end

	return ffi.string(buffer, at)
end

--- Writes one codepoint as UTF-8 and returns the new end.
---@param buffer ffi.cdata*
---@param at number
---@param codepoint number
local function putCodepoint(buffer, at, codepoint)
	if codepoint < 0x80 then
		buffer[at] = codepoint
		return at + 1
	end
	if codepoint < 0x800 then
		buffer[at] = 0xC0 + floor(codepoint / 0x40)
		buffer[at + 1] = 0x80 + codepoint % 0x40
		return at + 2
	end
	if codepoint < 0x10000 then
		buffer[at] = 0xE0 + floor(codepoint / 0x1000)
		buffer[at + 1] = 0x80 + floor(codepoint / 0x40) % 0x40
		buffer[at + 2] = 0x80 + codepoint % 0x40
		return at + 3
	end

	buffer[at] = 0xF0 + floor(codepoint / 0x40000)
	buffer[at + 1] = 0x80 + floor(codepoint / 0x1000) % 0x40
	buffer[at + 2] = 0x80 + floor(codepoint / 0x40) % 0x40
	buffer[at + 3] = 0x80 + codepoint % 0x40
	return at + 4
end

--- Turns ISO-8859-1 bytes into UTF-8.
---
--- Every byte is one codepoint in Latin-1, so this is the lossless way to read a tag or a path
--- that a format stored one byte to a character.
---@param text string
---@return string
function utf8.fromLatin1(text)
	local length = #text
	if length == 0 then
		return ""
	end

	local pointer = ffi.cast(bytePointer, text)
	local buffer = ensureOutput(length * 2)
	local at = 0

	for index = 0, length - 1 do
		local byte = pointer[index]
		if byte < 0x80 then
			buffer[at] = byte
			at = at + 1
		else
			buffer[at] = 0xC0 + floor(byte / 0x40)
			buffer[at + 1] = 0x80 + byte % 0x40
			at = at + 2
		end
	end

	return ffi.string(buffer, at)
end

--- Reads UTF-16 text as UTF-8.
---
--- `bigEndian` chooses the byte order. Without it a byte order mark decides, and a string without
--- one is big endian, which is what ID3 and the Unicode standard say to assume. A lone surrogate
--- or a byte left over at the end becomes U+FFFD.
---@param text string
---@param bigEndian boolean?
---@return string
function utf8.fromUTF16(text, bigEndian)
	local length = #text
	if length == 0 then
		return ""
	end

	local pointer = ffi.cast(bytePointer, text)
	local start = 0
	local isBig

	if bigEndian == nil then
		if length >= 2 and pointer[0] == 0xFF and pointer[1] == 0xFE then
			isBig, start = false, 2
		elseif length >= 2 and pointer[0] == 0xFE and pointer[1] == 0xFF then
			isBig, start = true, 2
		else
			isBig = true
		end
	else
		isBig = bigEndian
	end

	local remaining = length - start
	if remaining == 0 then
		return ""
	end

	-- The kernel's converter reads native little-endian UTF-16, which is the common Windows path.
	if backend ~= nil and not isBig and remaining % 2 == 0 and remaining >= NATIVE_THRESHOLD
		and band(ffi.cast(addressOf, pointer + start), 1) == 0 then
		local wide = ffi.cast(widePointer, pointer + start)
		local converted = backend.fromWide(wide, remaining / 2)
		if converted ~= nil then
			return converted
		end
	end

	local buffer = ensureOutput(floor(remaining * 3 / 2) + 4)
	local at = 0
	local index = start

	while index + 1 < length do
		local first = pointer[index]
		local second = pointer[index + 1]
		local unit = isBig and bor(lshift(first, 8), second) or bor(lshift(second, 8), first)
		local codepoint

		if unit >= 0xD800 and unit <= 0xDBFF then
			if index + 3 < length then
				local third = pointer[index + 2]
				local fourth = pointer[index + 3]
				local low = isBig and bor(lshift(third, 8), fourth) or bor(lshift(fourth, 8), third)

				if low >= 0xDC00 and low <= 0xDFFF then
					codepoint = 0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00)
					index = index + 4
				else
					codepoint = REPLACEMENT
					index = index + 2
				end
			else
				codepoint = REPLACEMENT
				index = index + 2
			end
		elseif unit >= 0xDC00 and unit <= 0xDFFF then
			codepoint = REPLACEMENT
			index = index + 2
		else
			codepoint = unit
			index = index + 2
		end

		at = putCodepoint(buffer, at, codepoint)
	end

	if index < length then
		at = putCodepoint(buffer, at, REPLACEMENT)
	end

	return ffi.string(buffer, at)
end

--- Writes UTF-8 text as UTF-16.
---
--- The result is a string of 16-bit code units, little endian unless `bigEndian` says otherwise,
--- with no byte order mark. Malformed UTF-8 becomes U+FFFD.
---@param text string
---@param bigEndian boolean?
---@return string
function utf8.toUTF16(text, bigEndian)
	local length = #text
	if length == 0 then
		return ""
	end

	-- The native encoder replaces malformed bytes its own way. Keeping it to input the portable
	-- validator accepted makes a long string come out the same on every platform.
	if backend ~= nil and not bigEndian and length >= NATIVE_THRESHOLD and utf8.valid(text) then
		local wide, count = backend.toWide(text)
		if wide ~= nil then
			return ffi.string(wide, count * 2)
		end
	end

	local pointer = ffi.cast(bytePointer, text)
	local buffer = ensureOutput(length * 2)
	local at = 0
	local index = 0

	while index < length do
		local codepoint
		local nextAt

		if pointer[index] < 0x80 then
			codepoint, nextAt = pointer[index], index + 1
		else
			codepoint, nextAt = decodeMultibyte(pointer, index, length)
			if codepoint == nil then
				codepoint, nextAt = REPLACEMENT, index + 1
			end
		end

		if codepoint < 0x10000 then
			local low = band(codepoint, 0xFF)
			local high = rshift(codepoint, 8)
			if bigEndian then
				buffer[at], buffer[at + 1] = high, low
			else
				buffer[at], buffer[at + 1] = low, high
			end
			at = at + 2
		else
			local value = codepoint - 0x10000
			local highSurrogate = 0xD800 + floor(value / 0x400)
			local lowSurrogate = 0xDC00 + value % 0x400

			if bigEndian then
				buffer[at], buffer[at + 1] = rshift(highSurrogate, 8), band(highSurrogate, 0xFF)
				buffer[at + 2], buffer[at + 3] = rshift(lowSurrogate, 8), band(lowSurrogate, 0xFF)
			else
				buffer[at], buffer[at + 1] = band(highSurrogate, 0xFF), rshift(highSurrogate, 8)
				buffer[at + 2], buffer[at + 3] = band(lowSurrogate, 0xFF), rshift(lowSurrogate, 8)
			end
			at = at + 4
		end

		index = nextAt
	end

	return ffi.string(buffer, at)
end

return utf8
