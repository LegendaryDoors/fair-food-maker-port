# Every SSEmitter configuration in v1.27, as the original passes it.
#
# Read from the setParticles:... call sites in the original code and checked
# against the stack stores in the disassembly (softfp: args from `random`
# on live at [sp+0..56]). The `site` field is the configuring method's IMP
# and the call instruction. Start/stop triggers, z-order and tint sources
# live in the screens that own each emitter; this file is data only.
#
# Keys are "<Class>.<ivar or role>". `frame` is the emitter view's frame in
# its superview (nib frame for nib emitters). `final` is the finalCenter
# argument in the emitter's own coordinates; where the original computed it
# from the frame (frame.size * 0.5) the computed value is stored and
# `final_from` says so. `variant` "offset" means the finalOffset: selector
# (0xB294C), whose `final` is an OFFSET from frame.size / 2.
#
# `tint` describes what the call passes; the screen supplies the Color (or
# null) to apply(). Use:
#   var e = SSEmitter.attach(outlet("crushedIce"), SSEmitterConfigs.frame_size(KEY))
#   SSEmitterConfigs.apply(e, KEY, null)

extends RefCounted

const CONFIGS := {
	"caCleanDirt.waterSplash": {
		"site": "-[caCleanDirt viewDidLoad] 0x14E0CC (call 0x14E850)",
		"frame": Rect2(129, 0, 62, 33), "variant": "center",
		"particles": ["ca_waterdrop.png"], "tint": "nil",
		"random": false, "interval": 0.01, "duration": 0.8, "repeat": true,
		"final": Vector2(0, 500), "final_from": "literal",
		"start_alpha": 0.0, "end_alpha": 1.0, "start_scale": 1.0, "end_scale": 1.0,
		"variance": [5, 0, 300, 0], "options": 3,
	},
	"caSelectChocolate.emitter": {
		"site": "-[caSelectChocolate viewDidLoad] 0x156174 (call 0x15664C)",
		"frame": Rect2(159, 162, 1, 1), "variant": "center",
		"particles": ["CA_Chocolate_Gtrate_PS1.png", "CA_Chocolate_Gtrate_PS2.png"],
		"tint": "selectedColor (nil at viewDidLoad; setTint: in showSugarBag: 0x157424)",
		"random": true, "interval": 0.05, "duration": 1.0, "repeat": true,
		"final": Vector2(0, 170), "final_from": "literal",
		"start_alpha": 1.0, "end_alpha": 0.0, "start_scale": 0.7, "end_scale": 0.7,
		"variance": [30, 0, -1, 0], "options": 3,
	},
	"caStirIngredients.fire": {
		"site": "-[caStirIngredients viewDidLoad] 0x159764 (call 0x159FE0)",
		"frame": Rect2(0, 360, 320, 24), "variant": "center",
		"particles": ["Candy_Apple_Flame_For_Pot_Anime_1.png",
			"Candy_Apple_Flame_For_Pot_Anime_2.png",
			"Candy_Apple_Flame_For_Pot_Anime_3.png"],
		"tint": "nil",
		"random": true, "interval": 0.05, "duration": 0.5, "repeat": true,
		"final": Vector2(160, 12), "final_from": "frame.size * 0.5",
		"start_alpha": 0.0, "end_alpha": 1.0, "start_scale": 0.5, "end_scale": 0.5,
		"variance": [0, 0, 0, 0], "options": 2,
	},
	"caStirIngredients.spoonTip": {
		"site": "-[caStirIngredients showSpoon] 0x15A320 (call 0x15AA58), mixer branches only",
		"frame": Rect2(9.5, 129.5, 1, 1), "variant": "center",
		"particles": ["White_Electric_Hand_Mixer_PS_1.png",
			"White_Electric_Hand_Mixer_PS_2.png",
			"White_Electric_Hand_Mixer_PS_3.png"],
		"tint": "infoDict[\"Color\"]",
		"random": true, "interval": 0.02, "duration": 0.1, "repeat": true,
		"final": Vector2(0.5, 0.5), "final_from": "frame.size * 0.5",
		"start_alpha": 0.0, "end_alpha": 1.0, "start_scale": 0.3, "end_scale": 0.3,
		"variance": [0, 0, 0, 0], "options": 1,
	},
	"ccbSelectChocolate.grateEmitter": {
		"site": "-[ccbSelectChocolate viewDidLoad] 0xBEE3C (call 0xBF268)",
		"frame": Rect2(80, 167, 160, 37), "variant": "center",
		"particles": ["CA_Chocolate_Gtrate_PS1.png", "CA_Chocolate_Gtrate_PS2.png"],
		"tint": "selectedColor (nil at viewDidLoad; setTint: in showSugarBag: 0xC003C)",
		"random": true, "interval": 0.05, "duration": 1.0, "repeat": true,
		"final": Vector2(0, 170), "final_from": "literal",
		"start_alpha": 1.0, "end_alpha": 0.0, "start_scale": 0.7, "end_scale": 0.7,
		"variance": [30, 0, -1, 0], "options": 3,
	},
	"ccbStirIngredients.fire": {
		"site": "-[ccbStirIngredients viewDidLoad] 0x1C16C (call 0x1C928)",
		"frame": Rect2(0, 360, 320, 24), "variant": "center",
		"particles": ["Candy_Apple_Flame_For_Pot_Anime_1.png",
			"Candy_Apple_Flame_For_Pot_Anime_2.png",
			"Candy_Apple_Flame_For_Pot_Anime_3.png"],
		"tint": "nil",
		"random": true, "interval": 0.05, "duration": 0.5, "repeat": true,
		"final": Vector2(160, 12), "final_from": "frame.size * 0.5",
		"start_alpha": 0.0, "end_alpha": 1.0, "start_scale": 0.5, "end_scale": 0.5,
		"variance": [0, 0, 0, 0], "options": 2,
	},
	"ccbStirIngredients.spoonTip": {
		"site": "-[ccbStirIngredients showSpoon] 0x1CD28 (call 0x1D460), mixer branches only",
		"frame": Rect2(9.5, 129.5, 1, 1), "variant": "center",
		"particles": ["White_Electric_Hand_Mixer_PS_1.png",
			"White_Electric_Hand_Mixer_PS_2.png",
			"White_Electric_Hand_Mixer_PS_3.png"],
		"tint": "infoDict[\"Color\"]",
		"random": true, "interval": 0.02, "duration": 0.1, "repeat": true,
		"final": Vector2(0.5, 0.5), "final_from": "frame.size * 0.5",
		"start_alpha": 0.0, "end_alpha": 1.0, "start_scale": 0.3, "end_scale": 0.3,
		"variance": [0, 0, 0, 0], "options": 1,
	},
	"cdFryDogViewController.fire": {
		"site": "-[cdFryDogViewController viewDidLoad] 0xD3D08 (call 0xD443E)",
		"frame": Rect2(0, 382, 320, 42), "variant": "center",
		"particles": ["Hot_Dog_Flame_PS_1.png", "Hot_Dog_Flame_PS_2.png",
			"Hot_Dog_Flame_PS_3.png", "Hot_Dog_Flame_PS_4.png"],
		"tint": "nil",
		"random": true, "interval": 0.05, "duration": 0.5, "repeat": true,
		"final": Vector2(160, 21), "final_from": "frame.size * 0.5",
		"start_alpha": 0.0, "end_alpha": 1.0, "start_scale": 0.5, "end_scale": 0.5,
		"variance": [0, 0, 0, 0], "options": 1,
	},
	# Configured but never started in v1.27: cdStir's only `start` is in
	# -[cdStirViewController startBurner] 0x131400, and no code references
	# the startBurner selector from cdStir. Kept so the wiring can show that.
	"cdStirViewController.spoonTip.pink": {
		"site": "-[cdStirViewController showSpoon] 0x130A88 (call 0x131142), pink mixer",
		"frame": Rect2(9.5, 129.5, 1, 1), "variant": "center",
		"particles": ["Hot_Dog_Mixer_Pink_PS_1.png", "Hot_Dog_Mixer_Pink_PS_2.png",
			"Hot_Dog_Mixer_Pink_PS_3.png"],
		"tint": "batterColor",
		"random": true, "interval": 0.02, "duration": 0.1, "repeat": true,
		"final": Vector2(0.5, 0.5), "final_from": "frame.size * 0.5",
		"start_alpha": 0.0, "end_alpha": 1.0, "start_scale": 0.3, "end_scale": 0.3,
		"variance": [0, 0, 0, 0], "options": 1,
	},
	"cdStirViewController.spoonTip.white": {
		"site": "-[cdStirViewController showSpoon] 0x130A88 (call 0x131142), white mixer",
		"frame": Rect2(9.5, 129.5, 1, 1), "variant": "center",
		"particles": ["Hot_Dog_Mixer_White_PS_1.png", "Hot_Dog_Mixer_White_PS_2.png",
			"Hot_Dog_Mixer_White_PS_3.png"],
		"tint": "batterColor",
		"random": true, "interval": 0.02, "duration": 0.1, "repeat": true,
		"final": Vector2(0.5, 0.5), "final_from": "frame.size * 0.5",
		"start_alpha": 0.0, "end_alpha": 1.0, "start_scale": 0.3, "end_scale": 0.3,
		"variance": [0, 0, 0, 0], "options": 1,
	},
	"cffDustSalt.saltSprites": {
		"site": "-[cffDustSalt viewDidLoad] 0x170C94 (call 0x170FDE)",
		"frame": Rect2(70, 140, 172, 124), "variant": "center",
		"particles": ["Fires_Salt_PS_1.png", "Fires_Salt_PS_2.png", "Fires_Salt_PS_3.png"],
		"tint": "nil",
		"random": true, "interval": 0.05, "duration": 0.5, "repeat": true,
		"final": Vector2(86, 62), "final_from": "frame.size * 0.5",
		"start_alpha": 1.0, "end_alpha": 0.0, "start_scale": 1.0, "end_scale": 1.0,
		"variance": [0, 0, 0, 0], "options": 3,
	},
	"fbtThrowballVC.smoke": {
		"site": "-[fbtThrowballVC viewDidLoad] 0x23660 (call 0x23D80)",
		"frame": Rect2(145, 280, 30, 30), "variant": "center",
		"particles": ["FootballGun_FX_1.png", "FootballGun_FX_2.png", "FootballGun_FX_3.png"],
		"tint": "nil",
		"random": false, "interval": 0.05, "duration": 1.0, "repeat": false,
		"final": Vector2(15, 15), "final_from": "frame.size * 0.5",
		"start_alpha": 1.0, "end_alpha": 0.0, "start_scale": 0.5, "end_scale": 1.0,
		"variance": [0, 0, 50, 50], "options": 2,
	},
	"fcSiftSugarVC.powder": {
		"site": "-[fcSiftSugarVC viewDidLoad] 0x9DF4C (call 0x9E08E)",
		"frame": Rect2(80, 145, 160, 48), "variant": "offset",
		"particles": ["sugar.png"], "tint": "nil",
		"random": false, "interval": 0.05, "duration": 0.5, "repeat": true,
		"final": Vector2(0, 200), "final_from": "offset; centre = offset + frame.size * 0.5",
		"start_alpha": 1.0, "end_alpha": 0.0, "start_scale": 1.0, "end_scale": 1.0,
		"variance": [0, 0, 80, 0], "options": 1,
	},
	"ipFlavorViewController.flavorMixSprites": {
		"site": "-[ipFlavorViewController showSugarBag:] 0xECD98 (call 0xECFD8)",
		"frame": Rect2(130, 115, 81, 298), "variant": "center",
		"particles": ["Ice_Pops_Flavor_Mix_PS_1.png", "Ice_Pops_Flavor_Mix_PS_2.png",
			"Ice_Pops_Flavor_Mix_PS_3.png"],
		"tint": "selectedColor (re-configured on every showSugarBag:)",
		"random": true, "interval": 0.05, "duration": 0.2, "repeat": true,
		"final": Vector2(40.5, 149), "final_from": "frame.size * 0.5",
		"start_alpha": 1.0, "end_alpha": 0.2, "start_scale": 1.0, "end_scale": 1.0,
		"variance": [0, 0, 0, 0], "options": 3,
	},
	"lsuSqueezeFruitViewController.freshJuice": {
		"site": "-[lsuSqueezeFruitViewController viewDidLoad] 0x670F0 (call 0x6738E)",
		"frame": Rect2(107, 145, 107, 42), "variant": "offset",
		"particles": ["lsu_juice_drop_two.png"],
		"tint": "fruitColor -- still nil at viewDidLoad (initFlavors runs in viewWillAppear: 0x674C0), so untinted",
		"random": false, "interval": 0.2, "duration": 1.0, "repeat": true,
		"final": Vector2(0, 250), "final_from": "offset; centre = offset + frame.size * 0.5",
		"start_alpha": 1.0, "end_alpha": 1.0, "start_scale": 1.0, "end_scale": 1.0,
		"variance": [0, 0, 20, 0], "options": 1,
	},
	"msFruitViewController.splash": {
		"site": "-[msFruitViewController viewDidLoad] 0x4B0A0 (call 0x4B3E0)",
		"frame": Rect2(20, 90, 279, 250), "variant": "center",
		"particles": ["Milk_Shake_Splash_PS_1.png", "Milk_Shake_Splash_PS_2.png",
			"Milk_Shake_Splash_PS_3.png", "Milk_Shake_Splash_PS_4.png"],
		"tint": "milkColor (set by initWithMilk:iceCream:iceCreamNum: 0x4AE6C, before viewDidLoad)",
		"random": false, "interval": 0.02, "duration": 0.5, "repeat": false,
		"final": Vector2(139.5, 125), "final_from": "frame.size * 0.5",
		"start_alpha": 1.0, "end_alpha": 0.0, "start_scale": 1.0, "end_scale": 1.0,
		"variance": [0, 0, 0, 0], "options": 2,
	},
	"scCrushIceViewController.crushedIce": {
		"site": "-[scCrushIceViewController viewDidLoad] 0x6F454 (call 0x6F86E)",
		"frame": Rect2(99, 261, 123, 164), "variant": "center",
		"particles": ["Grinding_Snow_PS_1.png", "Grinding_Snow_PS_2.png", "Grinding_Snow_PS_3.png"],
		"tint": "nil",
		"random": true, "interval": 0.05, "duration": 0.2, "repeat": true,
		"final": Vector2(61.5, 82), "final_from": "frame.size * 0.5",
		"start_alpha": 0.0, "end_alpha": 1.0, "start_scale": 1.0, "end_scale": 1.0,
		"variance": [0, 0, 0, 0], "options": 2,
	},
}


static func frame_size(key: String) -> Vector2:
	return (CONFIGS[key].frame as Rect2).size


## Configure `emitter` (an SSEmitter.gd node) exactly as the original call
## site does. `tint` is the Color the screen holds for that call's tint
## argument, or null where the original passes nil.
static func apply(emitter: Node, key: String, tint: Variant = null) -> void:
	var c: Dictionary = CONFIGS[key]
	var v: Array = c.variance
	var method := "set_particles_final_offset" if c.variant == "offset" \
		else "set_particles"
	emitter.call(method, c.particles, tint, c.random, c.interval, c.duration,
		c.repeat, c.final, c.start_alpha, c.end_alpha, c.start_scale,
		c.end_scale, v[0], v[1], v[2], v[3], c.options)
