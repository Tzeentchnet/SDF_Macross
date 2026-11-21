// File overrides: a localization mod's files/<FILE> replace same-size files
// at the disc root, while files/<CVM>/<FILE> replace files inside the disc's
// CVM containers as the game reads them, without writing a new disc image.
// Used for art that holds Japanese text (title cards, menus: TIM2 textures
// inside JPN.CVM's .CMP files), and for audio.
//
// The runtime calls overlay_read through disc.read_hook after
// every read of the image's sectors. The overlay serves:
//
//   * replaced files' bytes over the sectors they occupy, and
//   * patched copies of the directory sectors that describe them (their
//     recorded size, and extent when moved, in both byte orders).
//
// A replacement that fits its extent is served in place. A larger one uses
// verified unallocated zero sectors in or immediately after its container.
// If needed, its volume and outer record grow to cover them. All patched
// ISO 9660 fields are written in both byte orders.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "ps:core"
import "ps:core/disc"

@(private = "file") SECTOR :: 2048
// A CVM's ISO 9660 volume starts 0x1800 bytes (3 sectors) into the file.
@(private = "file") CVM_ISO :: 3
// The CVMH header's big-endian total size of the .CVM.
@(private = "file") CVMH_SIZE :: 0x20
@(private = "file")
Region :: struct {
	lba, sectors: u32, // absolute sectors served
	file:         ^os.File, // the replacement's bytes from its start
	size:         i64, // bytes of it; the rest of the last sector is zero
	path:         string,
}

@(private = "file")
Entry :: struct {
	name:         string,
	lba:          u32, // extent: absolute for an outer file, inner for a CVM's
	size:         u32,
	record:       i64, // absolute byte offset of its directory record
	dir:          bool,
}

@(private = "file")
Span :: struct {
	lba, sectors: u32,
}

@(private = "file")
Volume :: struct {
	sectors:  u32,
	root:     Entry,
	metadata: [dynamic]Span,
}

@(private = "file")
ov: struct {
	image:      ^os.File,
	image_info: os.File_Info,
	image_size: u64,
	regions:    [dynamic]Region, // sorted by lba, disjoint
	patches:    map[u32][]u8, // whole-sector replacements
	lo, hi:     u32, // the sectors anything covers
	installed:  bool,
}

overlay_span_fits :: proc(start, length, limit: u64) -> bool {
	return start <= limit && length <= limit - start
}

overlay_spans_overlap :: proc(a, a_len, b, b_len: u64) -> bool {
	if a_len == 0 || b_len == 0 {return false}
	if a <= b {return b - a < a_len}
	return a - b < b_len
}

@(private = "file")
sectors_for :: proc(size: u32) -> u32 {
	return u32((u64(size) + SECTOR - 1) / SECTOR)
}

@(private = "file")
read_image :: proc(pos: i64, buf: []u8) -> bool {
	if pos < 0 || !overlay_span_fits(u64(pos), u64(len(buf)), ov.image_size) {return false}
	n, err := os.read_at(ov.image, buf, pos)
	return err == nil && n == len(buf)
}

@(private = "file")
le32 :: proc(b: []u8, o: int) -> u32 {return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24}

@(private = "file")
be32 :: proc(b: []u8, o: int) -> u32 {return u32(b[o]) << 24 | u32(b[o + 1]) << 16 | u32(b[o + 2]) << 8 | u32(b[o + 3])}

@(private = "file")
both32 :: proc(b: []u8, o: int) -> (u32, bool) {
	value := le32(b, o)
	return value, value == be32(b, o + 4)
}

@(private = "file")
put_both32 :: proc(b: []u8, o: int, v: u32) {
	for k in 0 ..< 4 {
		b[o + k] = u8(v >> (8 * uint(k)))
		b[o + 7 - k] = u8(v >> (8 * uint(k)))
	}
}

