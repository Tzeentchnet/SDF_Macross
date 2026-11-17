package runtime_localization_test

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import port "game:src"

loc_test_mutex: sync.Mutex

@(test)
settings_layering_and_defaults :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	global := port.config_parse("SW\t1\nSCALE\t5\nUPSCALER\tlinear\nLOC\tglobal\n", context.temp_allocator)
	repository := port.config_parse("SW\t0\nSCALE\t1\nUPSCALER\tfsr1\nLOC\trepository\nSYSTEM_EN\t1\n", context.temp_allocator)
	local := port.config_parse("SCALE\t2\nLOC\tlocal\n", context.temp_allocator)
	env := port.config_parse("LOC\t\n", context.temp_allocator)
	c := port.config_resolve(local, repository, global, env, false)
	testing.expect(t, !c.software && c.source[.Sw] == .Repository)
	testing.expect(t, c.scale == 2 && c.source[.Scale] == .Local)
	testing.expect(t, c.upscaler == .Fsr1 && c.source[.Upscaler] == .Repository)
	testing.expect(t, c.loc == "" && c.source[.Loc] == .Environment)
	testing.expect(t, c.system_english && c.source[.System_English] == .Repository)
	testing.expect(t, c.launcher)

	c = port.config_resolve({}, repository, global, {}, false)
	testing.expect(t, c.scale == 1 && c.source[.Scale] == .Repository)
	c = port.config_resolve({}, {}, global, {}, false)
	testing.expect(t, c.scale == 5 && c.software && c.upscaler == .Linear)
	c = port.config_resolve({}, {}, {}, {}, false)
	testing.expect(t, c.scale == 1 && !c.software && c.upscaler == .Fsr1 && !c.system_english)
	c = port.config_resolve({}, {}, {}, {}, true)
	testing.expect(t, c.scale == 1)

	// A set but invalid environment value still blocks inherited values.
	env = port.config_parse("SCALE\t0\n", context.temp_allocator)
	c = port.config_resolve({}, repository, global, env, false)
	testing.expect(t, c.scale == 1 && c.source[.Scale] == .Environment)
	c = port.config_resolve({}, repository, global, env, true)
	testing.expect(t, c.scale == 1 && c.source[.Scale] == .Environment)
}

@(test)
launcher_render_presets_and_mouse_arrows :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := port.CONFIG_DEFAULT
	testing.expect(t, port.render_preset(&c) == .Performance)

	port.change_render_preset(&c, 1)
	testing.expect(t, port.render_preset(&c) == .Balanced)
	testing.expect(t, c.scale == 2 && c.upscaler == .Fsr1)
	testing.expect(t, .Scale in c.dirty && .Upscaler in c.dirty)

	port.change_render_preset(&c, 1)
	testing.expect(t, port.render_preset(&c) == .Quality)
	testing.expect(t, c.scale == 3 && c.upscaler == .Linear)

	c.scale, c.upscaler = 8, .Linear
	c.dirty = {}
	testing.expect(t, port.render_preset(&c) == .Custom)
	port.change_render_preset(&c, -1)
	testing.expect(t, port.render_preset(&c) == .Quality)
	testing.expect(t, .Scale in c.dirty && .Upscaler in c.dirty)

	testing.expect(t, port.launcher_arrow_direction(port.LAUNCHER_LEFT_ARROW_X) == -1)
	testing.expect(t, port.launcher_arrow_direction(port.LAUNCHER_RIGHT_ARROW_X) == 1)
	middle := (port.LAUNCHER_LEFT_ARROW_X + port.LAUNCHER_RIGHT_ARROW_X) / 2
	testing.expect(t, port.launcher_arrow_direction(middle) == 0)

	system := port.Loc_Mod{id = port.SYSTEM_MOD_ID, name = "English system messages only"}
	testing.expect(t, !port.launcher_text_mod(system))
	multilingual := port.Loc_Mod{name = "Multilingual localization", languages = []string{"en", "fr"}}
	testing.expect(t, port.launcher_text_label(multilingual, "en") == "[en] en")

	legacy := port.CONFIG_DEFAULT
	legacy.loc, legacy.lang = port.SYSTEM_MOD_ID, "en"
	port.launcher_migrate_system_selection(&legacy)
	testing.expect(t, legacy.loc == "" && legacy.lang == "" && legacy.system_english)
	testing.expect(t, .Loc in legacy.dirty && .Lang in legacy.dirty && .System_English in legacy.dirty)
}

