// What the port takes from local.tsv, which play --export wrote and git
// ignores: the disc image, and the player's directory for the disc, which
// has its memory cards and the code the player learned.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "ps:core"

Local :: struct {
	// The repository's root (above port/, the binary's directory), the
	// disc image and the player's directory for the disc.
	root, image, data: string,
}

// local.tsv. Exits after a message when it cannot be read or names no disc.
local_read :: proc() -> (l: Local) {
	dir, err := os.get_executable_directory(context.allocator)
	if err != nil {
		fmt.eprintln("cannot find the port's directory:", err)
		os.exit(1)
	}
	l.root = filepath.dir(dir)
	path, _ := filepath.join({l.root, "local.tsv"})
	text, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		fmt.eprintln("cannot read", path, rerr)
		os.exit(1)
	}
	rest := string(text)
	for line in strings.split_lines_iterator(&rest) {
		key, _, value := strings.partition(strings.trim_right(line, "\r"), "\t")
		switch key {
		case "image":
			l.image = value
		case "data":
			l.data = value
		}
	}
	if l.image == "" || l.data == "" {
		fmt.eprintln(path, "names no disc image or player directory")
		os.exit(1)
	}
	return
}

// The repository's settings.tsv, then the player's settings for every disc,
// into the environment; not for a COMPAT run, as in the player. Exits after
// a message on a failure.
settings :: proc(l: Local) {
	if core.env("COMPAT") != "1" && !core.settings_apply(l.root) {
		os.exit(1)
	}
}

// The player's blob of learned code for the disc, when it was made by the
// ps-recomp commit the port is built from; else "" (that code is
// interpreted).
learned :: proc(l: Local, kind: core.Blob_Kind, blob, key: core.Disc_File) -> string {
	text, err := os.read_entire_file(core.disc_path(l.data, key, context.temp_allocator), context.temp_allocator)
	if err != nil {
		return ""
	}
	fields := strings.fields(string(text), context.temp_allocator)
	if len(fields) != 3 || !core.blob_cached(l.data, core.COMMIT, kind, fields[2]) {
		fmt.eprintln("the player's learned code is from another ps-recomp commit: interpreting it")
		return ""
	}
	return core.disc_path(l.data, blob)
}

// The player's memory card directory for the disc, made if missing. Exits
// after a message when it cannot be made.
cards :: proc(l: Local) -> string {
	dir := core.disc_path(l.data, .Cards)
	if err := os.make_directory_all(dir); err != nil && !(err == .Exist && os.is_dir(dir)) {
		fmt.eprintln("cannot make", dir, err)
		os.exit(1)
	}
	return dir
}