// The directory entries of the directory at absolute byte `base` + extent.
@(private = "file")
read_dir :: proc(base: i64, lba, size, volume: u32) -> (out: [dynamic]Entry, ok: bool) {
	if size == 0 || size > 64 << 20 || !overlay_span_fits(u64(lba), u64(sectors_for(size)), u64(volume)) {
		return nil, false
	}
	out = make([dynamic]Entry, context.temp_allocator)
	data := make([]u8, int(sectors_for(size)) * SECTOR, context.temp_allocator)
	read_image(base + i64(lba) * SECTOR, data) or_return
	for off := 0; off < int(size); {
		n := int(data[off])
		if n == 0 { // records do not cross sectors: on to the next
			off = (off / SECTOR + 1) * SECTOR
			continue
		}
		if n < 34 || off + n > int(size) || off % SECTOR + n > SECTOR {return nil, false}
		name_len := int(data[off + 32])
		if name_len == 0 || 33 + name_len > n {return nil, false}
		if data[off + 1] != 0 || data[off + 25] & 0x80 != 0 || data[off + 26] != 0 || data[off + 27] != 0 {
			return nil, false
		}
		raw := string(data[off + 33:][:name_len])
		if name_len == 1 && (raw[0] == 0 || raw[0] == 1) {
			off += n
			continue // . and ..
		}
		extent, extent_ok := both32(data, off + 2)
		bytes, bytes_ok := both32(data, off + 10)
		if !extent_ok || !bytes_ok || !overlay_span_fits(u64(extent), u64(sectors_for(bytes)), u64(volume)) {
			return nil, false
		}
		name, _, _ := strings.partition(raw, ";")
		append(&out, Entry{
			name = strings.to_upper(name, context.temp_allocator),
			lba = extent,
			size = bytes,
			record = base + i64(lba) * SECTOR + i64(off),
			dir = data[off + 25] & 2 != 0,
		})
		off += n
	}
	return out, true
}

// Include nested files as well as root entries when checking free sectors.
@(private = "file")
read_tree :: proc(base: i64, volume: Volume) -> (root, all: [dynamic]Entry, ok: bool) {
	pending := make([dynamic]Entry, context.temp_allocator)
	seen := make(map[u32]bool, context.temp_allocator)
	append(&pending, volume.root)
	seen[volume.root.lba] = true
	all = make([dynamic]Entry, context.temp_allocator)
	for cursor := 0; cursor < len(pending); cursor += 1 {
		dir := pending[cursor]
		entries, read_ok := read_dir(base, dir.lba, dir.size, volume.sectors)
		if !read_ok || len(all) + len(entries) > 1_000_000 {return nil, nil, false}
		if cursor == 0 {root = entries}
		for e in entries {
			append(&all, e)
			if e.dir {
				if e.lba in seen || len(pending) >= 4096 {return nil, nil, false}
				seen[e.lba] = true
				append(&pending, e)
			}
		}
	}
	return root, all, true
}

