// Runtime localization: the game's text replaced from a CSV table as the
// game asks for it, with no change to the disc image.
//
// Every BOOTDAT string the game shows is fetched through two functions
// (docs/localization.md has the evidence):
//
//   STR_GetDcFontString(table, index)     -> pointer to the text
//   STR_GetDcFontStringAttr(table, index) -> pointer to the record, whose
//                                            6-byte id precedes the text
//
// over 11 tables that STR_Init points str_data at. Tables 0..5 begin each
// entry with a 6-character id (speaker/priority, display attribute, index);
// tables 6..10 are plain string pools. Shadow offset tables and replacement
// strings live in the EE mod region. The original getters therefore also
// see replacements when generated code calls them directly.
//
// Supported system messages in the executable are patched in place when
// the game's main() starts; they are limited to their original slots.
//
// Subtitles: byte 2 of a record's id is its display attribute. With
// subtitles on, attribute '0' becomes '1' for Japanese voiced prose;
// attributes '2' and '3' retain their distinct meanings.
package main

import "core:crypto/sha2"
import "core:encoding/csv"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "ps:core"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"

// Addresses in SLPM_654.05 (SLPM-65405, executable SHA-1 84ff167e...).
STR_INIT :: 0x001a1510
STR_GET :: 0x001a1640
STR_GET_ATTR :: 0x001a1600
GAME_MAIN :: 0x002f33c0
// The 11 table pointers STR_Init fills.
STR_DATA :: 0x004292a0
// str_dummy_attr ($gp - 0x7c28): what STR_GetDcFontStringAttr returns for a
// pool table.
STR_DUMMY_ATTR :: 0x003cc7c8
// Where main_InitGui loads the decompressed BOOTDAT.CMP; the string bank is
// its first MRG entry. Export reports offsets from here, which are the file
// offsets the external translation tooling keys its JSON by.
BOOTDAT_BUF :: 0x00585e60

STR_TABLES :: 11
// Tables below this begin each entry with a 6-byte id.
STR_ID_TABLES :: 6
STR_ID :: 6
// Tables 0..4 hold voiced records; SND_GetAdxFid maps (table, index) to the
// voice AFS entry index + VOICE_BASE[table].
VOICE_TABLES :: 5
VOICE_BASE := [VOICE_TABLES]u32{0x1c6, 0x2a8, 0x897, 0x923, 0}

