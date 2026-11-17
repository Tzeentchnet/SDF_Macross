package runtime_localization_test

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import port "game:src"
import "ps:core"
import mem "ps:ps2/mem"

Test_Font_Record :: struct {
	codepoint: u32,
	code:      u16,
	flags:     u16,
	fill:      u8,
}

test_font_u16 :: proc(out: ^[dynamic]u8, value: u16) {
	append(out, u8(value), u8(value >> 8))
}

test_font_u32 :: proc(out: ^[dynamic]u8, value: u32) {
	append(out, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
}

test_font_pack :: proc(records: []Test_Font_Record, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, 12 + len(records) * (8 + port.LOC_FONT_GLYPH), allocator)
	for b in "MCFNT1\x00\x00" {append(&out, u8(b))}
	test_font_u32(&out, u32(len(records)))
	for record in records {
		test_font_u32(&out, record.codepoint)
		test_font_u16(&out, record.code)
		test_font_u16(&out, record.flags)
		for _ in 0 ..< port.LOC_FONT_GLYPH {append(&out, record.fill)}
	}
	return out[:]
}

test_font_text :: proc() -> string {
	out := strings.builder_make(context.allocator)
	strings.write_rune(&out, rune(0x00e9))
	strings.write_byte(&out, 'A')
	strings.write_rune(&out, rune(0x1f600))
	return strings.to_string(out)
}

@(test)
runtime_font_pack_encoding_and_glyph_copy :: proc(t: ^testing.T) {
	sync.mutex_lock(&loc_test_mutex)
	defer sync.mutex_unlock(&loc_test_mutex)
	context.allocator = context.temp_allocator
	base :: "tests\\runtime_localization\\runtime_font_fixture"
	path :: base + "\\font.bin"
	if !testing.expect(t, !os.exists(base), "font fixture path must not already exist") {return}
	if !testing.expect(t, os.make_directory_all(base) == nil) {return}
	defer os.remove_all(base)
	defer port.loc_reset()

	records := [?]Test_Font_Record{
		{codepoint = 0x00e9, code = 0x00a2, fill = 0x3c},
		{codepoint = 0x1f600, code = 0x8541, fill = 0xa5},
	}
	data := test_font_pack(records[:])
	if !testing.expect(t, os.write_entire_file(path, data) == nil) {return}
	if !testing.expect(t, port.loc_fonts_load([]string{path})) {return}
	encoded, missing := port.loc_encode(test_font_text(), false, context.temp_allocator)
	testing.expect(t, missing == 0)
	testing.expect(t, slice.equal(encoded, []u8{0xa2, 'A', 0x85, 0x41}))

	old_ram := mem.ram
	mem.ram = make([]u8, mem.RAM_SIZE, core.long_allocator())
	defer {
		delete(mem.ram, core.long_allocator())
		mem.ram = old_ram
	}
	testing.expect(t, port.loc_font_copy(0x00a2, 0x1000))
	for b in mem.ram[0x1000:0x1000 + port.LOC_FONT_GLYPH] {
		if !testing.expect(t, b == 0x3c) {break}
	}
	testing.expect(t, !port.loc_font_copy(0x8542, 0x2000))

	port.loc_reset()
	testing.expect(t, port.loc_fonts_load([]string{path, path}), "identical duplicate packs")
}

@(test)
runtime_font_pack_rejects_malformed_and_conflicting_records :: proc(t: ^testing.T) {
	sync.mutex_lock(&loc_test_mutex)
	defer sync.mutex_unlock(&loc_test_mutex)
	context.allocator = context.temp_allocator
	base :: "tests\\runtime_localization\\runtime_bad_font_fixture"
	path :: base + "\\font.bin"
	if !testing.expect(t, !os.exists(base), "font fixture path must not already exist") {return}
	if !testing.expect(t, os.make_directory_all(base) == nil) {return}
	defer os.remove_all(base)
	defer port.loc_reset()

	check_bad :: proc(t: ^testing.T, path: string, data: []u8) {
		port.loc_reset()
		if !testing.expect(t, os.write_entire_file(path, data) == nil) {return}
		testing.expect(t, !port.loc_fonts_load([]string{path}))
		encoded, missing := port.loc_encode(test_font_text(), false, context.temp_allocator)
		testing.expect(t, missing == 2 && encoded[0] == '?' && encoded[2] == '?')
	}

	check_bad(t, path, []u8{'n', 'o', 't', ' ', 'a', ' ', 'p', 'a', 'c', 'k'})
	valid := test_font_pack([]Test_Font_Record{{codepoint = 0x00e9, code = 0x8540, fill = 1}})
	check_bad(t, path, valid[:len(valid) - 1])
	check_bad(t, path, test_font_pack([]Test_Font_Record{{codepoint = 0x00e9, code = 0x8140, fill = 1}}))
	check_bad(t, path, test_font_pack([]Test_Font_Record{{codepoint = 0x00e9, code = 0x8540, flags = 1, fill = 1}}))
	check_bad(t, path, test_font_pack([]Test_Font_Record{
		{codepoint = 0x00e9, code = 0x8540, fill = 1},
		{codepoint = 0x00e9, code = 0x8541, fill = 1},
	}))
	check_bad(t, path, test_font_pack([]Test_Font_Record{
		{codepoint = 0x00e9, code = 0x8540, fill = 1},
		{codepoint = 0x00ea, code = 0x8540, fill = 1},
	}))
}
