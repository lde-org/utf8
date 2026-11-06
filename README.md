# utf8

[![Test](https://github.com/lde-org/utf8/actions/workflows/test.yml/badge.svg)](https://github.com/lde-org/utf8/actions/workflows/test.yml)

A fast, lean UTF-8 library for LuaJIT. It reads and writes text a machine word at a time through
FFI, and has no runtime dependencies beyond LuaJIT itself.

```sh
lde add utf8
```

## Usage

```lua
local utf8 = require("utf8")

utf8.len("héllo")                    --> 5
utf8.valid("héllo")                  --> true
utf8.char(0x1F3B5)                   --> "🎵"
utf8.decode("héllo", 1)              --> 104, 2
utf8.codepoint("héllo", 1, 3)        --> 104, 233
utf8.fromLatin1("Caf\233")           --> "Café"
utf8.fromUTF16("\0C\0a\0f\0\233")    --> "Café"
```

## API

### Reading

- `utf8.decode(text, at?) -> codepoint, nextAt`  
  Reads one character starting at the one-based byte `at` (default `1`). The second result is one
  past its last byte. A malformed byte becomes `U+FFFD` and consumes one byte, so a caller that
  walks a string never loses its place or loops.
- `utf8.one(text) -> codepoint, nextAt`  
  The first character of a string.
- `utf8.len(text, i?, j?) -> count | nil, badPosition`  
  Counts characters whose first byte lies between `i` and `j`. Positions follow Lua's `string.sub`
  rules. Malformed input returns `nil` and the position of the offending byte.
- `utf8.valid(text, i?, j?) -> boolean, badPosition?`  
  A fast validation pass. It says whether every character that starts in the range is well formed.
- `utf8.codepoint(text, i?, j?) -> ...`  
  The codepoints whose first byte lies between `i` and `j`, as multiple return values. Malformed
  input raises.
- `utf8.codes(text) -> iterator, text, 0`  
  The iterator Lua's own `utf8.codes` returns: a byte position and a codepoint per step. Malformed
  input raises.
- `utf8.back(text, at) -> byteOffset`  
  The byte offset one character back of the caret at `at` (bytes before the caret, from zero).
- `utf8.forward(text, at) -> byteOffset`  
  The byte offset one character on from the caret at `at`.

### Writing

- `utf8.char(...) -> string`  
  Encodes one or more Unicode scalar values. Surrogates and values above `U+10FFFF` raise.
- `utf8.fromLatin1(text) -> string`  
  Expands ISO-8859-1 bytes into UTF-8. Every byte is one codepoint.
- `utf8.toUTF16(text, bigEndian?) -> string`  
  UTF-16 code units, little endian unless `bigEndian` is true, with no byte order mark. Malformed
  UTF-8 becomes `U+FFFD`.
- `utf8.fromUTF16(text, bigEndian?) -> string`  
  Reads UTF-16 code units. Without `bigEndian`, a byte order mark decides the order and a string
  without one is big endian, as ID3 and Unicode specify. A lone surrogate or an odd trailing byte
  becomes `U+FFFD`.

`len`, `valid`, `codepoint` and `codes` treat UTF-8 as Unicode does: overlong forms, surrogates,
values beyond `U+10FFFF`, stray continuation bytes and truncated sequences are malformed.
`decode` is the replacement-mode reader: it turns each malformed byte into `U+FFFD` and moves on.

## Why it is fast

- Strings stay byte pointers. Multi-byte characters are decoded with shifts and masks, never with
  `string.sub` or a temporary string.
- ASCII runs are skipped eight bytes at a time with a 64-bit word test. The head and tail are read
  byte by byte, so no word crosses the end of a string. Word reads are aligned first, which keeps
  the same code safe on x86, ARM and anything else LuaJIT runs on.
- `ffi.typeof` constructors are cached, and output buffers, the last string pointer and the last
  string length are reused. A caller walking one string does not cast it or measure it again.
- On Windows, UTF-16 conversion of strings 256 bytes or more goes through kernel32's
  `MultiByteToWideChar` and `WideCharToMultiByte`, which are SIMD tuned. The backend lives in
  `src/raw/windows.lua` and is claimed by the `windows` feature, so a bundle for another platform
  does not contain it. Validation and decoding stay on the portable path: the codec's
  invalid-character flag is not consistent across Windows-compatible implementations, and a
  validator that disagrees with the decoder is worse than no validator at all. The module also
  exposes `toWide(text) -> uint16_t[]?, count` and `fromWide(wide, count?) -> string?` for a
  library such as `fs` that crosses the UTF-8/UTF-16 path boundary itself.

There is no syscall to make UTF-8 faster. Decoding text is memory work, not I/O, so a syscall adds
a crossing without doing any of the work. On POSIX the converters in libc are locale-bound: they
only decode UTF-8 when the process locale says so, and benchmarks against the word-at-a-time loop
here put them behind it. The portable path is the fast path, and the one OS with a UTF-8 codec
worth calling is the one that gets a native backend.

Measured on one Linux x86-64 machine with LuaJIT 2.1, fastest of seven runs, in nanoseconds per
input byte:

| input | `len` | `decode` loop | `codes` loop |
|---|---:|---:|---:|
| ASCII, 900 KB | 0.11 | 1.52 | 2.01 |
| Latin-1-ish text, 720 KB | 2.90 | 2.58 | 4.02 |
| CJK, 1.08 MB | 2.38 | 3.94 | 4.09 |
| emoji, 880 KB | 2.30 | 3.47 | 4.39 |
| mixed, 560 KB | 2.63 | 3.09 | 3.92 |

Run `lde run tools/bench.lua --profile --jit` to reproduce them on your machine and see where the
JIT spends its time.