// The volume at absolute byte `base`, bounded by its containing file.
@(private = "file")
read_volume :: proc(base: i64, limit: u32) -> (volume: Volume, ok: bool) {
	if base < 0 || base % SECTOR != 0 || limit <= 16 {return}
	pvd: [SECTOR]u8
	read_image(base + 16 * SECTOR, pvd[:]) or_return
	if pvd[0] != 1 || string(pvd[1:6]) != "CD001" || pvd[6] != 1 || pvd[156] < 34 {return}
	sectors, sectors_ok := both32(pvd[:], 80)
	root_lba, root_lba_ok := both32(pvd[:], 156 + 2)
	root_size, root_size_ok := both32(pvd[:], 156 + 10)
	if !sectors_ok || !root_lba_ok || !root_size_ok || sectors <= 16 || sectors > limit ||
		root_size == 0 || pvd[156 + 25] & 2 == 0 ||
		pvd[156 + 1] != 0 || pvd[156 + 25] & 0x80 != 0 || pvd[156 + 26] != 0 || pvd[156 + 27] != 0 ||
		!overlay_span_fits(u64(root_lba), u64(sectors_for(root_size)), u64(sectors)) {
		return
	}
	volume.sectors = sectors
	volume.root = Entry{lba = root_lba, size = root_size, dir = true}
	volume.metadata = make([dynamic]Span, context.temp_allocator)
	append(&volume.metadata, Span{0, 16}, Span{root_lba, sectors_for(root_size)})
	terminated := false
	for index in u32(16) ..< min(sectors, u32(128)) {
		descriptor: [SECTOR]u8
		if !read_image(base + i64(index) * SECTOR, descriptor[:]) ||
			string(descriptor[1:6]) != "CD001" || descriptor[6] != 1 {
			return {}, false
		}
		append(&volume.metadata, Span{index, 1})
		if descriptor[0] == 255 {terminated = true; break}
	}
	if !terminated {return {}, false}
	path_size, path_ok := both32(pvd[:], 132)
	if !path_ok {return {}, false}
	for path_lba in ([?]u32{le32(pvd[:], 140), le32(pvd[:], 144), be32(pvd[:], 148), be32(pvd[:], 152)}) {
		if path_lba == 0 {continue}
		if path_size == 0 || !overlay_span_fits(u64(path_lba), u64(sectors_for(path_size)), u64(sectors)) {
			return {}, false
		}
		append(&volume.metadata, Span{path_lba, sectors_for(path_size)})
	}
	return volume, true
}

// The sector holding absolute byte `pos`, as patched so far.
@(private = "file")
patch_sector :: proc(pos: i64) -> (sec: []u8, at: int, ok: bool) {
	if pos < 0 || u64(pos) >= ov.image_size {return nil, 0, false}
	lba := u32(pos / SECTOR)
	if p, found := ov.patches[lba]; found {return p, int(pos % SECTOR), true}
	p := make([]u8, SECTOR)
	if !read_image(i64(lba) * SECTOR, p) {
		delete(p)
		return nil, 0, false
	}
	ov.patches[lba] = p
	return p, int(pos % SECTOR), true
}

// Set a directory record's extent and size (both byte orders).
@(private = "file")
patch_record :: proc(record: i64, lba, size: u32) -> bool {
	sec, at, ok := patch_sector(record)
	if !ok || at + 18 > SECTOR {return false}
	put_both32(sec, at + 2, lba)
	put_both32(sec, at + 10, size)
	return true
}

// The replacement files of a mod chain: CVM name -> file name -> host path.
// An empty CVM name holds same-size files at the outer ISO root. Later mods
// override earlier ones.
@(private = "file")
overlay_files :: proc(mod_dirs: []string) -> (map[string]map[string]string, bool) {
	context.allocator = context.temp_allocator
	out: map[string]map[string]string
	for dir in mod_dirs {
		files, _ := filepath.join({dir, "files"}, context.temp_allocator)
		info, stat_err := os.stat(files, context.temp_allocator)
		if stat_err == .Not_Exist {continue}
		if stat_err != nil {
			fmt.eprintln("overlay: cannot inspect", files, stat_err)
			return nil, false
		}
		if info.type != .Directory {
			fmt.eprintln("overlay: not a directory:", files)
			return nil, false
		}
		cvms, err := core.read_dir(files, context.temp_allocator)
		if err != nil {
			fmt.eprintln("overlay: cannot read", files, err)
			return nil, false
		}
		seen: map[string]bool
		for c in cvms {
			if !os.is_dir(c.fullpath) {
				name := strings.to_upper(c.name)
				key := fmt.tprintf("/%s", name)
				if key in seen {
					fmt.eprintln("overlay: duplicate case-insensitive replacement:", key)
					return nil, false
				}
				seen[key] = true
				if "" not_in out {out[""] = {}}
				replacements := &out[""]
				replacements[name] = strings.clone(c.fullpath)
				continue
			}
			cvm := strings.to_upper(c.name)
			inner, ierr := core.read_dir(c.fullpath, context.temp_allocator)
			if ierr != nil {
				fmt.eprintln("overlay: cannot read", c.fullpath, ierr)
				return nil, false
			}
			for f in inner {
				if os.is_dir(f.fullpath) {
					fmt.eprintln("overlay: nested replacement directories are not supported:", f.fullpath)
					return nil, false
				}
				name := strings.to_upper(f.name)
				key := fmt.tprintf("%s/%s", cvm, name)
				if key in seen {
					fmt.eprintln("overlay: duplicate case-insensitive replacement:", key)
					return nil, false
				}
				seen[key] = true
				if cvm not_in out {out[cvm] = {}}
				replacements := &out[cvm]
				replacements[name] = strings.clone(f.fullpath)
			}
		}
	}
	return out, true
}

