package runtime_localization_test

import "core:os"
import "core:sync"
import "core:testing"
import port "game:src"
import "ps:core"
import mem "ps:ps2/mem"

// The original compiled getters add an entry's stored offset to the table.
test_guest_entry :: proc(table, index: u32) -> u32 {
	base := mem.rd32(port.STR_DATA + 4 * table)
	offset := mem.rd32(base + 4 * index)
	return u32((u64(base) + u64(offset)) & 0xffff_ffff)
}

@(test)
shadow_tables_preserve_disc_fallback_and_attributes :: proc(t: ^testing.T) {
	sync.mutex_lock(&loc_test_mutex)
	defer sync.mutex_unlock(&loc_test_mutex)
	defer port.loc_reset()
	path :: "tests\\runtime_localization\\runtime_shadow_fixture.csv"
	if !testing.expect(t, !os.exists(path), "shadow fixture path must not already exist") {return}
	defer os.remove(path)
	csv := "key,en\nt00.0003,Translated\nt06.0001,New menu\n"
	if !testing.expect(t, os.write_entire_file(path, transmute([]u8)csv) == nil) {return}
	if !testing.expect(t, port.loc_load(path, "en", true)) {return}
	if !testing.expect(t, mem.mod_ram == nil) {return}

	old_ram := mem.ram
	mem.ram = make([]u8, mem.RAM_SIZE, core.long_allocator())
	defer {
		port.loc_reset()
		delete(mem.ram, core.long_allocator())
		mem.ram = old_ram
	}
	base0 := u32(0x10000)
	mem.wr32(port.STR_DATA, base0)
	attributes := [?]u8{'0', '2', '3', '0'}
	for i in u32(0) ..< 4 {
		mem.wr32(base0 + 4 * i, 16 + 16 * i)
		rec := base0 + 16 + 16 * i
		mem.ram[rec + 0] = 'A'
		mem.ram[rec + 1] = 'B'
		mem.ram[rec + 2] = attributes[i]
		mem.ram[rec + 3], mem.ram[rec + 4], mem.ram[rec + 5] = '0', '0', '0'
		mem.ram[rec + 6], mem.ram[rec + 7], mem.ram[rec + 8] = 0x82, 0xa0, 0
	}
	base6 := u32(0x11000)
	mem.wr32(port.STR_DATA + 4 * 6, base6)
	mem.wr32(base6, 8)
	mem.wr32(base6 + 4, 16)
	copy(mem.ram[base6 + 8:], "disc0")
	copy(mem.ram[base6 + 16:], "disc1")
	port.loc_rebuild_tables(true)

	// A direct getter sees both substitutions and original unmodified records.
	record0 := test_guest_entry(0, 0)
	record1 := test_guest_entry(0, 1)
	record2 := test_guest_entry(0, 2)
	record3 := test_guest_entry(0, 3)
	testing.expect(t, mem.rd8(record0 + 2) == '1')
	testing.expect(t, record1 == base0 + 32 && mem.rd8(record1 + 2) == '2')
	testing.expect(t, record2 == base0 + 48 && mem.rd8(record2 + 2) == '3')
	testing.expect(t, mem.rd8(record3 + 2) == '1' && mem.rd8(record3 + 6) == 'T')
	testing.expect(t, test_guest_entry(6, 0) == base6 + 8)
	testing.expect(t, mem.rd8(test_guest_entry(6, 1)) == 'N')
}
