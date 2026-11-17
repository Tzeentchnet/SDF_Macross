// The launcher: a small options window shown before the game starts.
// Keyboard, mouse and controller all work; the choices are saved to the
// player's settings.tsv (config.odin) when the game starts or the window
// closes. The game then boots in this process, so closing the launcher
// before it does releases its window and SDL first.
package main

import "core:fmt"
import "core:strings"
import "ps:core"
import sdl "vendor:sdl2"

Launch_Result :: enum {
	Play,
	Quit,
}

// Logical size of the launcher's picture; SDL scales it to the window.
@(private = "file") LW :: 640
@(private = "file") LH :: 456
@(private = "file") GLYPH :: 2 // font scale: 16-pixel characters
@(private = "file") CH :: core.FONT_GLYPH * GLYPH
@(private = "file") ROW_Y0 :: 92
@(private = "file") ROW_H :: 24
@(private = "file") LABEL_X :: 40
@(private = "file") VALUE_X :: 300
LAUNCHER_LEFT_ARROW_X :: VALUE_X - 14
LAUNCHER_RIGHT_ARROW_X :: LW - 52
@(private = "file") ARROW_HIT_PAD :: 8

@(private = "file") BG :: 0xff0b1020
@(private = "file") PANEL :: 0xff141c34
@(private = "file") SEL :: 0xff23407a
@(private = "file") TEXT :: 0xffd8e0f0
@(private = "file") DIM :: 0xff7f8aa8
@(private = "file") ACCENT :: 0xff5fb0ff

@(private = "file")
Row :: enum {
	Text,
	System_Messages,
	Subtitles,
	Renderer,
	Preset,
	Scale,
	Upscaler,
	Display,
	Launcher,
	Play,
	Quit,
}

Render_Preset :: enum {
	Performance,
	Balanced,
	Quality,
	Custom,
}

@(private = "file")
Text_Choice :: struct {
	label:     string,
	mod, lang: string,
	info:      string,
}

@(private = "file")
Ui :: struct {
	cfg:     ^Config,
	choices: []Text_Choice,
	text:    int, // index into choices
	sel:     Row,
	px:      []u32,
}

launcher_text_mod :: proc(m: Loc_Mod) -> bool {
	return m.id != SYSTEM_MOD_ID
}

launcher_text_label :: proc(m: Loc_Mod, lang: string) -> string {
	if len(m.languages) > 1 && lang != "" {
		return fmt.aprintf("[%s] %s", lang, loc_language_name(m, lang))
	}
	return m.name
}

launcher_migrate_system_selection :: proc(c: ^Config) {
	if c.loc != SYSTEM_MOD_ID {return}
	c.loc, c.lang = "", ""
	c.system_english = true
	c.dirty += {.Loc, .Lang, .System_English}
}

@(private = "file")
text_choices :: proc(mods: []Loc_Mod) -> []Text_Choice {
	out := make([dynamic]Text_Choice)
	append(&out, Text_Choice{label = "Japanese (as on the disc)", info = "The game's own text. No localization mod is loaded."})
	for m in mods {
		if !launcher_text_mod(m) {continue}
		for lang in m.languages {
			info := m.description
			if m.author != "" {info = fmt.aprintf("%s%sBy %s.", info, info != "" ? " " : "", m.author)}
			if info == "" {
				info = lang != "" ? fmt.aprintf("localization/%s/strings.csv, column '%s'.", m.id, lang) : fmt.aprintf("localization/%s: replacement files only.", m.id)
			}
			label := launcher_text_label(m, lang)
			append(&out, Text_Choice{label = label, mod = m.id, lang = lang, info = info})
		}
	}
	return out[:]
}

@(private = "file")
row_label :: proc(r: Row) -> string {
	switch r {
	case .Text: return "Text language"
	case .System_Messages: return "English system messages"
	case .Subtitles: return "Radio subtitles"
	case .Renderer: return "Renderer"
	case .Preset: return "Render preset"
	case .Scale: return "Internal resolution"
	case .Upscaler: return "Output upscaler"
	case .Display: return "Display"
	case .Launcher: return "Show this launcher"
	case .Play: return "Play"
	case .Quit: return "Quit"
	}
	return ""
}