@(test)
settings_parser_and_non_destructive_save :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "SCALE\t1\nSCALE\t8\nUPSCALER\tlinear\nSYSTEM_EN\t0\nSW\t1\textra\nSW\t0\nIRX\t0\nNATIVE\t0\nUNKNOWN\tx\n"
	rows := port.config_parse(text, context.temp_allocator)
	testing.expect(t, rows.value[.Scale] == "1")
	testing.expect(t, rows.value[.Sw] == "0")
	c := port.config_resolve(rows, {}, {}, {}, false)
	c.scale = 4
	c.upscaler = .Fsr1
	c.system_english = true
	c.dirty += {.Scale, .Upscaler, .System_English}
	saved := port.config_serialize(text, c, context.temp_allocator)
	testing.expect(t, strings.contains(saved, "IRX\t0\n"))
	testing.expect(t, strings.contains(saved, "NATIVE\t0\n"))
	testing.expect(t, strings.contains(saved, "UNKNOWN\tx\n"))
	testing.expect(t, strings.contains(saved, "SW\t1\textra\nSW\t0\n"))
	testing.expect(t, !strings.contains(saved, "SCALE\t1\n"))
	testing.expect(t, !strings.contains(saved, "SCALE\t8\n"))
	testing.expect(t, strings.contains(saved, "SCALE\t4\n"))
	testing.expect(t, strings.contains(saved, "UPSCALER\tfsr1\n"))
	testing.expect(t, strings.contains(saved, "SYSTEM_EN\t1\n"))
	testing.expect(t, !strings.contains(saved, "SYSTEM_EN\t0\n"))
	testing.expect(t, !strings.contains(saved, "LOC\t"))
}

