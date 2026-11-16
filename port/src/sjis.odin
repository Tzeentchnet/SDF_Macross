// Shift-JIS (CP932) conversion for the game's text, using the generated
// tables in sjis_table.odin.
package main

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Whether b starts a two-byte Shift-JIS character.
sjis_lead :: proc(b: u8) -> bool {
	return (b >= 0x81 && b <= 0x9f) || (b >= 0xe0 && b <= 0xfc)
}

// The game's bytes as UTF-8. Undecodable bytes become U+FFFD; an invalid
// lead byte does not consume the next byte.
sjis_decode :: proc(b: []u8, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for i := 0; i < len(b); {
		c := b[i]
		switch {
		case c < 0x80:
			strings.write_byte(&sb, c)
			i += 1
		case c == 0x80:
			strings.write_rune(&sb, rune(0x80))
			i += 1
		case c == 0xa0:
			strings.write_rune(&sb, rune(0xf8f0))
			i += 1
		case c >= 0xa1 && c <= 0xdf:
			strings.write_rune(&sb, rune(0xff61 + int(c) - 0xa1))
			i += 1
		case c >= 0xfd:
			strings.write_rune(&sb, rune(0xf8f1 + int(c) - 0xfd))
			i += 1
		case sjis_lead(c) && i + 1 < len(b):
			code := u32(c) << 8 | u32(b[i + 1])
			k, found := slice.binary_search_by(SJIS_DECODE[:], code, proc(e, key: u32) -> slice.Ordering {
				return slice.cmp(e >> 16, key)
			})
			if found {
				strings.write_rune(&sb, rune(SJIS_DECODE[k] & 0xffff))
				i += 2
			} else {
				strings.write_rune(&sb, utf8.RUNE_ERROR)
				i += 1
			}
		case:
			strings.write_rune(&sb, utf8.RUNE_ERROR)
			i += 1
		}
	}
	return strings.to_string(sb)
}

// Typographic punctuation a translator's editor tends to insert, and the
// ASCII the game's narrow Latin glyphs have for it. Shift-JIS has wide
// versions of most of these, which look out of place in English text.
@(private = "file")
ASCII_PUNCT := [?]struct {
	r: rune,
	s: string,
}{
	{rune(0x2018), "'"}, {rune(0x2019), "'"}, {rune(0x201c), "\""}, {rune(0x201d), "\""},
	{rune(0x2013), "-"}, {rune(0x2014), "--"}, {rune(0x2026), "..."}, {rune(0x00a0), " "},
}

// UTF-8 text as the game's bytes. Unmappable characters become '?' and are
// counted in `missing`. With `ascii_punct`, curly quotes, dashes and the
// ellipsis are written as ASCII.
sjis_encode :: proc(s: string, ascii_punct: bool, allocator := context.allocator) -> (out: []u8, missing: int) {
	buf := make([dynamic]u8, 0, len(s) + 1, allocator)
	outer: for r in s {
		switch {
		case r < 0x80:
			append(&buf, u8(r))
			continue
		case r == 0x80:
			append(&buf, 0x80)
			continue
		case r >= 0xff61 && r <= 0xff9f:
			append(&buf, u8(0xa1 + int(r) - 0xff61))
			continue
		case r == 0xf8f0:
			append(&buf, 0xa0)
			continue
		case r >= 0xf8f1 && r <= 0xf8f3:
			append(&buf, u8(0xfd + int(r) - 0xf8f1))
			continue
		}
		if ascii_punct {
			for p in ASCII_PUNCT {
				if p.r == r {
					append(&buf, p.s)
					continue outer
				}
			}
		}
		if r <= 0xffff {
			k, found := slice.binary_search_by(SJIS_ENCODE[:], u32(r), proc(e, key: u32) -> slice.Ordering {
				return slice.cmp(e >> 16, key)
			})
			if found {
				code := SJIS_ENCODE[k] & 0xffff
				append(&buf, u8(code >> 8), u8(code))
				continue
			}
		}
		append(&buf, '?')
		missing += 1
	}
	return buf[:], missing
}

// Whether the game's bytes hold Japanese prose: a hiragana, katakana or kanji
// character. Used to pick the voice lines the subtitle option captions,
// matching the records the external translation tool's parser reports.
sjis_has_japanese :: proc(b: []u8) -> bool {
	for i := 0; i < len(b); {
		c := b[i]
		if !sjis_lead(c) {
			i += 1
			continue
		}
		t := i + 1 < len(b) ? b[i + 1] : 0
		switch {
		case c == 0x82 && t >= 0x9f, c == 0x83 && t <= 0x96, c >= 0x88 && c <= 0x9f, c >= 0xe0 && c <= 0xea:
			return true
		}
		i += 2
	}
	return false
}
