-- The one place an operating system ships a UTF-8 codec worth calling: kernel32's conversion runs
-- in C, is what Windows itself uses, and is SIMD tuned. The cdef is guarded because fs, winit and
-- other packages declare the same two symbols.
local ffi = require("ffi")

pcall(ffi.cdef, [[
	int MultiByteToWideChar(unsigned int CodePage, uint32_t dwFlags, const char* lpMultiByteStr,
		int cbMultiByte, uint16_t* lpWideCharStr, int cchWideChar);
	int WideCharToMultiByte(unsigned int CodePage, uint32_t dwFlags, const uint16_t* lpWideCharStr,
		int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar,
		int* lpUsedDefaultChar);
]])

local kernel32 = ffi.load("kernel32")

local CP_UTF8 = 65001

local ByteArray = ffi.typeof("uint8_t[?]")
local WideArray = ffi.typeof("uint16_t[?]")

---@class utf8.raw.windows: utf8.raw
local windows = {}

--- UTF-8 as a NUL-terminated native UTF-16 buffer. Malformed bytes become U+FFFD, as they do in
--- the portable writer. Returns nil when the codec refuses the input.
---
--- The buffer is fresh on every call: a caller that converts two paths before using either one
--- must not have the second conversion overwrite the first.
---@param text string
---@return ffi.cdata*? wide
---@return number count
function windows.toWide(text)
	local count = kernel32.MultiByteToWideChar(CP_UTF8, 0, text, #text, nil, 0)
	if count <= 0 then
		return nil, 0
	end

	local wide = WideArray(count + 1)
	if kernel32.MultiByteToWideChar(CP_UTF8, 0, text, #text, wide, count) <= 0 then
		return nil, 0
	end
	wide[count] = 0

	return wide, count
end

local byteBuffer = ByteArray(256)
local byteCapacity = 256

---@param size number
---@return ffi.cdata* buffer
local function ensureBytes(size)
	if size > byteCapacity then
		local capacity = byteCapacity
		while capacity < size do
			capacity = capacity * 2
		end
		byteBuffer, byteCapacity = ByteArray(capacity), capacity
	end
	return byteBuffer
end

--- Native UTF-16 as UTF-8. `count` is in 16-bit units; without it the buffer ends at NUL.
--- Returns nil when the codec refuses the input, so the caller can use the portable decoder.
---@param wide ffi.cdata*
---@param count number?
---@return string? text
function windows.fromWide(wide, count)
	count = count or -1
	local size = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide, count, nil, 0, nil, nil)
	if size <= 0 then
		return nil
	end

	local buffer = ensureBytes(size)
	if kernel32.WideCharToMultiByte(CP_UTF8, 0, wide, count, buffer, size, nil, nil) <= 0 then
		return nil
	end

	-- A NUL-terminated conversion counts its terminator in the size.
	return ffi.string(buffer, count == -1 and size - 1 or size)
end

return windows