// Release both a completed overlay and a failed, partially prepared one.
overlay_reset :: proc() {
	if ov.installed {disc.read_hook = nil}
	for r in ov.regions {
		if r.file != nil {os.close(r.file)}
		if r.path != "" {delete(r.path, core.long_allocator())}
	}
	delete(ov.regions)
	for _, bytes in ov.patches {delete(bytes, core.long_allocator())}
	delete(ov.patches)
	if ov.image != nil {os.close(ov.image)}
	if ov.image_info.fullpath != "" {os.file_info_delete(ov.image_info, core.long_allocator())}
	ov = {}
}

@(private = "file")
find_entry :: proc(entries: []Entry, name: string) -> (entry: Entry, found, unique: bool) {
	unique = true
	for e in entries {
		if e.name != name {continue}
		if found {return {}, true, false}
		entry, found = e, true
	}
	return
}

@(private = "file")
overlaps_metadata :: proc(start, length: u32, v: Volume) -> bool {
	for span in v.metadata {
		if overlay_spans_overlap(u64(start), u64(length), u64(span.lba), u64(span.sectors)) {return true}
	}
	return false
}

// Find a complete, verified zero-filled sector run in the permitted range.
@(private = "file")
find_zero_run :: proc(first, last, need: u32) -> (start: u32, found, read_ok: bool) {
	if need == 0 || first > last {return 0, false, false}
	buffer := make([]u8, 64 * SECTOR, core.long_allocator())
	defer delete(buffer, core.long_allocator())
	run, begin := u32(0), u32(0)
	for at := first; at < last; {
		count := min(u32(64), last - at)
		if !read_image(i64(at) * SECTOR, buffer[:int(count) * SECTOR]) {
			return 0, false, false
		}
		for i in u32(0) ..< count {
			zero := true
			for b in buffer[int(i) * SECTOR:][:SECTOR] {
				if b != 0 {zero = false; break}
			}
			if zero {
				if run == 0 {begin = at + i}
				run += 1
				if run == need {return begin, true, true}
			} else {
				run = 0
			}
		}
		at += count
	}
	return 0, false, true
}

// Zeroes inside a declared file are not free, including in subdirectories.
@(private = "file")
find_inner_run :: proc(base_lba: u32, volume: Volume, entries: []Entry, need: u32, occupied: ^[dynamic]Span) -> (u32, bool, bool) {
	clear(occupied)
	append(occupied, ..volume.metadata[:])
	for e in entries {
		if n := sectors_for(e.size); n > 0 {append(occupied, Span{e.lba, n})}
	}
	for r in ov.regions {
		if r.lba >= base_lba && overlay_span_fits(u64(r.lba - base_lba), u64(r.sectors), u64(volume.sectors)) {
			append(occupied, Span{r.lba - base_lba, r.sectors})
		}
	}
	slice.sort_by(occupied^[:], proc(a, b: Span) -> bool {return a.lba < b.lba})
	cursor := u32(0)
	for s in occupied^ {
		if s.lba > cursor && s.lba - cursor >= need {
			at, found, ok := find_zero_run(base_lba + cursor, base_lba + s.lba, need)
			if !ok {return 0, false, false}
			if found {return at - base_lba, true, true}
		}
		cursor = max(cursor, s.lba + s.sectors)
	}
	if volume.sectors - cursor >= need {
		at, found, ok := find_zero_run(base_lba + cursor, base_lba + volume.sectors, need)
		if !ok {return 0, false, false}
		if found {return at - base_lba, true, true}
	}
	return 0, false, true
}