// The executable's own Shift-JIS strings (memory card, save/load, HDD,
// network adaptor, controller calibration, dialog buttons, tutorial
// hints): every string literal the compiler emitted with Japanese in it.
// Each slot runs to the next literal's symbol (@NNN in .symtab), so a
// replacement may use the alignment padding but must stay shorter than the
// slot. Some hold printf conversions (%s) that a translation must keep.
Exe_String :: struct {
	addr, slot: u32,
}
EXE_STRINGS := [?]Exe_String {
	{0x003b9408, 24}, {0x003c79e0, 128}, {0x003c8590, 32}, {0x003c85c0, 32},
	{0x003c85f0, 80}, {0x003c8660, 112}, {0x003c8730, 32}, {0x003c8780, 192},
	{0x003c8880, 64}, {0x003c8990, 64}, {0x003c8a00, 96}, {0x003c8ab0, 96},
	{0x003c8b60, 32}, {0x003c8b80, 32}, {0x003c8ba0, 64}, {0x003c8c20, 96},
	{0x003c8cc0, 48}, {0x003c8d20, 112}, {0x003c8dd0, 64}, {0x003c8e10, 80},
	{0x003c8e60, 112}, {0x003c8f20, 24}, {0x003c8f50, 96}, {0x003c9010, 32},
	{0x003c9040, 96}, {0x003c9100, 112}, {0x003c9170, 112}, {0x003c91e0, 48},
	{0x003c9230, 48}, {0x003c9280, 24}, {0x003c92b0, 32}, {0x003c92f0, 96},
	{0x003c93b0, 64}, {0x003c9410, 64}, {0x003c9470, 32}, {0x003c94b0, 32},
	{0x003c94f0, 112}, {0x003c95c0, 32}, {0x003c95e0, 32}, {0x003c9600, 32},
	{0x003c9640, 144}, {0x003c9700, 48}, {0x003c9750, 64}, {0x003c97e0, 160},
	{0x003c98e0, 160}, {0x003c99f0, 96}, {0x003c9aa0, 272}, {0x003c9bb0, 144},
	{0x003c9c40, 80}, {0x003c9c90, 32}, {0x003c9cb0, 48}, {0x003c9ce0, 80},
	{0x003c9d30, 96}, {0x003c9d90, 128}, {0x003c9e10, 64}, {0x003c9e50, 96},
	{0x003c9eb0, 48}, {0x003c9ee0, 80}, {0x003c9f30, 80}, {0x003c9f80, 80},
	{0x003c9fd0, 128}, {0x003ca050, 112}, {0x003ca0c0, 176}, {0x003ca170, 80},
	{0x003ca1c0, 144}, {0x003ca250, 64}, {0x003ca2d0, 80}, {0x003ca380, 64},
	{0x003ca400, 80}, {0x003ca4b0, 80}, {0x003ca550, 64}, {0x003ca5b0, 48},
	{0x003ca610, 48}, {0x003ca640, 112}, {0x003ca6b0, 160}, {0x003ca750, 64},
	{0x003ca7e0, 112}, {0x003ca850, 80}, {0x003ca8d0, 48}, {0x003ca900, 160},
	{0x003ca9a0, 8}, {0x003ca9c8, 8}, {0x003caa50, 32}, {0x003caa88, 24},
	{0x003caaa0, 32}, {0x003caac0, 32}, {0x003caae0, 16}, {0x003caaf0, 24},
	{0x003cab08, 8}, {0x003cab18, 8}, {0x003cab28, 8}, {0x003cab38, 8},
	{0x003cab48, 8}, {0x003cab58, 16}, {0x003cab70, 16}, {0x003cab80, 16},
	{0x003cab90, 16}, {0x003caba0, 16}, {0x003cabb0, 16}, {0x003cabc0, 16},
	{0x003cabd0, 16}, {0x003cabe0, 16}, {0x003cabf0, 16}, {0x003cac50, 8},
	{0x003caca0, 8}, {0x003cbb90, 32}, {0x003cbbb0, 48}, {0x003cbbe0, 48},
	{0x003cbc10, 32},
}

// Room for the replacement strings, in the mod region. BOOTDAT's whole
// string bank is about 160 KiB of Shift-JIS; English runs about twice that.
LOC_REGION :: 4 << 20

// Reserved CSV columns; every other column is a language.
LOC_RESERVED := [?]string{"key", "offset", "speaker", "caption", "voice", "shared", "max_bytes", "notes", "context"}

Loc_Table :: struct {
	path:        string,
	ascii_punct: bool,
}

Loc :: struct {
	// A text replacement for (table << 16 | index), Shift-JIS.
	text:      map[u32][]u8,
	// A replacement for an executable string, by address.
	exe:       map[u32][]u8,
	subtitles: bool,
	// The guest address of an entry's buffer once built (0: the entry is
	// served from BOOTDAT unchanged). Cleared when STR_Init runs again.
	built:     map[u32]u32,
	next:      u32, // next free byte of the region, an offset
	region:    []u8,
	table:     [STR_TABLES]u32,
	count:     [STR_TABLES]u32,
	// The original STR_Init and main, called by their wrappers.
	str_init:  cpu.Func_Proc,
	game_main: cpu.Func_Proc,
	// --export-strings: where to write the base table; the run exits after.
	export:    string,
}

@(private = "file")
loc: Loc

loc_translation :: proc(key: u32, exe: bool) -> (bytes: []u8, found: bool) {
	if exe {return loc.exe[key]}
	return loc.text[key]
}

// Only call after the guest has stopped using the shadow tables.
loc_reset :: proc() {
	if loc.region != nil && mem.mod_ram != nil && raw_data(loc.region) == raw_data(mem.mod_ram) {
		mem.mod_ram = nil
		delete(loc.region, core.long_allocator())
	}
	for _, bytes in loc.text {delete(bytes, core.long_allocator())}
	for _, bytes in loc.exe {delete(bytes, core.long_allocator())}
	delete(loc.text)
	delete(loc.exe)
	delete(loc.built)
	loc = {}
}