@(private = "file")
row_value :: proc(u: ^Ui, r: Row) -> string {
	c := u.cfg
	switch r {
	case .Text: return u.choices[u.text].label
	case .System_Messages: return c.system_english ? "On" : "Off"
	case .Subtitles: return c.subtitles ? "On" : "Off"
	case .Renderer: return c.software ? "Software (compatibility)" : "Vulkan (recommended)"
	case .Preset: return render_preset_label(render_preset(c))
	case .Scale: return fmt.tprintf("%dx (%dx%d)", c.scale, 640 * c.scale, 448 * c.scale)
	case .Upscaler: return c.upscaler == .Fsr1 ? "FSR 1 (EASU + RCAS)" : "Linear"
	case .Display: return c.fullscreen ? "Fullscreen" : "Windowed"
	case .Launcher: return c.launcher ? "At every start" : "Only with --launcher"
	case .Play, .Quit: return ""
	}
	return ""
}

@(private = "file")
row_help :: proc(u: ^Ui, r: Row) -> string {
	switch r {
	case .Text: return u.choices[u.text].info
	case .System_Messages: return "Override 47 supported executable messages with project-authored English."
	case .Subtitles: return "Show captions for supported radio lines the game only speaks."
	case .Renderer: return "Vulkan holds full speed on the animated main menu. Software is a slower compatibility fallback."
	case .Preset: return u.cfg.software ? "Saved for Vulkan; software ignores resolution and upscaling." : "Sets resolution and upscaler together. Other combinations appear as Custom."
	case .Scale: return u.cfg.software ? "Applies to the Vulkan renderer only." : "Higher is sharper but slower. Use 1x or 2x when full speed matters."
	case .Upscaler: return "Vulkan only. FSR 1 spatially upscales when the output is larger than the internal image."
	case .Display: return "Borderless fullscreen. Press F11 in game to toggle."
	case .Launcher: return "Off starts the game directly. Run with --launcher to see this again."
	case .Play: return "Save these options and start the game."
	case .Quit: return "Save these options and exit."
	}
	return ""
}

render_preset :: proc(c: ^Config) -> Render_Preset {
	switch {
	case c.scale == 1 && c.upscaler == .Fsr1: return .Performance
	case c.scale == 2 && c.upscaler == .Fsr1: return .Balanced
	case c.scale == 3 && c.upscaler == .Linear: return .Quality
	}
	return .Custom
}

render_preset_label :: proc(preset: Render_Preset) -> string {
	switch preset {
	case .Performance: return "Performance (1x + FSR 1)"
	case .Balanced: return "Balanced (2x + FSR 1)"
	case .Quality: return "Quality (3x + Linear)"
	case .Custom: return "Custom"
	}
	return ""
}

@(private = "file")
set_render_preset :: proc(c: ^Config, preset: Render_Preset) {
	scale := 1
	upscaler := Upscaler.Fsr1
	switch preset {
	case .Performance:
	case .Balanced:
		scale = 2
	case .Quality:
		scale, upscaler = 3, .Linear
	case .Custom:
		return
	}
	c.scale, c.upscaler = scale, upscaler
	c.dirty += {.Scale, .Upscaler}
}

change_render_preset :: proc(c: ^Config, dir: int) {
	next := Render_Preset.Performance
	switch render_preset(c) {
	case .Performance: next = dir < 0 ? .Quality : .Balanced
	case .Balanced: next = dir < 0 ? .Performance : .Quality
	case .Quality: next = dir < 0 ? .Balanced : .Performance
	case .Custom: next = dir < 0 ? .Quality : .Performance
	}
	set_render_preset(c, next)
}

launcher_arrow_direction :: proc(x: int) -> int {
	if x >= LAUNCHER_LEFT_ARROW_X - ARROW_HIT_PAD &&
	   x < LAUNCHER_LEFT_ARROW_X + core.FONT_GLYPH + ARROW_HIT_PAD {
		return -1
	}
	if x >= LAUNCHER_RIGHT_ARROW_X - ARROW_HIT_PAD &&
	   x < LAUNCHER_RIGHT_ARROW_X + core.FONT_GLYPH + ARROW_HIT_PAD {
		return 1
	}
	return 0
}

@(private = "file")
change :: proc(u: ^Ui, r: Row, dir: int) {
	c := u.cfg
	switch r {
	case .Text:
		n := len(u.choices)
		u.text = ((u.text + dir) % n + n) % n
		if c.loc != u.choices[u.text].mod || c.lang != u.choices[u.text].lang {
			c.loc, c.lang = u.choices[u.text].mod, u.choices[u.text].lang
			c.dirty += {.Loc, .Lang}
		}
	case .System_Messages:
		c.system_english = !c.system_english
		c.dirty += {.System_English}
	case .Subtitles:
		c.subtitles = !c.subtitles
		c.dirty += {.Subtitles}
	case .Renderer:
		c.software = !c.software
		c.dirty += {.Sw}
	case .Preset:
		change_render_preset(c, dir)
	case .Scale:
		next := clamp(c.scale + dir, 1, 8)
		if next != c.scale {c.scale = next; c.dirty += {.Scale}}
	case .Upscaler:
		c.upscaler = c.upscaler == .Fsr1 ? .Linear : .Fsr1
		c.dirty += {.Upscaler}
	case .Display:
		c.fullscreen = !c.fullscreen
		c.dirty += {.Fullscreen}
	case .Launcher:
		c.launcher = !c.launcher
		c.dirty += {.Launcher}
	case .Play, .Quit:
	}
}

