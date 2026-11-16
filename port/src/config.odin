// The player's options: one `NAME<TAB>value` row each. Environment
// variables win over the player's file, the repository file and the
// framework's global file, in that order. The launcher only writes options
// the player actually changes.
//
//   SW         1 draws in software, else Vulkan          (runtime setting)
//   SCALE      Vulkan internal resolution, 1..8          (runtime setting)
//   UPSCALER   linear or fsr1                             (runtime setting)
//   LOC        localization mod: a folder in localization/, "" for the disc's text
//   LANG       the language column of that mod's strings.csv
//   SUBTITLES  1 captions radio lines that are voice-only on the disc
//   FULLSCREEN 1 starts in borderless fullscreen (F11 toggles it)
//   LAUNCHER   0 starts the game directly; --launcher shows it anyway
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "ps:core"

Upscaler :: enum {
	Linear,
	Fsr1,
}

Config :: struct {
	software:   bool,
	scale:      int,
	upscaler:   Upscaler,
	loc:        string,
	lang:       string,
	subtitles:  bool,
	fullscreen: bool,
	launcher:   bool,
	source:     [Config_Option]Config_Source,
	dirty:      bit_set[Config_Option],
}

CONFIG_DEFAULT :: Config {
	software = true,
	scale    = 1,
	upscaler = .Fsr1,
	launcher = true,
}

Config_Option :: enum {
	Sw,
	Scale,
	Upscaler,
	Loc,
	Lang,
	Subtitles,
	Fullscreen,
	Launcher,
}

CONFIG_NAMES :: [Config_Option]string {
	.Sw        = "SW",
	.Scale     = "SCALE",
	.Upscaler  = "UPSCALER",
	.Loc       = "LOC",
	.Lang      = "LANG",
	.Subtitles = "SUBTITLES",
	.Fullscreen = "FULLSCREEN",
	.Launcher  = "LAUNCHER",
}

Config_Source :: enum {
	Default,
	Global,
	Repository,
	Local,
	Environment,
}

Config_Rows :: struct {
	value: [Config_Option]string,
	set:   bit_set[Config_Option],
}

@(private = "file")
config_path :: proc(l: Local) -> string {
	p, _ := filepath.join({l.data, "settings.tsv"}, context.temp_allocator)
	return p
}

@(private = "file")
config_bool :: proc(v: string) -> bool {
	return v == "1" || strings.equal_fold(v, "true") || strings.equal_fold(v, "yes")
}

// Match the framework's first-valid-row and value-length rules.
config_parse :: proc(text: string, allocator := context.allocator) -> (rows: Config_Rows) {
	rest := text
	names := CONFIG_NAMES
	for line in strings.split_lines_iterator(&rest) {
		name, tab, value := strings.partition(strings.trim_right(line, "\r"), "\t")
		if tab == "" || len(value) > core.SETTING_MAX || strings.contains_any(value, "\t\x00") {continue}
		for option in Config_Option {
			if name == names[option] && option not_in rows.set {
				rows.value[option] = strings.clone(value, allocator)
				rows.set += {option}
			}
		}
	}
	return
}

@(private = "file")
config_read :: proc(path: string) -> Config_Rows {
	if text, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		return config_parse(string(text), context.temp_allocator)
	}
	return {}
}

// Pure resolution also keeps track of where an option came from, so a
// default or an inherited setting is not turned into a local override.
config_resolve :: proc(local, repository, global, environment: Config_Rows, headless: bool) -> (c: Config) {
	c = CONFIG_DEFAULT
	if headless {c.scale = 1}
	values: [Config_Option]string
	for option in Config_Option {
		switch {
		case option in environment.set:
			values[option], c.source[option] = environment.value[option], .Environment
		case option in local.set:
			values[option], c.source[option] = local.value[option], .Local
		case option in repository.set:
			values[option], c.source[option] = repository.value[option], .Repository
		case option in global.set:
			values[option], c.source[option] = global.value[option], .Global
		}
	}
	if c.source[.Sw] != .Default {c.software = values[.Sw] == "1"}
	if c.source[.Scale] != .Default {
		if n, ok := strconv.parse_int(values[.Scale]); ok && n >= 1 && n <= 8 {c.scale = n}
	}
	if c.source[.Upscaler] != .Default {
		switch {
		case strings.equal_fold(values[.Upscaler], "linear"): c.upscaler = .Linear
		case strings.equal_fold(values[.Upscaler], "fsr1"): c.upscaler = .Fsr1
		}
	}
	if c.source[.Loc] != .Default {c.loc = strings.clone(values[.Loc])}
	if c.source[.Lang] != .Default {c.lang = strings.clone(values[.Lang])}
	if c.source[.Subtitles] != .Default {c.subtitles = config_bool(values[.Subtitles])}
	if c.source[.Fullscreen] != .Default {c.fullscreen = config_bool(values[.Fullscreen])}
	if c.source[.Launcher] != .Default {c.launcher = config_bool(values[.Launcher])}
	return
}