// The addresses and generated functions below are specific to this exact
// executable, not merely to a disc whose name resembles its serial.
loc_verify_revision :: proc() -> bool {
	name, _, ok := iop.disc_boot(context.temp_allocator)
	if !ok || !strings.equal_fold(name, "SLPM_654.05") {
		fmt.eprintln("loc: SYSTEM.CNF does not name the supported SLPM_654.05 executable")
		return false
	}
	exe, read := iop.disc_file(name, context.temp_allocator, false)
	if !read || len(exe) != 4262380 {
		fmt.eprintln("loc: cannot read the supported executable at its expected size")
		return false
	}
	hash: [sha2.DIGEST_SIZE_256]u8
	hasher: sha2.Context_256
	sha2.init_256(&hasher)
	sha2.update(&hasher, exe)
	sha2.final(&hasher, hash[:])
	expected := [sha2.DIGEST_SIZE_256]u8{
		0x5e, 0x51, 0xcf, 0x5e, 0xcb, 0x8f, 0x34, 0x4c,
		0xca, 0xb9, 0x0f, 0x7d, 0x99, 0xdf, 0x04, 0xff,
		0x05, 0x0f, 0xad, 0xba, 0x02, 0x55, 0x79, 0xe4,
		0x36, 0x9c, 0x4a, 0xbe, 0x0e, 0xbe, 0x75, 0xa1,
	}
	if hash != expected {
		fmt.eprintln("loc: executable SHA-256 does not match the supported SLPM-65405 revision")
		return false
	}
	return true
}

// The language columns a strings.csv offers, read from its header.
loc_languages :: proc(csv_path: string, allocator := context.allocator) -> ([]string, bool) {
	text, err := os.read_entire_file(csv_path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("loc: cannot read %s: %v", csv_path, err)
		return nil, false
	}
	header, _, rerr := csv.read_from_string(strings.trim_prefix(string(text), "\xef\xbb\xbf"), context.temp_allocator, context.temp_allocator)
	if rerr != nil {
		fmt.eprintfln("loc: malformed CSV header in %s: %v", csv_path, rerr)
		return nil, false
	}
	out := make([dynamic]string, allocator)
	key_found := false
	cols: for h, i in header {
		name := strings.trim_space(h)
		if name == "" {
			fmt.eprintfln("loc: empty CSV column name in %s", csv_path)
			return nil, false
		}
		for earlier in header[:i] {
			if strings.equal_fold(strings.trim_space(earlier), name) {
				fmt.eprintfln("loc: duplicate CSV column %q in %s", name, csv_path)
				return nil, false
			}
		}
		for r in LOC_RESERVED {
			if strings.equal_fold(r, name) {
				if strings.equal_fold(name, "key") {
					key_found = true
				}
				continue cols
			}
		}
		append(&out, strings.clone(name, allocator))
	}
	if !key_found {
		fmt.eprintfln("loc: %s has no key column", csv_path)
		return nil, false
	}
	return out[:], true
}

// Parse a CSV key: "t01.0042" (table 1, index 42) or "exe.003c79e0".
loc_key :: proc(k: string) -> (key: u32, exe: bool, ok: bool) {
	k := strings.trim_space(k)
	if strings.has_prefix(k, "exe.") {
		if len(k) <= 4 || len(k) > 12 {return}
		v, vok := strconv.parse_u64_of_base(k[4:], 16)
		if !vok || v > u64(max(u32)) {return}
		return u32(v), true, true
	}
	if len(k) < 4 || k[0] != 't' {return}
	t_str, _, i_str := strings.partition(k[1:], ".")
	t, tok := strconv.parse_uint(t_str, 10)
	i, iok := strconv.parse_uint(i_str, 10)
	if !tok || !iok || t >= STR_TABLES || i > 0xffff {return}
	return u32(t) << 16 | u32(i), false, true
}

// Turn a cell's text into what the game shows: "\n" written out as two
// characters becomes a line break, and CRLF from a spreadsheet becomes LF.
@(private = "file")
loc_cell :: proc(s: string) -> string {
	s, _ := strings.replace_all(s, "\r\n", "\n", context.temp_allocator)
	s, _ = strings.replace_all(s, "\\n", "\n", context.temp_allocator)
	return s
}

