package runtime_localization_test

import "core:os"
import "core:testing"
import port "game:src"
import "ps:core/disc"

TEST_SECTOR :: 2048

test_both32 :: proc(b: []u8, at: int, n: u32) {
	for i in 0 ..< 4 {
		b[at + i] = u8(n >> (8 * uint(i)))
		b[at + 7 - i] = u8(n >> (8 * uint(i)))
	}
}

test_le32 :: proc(b: []u8, at: int) -> u32 {
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}

test_be32 :: proc(b: []u8, at: int) -> u32 {
	return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}

test_record :: proc(b: []u8, at: int, name: string, lba, size: u32, dir: bool) -> int {
	length := 33 + len(name) + int(len(name) % 2 == 0)
	b[at] = u8(length)
	test_both32(b, at + 2, lba)
	test_both32(b, at + 10, size)
	b[at + 25] = dir ? 2 : 0
	b[at + 28], b[at + 31] = 1, 1
	b[at + 32] = u8(len(name))
	copy(b[at + 33:], name)
	return at + length
}

test_volume :: proc(image: []u8, base, size, root: int) {
	pvd := image[(base + 16) * TEST_SECTOR:][:TEST_SECTOR]
	pvd[0], pvd[6] = 1, 1
	copy(pvd[1:6], "CD001")
	test_both32(pvd, 80, u32(size))
	dot: [1]u8
	test_record(pvd, 156, string(dot[:]), u32(root), TEST_SECTOR, true)
	terminator := image[(base + 17) * TEST_SECTOR:][:TEST_SECTOR]
	terminator[0], terminator[6] = 255, 1
	copy(terminator[1:6], "CD001")
}

test_image :: proc() -> []u8 {
	image := make([]u8, 200 * TEST_SECTOR, context.temp_allocator)
	test_volume(image, 0, 200, 20)
	test_volume(image, 35, 57, 20)
	dot: [1]u8
	parent := [1]u8{1}
	outer := image[20 * TEST_SECTOR:][:TEST_SECTOR]
	at := test_record(outer, 0, string(dot[:]), 20, TEST_SECTOR, true)
	at = test_record(outer, at, string(parent[:]), 20, TEST_SECTOR, true)
	at = test_record(outer, at, "JPN.CVM;1", 32, 60 * TEST_SECTOR, false)
	at = test_record(outer, at, "ETC.CVM;1", 100, 50 * TEST_SECTOR, false)
	test_record(outer, at, "TAIL.BIN;1", 160, TEST_SECTOR, false)
	inner := image[55 * TEST_SECTOR:][:TEST_SECTOR]
	at = test_record(inner, 0, string(dot[:]), 20, TEST_SECTOR, true)
	at = test_record(inner, at, string(parent[:]), 20, TEST_SECTOR, true)
	at = test_record(inner, at, "TEST.BIN;1", 25, 1500, false)
	test_record(inner, at, "OTHER.BIN;1", 26, TEST_SECTOR, false)
	copy(image[32 * TEST_SECTOR:], "CVMH")
	for i in 0 ..< 4 {
		image[32 * TEST_SECTOR + 32 + i] = u8(u32(60 * TEST_SECTOR) >> (8 * uint(3 - i)))
	}
	for &b in image[53 * TEST_SECTOR:55 * TEST_SECTOR] {b = 0x44}
	for &b in image[56 * TEST_SECTOR:60 * TEST_SECTOR] {b = 0x44}
	for &b in image[62 * TEST_SECTOR:92 * TEST_SECTOR] {b = 0x44}
	for &b in image[60 * TEST_SECTOR:60 * TEST_SECTOR + 1500] {b = 0x11}
	for &b in image[61 * TEST_SECTOR:62 * TEST_SECTOR] {b = 0x22}
	image[100 * TEST_SECTOR] = 0x7f // adjacent container header is not free
	return image
}