// Compatibility runs, like the original port, do not apply saved settings.
config_load :: proc(l: Local, saved := true) -> Config {
	local, repository, global: Config_Rows
	if saved {
		local = config_read(config_path(l))
		repository = config_read(core.disc_path(l.root, .Settings, context.temp_allocator))
		if path, ok := core.settings_global_path(context.temp_allocator); ok {
			global = config_read(path)
		}
	}
	environment: Config_Rows
	names := CONFIG_NAMES
	for option in Config_Option {
		if v, ok := core.env_lookup(names[option]); ok {
			environment.value[option] = v
			environment.set += {option}
		}
	}
	return config_resolve(local, repository, global, environment, core.env("HEADLESS") == "1")
}

// Preserve unknown, inherited and untouched rows, including IRX and NATIVE.
config_serialize :: proc(original: string, c: Config, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	rest := original
	names := CONFIG_NAMES
	for raw_line in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw_line, "\r")
		name, tab, _ := strings.partition(line, "\t")
		replace := false
		if tab != "" {
			for option in c.dirty {
				if name == names[option] {replace = true; break}
			}
		}
		if !replace {fmt.sbprintf(&sb, "%s\n", line)}
	}
	b01 :: proc(b: bool) -> string {return b ? "1" : "0"}
	for option in c.dirty {
		switch option {
		case .Sw: fmt.sbprintf(&sb, "SW\t%s\n", b01(c.software))
		case .Scale: fmt.sbprintf(&sb, "SCALE\t%d\n", c.scale)
		case .Upscaler: fmt.sbprintf(&sb, "UPSCALER\t%s\n", c.upscaler == .Fsr1 ? "fsr1" : "linear")
		case .Loc: fmt.sbprintf(&sb, "LOC\t%s\n", c.loc)
		case .Lang: fmt.sbprintf(&sb, "LANG\t%s\n", c.lang)
		case .Subtitles: fmt.sbprintf(&sb, "SUBTITLES\t%s\n", b01(c.subtitles))
		case .Fullscreen: fmt.sbprintf(&sb, "FULLSCREEN\t%s\n", b01(c.fullscreen))
		case .Launcher: fmt.sbprintf(&sb, "LAUNCHER\t%s\n", b01(c.launcher))
		}
	}
	return strings.to_string(sb)
}

config_save :: proc(l: Local, c: Config) -> bool {
	if c.dirty == {} {return true}
	if (.Loc in c.dirty && (len(c.loc) > core.SETTING_MAX || strings.contains_any(c.loc, "\t\r\n\x00"))) ||
		(.Lang in c.dirty && (len(c.lang) > core.SETTING_MAX || strings.contains_any(c.lang, "\t\r\n\x00"))) {
		fmt.eprintln("cannot save an invalid localization option")
		return false
	}
	path := config_path(l)
	original := ""
	if text, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		original = string(text)
	} else if err != .Not_Exist {
		fmt.eprintln("cannot read", path, err)
		return false
	}
	if err := os.make_directory_all(l.data); err != nil && !os.is_dir(l.data) {
		fmt.eprintln("cannot make", l.data, err)
		return false
	}
	text := config_serialize(original, c, context.temp_allocator)
	if err := core.write_file_atomic(path, transmute([]u8)text); err != nil {
		fmt.eprintln("cannot write", path, err)
		return false
	}
	return true
}

// Apply local overrides first, then the original repository/global resolver.
// Existing environment variables always win, including variables set to "".
config_apply :: proc(l: Local, c: Config) -> bool {
	set :: proc(name, value: string) -> bool {
		if _, ok := core.env_lookup(name); ok {return true}
		if err := os.set_env(core.env_name(name), value); err != nil {
			fmt.eprintln("cannot set", core.env_name(name), err)
			return false
		}
		return true
	}
	local := core.settings_load(config_path(l), context.temp_allocator)
	names := core.SETTING_NAMES
	for setting in local.set {
		if setting == .Sw || setting == .Scale {continue}
		if !set(names[setting], local.value[setting]) {return false}
	}
	if c.source[.Sw] == .Local || .Sw in c.dirty {
		if !set("SW", c.software ? "1" : "0") {return false}
	}
	if c.source[.Scale] == .Local || .Scale in c.dirty {
		if !set("SCALE", fmt.tprintf("%d", c.scale)) {return false}
	}
	if !set("UPSCALER", c.upscaler == .Fsr1 ? "fsr1" : "linear") {return false}
	return core.settings_apply(l.root)
}