// Load one complete table transactionally. A missing key falls back to the
// disc; malformed rows or CSV syntax are not silently accepted.
loc_load :: proc(csv_path, lang: string, ascii_punct: bool) -> bool {
	context.allocator = core.long_allocator()
	if lang == "" {
		fmt.eprintfln("loc: %s: no language column selected", csv_path)
		return false
	}
	for reserved in LOC_RESERVED {
		if strings.equal_fold(lang, reserved) {
			fmt.eprintfln("loc: %s: %q is a metadata column, not a language", csv_path, lang)
			return false
		}
	}
	text, err := os.read_entire_file(csv_path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("loc: cannot read %s: %v", csv_path, err)
		return false
	}
	r: csv.Reader
	csv.reader_init_with_string(&r, strings.trim_prefix(string(text), "\xef\xbb\xbf"))
	defer csv.reader_destroy(&r)
	header, herr := csv.read(&r, context.temp_allocator)
	if herr != nil {
		fmt.eprintfln("loc: malformed CSV header in %s: %v", csv_path, herr)
		return false
	}
	key_col, lang_col := -1, -1
	for h, i in header {
		name := strings.trim_space(h)
		if name == "" {
			fmt.eprintfln("loc: empty CSV column name in %s", csv_path)
			return false
		}
		for earlier in header[:i] {
			if strings.equal_fold(strings.trim_space(earlier), name) {
				fmt.eprintfln("loc: duplicate CSV column %q in %s", name, csv_path)
				return false
			}
		}
		if strings.equal_fold(name, "key") {key_col = i}
		if strings.equal_fold(name, lang) {lang_col = i}
	}
	if key_col < 0 || lang_col < 0 {
		fmt.eprintfln("loc: %s has no 'key' column or no '%s' column", csv_path, lang)
		return false
	}
	staged_text, staged_exe: map[u32][]u8
	success := false
	defer {
		if !success {
			for _, bytes in staged_text {delete(bytes)}
			for _, bytes in staged_exe {delete(bytes)}
		}
		delete(staged_text)
		delete(staged_exe)
	}
	rows, missing := 0, 0
	seen_text := make(map[u32]bool, context.temp_allocator)
	seen_exe := make(map[u32]bool, context.temp_allocator)
	for {
		rec, rerr := csv.read(&r, context.temp_allocator)
		if csv.is_io_error(rerr, .EOF) {break}
		if rerr != nil {
			fmt.eprintfln("loc: malformed CSV in %s after %d rows: %v", csv_path, rows, rerr)
			return false
		}
		key, exe, ok := loc_key(rec[key_col])
		if !ok {
			fmt.eprintfln("loc: %s has an invalid key %q", csv_path, rec[key_col])
			return false
		}
		if exe {
			known := false
			for e in EXE_STRINGS {if e.addr == key {known = true; break}}
			if !known {
				fmt.eprintfln("loc: %s: unknown executable key %q", csv_path, rec[key_col])
				return false
			}
			if key in seen_exe {
				fmt.eprintfln("loc: %s: duplicate key %q", csv_path, rec[key_col])
				return false
			}
			seen_exe[key] = true
		} else {
			if key in seen_text {
				fmt.eprintfln("loc: %s: duplicate key %q", csv_path, rec[key_col])
				return false
			}
			seen_text[key] = true
		}
		if rec[lang_col] == "" {continue}
		if strings.contains(rec[lang_col], "\x00") {
			fmt.eprintfln("loc: %s: %q contains a NUL character", csv_path, rec[key_col])
			return false
		}
		bytes, miss := sjis_encode(loc_cell(rec[lang_col]), ascii_punct)
		missing += miss
		if exe {
			staged_exe[key] = bytes
		} else {
			staged_text[key] = bytes
		}
		rows += 1
	}
	for key, bytes in staged_text {
		if old, ok := loc.text[key]; ok {delete(old)}
		loc.text[key] = bytes
	}
	for key, bytes in staged_exe {
		if old, ok := loc.exe[key]; ok {delete(old)}
		loc.exe[key] = bytes
	}
	success = true
	fmt.eprintfln("loc: %d strings from %s (%s)%s", rows, csv_path, lang,
		missing > 0 ? fmt.tprintf(", %d characters with no Shift-JIS form shown as '?'", missing) : "")
	return true
}

