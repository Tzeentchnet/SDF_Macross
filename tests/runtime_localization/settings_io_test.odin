package runtime_localization_test

import "core:os"
import "core:strings"
import "core:testing"
import port "game:src"
import "ps:core"

@(test)
settings_apply_preserves_runtime_options :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base :: "tests\\runtime_localization\\runtime_settings_fixture"
	global_dir :: base + "\\global"
	repo_dir :: base + "\\repo"
	player_dir :: base + "\\player"
	if !testing.expect(t, !os.exists(base), "settings fixture path must not already exist") {return}
	if !testing.expect(t, os.make_directory_all(global_dir) == nil) {return}
	defer os.remove_all(base)
	if !testing.expect(t, os.make_directory_all(repo_dir) == nil) {return}
	if !testing.expect(t, os.make_directory_all(player_dir) == nil) {return}

	names := [?]string{
		"DATA", "SW", "SCALE", "IRX", "NATIVE", "LOC", "LANG", "SUBTITLES",
		"FULLSCREEN", "LAUNCHER", "HEADLESS",
	}
	old: [len(names)]string
	present: [len(names)]bool
	for name, i in names {
		full_name := core.env_name(name)
		old[i], present[i] = os.lookup_env(full_name, context.temp_allocator)
		os.unset_env(full_name)
	}
	defer for name, i in names {
		full_name := core.env_name(name)
		if present[i] {_ = os.set_env(full_name, old[i])} else {os.unset_env(full_name)}
	}
	testing.expect(t, os.set_env(core.env_name("DATA"), global_dir) == nil)
	testing.expect(t, os.set_env(core.env_name("NATIVE"), "1") == nil)
	global := "SW\t1\nSCALE\t5\nIRX\t1\nNATIVE\t0\nLOC\tglobal\n"
	repository := "SCALE\t1\nIRX\t1\nNATIVE\t0\nLOC\trepository\n"
	player := "SW\t0\nIRX\t0\nLOC\tlocal\nUNKNOWN\tkeep\n"
	if !testing.expect(t, os.write_entire_file(global_dir + "\\settings.tsv", transmute([]u8)global) == nil) {return}
	if !testing.expect(t, os.write_entire_file(repo_dir + "\\settings.tsv", transmute([]u8)repository) == nil) {return}
	if !testing.expect(t, os.write_entire_file(player_dir + "\\settings.tsv", transmute([]u8)player) == nil) {return}
	l := port.Local{root = repo_dir, data = player_dir}
	cfg := port.config_load(l)
	testing.expect(t, cfg.loc == "local" && cfg.scale == 1 && !cfg.software)
	testing.expect(t, port.config_apply(l, cfg))
	testing.expect(t, core.env("SW") == "0")
	testing.expect(t, core.env("SCALE") == "1")
	testing.expect(t, core.env("IRX") == "0")
	testing.expect(t, core.env("NATIVE") == "1")

	cfg.fullscreen = true
	long_loc := make([]u8, core.SETTING_MAX + 1, context.temp_allocator)
	for &b in long_loc {b = 'x'}
	cfg.loc = string(long_loc) // An untouched inherited value is not serialized.
	cfg.dirty += {.Fullscreen}
	testing.expect(t, port.config_save(l, cfg))
	saved, err := os.read_entire_file(player_dir + "\\settings.tsv", context.temp_allocator)
	if testing.expect(t, err == nil) {
		testing.expect(t, strings.contains(string(saved), "IRX\t0\n"))
		testing.expect(t, strings.contains(string(saved), "UNKNOWN\tkeep\n"))
		testing.expect(t, strings.contains(string(saved), "LOC\tlocal\n"))
		testing.expect(t, strings.contains(string(saved), "FULLSCREEN\t1\n"))
		testing.expect(t, !strings.contains(string(saved), "SCALE\t"))
		testing.expect(t, !strings.contains(string(saved), "NATIVE\t"))
	}
	cfg.dirty = {.Loc}
	testing.expect(t, !port.config_save(l, cfg))
	after, read_err := os.read_entire_file(player_dir + "\\settings.tsv", context.temp_allocator)
	testing.expect(t, read_err == nil && string(after) == string(saved))
	compat := port.config_load(l, false)
	testing.expect(t, compat.loc == "" && !compat.fullscreen)
}