@(test)
disc_hook_in_place_relocation_and_failures :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base :: "tests\\runtime_localization\\runtime_overlay_fixture"
	image_path :: base + "\\disc.iso"
	other_path :: base + "\\other.iso"
	mod :: base + "\\mod"
	files :: mod + "\\files\\JPN.CVM"
	replacement :: files + "\\TEST.BIN"
	if !testing.expect(t, !os.exists(base), "overlay fixture path must not already exist") {return}
	if !testing.expect(t, os.make_directory_all(files) == nil) {return}
	defer os.remove_all(base)
	defer port.overlay_reset()
	image := test_image()
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	if !testing.expect(t, os.write_entire_file(other_path, image) == nil) {return}
	small := make([]u8, 1300, context.temp_allocator)
	for &b in small {b = 0xa5}
	if !testing.expect(t, os.write_entire_file(replacement, small) == nil) {return}
	if !testing.expect(t, port.overlay_install(image_path, []string{mod})) {return}
	d, opened := disc.open(image_path)
	if !testing.expect(t, opened && d.volume == 200) {return}
	block: [TEST_SECTOR]u8
	testing.expect(t, disc.read(&d, 60, block[:]))
	testing.expect(t, block[0] == 0xa5 && block[1299] == 0xa5 && block[1300] == 0)
	testing.expect(t, disc.read(&d, 55, block[:]))
	testing.expect(t, test_le32(block[:], 68 + 10) == 1300)
	testing.expect(t, disc.read(&d, 61, block[:]) && block[0] == 0x22)
	testing.expect(t, !port.overlay_read(&d, 60, block[:], false))
	other, other_opened := disc.open(other_path)
	if testing.expect(t, other_opened) {
		testing.expect(t, disc.read(&other, 60, block[:]) && block[0] == 0x11)
		disc.close(&other)
	}
	disc.close(&d)
	port.overlay_reset()

	large := make([]u8, 3 * TEST_SECTOR, context.temp_allocator)
	for &b in large {b = 0x5a}
	if !testing.expect(t, os.write_entire_file(replacement, large) == nil) {return}
	if !testing.expect(t, port.overlay_install(image_path, []string{mod})) {return}
	d, opened = disc.open(image_path)
	if !testing.expect(t, opened) {return}
	testing.expect(t, disc.read(&d, 100, block[:]) && block[0] == 0x7f)
	testing.expect(t, disc.read(&d, 92, block[:]) && block[0] == 0x5a)
	testing.expect(t, disc.read(&d, 55, block[:]))
	testing.expect(t, test_le32(block[:], 68 + 2) == 92 - 35)
	testing.expect(t, test_le32(block[:], 68 + 10) == u32(len(large)))
	testing.expect(t, disc.read(&d, 51, block[:]) && test_le32(block[:], 80) == 60)
	testing.expect(t, disc.read(&d, 32, block[:]) && test_be32(block[:], 32) == 63 * TEST_SECTOR)
	testing.expect(t, disc.read(&d, 20, block[:]) && test_le32(block[:], 68 + 10) == 63 * TEST_SECTOR)
	writable, open_err := os.open(replacement, {.Write})
	if testing.expect(t, open_err == nil) {
		testing.expect(t, os.truncate(writable, 1) == nil)
		os.close(writable)
		testing.expect(t, !disc.read(&d, 92, block[:]))
	}
	disc.close(&d)
	port.overlay_reset()

	// A zero-filled gap in the existing CVM can be reused without growing it.
	image = test_image()
	for &b in image[57 * TEST_SECTOR:60 * TEST_SECTOR] {b = 0}
	if !testing.expect(t, os.write_entire_file(replacement, large) == nil) {return}
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	if !testing.expect(t, port.overlay_install(image_path, []string{mod})) {return}
	d, opened = disc.open(image_path)
	if !testing.expect(t, opened) {return}
	testing.expect(t, disc.read(&d, 55, block[:]) && test_le32(block[:], 68 + 2) == 57 - 35)
	testing.expect(t, disc.read(&d, 57, block[:]) && block[0] == 0x5a)
	testing.expect(t, disc.read(&d, 60, block[:]) && block[0] == 0x11)
	disc.close(&d)
	port.overlay_reset()
	image = test_image()

	// Independent replacements cannot reserve the same inner zero-filled gap.
	for &b in image[57 * TEST_SECTOR:60 * TEST_SECTOR] {b = 0}
	other_replacement :: files + "\\OTHER.BIN"
	other_data := make([]u8, 3 * TEST_SECTOR, context.temp_allocator)
	for &b in other_data {b = 0x6a}
	if !testing.expect(t, os.write_entire_file(other_replacement, other_data) == nil) {return}
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	if !testing.expect(t, port.overlay_install(image_path, []string{mod})) {return}
	d, opened = disc.open(image_path)
	if !testing.expect(t, opened) {return}
	if testing.expect(t, disc.read(&d, 55, block[:])) {
		testing.expect(t, test_le32(block[:], 112 + 2) == 57 - 35)
		testing.expect(t, test_le32(block[:], 68 + 2) == 92 - 35)
	}
	testing.expect(t, disc.read(&d, 57, block[:]) && block[0] == 0x6a)
	testing.expect(t, disc.read(&d, 92, block[:]) && block[0] == 0x5a)
	disc.close(&d)
	port.overlay_reset()
	os.remove(other_replacement)
	image = test_image()

	missing :: files + "\\MISSING.BIN"
	if !testing.expect(t, os.write_entire_file(missing, small) == nil) {return}
	testing.expect(t, !port.overlay_install(image_path, []string{mod}))
	testing.expect(t, disc.read_hook == nil)
	os.remove(missing)
	bad_mod :: base + "\\bad_mod"
	if !testing.expect(t, os.make_directory_all(bad_mod) == nil) {return}
	if !testing.expect(t, os.write_entire_file(bad_mod + "\\files", small) == nil) {return}
	testing.expect(t, !port.overlay_install(image_path, []string{bad_mod}))
	testing.expect(t, disc.read_hook == nil)
	// Relocation must not expand the container across unrelated ISO files.
	test_both32(image[20 * TEST_SECTOR:][:TEST_SECTOR], 152 + 2, 94)
	if !testing.expect(t, os.write_entire_file(replacement, large) == nil) {return}
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	testing.expect(t, !port.overlay_install(image_path, []string{mod}))
	testing.expect(t, disc.read_hook == nil)
	image = test_image()
	image[92 * TEST_SECTOR] = 0x55
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	testing.expect(t, !port.overlay_install(image_path, []string{mod}))
	testing.expect(t, disc.read_hook == nil)
	image = test_image()
	outer := image[20 * TEST_SECTOR:][:TEST_SECTOR]
	test_record(outer, 196, "SUBDIR", 21, TEST_SECTOR, true)
	dot: [1]u8
	parent := [1]u8{1}
	outer_subdir := image[21 * TEST_SECTOR:][:TEST_SECTOR]
	at := test_record(outer_subdir, 0, string(dot[:]), 21, TEST_SECTOR, true)
	at = test_record(outer_subdir, at, string(parent[:]), 20, TEST_SECTOR, true)
	test_record(outer_subdir, at, "NESTED.BIN;1", 94, TEST_SECTOR, false)
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	testing.expect(t, !port.overlay_install(image_path, []string{mod}))
	testing.expect(t, disc.read_hook == nil)
	image = test_image()
	image[32 * TEST_SECTOR] = 0
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	testing.expect(t, !port.overlay_install(image_path, []string{mod}))
	testing.expect(t, disc.read_hook == nil)
	image = test_image()
	// A file extent pointing into its own directory is never overwritten.
	test_both32(image[55 * TEST_SECTOR:][:TEST_SECTOR], 68 + 2, 20)
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	testing.expect(t, !port.overlay_install(image_path, []string{mod}))
	testing.expect(t, disc.read_hook == nil)

	// Nonzero unallocated sectors must not be used for in-place growth.
	image = test_image()
	test_both32(image[55 * TEST_SECTOR:][:TEST_SECTOR], 112 + 2, 28)
	for &b in image[63 * TEST_SECTOR:64 * TEST_SECTOR] {b = 0x22}
	growing := make([]u8, 2200, context.temp_allocator)
	for &b in growing {b = 0x33}
	if !testing.expect(t, os.write_entire_file(replacement, growing) == nil) {return}
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	if !testing.expect(t, port.overlay_install(image_path, []string{mod})) {return}
	d, opened = disc.open(image_path)
	if !testing.expect(t, opened) {return}
	testing.expect(t, disc.read(&d, 55, block[:]) && test_le32(block[:], 68 + 2) == 92 - 35)
	testing.expect(t, disc.read(&d, 61, block[:]) && block[0] == 0x22)
	testing.expect(t, disc.read(&d, 92, block[:]) && block[0] == 0x33)
	disc.close(&d)
	port.overlay_reset()

	// A zero-filled nested file is still allocated and may not be overwritten.
	image = test_image()
	inner := image[55 * TEST_SECTOR:][:TEST_SECTOR]
	test_both32(inner, 112 + 2, 28)
	test_record(inner, 156, "SUBDIR", 21, TEST_SECTOR, true)
	inner_subdir := image[56 * TEST_SECTOR:][:TEST_SECTOR]
	for &b in inner_subdir {b = 0}
	at = test_record(inner_subdir, 0, string(dot[:]), 21, TEST_SECTOR, true)
	at = test_record(inner_subdir, at, string(parent[:]), 20, TEST_SECTOR, true)
	test_record(inner_subdir, at, "NESTED.BIN;1", 26, TEST_SECTOR, false)
	for &b in image[61 * TEST_SECTOR:62 * TEST_SECTOR] {b = 0}
	for &b in image[63 * TEST_SECTOR:64 * TEST_SECTOR] {b = 0x22}
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	if !testing.expect(t, port.overlay_install(image_path, []string{mod})) {return}
	d, opened = disc.open(image_path)
	if !testing.expect(t, opened) {return}
	testing.expect(t, disc.read(&d, 55, block[:]) && test_le32(block[:], 68 + 2) == 92 - 35)
	testing.expect(t, disc.read(&d, 61, block[:]) && block[0] == 0)
	testing.expect(t, disc.read(&d, 92, block[:]) && block[0] == 0x33)
	disc.close(&d)
	port.overlay_reset()

	// Likewise, leave nonzero bytes beyond the original file's end untouched.
	image = test_image()
	image[60 * TEST_SECTOR + 1500] = 0x5b
	if !testing.expect(t, os.write_entire_file(replacement, small) == nil) {return}
	if !testing.expect(t, os.write_entire_file(image_path, image) == nil) {return}
	if !testing.expect(t, port.overlay_install(image_path, []string{mod})) {return}
	d, opened = disc.open(image_path)
	if !testing.expect(t, opened) {return}
	testing.expect(t, disc.read(&d, 55, block[:]) && test_le32(block[:], 68 + 2) == 92 - 35)
	testing.expect(t, disc.read(&d, 60, block[:]) && block[1500] == 0x5b)
	testing.expect(t, disc.read(&d, 92, block[:]) && block[0] == 0xa5)
	disc.close(&d)
	port.overlay_reset()
}
