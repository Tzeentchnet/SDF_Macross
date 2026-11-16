package runtime_localization_test

import "core:os"
import "core:path/filepath"
import "core:testing"
import port "game:src"

@(test)
direct_start_discovers_only_selected_mod_and_includes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root :: "tests\\runtime_localization\\runtime_discovery_fixture"
	parent :: root + "\\localization"
	if !testing.expect(t, !os.exists(root), "discovery fixture path must not already exist") {return}
	if !testing.expect(t, os.make_directory_all(parent + "\\base") == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(t, os.make_directory_all(parent + "\\top") == nil) {return}
	if !testing.expect(t, os.make_directory_all(parent + "\\unselected") == nil) {return}
	if !testing.expect(t, os.make_directory_all(parent + "\\bad") == nil) {return}
	table := "key,en\nt00.0000,Test\n"
	for name in ([]string{"base", "top", "unselected", "bad"}) {
		path, _ := filepath.join({parent, name, "strings.csv"}, context.temp_allocator)
		if !testing.expect(t, os.write_entire_file(path, transmute([]u8)table) == nil) {return}
	}
	manifest := "key\tvalue\ninclude\tbase\n"
	if !testing.expect(t, os.write_entire_file(parent + "\\top\\mod.tsv", transmute([]u8)manifest) == nil) {return}
	mods := port.loc_mods(root, "top", context.temp_allocator)
	if testing.expect(t, len(mods) == 2) {
		testing.expect(t, mods[0].id == "base" && mods[1].id == "top")
		chain, ok := port.loc_mod_chain(mods[1], mods, context.temp_allocator)
		testing.expect(t, ok && len(chain) == 2 && chain[0].id == "base" && chain[1].id == "top")
	}
	bad_manifest := "ascii_punctuation\tperhaps\n"
	if !testing.expect(t, os.write_entire_file(parent + "\\bad\\mod.tsv", transmute([]u8)bad_manifest) == nil) {return}
	bad := port.loc_mods(root, "bad", context.temp_allocator)
	if testing.expect(t, len(bad) == 1 && bad[0].problem != "") {
		_, ok := port.loc_mod_chain(bad[0], bad, context.temp_allocator)
		testing.expect(t, !ok)
	}
	if !testing.expect(t, os.write_entire_file(parent + "\\not-a-directory", []u8{'x'}) == nil) {return}
	not_dir := port.loc_mods(root, "not-a-directory", context.temp_allocator)
	if testing.expect(t, len(not_dir) == 1 && not_dir[0].problem != "") {
		_, ok := port.loc_mod_chain(not_dir[0], not_dir, context.temp_allocator)
		testing.expect(t, !ok)
	}
	if !testing.expect(t, os.make_directory_all(parent + "\\broken\\strings.csv") == nil) {return}
	broken := port.loc_mods(root, "broken", context.temp_allocator)
	if testing.expect(t, len(broken) == 1 && broken[0].problem != "") {
		_, ok := port.loc_mod_chain(broken[0], broken, context.temp_allocator)
		testing.expect(t, !ok)
	}
}
