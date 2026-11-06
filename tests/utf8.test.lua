local test = require("lde-test")
local utf8 = require("utf8")

local REPLACEMENT = "\239\191\189"

--
-- char / decode
--

test.it("char encodes every UTF-8 length", function()
	test.equal(utf8.char(0), "\0")
	test.equal(utf8.char(0x7F), "\127")
	test.equal(utf8.char(0x80), "\194\128")
	test.equal(utf8.char(0x7FF), "\223\191")
	test.equal(utf8.char(0x800), "\224\160\128")
	test.equal(utf8.char(0xD7FF), "\237\159\191")
	test.equal(utf8.char(0xE000), "\238\128\128")
	test.equal(utf8.char(0xFFFF), "\239\191\191")
	test.equal(utf8.char(0x10000), "\240\144\128\128")
	test.equal(utf8.char(0x10FFFF), "\244\143\191\191")
end)

test.it("char encodes several codepoints at once", function()
	local text = utf8.char(0x68, 0xE9, 0x65E5, 0x1F3B5)

	test.equal(text, "h\195\169\230\151\165\240\159\142\181")
	test.equal(utf8.char(), "")
end)

test.it("char rejects values that are not Unicode scalars", function()
	test.errors(function() utf8.char(-1) end)
	test.errors(function() utf8.char(0x110000) end)
	test.errors(function() utf8.char(0xD800) end)
	test.errors(function() utf8.char(0xDFFF) end)
	test.errors(function() utf8.char(1.5) end)
	test.errors(function() utf8.char(0x41, 0xD800) end)
end)

---@class utf8.Test.DecodeCase
---@field text string
---@field codepoint number
---@field nextAt number

test.it("decode reads each length and advances past it", function()
	---@type utf8.Test.DecodeCase[]
	local cases = {
		{ text = "A", codepoint = 0x41, nextAt = 2},
		{ text = "\195\169", codepoint = 0xE9, nextAt = 3},
		{ text = "\230\151\165", codepoint = 0x65E5, nextAt = 4},
		{ text = "\240\159\142\181", codepoint = 0x1F3B5, nextAt = 5},
	}

	for _, case in ipairs(cases) do
		local codepoint, nextAt = utf8.decode(case.text, 1)

		test.equal(codepoint, case.codepoint)
		test.equal(nextAt, case.nextAt)
	end
end)

test.it("decode turns malformed bytes into one replacement each", function()
	local cases = {
		"\128", -- a continuation byte that starts nothing
		"\192\128", -- an overlong two-byte form
		"\224\128\128", -- an overlong three-byte form
		"\237\160\128", -- a surrogate
		"\244\144\128\128", -- beyond U+10FFFF
		"\245\128\128\128", -- an invalid leading byte
		"\226\130", -- a sequence the string ends in the middle of
	}

	for _, text in ipairs(cases) do
		local codepoint, nextAt = utf8.decode(text, 1)

		test.equal(codepoint, 0xFFFD)
		test.equal(nextAt, 2)
	end
end)

test.it("decode at the end or before the start returns a replacement", function()
	test.equal(utf8.decode("A", 2), 0xFFFD)
	test.equal(utf8.decode("A", 0), 0xFFFD)
	test.equal(utf8.decode("", 1), 0xFFFD)
	test.equal(utf8.decode("A"), 0x41, "the offset defaults to one")
end)

test.it("one reads the first character only", function()
	test.equal(utf8.one("\195\169x"), 0xE9)
	test.equal(utf8.one(""), 0xFFFD)
end)

--
-- len / valid
--

test.it("len counts characters", function()
	test.equal(utf8.len(""), 0)
	test.equal(utf8.len("hello"), 5)
	test.equal(utf8.len("h\195\169llo"), 5)
	test.equal(utf8.len("\230\151\165\230\156\172\232\170\158"), 3)
	test.equal(utf8.len("\240\159\142\181"), 1)
end)

test.it("len skips ASCII eight bytes at a time without losing a count", function()
	for length = 0, 64 do
		local text = string.rep("a", length)

		test.equal(utf8.len(text), length, "ASCII length " .. length)
		test.equal(utf8.valid(text), true, "ASCII valid " .. length)
	end
end)

test.it("len finds a character after an ASCII run at every alignment", function()
	for prefix = 0, 16 do
		local text = string.rep("a", prefix) .. "\195\169" .. string.rep("b", prefix)

		test.equal(utf8.len(text), prefix * 2 + 1, "prefix " .. prefix)
	end
end)

test.it("len reports the first malformed byte", function()
	local count, position = utf8.len("a\255b")

	test.equal(count, nil)
	test.equal(position, 2)
	test.equal(utf8.len("\192\128"), nil)
	test.equal(select(2, utf8.len("\192\128")), 1)
end)

