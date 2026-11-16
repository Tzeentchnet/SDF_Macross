// The port's main package: ps2.boot boots the disc with the functions
// setup.sh generated into port/src/rec. This file is yours: ps2.Boot's
// setup and hooks are where a port changes the game (ps-recomp's
// docs/porting.md).
package main

import "core:os"
import "ps:ps2"
import "rec"

TITLE :: "Chou Jikuu Yousai Macross"

main :: proc() {
	l := local_read()
	settings(l)
	// ps2.boot returns only on a failure.
	ps2.boot(
		{
			disc = l.image,
			title = TITLE,
			learned = learned(l, .Learned_Iop, .Learned_Iop, .Learned_Iop_Key),
			learned_ee = learned(l, .Learned_Ee, .Learned_Ee, .Learned_Ee_Key),
			cards = cards(l),
			hooks = hooks,
		},
	)
	os.exit(1)
}

// Once the runtime is set up: the generated functions in place of the
// interpreter. A port replaces game functions here too.
hooks :: proc() -> bool {
	rec.register_all()
	return true
}