// Set up atomically: any bad file, read, extent or overlap aborts boot
// rather than installing a partial overlay.
overlay_install :: proc(image: string, mod_dirs: []string) -> (success: bool) {
	context.allocator = core.long_allocator()
	files, files_ok := overlay_files(mod_dirs)
	if !files_ok {return false}
	if len(files) == 0 {return true}
	if ov.image != nil || ov.installed || disc.read_hook != nil {
		fmt.eprintln("overlay: a disc overlay or read hook is already installed")
		return false
	}
	if !strings.equal_fold(filepath.ext(image), ".iso") {
		fmt.eprintln("overlay: file replacements need a .iso image with 2048-byte sectors")
		return false
	}
	defer if !success {overlay_reset()}
	f, err := os.open(image)
	if err != nil {
		fmt.eprintln("overlay: cannot open", image, err)
		return false
	}
	ov.image = f
	size, size_err := os.file_size(f)
	if size_err != nil || size <= 0 || size % SECTOR != 0 || u64(size / SECTOR) > disc.MAX_SECTORS {
		fmt.eprintfln("overlay: invalid image size for %s: %d (%v)", image, size, size_err)
		return false
	}
	ov.image_size = u64(size)
	ov.image_info, err = os.fstat(f, core.long_allocator())
	if err != nil || ov.image_info.type != .Regular {
		fmt.eprintln("overlay: cannot identify the regular disc image:", image, err)
		return false
	}
	outer_volume, vok := read_volume(0, u32(size / SECTOR))
	if !vok {
		fmt.eprintln("overlay: malformed ISO 9660 volume in", image)
		return false
	}
	outer, outer_all, dok := read_tree(0, outer_volume)
	if !dok {
		fmt.eprintln("overlay: cannot read the outer ISO directory")
		return false
	}
	replaced := 0
	if wanted, has_root := files[""]; has_root {
		names := make([dynamic]string, context.temp_allocator)
		for name in wanted {append(&names, name)}
		slice.sort(names[:])
		for name in names {
			path := wanted[name]
			e, present, only := find_entry(outer[:], name)
			if !present || !only || e.dir || e.lba == 0 || e.size == 0 ||
				overlaps_metadata(e.lba, sectors_for(e.size), outer_volume) {
				fmt.eprintfln("overlay: files/%s: missing, ambiguous or unsafe root file", name)
				return false
			}
			for x in outer_all {
				if x.record != e.record && overlay_spans_overlap(
					u64(e.lba), u64(sectors_for(e.size)),
					u64(x.lba), u64(sectors_for(x.size)),
				) {
					fmt.eprintfln("overlay: root file %s overlaps %s", name, x.name)
					return false
				}
			}
			rf, ferr := os.open(path)
			if ferr != nil {
				fmt.eprintln("overlay: cannot open", path, ferr)
				return false
			}
			file_size, size_error := os.file_size(rf)
			if size_error != nil || file_size != i64(e.size) {
				fmt.eprintfln(
					"overlay: root replacement %s must match the original size %d (got %d; %v)",
					path, e.size, file_size, size_error,
				)
				os.close(rf)
				return false
			}
			append(&ov.regions, Region{
				e.lba, sectors_for(e.size), rf, file_size, strings.clone(path),
			})
			replaced += 1
			fmt.eprintfln("overlay: %s <- %s (%d bytes)", name, path, file_size)
		}
	}
	cvm_names := make([dynamic]string, context.temp_allocator)
	for name in files {if name != "" {append(&cvm_names, name)}}
	slice.sort(cvm_names[:])
	for cvm_name in cvm_names {
		wanted := files[cvm_name]
		cvm, found, unique := find_entry(outer[:], cvm_name)
		if !found || !unique || cvm.dir || cvm.lba == 0 ||
			sectors_for(cvm.size) <= CVM_ISO || overlaps_metadata(cvm.lba, sectors_for(cvm.size), outer_volume) {
			fmt.eprintfln("overlay: files/%s: missing, ambiguous or unsafe container", cvm_name)
			return false
		}
		for e in outer_all {
			if e.record != cvm.record && overlay_spans_overlap(u64(cvm.lba), u64(sectors_for(cvm.size)), u64(e.lba), u64(sectors_for(e.size))) {
				fmt.eprintfln("overlay: %s overlaps outer entry %s", cvm_name, e.name)
				return false
			}
		}
		header: [SECTOR]u8
		if !read_image(i64(cvm.lba) * SECTOR, header[:]) || string(header[:4]) != "CVMH" ||
			be32(header[:], CVMH_SIZE) != cvm.size {
			fmt.eprintfln("overlay: %s has an invalid or mismatched CVMH header", cvm_name)
			return false
		}
		spare_next := cvm.lba + sectors_for(cvm.size)
		spare_end := outer_volume.sectors
		for e in outer_all {
			if e.record != cvm.record && e.lba >= spare_next {spare_end = min(spare_end, e.lba)}
		}
		for span in outer_volume.metadata {
			if span.lba >= spare_next {spare_end = min(spare_end, span.lba)}
		}
		base_lba := cvm.lba + CVM_ISO
		base := i64(base_lba) * SECTOR
		volume, ok := read_volume(base, sectors_for(cvm.size) - CVM_ISO)
		if !ok {
			fmt.eprintfln("overlay: %s has a malformed ISO 9660 volume at 0x1800", cvm_name)
			return false
		}
		inner, inner_all, inner_ok := read_tree(base, volume)
		if !inner_ok {
			fmt.eprintfln("overlay: cannot read %s directory", cvm_name)
			return false
		}
		names := make([dynamic]string, context.temp_allocator)
		for name in wanted {append(&names, name)}
		slice.sort(names[:])
		new_volume := volume.sectors
		occupied := make([dynamic]Span, context.temp_allocator)
		for name in names {
			path := wanted[name]
			e, present, only := find_entry(inner[:], name)
			if !present || !only || e.dir || e.lba == 0 || e.size == 0 ||
				overlaps_metadata(e.lba, sectors_for(e.size), volume) {
				fmt.eprintfln("overlay: files/%s/%s: missing, ambiguous or unsafe file", cvm_name, name)
				return false
			}
			room := volume.sectors - e.lba
			for x in inner_all {
				if x.record == e.record {continue}
				if overlay_spans_overlap(u64(e.lba), u64(sectors_for(e.size)), u64(x.lba), u64(sectors_for(x.size))) {
					fmt.eprintfln("overlay: %s/%s overlaps %s", cvm_name, name, x.name)
					return false
				}
				if x.lba > e.lba {room = min(room, x.lba - e.lba)}
			}
			for span in volume.metadata {
				if span.lba > e.lba {room = min(room, span.lba - e.lba)}
			}
			rf, ferr := os.open(path)
			if ferr != nil {
				fmt.eprintln("overlay: cannot open", path, ferr)
				return false
			}
			file_size, size_error := os.file_size(rf)
			if size_error != nil || file_size <= 0 || u64(file_size) > u64(max(u32)) {
				fmt.eprintfln("overlay: %s: unusable size %d (%v)", path, file_size, size_error)
				os.close(rf)
				return false
			}
			need := sectors_for(u32(file_size))
			inner_lba := e.lba
			original_sectors := sectors_for(e.size)
			in_place := need <= room
			if in_place && need >= original_sectors && e.size % SECTOR != 0 {
				tail: [SECTOR]u8
				tail_len := SECTOR - int(e.size % SECTOR)
				if !read_image(base + i64(e.lba) * SECTOR + i64(e.size), tail[:tail_len]) {
					fmt.eprintfln("overlay: cannot verify padding after %s/%s", cvm_name, name)
					os.close(rf)
					return false
				}
				for b in tail[:tail_len] {if b != 0 {in_place = false; break}}
			}
			if in_place && need > original_sectors {
				start := base_lba + e.lba + original_sectors
				_, zero_found, read_ok := find_zero_run(start, start + need - original_sectors, need - original_sectors)
				if !read_ok {
					fmt.eprintfln("overlay: cannot verify unused sectors after %s/%s", cvm_name, name)
					os.close(rf)
					return false
				}
				in_place = zero_found
			}
			if !in_place {
				at, found_inner, read_ok := find_inner_run(base_lba, volume, inner_all[:], need, &occupied)
				if !read_ok {
					fmt.eprintfln("overlay: cannot verify unallocated sectors in %s", cvm_name)
					os.close(rf)
					return false
				}
				if found_inner {
					inner_lba = at
				} else {
					if need > spare_end - spare_next {
						fmt.eprintfln("overlay: %s needs %d unallocated sectors in or after %s", path, need, cvm_name)
						os.close(rf)
						return false
					}
					absolute, zero_found, spare_ok := find_zero_run(spare_next, spare_next + need, need)
					if !spare_ok {
						fmt.eprintfln("overlay: cannot read the spare sectors for %s", path)
						os.close(rf)
						return false
					}
					if !zero_found {
						fmt.eprintfln("overlay: the unallocated sectors needed for %s are not all zero", path)
						os.close(rf)
						return false
					}
					inner_lba = absolute - base_lba
					spare_next = absolute + need
				}
				new_volume = max(new_volume, inner_lba + need)
			}
			absolute := base_lba + inner_lba
			append(&ov.regions, Region{absolute, need, rf, file_size, strings.clone(path)})
			if !patch_record(e.record, inner_lba, u32(file_size)) {
				fmt.eprintfln("overlay: cannot read or patch the directory record for %s/%s", cvm_name, name)
				return false
			}
			replaced += 1
			fmt.eprintfln("overlay: %s/%s <- %s (%d bytes%s)", cvm_name, name, path, file_size, inner_lba != e.lba ? ", moved to verified spare sectors" : "")
		}
		if new_volume != volume.sectors {
			if (u64(CVM_ISO) + u64(new_volume)) * SECTOR > u64(max(u32)) {
				fmt.eprintfln("overlay: expanded %s is too large for ISO 9660", cvm_name)
				return false
			}
			grown := u32(CVM_ISO + new_volume)
			if overlaps_metadata(cvm.lba, grown, outer_volume) {
				fmt.eprintfln("overlay: expanded %s overlaps outer ISO metadata", cvm_name)
				return false
			}
			for e in outer_all {
				if e.record == cvm.record {continue}
				if overlay_spans_overlap(u64(cvm.lba), u64(grown), u64(e.lba), u64(sectors_for(e.size))) {
					fmt.eprintfln("overlay: expanded %s would overlap outer entry %s", cvm_name, e.name)
					return false
				}
			}
			sec, at, sec_ok := patch_sector(base + 16 * SECTOR)
			if !sec_ok || at + 88 > SECTOR {
				fmt.eprintfln("overlay: cannot patch the volume descriptor for %s", cvm_name)
				return false
			}
			put_both32(sec, at + 80, new_volume)
			total := u32(CVM_ISO + new_volume) * SECTOR
			hdr, hat, hdr_ok := patch_sector(i64(cvm.lba) * SECTOR)
			if !hdr_ok || hat + CVMH_SIZE + 4 > SECTOR {
				fmt.eprintfln("overlay: cannot patch the CVMH header for %s", cvm_name)
				return false
			}
			for k in 0 ..< 4 {hdr[hat + CVMH_SIZE + k] = u8(total >> (8 * uint(3 - k)))}
			if !patch_record(cvm.record, cvm.lba, total) {
				fmt.eprintfln("overlay: cannot patch the outer record for %s", cvm_name)
				return false
			}
		}
	}
	slice.sort_by(ov.regions[:], proc(a, b: Region) -> bool {return a.lba < b.lba})
	for r, i in ov.regions {
		if !overlay_span_fits(u64(r.lba), u64(r.sectors), ov.image_size / SECTOR) {
			fmt.eprintln("overlay: replacement extends outside the image:", r.path)
			return false
		}
		if i > 0 && overlay_spans_overlap(u64(ov.regions[i - 1].lba), u64(ov.regions[i - 1].sectors), u64(r.lba), u64(r.sectors)) {
			fmt.eprintln("overlay: replacement extents overlap:", ov.regions[i - 1].path, r.path)
			return false
		}
		for lba in ov.patches {
			if overlay_spans_overlap(u64(r.lba), u64(r.sectors), u64(lba), 1) {
				fmt.eprintln("overlay: replacement overlaps a patched directory sector:", r.path)
				return false
			}
		}
	}
	ov.lo, ov.hi = max(u32), 0
	for r in ov.regions {
		ov.lo = min(ov.lo, r.lba)
		ov.hi = max(ov.hi, r.lba + r.sectors)
	}
	for lba in ov.patches {
		ov.lo = min(ov.lo, lba)
		ov.hi = max(ov.hi, lba + 1)
	}
	disc.read_hook = overlay_read
	ov.installed = true
	fmt.eprintfln("overlay: %d files replaced", replaced)
	return true
}