test.it("len follows the byte range it is given", function()
	local text = "h\195\169llo" -- six bytes: h, é (two), l, l, o

	test.equal(utf8.len(text, 2, 3), 1, "é starts in the range")
	test.equal(utf8.len(text, 1, 2), 2, "a character that starts at j is counted")
	test.equal(utf8.len(text, 1, 1), 1)
	test.equal(utf8.len(text, 7, 6), 0)
	test.equal(utf8.len(text, 5, 1), 0)
	test.equal(utf8.len(text, -3, -1), 3)
	test.equal(select(2, utf8.len(text, 3, 6)), 3, "a continuation cannot start a character")
end)

test.it("len rejects positions outside the string", function()
	test.errors(function() utf8.len("abc", 0) end)
	test.errors(function() utf8.len("abc", 1, 4) end)
	test.errors(function() utf8.len("abc", -4) end)
end)

test.it("valid is len without a count", function()
	test.equal(utf8.valid("hello"), true)
	test.equal(utf8.valid("h\195\169llo"), true)
	test.equal(utf8.valid("h\195\169llo", 2, 3), true)
	test.equal(utf8.valid("a\255b", 1, 1), true, "the bad byte starts outside the range")

	local isValid, position = utf8.valid("a\255b", 2, 3)
	test.equal(isValid, false)
	test.equal(position, 2)
end)

test.it("valid handles embedded NULs", function()
	test.equal(utf8.valid("a\0b"), true)
	test.equal(utf8.len("a\0b"), 3)
end)

--
-- codepoint / codes
--

test.it("codepoint returns the requested characters", function()
	local first = utf8.codepoint("h\195\169llo", 1, 1)
	local second = utf8.codepoint("h\195\169llo", 2, 3)
	local a, b = utf8.codepoint("h\195\169llo", 1, 3)

	test.equal(first, 0x68)
	test.equal(second, 0xE9)
	test.equal(a, 0x68)
	test.equal(b, 0xE9)
end)

test.it("codepoint raises on malformed input", function()
	test.errors(function() utf8.codepoint("a\255b") end)
	test.errors(function() utf8.codepoint("h\195\169llo", 3, 6) end)
end)