// A localization mod: localization/<id>/ with strings.csv and an optional
// mod.tsv (name, author, description, ascii_punctuation, include). `include`
// names other mods, comma-separated, whose tables load first, so this one's
// rows win: a story translation can include a separate system-text mod.
Loc_Mod :: struct {
	id, dir, name, author, description: string,
	csv:                                string,
	languages:                          []string,
	ascii_punct:                        bool,
	includes:                           []string,
	problem:                            string,
}

// Mod `m` and the mods it includes, included ones first, each once: the
// order their tables and files apply in, later ones winning.
loc_mod_chain :: proc(m: Loc_Mod, mods: []Loc_Mod, allocator := context.allocator) -> ([]Loc_Mod, bool) {
	out := make([dynamic]Loc_Mod, allocator)
	state := make(map[string]u8, context.temp_allocator)
	visit :: proc(m: Loc_Mod, mods: []Loc_Mod, out: ^[dynamic]Loc_Mod, state: ^map[string]u8, depth: int) -> bool {
		if depth > 128 {
			fmt.eprintfln("loc: include chain for %s exceeds 128 mods", m.id)
			return false
		}
		if state^[m.id] == 2 {return true}
		if state^[m.id] == 1 {
			fmt.eprintfln("loc: cyclic mod include involving %s", m.id)
			return false
		}
		if m.problem != "" {
			fmt.eprintfln("loc: mod %s is malformed: %s", m.id, m.problem)
			return false
		}
		state^[m.id] = 1
		for inc in m.includes {
			found := false
			for other in mods {
				if other.id == inc {
					found = true
					if !visit(other, mods, out, state, depth + 1) {return false}
					break
				}
			}
			if !found {
				fmt.eprintfln("loc: %s includes '%s', which is not installed", m.id, inc)
				return false
			}
		}
		append(out, m)
		state^[m.id] = 2
		return true
	}
	if !visit(m, mods, &out, &state, 0) {
		delete(out)
		return nil, false
	}
	return out[:], true
}

