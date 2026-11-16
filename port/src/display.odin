// Window handling the runtime leaves to ports: starting in borderless
// fullscreen, and F11 to toggle it while playing. (Alt+Enter is not used:
// Return is the keyboard's Start button.)
package main

import "ps:core"
import sdl "vendor:sdl2"

@(private = "file")
display: struct {
	fullscreen: bool,
	applied:    bool,
	held:       bool,
}

display_init :: proc(fullscreen: bool) {
	display = {fullscreen = fullscreen}
}

// The game's window. The runtime keeps its handle private; it is the only
// window open once the launcher's has closed, so take the newest live id.
@(private = "file")
display_window :: proc() -> ^sdl.Window {
	if w := sdl.GetKeyboardFocus(); w != nil {return w}
	if w := sdl.GetMouseFocus(); w != nil {return w}
	for id := u32(16); id >= 1; id -= 1 {
		if w := sdl.GetWindowFromID(id); w != nil {return w}
	}
	return nil
}

@(private = "file")
display_set :: proc(on: bool) -> bool {
	win := display_window()
	if win == nil {return false}
	if sdl.SetWindowFullscreen(win, on ? sdl.WINDOW_FULLSCREEN_DESKTOP : {}) != 0 {return false}
	sdl.ShowCursor(on ? sdl.DISABLE : sdl.ENABLE)
	return true
}

// Run at each vblank (ps2.Boot.vblank), on the thread that owns the window.
display_vblank :: proc() {
	if core.headless {return}
	if !display.applied {
		if !display.fullscreen || display_set(true) {display.applied = true}
	}
	keys := sdl.GetKeyboardState(nil)
	down := keys[sdl.Scancode.F11] != 0
	if down && !display.held {
		if display_set(!display.fullscreen) {display.fullscreen = !display.fullscreen}
	}
	display.held = down
}