test.it("codes visits every character and its byte position", function()
	local expected = {
		{ 1, 0x61},
		{ 2, 0xE9},
		{ 4, 0x65E5},
		{ 7, 0x1F3B5},
	}
	local index = 0

	for position, codepoint in utf8.codes("a\195\169\230\151\165\240\159\142\181") do
		index = index + 1
		test.equal(position, expected[index][1])
		test.equal(codepoint, expected[index][2])
	end

	test.equal(index, #expected)
end)

test.it("codes raises on malformed input", function()
	test.errors(function()
		for _ in utf8.codes("a\255b") do end
	end)
end)

--
-- caret movement
--

test.it("back moves one character at a time", function()
	test.equal(utf8.back("abc", 0), 0)
	test.equal(utf8.back("abc", 1), 0)
	test.equal(utf8.back("abc", 2), 1)
	test.equal(utf8.back("abc", 3), 2)
	test.equal(utf8.back("a\195\169", 2), 1, "a caret inside é moves to its start")
	test.equal(utf8.back("a\195\169", 3), 1)
end)

test.it("forward moves one character at a time", function()
	test.equal(utf8.forward("abc", 0), 1)
	test.equal(utf8.forward("abc", 1), 2)
	test.equal(utf8.forward("abc", 2), 3)
	test.equal(utf8.forward("abc", 3), 3)
	test.equal(utf8.forward("a\195\169", 1), 3)
	test.equal(utf8.forward("a\195\169", 2), 3)
end)

--
-- Latin-1
--

test.it("fromLatin1 expands every byte above ASCII", function()
	test.equal(utf8.fromLatin1(""), "")
	test.equal(utf8.fromLatin1("A\0\127\128\255"), "A\0\127\194\128\195\191")
end)

test.it("fromLatin1 maps all 256 bytes to the same codepoints", function()
	local bytes = {}
	for byte = 0, 255 do
		bytes[#bytes + 1] = string.char(byte)
	end

	local text = utf8.fromLatin1(table.concat(bytes))
	test.equal(utf8.len(text), 256)
	test.equal(utf8.valid(text), true)

	local index = 0
	for _, codepoint in utf8.codes(text) do
		test.equal(codepoint, index)
		index = index + 1
	end
end)

--
-- UTF-16
--

local function le16(unit)
	return string.char(unit % 256, math.floor(unit / 256))
end

local function be16(unit)
	return string.char(math.floor(unit / 256), unit % 256)
end

test.it("fromUTF16 reads both byte orders", function()
	test.equal(utf8.fromUTF16(le16(0x41) .. le16(0xE9), false), "A\195\169")
	test.equal(utf8.fromUTF16(be16(0x41) .. be16(0xE9), true), "A\195\169")
end)

test.it("fromUTF16 assumes big endian without a byte order mark", function()
	test.equal(utf8.fromUTF16(be16(0x41) .. be16(0xE9)), "A\195\169")
end)

test.it("fromUTF16 reads and strips either byte order mark", function()
	local little = "\255\254" .. le16(0x41) .. le16(0xE9)
	local big = "\254\255" .. be16(0x41) .. be16(0xE9)

	test.equal(utf8.fromUTF16(little), "A\195\169")
	test.equal(utf8.fromUTF16(big), "A\195\169")
	test.equal(utf8.fromUTF16("\255\254"), "")
end)

test.it("fromUTF16 keeps a byte order mark when the order is explicit", function()
	test.equal(utf8.fromUTF16("\255\254" .. le16(0x41), false), "\239\187\191A")
end)

test.it("fromUTF16 combines surrogate pairs", function()
	test.equal(utf8.fromUTF16("\60\216\181\223", false), "\240\159\142\181")
	test.equal(utf8.fromUTF16("\216\60\223\181", true), "\240\159\142\181")
end)

test.it("fromUTF16 replaces a lone surrogate and an odd tail", function()
	test.equal(utf8.fromUTF16("\0\216", false), REPLACEMENT)
	test.equal(utf8.fromUTF16("\0\220", false), REPLACEMENT)
	test.equal(utf8.fromUTF16("A", false), REPLACEMENT)
	test.equal(utf8.fromUTF16("\0\216\0\216", false), REPLACEMENT .. REPLACEMENT)
end)

test.it("toUTF16 writes both byte orders and no byte order mark", function()
	test.equal(utf8.toUTF16("A", false), "\65\0")
	test.equal(utf8.toUTF16("A", true), "\0\65")
	test.equal(utf8.toUTF16("\195\169", false), "\233\0")
	test.equal(utf8.toUTF16("\240\159\142\181", false), "\60\216\181\223")
	test.equal(utf8.toUTF16("\240\159\142\181", true), "\216\60\223\181")
	test.equal(utf8.toUTF16(""), "")
end)

test.it("toUTF16 replaces malformed UTF-8", function()
	test.equal(utf8.toUTF16("\255", false), "\253\255")
end)

test.it("UTF-16 survives a round trip", function()
	local text = "A\195\169\230\151\165\240\159\142\181\0z"

	test.equal(utf8.fromUTF16(utf8.toUTF16(text, false), false), text)
	test.equal(utf8.fromUTF16(utf8.toUTF16(text, true), true), text)
	test.equal(utf8.fromUTF16(utf8.toUTF16(text, true)), text)
end)

test.it("UTF-16 round trips a long mixed string", function()
	local text = string.rep("A\195\169\230\151\165\240\159\142\181", 100)

	test.equal(utf8.fromUTF16(utf8.toUTF16(text, false), false), text)
	test.equal(utf8.fromUTF16(utf8.toUTF16(text, true), true), text)
	test.equal(utf8.len(text), 400)
end)

test.it("long malformed UTF-8 is encoded the same way on every platform", function()
	local text = "\255" .. string.rep("a", 300)

	test.equal(utf8.toUTF16(text, false), "\253\255" .. string.rep("a\0", 300))
end)

test.it("long unpaired surrogates become replacements", function()
	test.equal(utf8.fromUTF16(string.rep("\0\216", 200), false), string.rep(REPLACEMENT, 200))
	test.equal(utf8.fromUTF16(string.rep("\0\220", 200), false), string.rep(REPLACEMENT, 200))
end)

test.skipIf(jit.os ~= "Windows")("native wide buffers outlive the next conversion", function()
	local windows = require("utf8.raw.windows")
	local first, count = assert(windows.toWide("hello"))
	local second = assert(windows.toWide("world"))

	test.equal(count, 5)
	test.equal(windows.fromWide(first, count), "hello")
	test.equal(windows.fromWide(second), "world")
end)

--
-- buffer reuse
--

test.it("reused output buffers do not leak a longer earlier result", function()
	local long = utf8.char(0x1F3B5, 0x1F3B5)
	local pairs = le16(0xD83C) .. le16(0xDFB5) .. le16(0xD83C) .. le16(0xDFB5)

	test.equal(utf8.char(0x41), "A")
	test.equal(utf8.fromLatin1("\128\128\128\128"), "\194\128\194\128\194\128\194\128")
	test.equal(utf8.fromLatin1("A"), "A")
	test.equal(utf8.fromUTF16(pairs, false), long)
	test.equal(utf8.fromUTF16(le16(0x41), false), "A")
end)
