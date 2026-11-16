// The port's main package: ps2.boot boots the disc with the functions
// setup.ps1 generated into port/src/rec, plus this port's own layer:
//
//   launcher.odin  options window before the game (skip with --play)
//   config.odin    the player's options in <data>/settings.tsv
//   loc.odin       text from a localization mod's CSV, and subtitles
//   display.odin   fullscreen and F11
//
// Command line:
//   macross-recomp                       launcher (unless turned off), then the game
//   macross-recomp --play                the game with the saved options
//   macross-recomp --launcher            the launcher even if turned off
//   macross-recomp --export-strings F    write the disc's text table to F and exit
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "ps:core"
import "ps:ps2"
import "rec"

TITLE :: "Chou Jikuu Yousai Macross"

@(private = "file")
run: struct {
	cfg:    Config,
	mod:    Loc_Mod,
	tables: [dynamic]Loc_Table,
	dirs:   [dynamic]string,
	image:  string,
	export: string,
}

main :: proc() {
	l := local_read()
	force_launcher, force_play := false, false
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--launcher": force_launcher = true
		case "--play": force_play = true
		case "--export-strings":
			if i + 1 >= len(args) {
				fmt.eprintln("--export-strings needs an output path")
				os.exit(2)
			}
			i += 1
			path, err := filepath.abs(args[i])
			if err != nil {
				fmt.eprintfln("cannot resolve export path %q: %v", args[i], err)
				os.exit(2)
			}
			run.export = path
		case:
			fmt.eprintln("unknown argument:", args[i])
			fmt.eprintln("usage: macross-recomp [--launcher | --play | --export-strings <file.csv>]")
			os.exit(2)
		}
	}

	compat := core.env("COMPAT") == "1"
	if run.export != "" {
		// The export needs no window and no player options: boot headless
		// until the string bank loads.
		if err := os.set_env(core.env_name("HEADLESS"), "1"); err != nil {
			fmt.eprintln("cannot enable headless export:", err)
			os.exit(1)
		}
	}
	run.cfg = config_load(l, !compat)
	show_launcher := run.export == "" && !compat && core.env("HEADLESS") != "1" &&
		(force_launcher || (run.cfg.launcher && !force_play))
	mods: []Loc_Mod
	if show_launcher {
		mods = loc_mods(l.root)
	} else if run.cfg.loc != "" && run.export == "" {
		mods = loc_mods(l.root, run.cfg.loc)
	}
	if run.export == "" && show_launcher {
		result := launcher_run(&run.cfg, l, mods)
		if !config_save(l, run.cfg) {os.exit(1)}
		if result == .Quit {os.exit(0)}
		// In particular, an environment override still wins over an edit.
		run.cfg = config_load(l)
	}
	if !compat && !config_apply(l, run.cfg) {os.exit(1)}
	if run.cfg.loc != "" && run.export == "" {
		found := false
		for m in mods {
			if m.id == run.cfg.loc {run.mod, found = m, true}
		}
		if found {
			chain, ok := loc_mod_chain(run.mod, mods)
			if !ok {os.exit(1)}
			if run.cfg.lang == "" && run.cfg.source[.Lang] == .Default && len(run.mod.languages) == 1 {
				run.cfg.lang = run.mod.languages[0]
			}
			if run.cfg.lang != "" {
				available := false
				for lang in run.mod.languages {
					if strings.equal_fold(lang, run.cfg.lang) {available = true; break}
				}
				if !available {
					fmt.eprintfln("loc: mod %s has no language column %q", run.mod.id, run.cfg.lang)
					os.exit(1)
				}
			}
			for m in chain {
				if m.csv != "" {append(&run.tables, Loc_Table{m.csv, m.ascii_punct})}
				append(&run.dirs, m.dir)
			}
		}
		if !found {fmt.eprintfln("loc: no localization mod '%s' in %s; using the disc's text", run.cfg.loc, filepath.join({l.root, "localization"}))}
	}
	display_init(run.cfg.fullscreen)
	run.image = l.image

	// ps2.boot returns only on a failure.
	ps2.boot(
		{
			disc = l.image,
			title = TITLE,
			learned = learned(l, .Learned_Iop, .Learned_Iop, .Learned_Iop_Key),
			learned_ee = learned(l, .Learned_Ee, .Learned_Ee, .Learned_Ee_Key),
			cards = cards(l),
			setup = setup,
			hooks = hooks,
			vblank = display_vblank,
		},
	)
	os.exit(1)
}

// Before the window opens and before the game reads the disc: the mods'
// replacement files.
setup :: proc() -> bool {
	if len(run.dirs) > 0 || run.cfg.subtitles || run.export != "" {
		if !loc_verify_revision() {return false}
	}
	if run.export == "" && !overlay_install(run.image, run.dirs[:]) {return false}
	return true
}

// Once the runtime is set up: the generated functions in place of the
// interpreter, then the port's replacements of game functions.
hooks :: proc() -> bool {
	rec.register_all()
	lang := run.mod.id != "" ? run.cfg.lang : ""
	subtitles := run.cfg.subtitles && run.export == ""
	return loc_install(run.tables[:], lang, subtitles, run.export)
}