@(private = "file")
fill :: proc(px: []u32, x, y, w, h: int, c: u32) {
	for yy in max(y, 0) ..< min(y + h, LH) {
		for xx in max(x, 0) ..< min(x + w, LW) {px[yy * LW + xx] = c}
	}
}

@(private = "file")
draw_text :: proc(px: []u32, x, y: int, s: string, c: u32, scale := GLYPH, max_chars := 1000) {
	n := 0
	for r in s {
		if n >= max_chars {break}
		if r < 0x80 {
			core.font_glyph(px, LW, u8(r), x + n * core.FONT_GLYPH * scale, y, c, scale)
		}
		n += 1
	}
}

// Wrap s to lines of at most n characters at spaces.
@(private = "file")
wrap :: proc(s: string, n: int) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	rest := s
	for len(rest) > n {
		cut := strings.last_index_byte(rest[:n + 1], ' ')
		if cut <= 0 {cut = n}
		append(&lines, rest[:cut])
		rest = strings.trim_left_space(rest[cut:])
	}
	if rest != "" {append(&lines, rest)}
	return lines[:]
}

@(private = "file")
row_y :: proc(r: Row) -> int {
	y := ROW_Y0 + int(r) * ROW_H
	if r >= .Play {y += 10}
	return y
}

@(private = "file")
draw :: proc(u: ^Ui) {
	px := u.px
	fill(px, 0, 0, LW, LH, BG)
	draw_text(px, LABEL_X, 22, TITLE, ACCENT, 2, 34)
	draw_text(px, LABEL_X, 46, "PC recompilation - options", DIM, 1)
	fill(px, LABEL_X - 12, ROW_Y0 - 8, LW - 2 * (LABEL_X - 12), row_y(.Quit) + ROW_H - ROW_Y0 + 8, PANEL)
	for r in Row {
		y := row_y(r)
		if r == u.sel {fill(px, LABEL_X - 8, y - 4, LW - 2 * (LABEL_X - 8), ROW_H, SEL)}
		label_color: u32 = r >= .Play ? ACCENT : TEXT
		draw_text(px, LABEL_X, y, row_label(r), label_color, 1 if r < .Play else GLYPH)
		if v := row_value(u, r); v != "" {
			arrows := r == u.sel
			x := VALUE_X
			if arrows {draw_text(px, LAUNCHER_LEFT_ARROW_X, y, "<", ACCENT, 1)}
			draw_text(px, x, y, v, TEXT, 1, (LW - 60 - VALUE_X) / core.FONT_GLYPH)
			if arrows {draw_text(px, LAUNCHER_RIGHT_ARROW_X, y, ">", ACCENT, 1)}
		}
	}
	// Help for the selected row, then the keys.
	help_y := row_y(.Quit) + ROW_H + 14
	for line, i in wrap(row_help(u, u.sel), (LW - 2 * LABEL_X) / core.FONT_GLYPH) {
		if i >= 3 {break}
		draw_text(px, LABEL_X, help_y + i * 11, line, DIM, 1)
	}
	draw_text(px, LABEL_X, LH - 18, "Arrows/D-pad: choose   Enter/A: select   Esc/B: quit", DIM, 1)
}

@(private = "file")
Action :: enum {
	None,
	Up,
	Down,
	Left,
	Right,
	Accept,
	Back,
	Start,
}

@(private = "file")
activate :: proc(u: ^Ui) -> (done: bool, result: Launch_Result) {
	#partial switch u.sel {
	case .Play: return true, .Play
	case .Quit: return true, .Quit
	case:
		change(u, u.sel, 1)
	}
	return
}