// Install the hooks once the generated functions are registered.
loc_install :: proc(tables: []Loc_Table, lang: string, subtitles: bool, export: string) -> bool {
	context.allocator = core.long_allocator()
	loc.subtitles = subtitles
	loc.export = export
	if lang != "" && export == "" {
		for table in tables {
			if !loc_load(table.path, lang, table.ascii_punct) {return false}
		}
	}
	if len(loc.text) == 0 && len(loc.exe) == 0 && !subtitles && export == "" {
		return true
	}
	when core.FLAT {
		fmt.eprintln("loc: localization hooks are unavailable in a FLAT build")
		return false
	}
	for addr in ([?]u32{STR_INIT, STR_GET, STR_GET_ATTR, GAME_MAIN}) {
		if cpu.lookup(addr) == nil {
			fmt.eprintfln("loc: required SLPM-65405 hook address %08x is not recompiled", addr)
			return false
		}
	}
	loc.str_init = cpu.lookup(STR_INIT)
	loc.game_main = cpu.lookup(GAME_MAIN)
	cpu.register(STR_INIT, loc_str_init)
	cpu.register(GAME_MAIN, loc_main)
	return true
}

// main(): the executable's strings are in RAM and nothing has shown yet.
@(private = "file")
loc_main :: proc() {
	if len(loc.exe) > 0 {
		patched := 0
		for e in EXE_STRINGS {
			bytes, ok := loc_translation(e.addr, true)
			if !ok {continue}
			if u32(len(bytes)) >= e.slot {
				fmt.eprintfln("loc: exe.%08x is %d bytes; its slot holds %d. Left as on the disc.", e.addr, len(bytes), e.slot - 1)
				continue
			}
			// The game passes some of these to printf: a translation with
			// other conversions would read the wrong arguments.
			if !same_conversions(transmute([]u8)mem.read_cstring(e.addr), bytes) {
				fmt.eprintfln("loc: exe.%08x does not keep the original's %%-conversions in order. Left as on the disc.", e.addr)
				continue
			}
			dst := mem.ram_slice(e.addr, e.slot)
			copy(dst, bytes)
			for &b in dst[len(bytes):] {b = 0}
			patched += 1
		}
		unknown := len(loc.exe) - patched
		fmt.eprintfln("loc: patched %d executable strings%s", patched,
			unknown > 0 ? fmt.tprintf(" (%d rows not applied)", unknown) : "")
	}
	loc.game_main()
}

// Whether a and b consume the same printf arguments in the same order.
// Shift-JIS trail bytes are never '%', so a byte scan is safe.
same_conversions :: proc(a, b: []u8) -> bool {
	Conversion :: struct {
		verb:           u8,
		length:         [2]u8,
		width_argument: bool,
		prec_argument:  bool,
	}
	next :: proc(s: []u8, i: ^int) -> (conv: Conversion, found, valid: bool) {
		for i^ < len(s) {
			c := s[i^]
			i^ += 1
			if c != '%' {continue}
			if i^ >= len(s) {return {}, false, false}
			if s[i^] == '%' {i^ += 1; continue}
			for i^ < len(s) && strings.index_byte("-+ #0'", s[i^]) >= 0 {i^ += 1}
			if i^ < len(s) && s[i^] == '*' {
				conv.width_argument = true
				i^ += 1
			} else {
				for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {i^ += 1}
			}
			if i^ < len(s) && s[i^] == '.' {
				i^ += 1
				if i^ < len(s) && s[i^] == '*' {
					conv.prec_argument = true
					i^ += 1
				} else {
					for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {i^ += 1}
				}
			}
			if i^ < len(s) && strings.index_byte("hljztL", s[i^]) >= 0 {
				conv.length[0] = s[i^]
				i^ += 1
				if i^ < len(s) && (conv.length[0] == 'h' || conv.length[0] == 'l') && s[i^] == conv.length[0] {
					conv.length[1] = s[i^]
					i^ += 1
				}
			}
			if i^ >= len(s) || strings.index_byte("diuoxXfFeEgGaAcspn", s[i^]) < 0 {
				return {}, false, false
			}
			conv.verb = s[i^]
			i^ += 1
			return conv, true, true
		}
		return {}, false, true
	}
	i, j := 0, 0
	for {
		ca, found_a, valid_a := next(a, &i)
		cb, found_b, valid_b := next(b, &j)
		if !valid_a || !valid_b || found_a != found_b || ca != cb {return false}
		if !found_a {return true}
	}
}

@(private = "file")
loc_str_init :: proc() {
	loc.str_init()
	loc_rebuild_tables(loc.subtitles)
}