@(test)
include_order_missing_dependencies_and_cycles :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	mods := [4]port.Loc_Mod{
		{id = "base"},
		{id = "left", includes = []string{"base"}},
		{id = "right", includes = []string{"base"}},
		{id = "top", includes = []string{"left", "right"}},
	}
	chain, ok := port.loc_mod_chain(mods[3], mods[:], context.temp_allocator)
	if testing.expect(t, ok && len(chain) == 4) {
		testing.expect(t, chain[0].id == "base" && chain[1].id == "left")
		testing.expect(t, chain[2].id == "right" && chain[3].id == "top")
	}
	missing := port.Loc_Mod{id = "missing", includes = []string{"not-installed"}}
	_, ok = port.loc_mod_chain(missing, mods[:], context.temp_allocator)
	testing.expect(t, !ok)
	cycle := [2]port.Loc_Mod{
		{id = "one", includes = []string{"two"}},
		{id = "two", includes = []string{"one"}},
	}
	_, ok = port.loc_mod_chain(cycle[0], cycle[:], context.temp_allocator)
	testing.expect(t, !ok)
	malformed := port.Loc_Mod{id = "broken", problem = "bad header"}
	_, ok = port.loc_mod_chain(malformed, mods[:], context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
keys_subtitles_and_reserved_regions :: proc(t: ^testing.T) {
	for lang in ([]string{"es-MX", "pt-BR", "zh-Hans", "fr", "de", "hu", "uk"}) {
		testing.expect(t, port.loc_language_id(lang), lang)
	}
	for lang in ([]string{"", "-fr", "fr-", "zh--Hans", "pt_BR", "français", "a/b"}) {
		testing.expect(t, !port.loc_language_id(lang), lang)
	}
	key, exe, ok := port.loc_key("t01.0042")
	testing.expect(t, ok && !exe && key == 0x0001_002a)
	key, exe, ok = port.loc_key("exe.003cab08")
	testing.expect(t, ok && exe && key == 0x003c_ab08)
	for invalid in ([]string{"t11.0", "t01.65536", "t1", "exe.100000000", "exe.", "t-1.0"}) {
		_, _, ok = port.loc_key(invalid)
		testing.expect(t, !ok, invalid)
	}
	testing.expect(t, port.loc_subtitle_attribute('0', true, true) == '1')
	testing.expect(t, port.loc_subtitle_attribute('0', true, false) == '0')
	testing.expect(t, port.loc_subtitle_attribute('0', false, true) == '0')
	testing.expect(t, port.loc_subtitle_attribute('1', true, true) == '1')
	testing.expect(t, port.loc_subtitle_attribute('2', true, true) == '2')
	testing.expect(t, port.loc_subtitle_attribute('3', true, true) == '3')

	ours: [16]u8
	other: [16]u8
	testing.expect(t, port.loc_region_can_use(nil, nil, 16))
	testing.expect(t, !port.loc_region_can_use(other[:], nil, 16))
	testing.expect(t, !port.loc_region_can_use(other[:], ours[:], 16))
	testing.expect(t, port.loc_region_can_use(ours[:], ours[:], 16))
	testing.expect(t, !port.loc_region_can_use(ours[:8], ours[:], 16))
	testing.expect(t, !port.loc_region_can_use(nil, nil, 0))
}

@(test)
overlay_extent_arithmetic :: proc(t: ^testing.T) {
	testing.expect(t, port.overlay_span_fits(5, 5, 10))
	testing.expect(t, !port.overlay_span_fits(5, 6, 10))
	testing.expect(t, !port.overlay_span_fits(max(u64) - 1, 4, max(u64)))
	testing.expect(t, port.overlay_spans_overlap(10, 4, 13, 5))
	testing.expect(t, port.overlay_spans_overlap(13, 5, 10, 4))
	testing.expect(t, !port.overlay_spans_overlap(10, 4, 14, 5))
	testing.expect(t, !port.overlay_spans_overlap(10, 0, 10, 5))
	testing.expect(t, port.overlay_spans_overlap(max(u64) - 1, 4, max(u64), 1))
}

@(test)
csv_errors_are_reported_without_partial_replacements :: proc(t: ^testing.T) {
	sync.mutex_lock(&loc_test_mutex)
	defer sync.mutex_unlock(&loc_test_mutex)
	defer port.loc_reset()
	path := "tests\\runtime_localization\\runtime_csv_fixture.csv"
	if !testing.expect(t, !os.exists(path), "fixture path must not already exist") {return}
	defer os.remove(path)
	valid := "key,en,notes\nt01.0042,First,\nt01.0043,,\n"
	if !testing.expect(t, os.write_entire_file(path, transmute([]u8)valid) == nil) {return}
	langs, ok := port.loc_languages(path, context.temp_allocator)
	testing.expect(t, ok && len(langs) == 1 && langs[0] == "en")
	testing.expect(t, port.loc_load(path, "en", true))
	testing.expect(t, !port.loc_load(path, "notes", true))
	bytes, found := port.loc_translation(0x0001_002a, false)
	testing.expect(t, found && string(bytes) == "First")
	_, found = port.loc_translation(0x0001_002b, false)
	testing.expect(t, !found)

	bad := "key,en,notes\nt01.0042,Changed,\nt01.0044,\"unterminated"
	if !testing.expect(t, os.write_entire_file(path, transmute([]u8)bad) == nil) {return}
	testing.expect(t, !port.loc_load(path, "en", true))
	bytes, found = port.loc_translation(0x0001_002a, false)
	testing.expect(t, found && string(bytes) == "First")
	_, found = port.loc_translation(0x0001_002c, false)
	testing.expect(t, !found)

	invalid_untranslated := "key,en\nnot-a-key,\n"
	if !testing.expect(t, os.write_entire_file(path, transmute([]u8)invalid_untranslated) == nil) {return}
	testing.expect(t, !port.loc_load(path, "en", true))
	bytes, found = port.loc_translation(0x0001_002a, false)
	testing.expect(t, found && string(bytes) == "First")

	short_row := "key,en\nt01.0042\n"
	if !testing.expect(t, os.write_entire_file(path, transmute([]u8)short_row) == nil) {return}
	testing.expect(t, !port.loc_load(path, "en", true))

	duplicate_row := "key,en\nt01.0042,\nt01.0042,Changed\n"
	if !testing.expect(t, os.write_entire_file(path, transmute([]u8)duplicate_row) == nil) {return}
	testing.expect(t, !port.loc_load(path, "en", true))

	duplicate := "key,en,en\nt01.0042,a,b\n"
	if !testing.expect(t, os.write_entire_file(path, transmute([]u8)duplicate) == nil) {return}
	_, ok = port.loc_languages(path, context.temp_allocator)
	testing.expect(t, !ok && !port.loc_load(path, "en", true))
}

@(test)
project_system_table_loads_with_missing_key_fallback :: proc(t: ^testing.T) {
	sync.mutex_lock(&loc_test_mutex)
	defer sync.mutex_unlock(&loc_test_mutex)
	defer port.loc_reset()
	system_path :: "localization\\en-system\\strings.csv"
	langs, ok := port.loc_languages(system_path, context.temp_allocator)
	testing.expect(t, ok && len(langs) == 1 && langs[0] == "en")
	text_path :: "tests\\runtime_localization\\runtime_system_overlay_fixture.csv"
	text := "key,es-MX\nt00.0000,Historia\nexe.003cab08,Aceptar\n"
	if !testing.expect(t, os.write_entire_file(text_path, transmute([]u8)text) == nil) {return}
	defer os.remove(text_path)
	tables := [2]port.Loc_Table{
		{path = text_path, lang = "es-MX", ascii_punct = true},
		{path = system_path, lang = "en", ascii_punct = true},
	}
	testing.expect(t, port.loc_tables_load(tables[:]))
	bytes, found := port.loc_translation(0x003c_ab08, true)
	testing.expect(t, found && string(bytes) == "OK")
	bytes, found = port.loc_translation(0, false)
	testing.expect(t, found && string(bytes) == "Historia")
	_, found = port.loc_translation(0x003c_79e0, true)
	testing.expect(t, !found)
}

@(test)
printf_argument_conversions :: proc(t: ^testing.T) {
	as_bytes :: proc(s: string) -> []u8 {return transmute([]u8)s}
	testing.expect(t, port.same_conversions(as_bytes("%s: %02d%%"), as_bytes("%s: %d%%")))
	testing.expect(t, !port.same_conversions(as_bytes("%s %d"), as_bytes("%d %s")))
	testing.expect(t, !port.same_conversions(as_bytes("%s"), as_bytes("no argument")))
	testing.expect(t, !port.same_conversions(as_bytes("%s"), as_bytes("%*s")))
	testing.expect(t, !port.same_conversions(as_bytes("%ld"), as_bytes("%ls")))
	testing.expect(t, !port.same_conversions(as_bytes("%ld"), as_bytes("%lld")))
	testing.expect(t, port.same_conversions(as_bytes("%*.*s"), as_bytes("%*.*s")))
	testing.expect(t, !port.same_conversions(as_bytes("%"), as_bytes("%")))
}