overlay_read :: proc(d: ^disc.Disc, lba: u32, buf: []u8, ok: bool) -> bool {
	if len(buf) % SECTOR != 0 {return false}
	n := u64(len(buf) / SECTOR)
	if !overlay_spans_overlap(u64(lba), n, u64(ov.lo), u64(ov.hi) - u64(ov.lo)) {return ok}
	if d == nil || len(d.tracks) != 1 || d.tracks[0].raw || d.tracks[0].start != 0 || d.tracks[0].at != 0 {
		return ok
	}
	info, err := os.fstat(d.tracks[0].file, context.temp_allocator)
	if err != nil {
		fmt.eprintln("overlay: cannot identify the disc being read:", err)
		return false
	}
	if !os.same_file(info, ov.image_info) {return ok}
	for i in u64(0) ..< n {
		sector := u64(lba) + i
		if sector > u64(max(u32)) {return false}
		s := u32(sector)
		sec := buf[int(i) * SECTOR:][:SECTOR]
		if p, found := ov.patches[s]; found {
			copy(sec, p)
			continue
		}
		k, _ := slice.binary_search_by(ov.regions[:], s, proc(r: Region, s: u32) -> slice.Ordering {
			return slice.cmp(r.lba, s)
		})
		// binary_search_by gives the insertion point when s is not a start:
		// the region before it may still cover s.
		if k == len(ov.regions) || ov.regions[k].lba != s {k -= 1}
		if k < 0 {continue}
		r := ov.regions[k]
		if s < r.lba || s >= r.lba + r.sectors {continue}
		pos := i64(s - r.lba) * SECTOR
		slice.zero(sec)
		if pos < r.size {
			part := sec[:min(SECTOR, r.size - pos)]
			count, read_err := os.read_at(r.file, part, pos)
			if read_err != nil || count != len(part) {
				fmt.eprintfln("overlay: short or failed read of %s at %d: got %d of %d bytes (%v)", r.path, pos, count, len(part), read_err)
				return false
			}
		}
	}
	// This overlay does not claim that unrelated sectors in a failed image
	// read were filled.
	return ok
}