// Build shadow tables from the original table pointers after STR_Init.
loc_rebuild_tables :: proc(subtitles: bool) {
	context.allocator = core.long_allocator()
	loc.subtitles = subtitles
	clear(&loc.built)
	loc.next = 0
	for t in u32(0) ..< STR_TABLES {
		base := mem.rd32(STR_DATA + 4 * t)
		loc.table[t], loc.count[t] = base, 0
		if base == 0 {continue}
		if base & 3 != 0 || u64(base) + 4 > mem.RAM_SIZE {
			cpu.fatal("loc: invalid string table %d at %08x", t, base)
		}
		first := mem.rd32(base)
		if first & 3 != 0 || first / 4 > 0x10000 || u64(base) + u64(first) > mem.RAM_SIZE {
			cpu.fatal("loc: invalid string table %d size %08x", t, first)
		}
		loc.count[t] = first / 4
	}
	if loc.export != "" {
		ok := loc_export(loc.export)
		os.exit(ok ? 0 : 1)
	}
	// Report keys that name no entry: a table made for another revision, or
	// a typo.
	stray := 0
	for key in loc.text {
		t, i := key >> 16, key & 0xffff
		if i >= str_count(t) {stray += 1}
	}
	if stray > 0 {fmt.eprintfln("loc: %d keys name no string in the game's tables", stray)}

	// Some generated functions call the original getter directly, bypassing
	// the dispatch table. Shadow the affected offset tables instead, leaving
	// their original entries and all missing-key fallbacks untouched.
	for t in u32(0) ..< STR_TABLES {
		needed := loc.subtitles && t < VOICE_TABLES
		for key in loc.text {
			if key >> 16 == t && key & 0xffff < str_count(t) {needed = true; break}
		}
		if !needed || str_count(t) == 0 {continue}
		at := loc_reserve(int(str_count(t)) * 4)
		shadow := u32(mem.MOD_BASE) + at
		for i in u32(0) ..< str_count(t) {
			target := loc_entry(t, i)
			if target == 0 {target = str_entry(t, i)}
			delta := u32((u64(target) + (u64(1) << 32) - u64(shadow)) & 0xffff_ffff)
			(^u32le)(&loc.region[at + 4 * i])^ = u32le(delta)
		}
		mem.wr32(STR_DATA + 4 * t, shadow)
	}
}

// Table t's base address, and its entry count (the first offset / 4).
@(private = "file")
str_table :: proc(t: u32) -> u32 {return t < STR_TABLES ? loc.table[t] : 0}

@(private = "file")
str_count :: proc(t: u32) -> u32 {
	return t < STR_TABLES ? loc.count[t] : 0
}

// The address of entry (t, i) as on the disc: the record (id first) for a
// table with ids.
@(private = "file")
str_entry :: proc(t, i: u32) -> u32 {
	base := str_table(t)
	if base == 0 || i >= str_count(t) {return 0}
	offset := mem.rd32(base + 4 * i)
	if offset < str_count(t) * 4 || u64(base) + u64(offset) >= mem.RAM_SIZE {
		cpu.fatal("loc: string table %d entry %d is outside EE RAM", t, i)
	}
	addr := base + offset
	if t < STR_ID_TABLES && u64(addr) + STR_ID > mem.RAM_SIZE {
		cpu.fatal("loc: string table %d entry %d has a truncated id", t, i)
	}
	return addr
}

// Existing mod RAM is usable only when it is this localization's own
// allocation; its size alone does not establish that the space is free.
loc_region_can_use :: proc(existing, owned: []u8, wanted: int) -> bool {
	if wanted <= 0 || wanted > mem.MOD_REGION {return false}
	if existing == nil {return owned == nil}
	return owned != nil && raw_data(existing) == raw_data(owned) && len(existing) >= wanted
}

@(private = "file")
loc_region :: proc() -> []u8 {
	if !loc_region_can_use(mem.mod_ram, loc.region, LOC_REGION) {
		cpu.fatal("loc: the reserved EE localization region overlaps another mod")
	}
	if loc.region == nil {
		mem.mod_ram = make([]u8, LOC_REGION)
		loc.region = mem.mod_ram
	}
	return loc.region
}

@(private = "file")
loc_reserve :: proc(size: int) -> u32 {
	region := loc_region()
	at := loc.next
	if size < 0 || u64(at) + u64(size) > u64(len(region)) {
		cpu.fatal("loc: replacement tables and text exceed %d bytes", LOC_REGION)
	}
	loc.next = (at + u32(size) + 3) &~ 3
	return at
}

