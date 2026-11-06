-- Throughput harness for the hot paths. Run it with
--
--   lde run tools/bench.lua --profile --jit
--
-- The numbers are the fastest of several runs, in nanoseconds per input byte where the input is
-- bytes, and in millions of characters per second where the work is per character.
local utf8 = require("utf8")

local clock = os.clock
local format = string.format
local rep = string.rep

local sets = {
	{ "ascii", rep("The quick brown fox jumps over the lazy dog. ", 20000) },
	{ "latin", rep("Café naïve façade — déjà vu. ", 20000) },
	{ "cjk", rep("日本語のテキスト、これはテストです。", 20000) },
	{ "emoji", rep("🎵 👨‍👩‍👧‍👦 🇧🇷 ✓ ", 20000) },
	{ "mixed", rep("aé日🎵 ok\t", 40000) },
	{ "invalid", rep("abc\255def\192\128", 40000) },
}

local sink = {}

--- Fastest of several runs: a slow sample says the machine was busy, not that the code is slow.
---@param fn fun(): any
local function measure(fn)
	fn() -- warm the trace before timing it
	local best = math.huge
	for _ = 1, 7 do
		collectgarbage("collect")
		local started = clock()
		sink[1] = fn()
		local elapsed = clock() - started
		if elapsed < best then
			best = elapsed
		end
	end
	return best
end

---@param name string
---@param fn fun(): any
---@param bytes number
---@param characters number
local function bench(name, fn, bytes, characters)
	local seconds = measure(fn)
	local nsPerByte = seconds * 1e9 / bytes
	local millionChars = characters / seconds / 1e6
	print(format("%-18s %8.2f ns/B %8.2f Mchar/s", name, nsPerByte, millionChars))
end

local function decodeAll(text)
	local at, sum = 1, 0
	while at <= #text do
		local codepoint
		codepoint, at = utf8.decode(text, at)
		sum = sum + codepoint
	end
	return sum
end

local function codesAll(text)
	local sum = 0
	for _, codepoint in utf8.codes(text) do
		sum = sum + codepoint
	end
	return sum
end

-- A plain Lua reference for the scan that dominates. It is not the fastest possible loop, just the
-- shape a library without FFI has to use.
local function plainLen(text)
	local at, count = 1, 0
	while at <= #text do
		local byte = text:byte(at)
		if byte < 0x80 then
			at = at + 1
		elseif byte < 0xE0 then
			at = at + 2
		elseif byte < 0xF0 then
			at = at + 3
		else
			at = at + 4
		end
		count = count + 1
	end
	return count
end

local function charsOf(text)
	local at, count = 1, 0
	while at <= #text do
		local byte = text:byte(at)
		if byte < 0x80 then
			at = at + 1
		elseif byte < 0xE0 then
			at = at + 2
		elseif byte < 0xF0 then
			at = at + 3
		else
			at = at + 4
		end
		count = count + 1
	end
	return count
end

for _, set in ipairs(sets) do
	local name, text = set[1], set[2]
	local count = utf8.len(text) or charsOf(text)
	print("")
	print(format("%s: %d bytes, %d characters", name, #text, count))
	bench("decode loop", function() decodeAll(text) end, #text, count)
	if name ~= "invalid" then
		bench("len", function() utf8.len(text) end, #text, count)
		bench("valid", function() utf8.valid(text) end, #text, count)
		bench("codes loop", function() codesAll(text) end, #text, count)
		bench("plain byte len", function() plainLen(text) end, #text, count)
	end
end

print("")
print("conversion")
local latin = sets[2][2]
bench("fromLatin1", function() utf8.fromLatin1(latin) end, #latin, #latin)
local ascii = sets[1][2]
bench("toUTF16", function() utf8.toUTF16(ascii) end, #ascii, #ascii)
local wide = utf8.toUTF16(ascii)
bench("fromUTF16", function() utf8.fromUTF16(wide, false) end, #ascii, #ascii)
bench("char x1000", function()
	local sum = 0
	for _ = 1, 1000 do
		sum = sum + #utf8.char(0x1F3B5)
	end
	return sum
end, 4000, 1000)