// Discover all mods for the launcher, or only a selected mod and its
// includes for a direct start. Working folders are never mods.
loc_mods :: proc(root: string, selected := "", allocator := context.allocator) -> []Loc_Mod {
	context.allocator = allocator
	out := make([dynamic]Loc_Mod)
	base, _ := filepath.join({root, "localization"}, context.temp_allocator)
	entries, err := core.read_dir(base, context.temp_allocator)
	if err != nil {
		if err != .Not_Exist {
			problem := fmt.tprintf("cannot read %s: %v", base, err)
			fmt.eprintln("loc:", problem)
			if selected != "" {
				append(&out, Loc_Mod{id = strings.clone(selected), problem = strings.clone(problem)})
				return out[:]
			}
		}
		return nil
	}
	pending := make([dynamic]string, context.temp_allocator)
	if selected != "" {
		append(&pending, selected)
	} else {
		for e in entries {append(&pending, e.name)}
	}
	visited := make(map[string]bool, context.temp_allocator)
	for cursor := 0; cursor < len(pending); cursor += 1 {
		id := pending[cursor]
		if id in visited {continue}
		visited[id] = true
		e: os.File_Info
		found := false
		for candidate in entries {
			if candidate.name == id {e, found = candidate, true; break}
		}
		if !found {continue}
		if strings.has_prefix(e.name, "_") || strings.has_prefix(e.name, ".") {continue}
		info, stat_err := os.stat(e.fullpath, context.temp_allocator)
		if stat_err != nil || info.type != .Directory {
			if stat_err != nil || selected != "" {
				problem := stat_err != nil ? fmt.tprintf("cannot inspect %s: %v", e.fullpath, stat_err) : "not a mod directory"
				fmt.eprintfln("loc: mod %s: %s", id, problem)
				if selected != "" {append(&out, Loc_Mod{id = strings.clone(id), problem = strings.clone(problem)})}
			}
			continue
		}
		csv_path, _ := filepath.join({e.fullpath, "strings.csv"})
		files_dir, _ := filepath.join({e.fullpath, "files"}, context.temp_allocator)
		csv_info, csv_err := os.stat(csv_path, context.temp_allocator)
		files_info, files_err := os.stat(files_dir, context.temp_allocator)
		has_csv := csv_err == nil && csv_info.type == .Regular
		has_files := files_err == nil && files_info.type == .Directory
		if !has_csv {csv_path = ""}
		m := Loc_Mod {
			id          = strings.clone(e.name),
			dir         = strings.clone(e.fullpath),
			name        = strings.clone(e.name),
			csv         = csv_path,
			ascii_punct = true,
		}
		fail :: proc(m: ^Loc_Mod, message: string) {
			fmt.eprintfln("loc: mod %s: %s", m.id, message)
			if m.problem == "" {m.problem = strings.clone(message)}
		}
		if csv_err != nil && csv_err != .Not_Exist {fail(&m, fmt.tprintf("cannot inspect strings.csv: %v", csv_err))}
		if csv_err == nil && !has_csv {fail(&m, "strings.csv is not a regular file")}
		if files_err != nil && files_err != .Not_Exist {fail(&m, fmt.tprintf("cannot inspect files: %v", files_err))}
		if files_err == nil && !has_files {fail(&m, "files is not a directory")}
		manifest, _ := filepath.join({e.fullpath, "mod.tsv"}, context.temp_allocator)
		if text, rerr := os.read_entire_file(manifest, context.temp_allocator); rerr == nil {
			rest := strings.trim_prefix(string(text), "\xef\xbb\xbf")
			seen := make(map[string]bool, context.temp_allocator)
			line_no := 0
			for line in strings.split_lines_iterator(&rest) {
				line_no += 1
				k, tab, v := strings.partition(strings.trim_right(line, "\r"), "\t")
				if strings.trim_space(line) == "" || strings.has_prefix(line, "#") {continue}
				if tab == "" || k == "" || strings.contains_any(k, "\x00") || strings.contains_any(v, "\t\x00") {
					fail(&m, fmt.tprintf("malformed manifest row %d", line_no))
					continue
				}
				if k == "key" && v == "value" {continue}
				switch k {
				case "name", "author", "description", "ascii_punctuation", "include":
					if k in seen {
						fail(&m, fmt.tprintf("duplicate manifest key %q", k))
						continue
					}
					seen[k] = true
				case:
					continue
				}
				switch k {
				case "name":
					if strings.trim_space(v) == "" {fail(&m, "empty mod name")}
					m.name = strings.clone(v)
				case "author": m.author = strings.clone(v)
				case "description": m.description = strings.clone(v)
				case "ascii_punctuation":
					if v != "0" && v != "1" && !strings.equal_fold(v, "true") &&
						!strings.equal_fold(v, "false") && !strings.equal_fold(v, "yes") &&
						!strings.equal_fold(v, "no") {
						fail(&m, fmt.tprintf("invalid ascii_punctuation value %q", v))
					} else {
						m.ascii_punct = config_bool(v)
					}
				case "include":
					incs := make([dynamic]string)
					for part in strings.split(v, ",", context.temp_allocator) {
						if id := strings.trim_space(part); id != "" {
							append(&incs, strings.clone(id))
						} else {
							fail(&m, "empty included mod id")
						}
					}
					m.includes = incs[:]
				}
			}
		} else if rerr != .Not_Exist {
			fail(&m, fmt.tprintf("cannot read manifest: %v", rerr))
		}
		langs := make([dynamic]string)
		if has_csv {
			// The Japanese column of a working table is the disc's own text.
			if available, ok := loc_languages(csv_path); ok {
				for lang in available {
					if !strings.equal_fold(lang, "ja") {append(&langs, lang)}
				}
			} else {
				fail(&m, "invalid strings.csv header")
			}
		}
		// A mod with replacement files but no text (art, audio) offers
		// itself once, with the disc's text.
		if len(langs) == 0 && has_csv && !has_files && m.problem == "" {
			fail(&m, "strings.csv has no translated language column")
		}
		if len(langs) == 0 && (has_files || m.problem != "") {append(&langs, "")}
		m.languages = langs[:]
		if selected != "" {append(&pending, ..m.includes)}
		if len(m.languages) > 0 {append(&out, m)}
	}
	slice.sort_by(out[:], proc(a, b: Loc_Mod) -> bool {return a.id < b.id})
	return out[:]
}