loc_subtitle_attribute :: proc(attribute: u8, enabled, japanese: bool) -> u8 {
	if enabled && japanese && attribute == '0' {return '1'}
	return attribute
}

// The buffer entry (t, i) is served from, built on first use; 0 for an
// entry served from BOOTDAT unchanged.
@(private = "file")
loc_entry :: proc(t, i: u32) -> u32 {
	if t >= STR_TABLES || i >= str_count(t) {return 0}
	key := t << 16 | i
	if a, done := loc.built[key]; done {return a}
	text, replaced := loc_translation(key, false)
	ids := t < STR_ID_TABLES
	rec := str_entry(t, i)
	id: [STR_ID]u8
	orig_text := rec
	if ids {
		copy(id[:], mem.ram_slice(rec, STR_ID))
		orig_text += STR_ID
	}
	caption := loc.subtitles && t < VOICE_TABLES && id[2] == '0' &&
		sjis_has_japanese(transmute([]u8)mem.read_cstring(orig_text))
	if !replaced && !caption {
		loc.built[key] = 0
		return 0
	}
	id[2] = loc_subtitle_attribute(id[2], loc.subtitles, caption)
	if !replaced {text = transmute([]u8)mem.read_cstring(orig_text)}
	region := loc_region()
	size := (ids ? STR_ID : 0) + len(text) + 1
	at := loc_reserve(size)
	n := 0
	if ids {n += copy(region[at:], id[:])}
	n += copy(region[int(at) + n:], text)
	region[int(at) + n] = 0
	addr := u32(mem.MOD_BASE) + at
	loc.built[key] = addr
	return addr
}

// Write every string the game has, as loaded from the disc, to a CSV: the
// base table translators work from. It holds the publisher's script, so it
// belongs in ignored local storage, never in a repository or a mod.
@(private = "file")
loc_export :: proc(path: string) -> bool {
	sb := strings.builder_make()
	strings.write_string(&sb, "\xef\xbb\xbf") // spreadsheets read UTF-8 with a BOM
	w: csv.Writer
	csv.writer_init(&w, strings.to_writer(&sb))
	csv.write(&w, {"key", "offset", "speaker", "caption", "voice", "shared", "max_bytes", "ja", "notes"})
	first: map[u32]string // entry address -> first key that uses it
	defer delete(first)
	rows := 0
	for t in u32(0) ..< STR_TABLES {
		for i in u32(0) ..< str_count(t) {
			key := fmt.tprintf("t%02d.%04d", t, i)
			rec := str_entry(t, i)
			text_at := rec
			speaker, caption, voice, shared := "", "", "", ""
			if t < STR_ID_TABLES {
				text_at += STR_ID
				if t < VOICE_TABLES {
					id := mem.ram_slice(rec, STR_ID)
					printable := true
					for b in id {printable &&= b >= 0x20 && b < 0x7f}
					// The last entry of some tables is padding, not a record.
					speaker = printable ? strings.clone(string(id), context.temp_allocator) : ""
					caption = !printable ? "" : id[2] == '1' || id[2] == '3' ? "1" : "0"
					voice = fmt.tprintf("%d", VOICE_BASE[t] + i)
				}
			}
			if k, seen := first[rec]; seen {
				shared = k
			} else {
				first[rec] = strings.clone(key)
			}
			ja := sjis_decode(transmute([]u8)mem.read_cstring(text_at), context.temp_allocator)
			csv.write(&w, {key, fmt.tprintf("%06x", rec - BOOTDAT_BUF), speaker, caption, voice, shared, "", ja, ""})
			rows += 1
		}
	}
	for e in EXE_STRINGS {
		ja := sjis_decode(transmute([]u8)mem.read_cstring(e.addr), context.temp_allocator)
		csv.write(&w, {fmt.tprintf("exe.%08x", e.addr), "", "", "", "", "", fmt.tprintf("%d", e.slot - 1), ja, ""})
		rows += 1
	}
	csv.writer_flush(&w)
	if dir := filepath.dir(path); dir != "" && !os.exists(dir) {
		os.make_directory_all(dir)
	}
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(sb)); err != nil {
		fmt.eprintfln("loc: cannot write %s: %v", path, err)
		return false
	}
	fmt.eprintfln("loc: exported %d strings to %s", rows, path)
	return true
}