// Show the launcher; the choices are written into cfg.
launcher_run :: proc(cfg: ^Config, mods: []Loc_Mod) -> Launch_Result {
	launcher_migrate_system_selection(cfg)
	u := Ui{cfg = cfg, choices = text_choices(mods)}
	for ch, i in u.choices {
		if ch.mod == cfg.loc && ch.lang == cfg.lang {u.text = i}
	}
	if sdl.Init({.VIDEO, .EVENTS, .GAMECONTROLLER}) != 0 {
		fmt.eprintln("launcher: SDL_Init:", sdl.GetError())
		return .Play
	}
	defer sdl.Quit()
	win := sdl.CreateWindow(TITLE, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED, LW * 2, LH * 2, {.RESIZABLE, .ALLOW_HIGHDPI})
	if win == nil {
		fmt.eprintln("launcher: SDL_CreateWindow:", sdl.GetError())
		return .Play
	}
	defer sdl.DestroyWindow(win)
	ren := sdl.CreateRenderer(win, -1, {.PRESENTVSYNC})
	if ren == nil {ren = sdl.CreateRenderer(win, -1, {.SOFTWARE})}
	if ren == nil {
		fmt.eprintln("launcher: SDL_CreateRenderer:", sdl.GetError())
		return .Play
	}
	defer sdl.DestroyRenderer(ren)
	sdl.RenderSetLogicalSize(ren, LW, LH)
	tex := sdl.CreateTexture(ren, .ARGB8888, .STREAMING, LW, LH)
	if tex == nil {
		fmt.eprintln("launcher: SDL_CreateTexture:", sdl.GetError())
		return .Play
	}
	defer sdl.DestroyTexture(tex)
	u.px = make([]u32, LW * LH)
	defer delete(u.px)
	pads: [dynamic]^sdl.GameController
	defer {
		for p in pads {sdl.GameControllerClose(p)}
		delete(pads)
	}
	stick_dir: Action

	for {
		free_all(context.temp_allocator)
		draw(&u)
		sdl.UpdateTexture(tex, nil, raw_data(u.px), LW * 4)
		sdl.RenderClear(ren)
		sdl.RenderCopy(ren, tex, nil, nil)
		sdl.RenderPresent(ren)

		ev: sdl.Event
		if !sdl.WaitEventTimeout(&ev, 250) {continue}
		for {
			a := Action.None
			#partial switch ev.type {
			case .QUIT:
				return .Quit
			case .KEYDOWN:
				#partial switch ev.key.keysym.sym {
				case .UP, .W: a = .Up
				case .DOWN, .S: a = .Down
				case .LEFT, .A: a = .Left
				case .RIGHT, .D: a = .Right
				case .RETURN, .KP_ENTER, .SPACE: a = .Accept
				case .ESCAPE: a = .Back
				case .F5: a = .Start
				}
			case .CONTROLLERDEVICEADDED:
				if p := sdl.GameControllerOpen(ev.cdevice.which); p != nil {append(&pads, p)}
			case .CONTROLLERBUTTONDOWN:
				#partial switch sdl.GameControllerButton(ev.cbutton.button) {
				case .DPAD_UP: a = .Up
				case .DPAD_DOWN: a = .Down
				case .DPAD_LEFT: a = .Left
				case .DPAD_RIGHT: a = .Right
				case .A: a = .Accept
				case .B, .BACK: a = .Back
				case .START: a = .Start
				}
			case .CONTROLLERAXISMOTION:
				if sdl.GameControllerAxis(ev.caxis.axis) == .LEFTY {
					d := Action.None
					if ev.caxis.value < -16000 {d = .Up}
					if ev.caxis.value > 16000 {d = .Down}
					if d != stick_dir {a = d}
					stick_dir = d
				}
			case .MOUSEMOTION:
				for r in Row {
					if y := row_y(r); int(ev.motion.y) >= y - 4 && int(ev.motion.y) < y + ROW_H - 4 {u.sel = r}
				}
			case .MOUSEBUTTONDOWN:
				if ev.button.button == sdl.BUTTON_LEFT {
					y := row_y(u.sel)
					if int(ev.button.y) >= y - 4 && int(ev.button.y) < y + ROW_H - 4 {
						if u.sel >= .Play {
							a = .Accept
						} else {
							switch launcher_arrow_direction(int(ev.button.x)) {
							case -1: a = .Left
							case 1: a = .Right
							case: a = .Accept
							}
						}
					}
				}
			case .MOUSEWHEEL:
				a = ev.wheel.y > 0 ? .Up : .Down
			}
			switch a {
			case .None:
			case .Up: u.sel = u.sel == min(Row) ? max(Row) : Row(int(u.sel) - 1)
			case .Down: u.sel = u.sel == max(Row) ? min(Row) : Row(int(u.sel) + 1)
			case .Left: change(&u, u.sel, -1)
			case .Right: change(&u, u.sel, 1)
			case .Accept:
				if done, result := activate(&u); done {return result}
			case .Back: return .Quit
			case .Start: return .Play
			}
			if !sdl.PollEvent(&ev) {break}
		}
	}
}
