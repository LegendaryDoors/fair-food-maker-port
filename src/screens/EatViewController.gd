# The shared eat/drink screen -- the finished, decorated food is consumed
# here, either by biting holes in it or by drinking it through a straw.
#
# Read from the original binary (drink bound 240 not 198, cup mask and bite
# applied upside down as the original's unflipped clip does, liquid category
# forced edible, startOver pops straight to root):
#   EatViewController  initWithClassStr:andInfoDict: 0xA13C8, viewDidLoad
#                      0xA148C, createEatView 0xA245C, createDrinkView 0xA274C,
#                      delayStartupEmitterBalloons 0xA1E68, viewWillAppear:
#                      0xA22C8, startOver: 0xA2958, back: 0xA2E5C, restore:
#                      0xA2F34, store: 0xA324C
#   EatView            initWithFrame:eatItem:andDelegate: 0xC1830 (one
#                      EatSubview per category, ascending ViewIndex),
#                      touchesBegan: 0xC2354 (bite / start drinking),
#                      touchesEnded: 0xC29A4, drinkTick 0xC1E04,
#                      hitTest: 0xC2324 (drink mode only takes y < 240)
#   EatSubview         initWithImage:properties: 0xBE41C (IsEdible),
#                      drawBite: 0xBE488, maskCup: 0xBE55C
#
# The mechanics, as read -- NOT a tap counter:
#
#  * EAT: every tap renders bite%d.png (1..3, random) into a 320x480 grey
#    mask centred on the touch and re-clips every EDIBLE layer through its
#    inverse -- i.e. a bite-shaped hole is erased from the food at the touch
#    point, cumulatively. Non-edible layers (glass, decals, attachments,
#    backgrounds) are untouched, so decorations float over the holes --
#    that is the shipped behaviour.
#  * DRINK (Milkshake / Lemon Shake-Up): while the finger holds the top of
#    the screen, a 0.05s tick moves every edible layer down by 1% of its
#    height (4.8px) and re-clips it against a screen-fixed cup mask
#    (black inside the cup = keep), so the liquid level drops. When a
#    layer's centre passes the view bottom the drink is empty and the
#    looping drink sound gives way to a slurp.
#
# The finished item arrives from MakeViewController.next: as `pending`
# (the port of EatItem/DrinkItem initWithThumbnail:data:images: -- one
# full-screen composite per category plus its properties).

extends "res://core/Screen.gd"

## Set by MakeViewController just before it pushes this screen; the original
## passed the EatItem/DrinkItem through setEatItem:/setDrinkItem: (0xA9294).
## {class_str, item_name, drink, liquid_mask, liquid_category,
##  layers: [{name, edible, image: Image}]}  -- layers in ViewIndex order.
static var pending: Dictionary = {}


static func set_pending(item: Dictionary) -> void:
	pending = item


const EatItem := preload("res://core/EatItem.gd")

## store: (0xA324C): the alerts it shows (delegate nil, so their OK is silent).
const STORE_OK_TITLE := "Success!"
const STORE_OK := "Saved to freezer!"
## ...and the failure, title @"".
const STORE_FAILED := "Unable to save image."
## EatItem writeToFile: (0xBDE38) sets filepath on entry, before anything is
## written -- so after one attempt on an EatItem, store: never writes again,
## even if that attempt failed.
var _store_attempted := false


# -- bites (EatView touchesBegan: 0xC2354) -----------------------------

## "bite%d.png", arc4random()%3 + 1 (0x6BCC94); files are bite1..bite3.png,
## 125x117 white-on-black RGB.
const BITE_VARIANTS := 3
## biteScale 0.75 (0x3F400000) for Candy Apple / French Fries (by itemName)
## and FUNNEL_CAKE (by classStr); 1.0 otherwise (createEatView 0xA245C,
## EatView init 0xC1830).
const BITE_SCALE_SMALL := 0.75
const SMALL_BITE_ITEMS := ["Candy Apple", "French Fries"]
const SMALL_BITE_CLASS := "FUNNEL_CAKE"

# -- drinking (drinkTick 0xC1E04, hitTest 0xC2324) ---------------------

## performSelector:afterDelay:0.05 (0x3FA99999A0000000).
const DRINK_TICK := 0.05
## center.y += frame.height * 0.01 (DAT_000c227c) = 4.8px per tick.
const DRINK_STEP_FRAC := 0.01
## hitTest: (0xC2324) returns nil for touches at y >= 240 in drink mode
## (`vcmpe s2, s0` against the literal 0x43700000 = 240.0 at 0xC2350, read
## from the disassembly); touchesBegan:'s own CGRectContainsPoint((0,0,320,240)) is
## the same bound. The port used to say 198, which no instruction holds.
const DRINK_MAX_Y := 240.0
## Empty when an edible layer's centre passes the 480px view bottom.
const DRINK_EMPTY_OFFSET := 240.0

# -- the finale balloons (viewDidLoad 0xA148C + 0xA1E68) ---------------

## Thirteen 80x80 aspect-fit image views (0x42A00000), parked at
## (-999,-999) (0xC479C000) until launch.
const BALLOONS := [
	"circus_ballbubble", "circus_clownbubble", "circus_greenbubble",
	"circus_pinkbubble", "circus_yellowbubble", "circus_yellowbubble",
	"circus_pinkbubble", "circus_greenbubble",
	"Star_Emitters_End_Game_PS_1", "Star_Emitters_End_Game_PS_2",
	"Star_Emitters_End_Game_PS_3", "Star_Emitters_End_Game_PS_4",
	"Star_Emitters_End_Game_PS_5",
]
const BALLOON_SIZE := 80.0
const BALLOON_PARK := Vector2(-999, -999)
## Launched 0.25s after load (0x3FD0000000000000).
const BALLOON_DELAY := 0.25
## Start centre: (rand%200 + 60, rand%50 + 520); duration rand%100/100 + 1.5
## seconds, UIViewAnimationCurveEaseIn; end centre (3x - 320, y - 650)
## (DAT_000a2188 = -160.0 doubled into the x term, DAT_000a218c = -650.0).
const BALLOON_X_BASE := 60
const BALLOON_X_SPAN := 200
const BALLOON_Y_BASE := 520
const BALLOON_Y_SPAN := 50
const BALLOON_MIN_SECONDS := 1.5
const BALLOON_END_Y := -650.0
## cheer + maker_finished both at volume 0.75 (0x3F400000).
const FINALE_VOLUME := 0.75

# -- crumbs (emitAtTouchLocation: 0xA347C, addBiteParticles:AtLocation:
#    0xA3668) -- plain UIImageViews, not the GL particle system ------------

## EatView touchesBegan: (0xC2354) ends every touch -- bite or drink -- with
## emitAtTouchLocation:, which adds four crumbs at the touch: each a random
## one of three images (per classStr), centred there, then
## animateWithDuration: 0.2 s (double 0x3FC99999A0000000) delay 0, options 3
## (curve bits 0 = ease-in-out) to alpha 0 and a centre offset by
## 50 - (rand%100 + 1) on each axis; the completion removes it.
const CRUMBS := {
	"COTTON_CANDY": ["Cotton_Eat_Crumbs_PS_1", "Cotton_Eat_Crumbs_PS_2", "Cotton_Eat_Crumbs_PS_3"],
	"KETTLE_CORN": ["KC_Eat_Popcorn_PS_1", "KC_Eat_Popcorn_PS_2", "KC_Eat_Popcorn_PS_3"],
}
const CRUMBS_DEFAULT := ["Eat_Crumbs_PS_1", "Eat_Crumbs_PS_2", "Eat_Crumbs_PS_3"]
const CRUMB_COUNT := 4
const CRUMB_SECONDS := 0.2
const CRUMB_SPREAD := 50

var _item: Dictionary = {}
## Per layer: {name, edible, pristine: Image, image: Image, sprite: Sprite2D,
##  texture: ImageTexture}
var _layers: Array = []
var _layer_root: Node2D
var _drink := false
var _drinking := false
var _drink_offset := 0.0
var _drink_empty := false
var _drink_accum := 0.0
var _cup_material: ShaderMaterial
var _bite_cache: Array = []
var _bite_scale := 1.0


func on_enter() -> void:
	_item = pending
	if _item.is_empty():
		push_warning("[Eat] no pending item -- was this screen pushed directly?")
	_drink = bool(_item.get("drink", false))

	var item_name := str(_item.get("item_name", ""))
	_bite_scale = 1.0
	if SMALL_BITE_ITEMS.has(item_name) \
			or str(_item.get("class_str", "")) == SMALL_BITE_CLASS:
		_bite_scale = BITE_SCALE_SMALL

	if _drink:
		_make_cup_material()
	_build_view()
	_build_balloons()
	_view_will_appear_chrome()
	set_process(true)

	var timer := get_tree().create_timer(BALLOON_DELAY)
	timer.timeout.connect(_launch_balloons)


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## createEatView 0xA245C / createDrinkView 0xA274C: swap the instruction art
## and the eat-again button per mode, stack one subview per category.
func _build_view() -> void:
	if _layer_root != null and is_instance_valid(_layer_root):
		_layer_root.queue_free()
	_layers.clear()
	_drink_offset = 0.0
	_drink_empty = false
	_drinking = false
	if _cup_material != null:
		_cup_material.set_shader_parameter("drop_px", 0.0)

	_layer_root = Node2D.new()
	_layer_root.name = "EatView"
	add_child(_layer_root)
	move_child(_layer_root, 0)   # sendSubviewToBack:

	var liquid := str(_item.get("liquid_category", ""))
	for entry: Dictionary in _item.get("layers", []):
		var pristine: Image = entry.get("image")
		if pristine == null:
			continue
		var img: Image = pristine.duplicate()
		var itex := ImageTexture.create_from_image(img)
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.texture = itex
		var edible := bool(entry.get("edible", false))
		# initWithFrame:drinkItem:andDelegate: (0xC1C54) forces the liquid
		# category edible (setIsEdible:YES); every other layer keeps its own
		# IsEdible, so an edible decoration drains with the drink.
		if _drink and str(entry.get("name", "")) == liquid:
			edible = true
		if _drink and edible and _cup_material != null:
			sprite.material = _cup_material
		_layer_root.add_child(sprite)
		_layers.append({
			"name": entry.get("name", ""), "edible": edible,
			"pristine": pristine, "image": img,
			"sprite": sprite, "texture": itex,
		})

	var inst := outlet("instIV")
	var inst_tex := _tex("inst_drink.png" if _drink else "inst_eat.png")
	if inst is Sprite2D and inst_tex != null:
		(inst as Sprite2D).texture = inst_tex
	var again := outlet("eatAgainButton")
	var again_tex := _tex("btn_drink_again.png" if _drink else "btn_eat_again.png")
	if again is TextureButton and again_tex != null:
		(again as TextureButton).texture_normal = again_tex


## maskCup: 0xBE55C keeps content only where the (screen-fixed) cup mask is
## BLACK -- CGImageMask inverse-alpha: white blocks the paint. Because the
## layers only ever move down, re-clipping the moved image every tick and
## sampling the mask live in screen space are pixel-identical, so the port
## uses a shader instead of mutating the image 20 times a second.
##
## The mask is applied UPSIDE DOWN, like every CGContextClipToMask in a UIKit
## image context (the MaskedIV quirk): drinkTick (0xC1E04) draws the mask PNG
## into an unflipped 320x480 grey bitmap, and maskCup: clips through it inside
## UIGraphicsBeginImageContext at (x, -frame.y, w, h) with no CTM flip -- so
## screen row y is governed by mask row 479 - y, wherever the layer has moved.
## The shipped masks are authored for that: Ice_Cream_Glass_Mask_Full.png's
## keep-region narrows toward the TOP of the file and lsu_cup_mask_full.png's
## opens at row ~48, above the cup; flipped, both fit their glass at
## (58,180) / (54,180). The port sampled them upright, which put the liquid's
## window in the wrong place. The flip is taken in the layer's own UV plus the
## drop offset, so letterboxing cannot misalign it.
func _make_cup_material() -> void:
	var mask := _tex(str(_item.get("liquid_mask", "")))
	if mask == null:
		return
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
uniform sampler2D cup_mask : filter_linear, repeat_disable;
uniform float drop_px = 0.0;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float screen_y = UV.y * 480.0 + drop_px;
	c.a *= 1.0 - texture(cup_mask, vec2(UV.x, 1.0 - screen_y / 480.0)).r;
	COLOR = c;
}
"""
	_cup_material = ShaderMaterial.new()
	_cup_material.shader = shader
	_cup_material.set_shader_parameter("cup_mask", mask)


func _build_balloons() -> void:
	for art: String in BALLOONS:
		var t := _tex(art + ".png")
		if t == null:
			continue
		var s := Sprite2D.new()
		s.texture = t
		s.centered = true
		s.position = BALLOON_PARK
		var sz := t.get_size()
		if sz.x > 0 and sz.y > 0:
			var f := minf(BALLOON_SIZE / sz.x, BALLOON_SIZE / sz.y)
			s.scale = Vector2(f, f)
		s.set_meta("balloon", true)
		add_child(s)   # addSubview: -- above the nib buttons, as shipped


## delayStartupEmitterBalloons 0xA1E68.
func _launch_balloons() -> void:
	if not is_inside_tree():
		return
	for child in get_children():
		if not (child is Sprite2D and child.has_meta("balloon")):
			continue
		var b := child as Sprite2D
		var start := Vector2(
			BALLOON_X_BASE + randi() % BALLOON_X_SPAN,
			BALLOON_Y_BASE + randi() % BALLOON_Y_SPAN)
		b.position = start
		var seconds := float(randi() % 100) / 100.0 + BALLOON_MIN_SECONDS
		var target := Vector2(3.0 * start.x - 320.0, start.y + BALLOON_END_Y)
		create_tween().tween_property(b, "position", target, seconds) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	Audio.play("cheer", linear_to_db(FINALE_VOLUME))
	Audio.play("maker_finished", linear_to_db(FINALE_VOLUME))


# -- eating ------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if _drink:
		if mb.pressed:
			# hitTest 0xC2324: only the strip above y=240 reaches the view.
			if mb.position.y < DRINK_MAX_Y:
				_start_drinking()
				_emit_crumbs(mb.position)
				get_viewport().set_input_as_handled()
		else:
			_stop_drinking()
	elif mb.pressed:
		_bite_at(mb.position)
		_emit_crumbs(mb.position)
		get_viewport().set_input_as_handled()


## emitAtTouchLocation: / addBiteParticles:AtLocation:. Added to the
## controller's view, so they fly over the buttons and balloons too.
func _emit_crumbs(at: Vector2) -> void:
	var cs := str(_item.get("class_str", ""))
	if cs == "TROPHY_CASE" or cs == "FOOD_COLLAGE":
		return
	var arts: Array = CRUMBS.get(cs, CRUMBS_DEFAULT)
	for i in CRUMB_COUNT:
		var t := _tex(str(arts[randi() % arts.size()]) + ".png")
		if t == null:
			continue
		var s := Sprite2D.new()
		s.texture = t
		s.centered = true
		s.position = at
		add_child(s)
		var to := at + Vector2(CRUMB_SPREAD - (randi() % 100 + 1),
			CRUMB_SPREAD - (randi() % 100 + 1))
		var tw := create_tween().set_parallel(true) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(s, "position", to, CRUMB_SECONDS)
		tw.tween_property(s, "modulate:a", 0.0, CRUMB_SECONDS)
		tw.chain().tween_callback(s.queue_free)


## touchesBegan: 0xC2354, eat branch.
func _bite_at(pos: Vector2) -> void:
	# Eat_apple for the munching foods (set for Candy Apple in createEatView),
	# cff_Eat for French Fries, plain eat otherwise.
	var item_name := str(_item.get("item_name", ""))
	if item_name == "Candy Apple":
		Audio.play("Eat_apple")
	elif item_name == "French Fries":
		Audio.play("cff_Eat")
	else:
		Audio.play("eat")

	var bite := _bite_factors(randi() % BITE_VARIANTS)
	if bite.is_empty():
		return
	var bw: int = bite["w"]
	var bh: int = bite["h"]
	var lut: PackedFloat32Array = bite["f"]
	var origin := Vector2i((pos - Vector2(bw, bh) * 0.5).round())

	for layer: Dictionary in _layers:
		if not bool(layer["edible"]):
			continue
		var img: Image = layer["image"]
		var w := img.get_width()
		var h := img.get_height()
		for by in bh:
			var y := origin.y + by
			if y < 0 or y >= h:
				continue
			for bx in bw:
				var x := origin.x + bx
				if x < 0 or x >= w:
					continue
				var f := lut[by * bw + bx]
				if f <= 0.0:
					continue
				var p := img.get_pixel(x, y)
				if p.a <= 0.0:
					continue
				# drawBite: 0xBE488 -- CGImageMask inverse alpha: the bite's
				# grey level blocks that much of the repaint.
				p.a *= 1.0 - f
				img.set_pixel(x, y, p)
		(layer["texture"] as ImageTexture).update(img)


## Bite art rendered to erase factors, scaled by biteScale, cached per
## variant. The art is opaque white-on-black RGB; its grey level (rendered
## into the CGColorSpaceCreateDeviceGray bitmap) is the mask sample.
func _bite_factors(variant: int) -> Dictionary:
	if _bite_cache.is_empty():
		_bite_cache.resize(BITE_VARIANTS)
	if _bite_cache[variant] is Dictionary:
		return _bite_cache[variant]
	var t := _tex("bite%d.png" % (variant + 1))
	if t == null:
		return {}
	var img := t.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	if _bite_scale != 1.0:
		img.resize(int(img.get_width() * _bite_scale),
			int(img.get_height() * _bite_scale))
	var w := img.get_width()
	var h := img.get_height()
	# The bite reaches the food upside down. touchesBegan: (0xC2354) draws it
	# into an unflipped grey CGBitmapContext at (x - w/2, y - h/2) -- CG's
	# bottom-left origin, so it lands centred on row 480 - y, upright -- and
	# drawBite: (0xBE488) clips through that mask in a UIKit image context
	# with no CTM flip, which turns it over again: the hole is centred on the
	# touch with the bite art mirrored top-to-bottom. (Same MaskedIV quirk as
	# the cup mask above.)
	img.flip_y()
	var lut := PackedFloat32Array()
	lut.resize(w * h)
	for y in h:
		for x in w:
			var p := img.get_pixel(x, y)
			lut[y * w + x] = (p.r + p.g + p.b) / 3.0 * p.a
	var entry := {"w": w, "h": h, "f": lut}
	_bite_cache[variant] = entry
	return entry


# -- drinking ----------------------------------------------------------

func _start_drinking() -> void:
	if _drinking:
		return
	_drinking = true
	_drink_accum = 0.0
	# The original never hides instIV here -- the banner stays up.
	_drink_step()   # touchesBegan calls drinkTick immediately
	if _drink_empty:
		Audio.loop("slurp")
	else:
		Audio.loop("drink")


## touchesEnded/Cancelled 0xC29A4/0xC2A50: stop both players, cancel the tick.
func _stop_drinking() -> void:
	_drinking = false
	Audio.stop("drink")
	Audio.stop("slurp")


func _process(delta: float) -> void:
	if not _drinking:
		return
	_drink_accum += delta
	while _drink_accum >= DRINK_TICK:
		_drink_accum -= DRINK_TICK
		_drink_step()


## drinkTick 0xC1E04.
func _drink_step() -> void:
	if _drink_empty:
		return
	_drink_offset += 480.0 * DRINK_STEP_FRAC
	for layer: Dictionary in _layers:
		if bool(layer["edible"]):
			(layer["sprite"] as Sprite2D).position.y = _drink_offset
	if _cup_material != null:
		_cup_material.set_shader_parameter("drop_px", _drink_offset)
	# Empty once the (full-screen) layer's centre, 240 + offset, passes the
	# 480px view bottom.
	if _drink_offset > DRINK_EMPTY_OFFSET:
		_drink_empty = true
		Audio.stop("drink")
		if _drinking:
			Audio.loop("slurp")


# -- the nib buttons ---------------------------------------------------

## back: 0xA2E5C -- stop the drink, pop back to the decorate screen.
func _on_back() -> void:
	_stop_drinking()
	Audio.play("button_press")
	Nav.back()


## restore: 0xA2F34 -- rebuild the eat/drink view from the stored item:
## a fresh, unbitten food.
func _on_restore() -> void:
	_stop_drinking()
	Audio.play("button_press")
	_build_view()


## startOver: 0xA2958 -- popToRootViewControllerAnimated: (straight to the
## main menu, no intermediate screen shown). The ad flag and the rate-us
## alert it also triggers are ad/analytics surface, not ported.
func _on_startOver() -> void:
	_stop_drinking()
	Audio.play("button_press")
	Nav.pop_to_root()


## viewWillAppear: (0xA22C8): fromFreezer hides saveBtn; classStr
## FOOD_COLLAGE or TROPHY_CASE hides eatAgainButton, saveBtn and instIV and
## moves shareBtn into saveBtn's frame. (Its startOver disable/enable pair
## nets out to nothing -- see the note at the bottom.)
func _view_will_appear_chrome() -> void:
	var save := outlet("saveBtn")
	if bool(_item.get("from_freezer", false)) and save is CanvasItem:
		(save as CanvasItem).visible = false
	var cs := str(_item.get("class_str", ""))
	if cs != "FOOD_COLLAGE" and cs != "TROPHY_CASE":
		return
	var again := outlet("eatAgainButton")
	if again is CanvasItem and again != self:
		(again as CanvasItem).visible = false
	if save is Control and save != self:
		(save as Control).visible = false
		var share := outlet("shareBtn")
		if share is Control and share != self:
			(share as Control).position = (save as Control).position
			(share as Control).size = (save as Control).size
	var inst := outlet("instIV")
	if inst is CanvasItem and inst != self:
		(inst as CanvasItem).visible = false


## store: (0xA324C): stop the drink, button_press, and -- when the eatItem
## has no file yet -- write the item to savePath/"%f.plist" and alert the
## result. The check reads the eatItem ivar, which a DRINK never sets (Make's
## next: uses setDrinkItem:), so for a milkshake / shake-up it is always nil
## and every press saves another copy -- ported as read. A freezer item
## already has its file (and its saveBtn hidden).
func _on_store() -> void:
	if _drink:
		_stop_drinking()
	Audio.play("button_press")
	if not _drink and (_store_attempted or str(_item.get("filepath", "")) != ""):
		return
	var target: Dictionary = _item.duplicate() if _drink else _item
	if _drink:
		target.erase("filepath")
	_store_attempted = true
	var ok: bool = EatItem.store_pending(target)
	show_alert(STORE_OK if ok else STORE_FAILED, ["OK"], Callable(), false,
		STORE_OK_TITLE if ok else "")


## share: (0xA3014) emails a picture of the food (MFMailComposeViewController).
## PORT CHOICE: no mail on a desktop port -- an iOS 6 alert says so, as the
## freezer's share button does.
const SHARE_UNAVAILABLE := "Sharing by email isn't available in this version."


func _on_share() -> void:
	Audio.play("button_press")
	show_alert(SHARE_UNAVAILABLE, ["OK"], Callable(), false)


## viewWillDisappear: (0xA2430) is only the super call. Every way off this
## screen (back: 0xA2E5C, startOver: 0xA2958) stops the drink first, so this
## is a no-op on those paths; it covers the dev browser leaving mid-drink.
func on_exit() -> void:
	_stop_drinking()


## Opted in, though nothing in the original pushes
## over this screen (store:, share: and restore: all stay on it; back: and
## startOver: pop). If something ever does, viewWillAppear: (0xA22C8) is what
## re-runs -- the fromFreezer / TROPHY_CASE / FOOD_COLLAGE chrome, which is
## idempotent -- and viewDidAppear: (0xA242C) is empty. The bitten food stays
## bitten; the balloons are viewDidLoad's (0xA148C) and do not rise again.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	_view_will_appear_chrome()

# NOT PORTED, deliberately, rather than guessed:
#
#  * Mail sharing (share: 0xA3014) -- a whole subsystem; the button says so
#    instead. (The freezer, store: 0xA324C -> core/EatItem.gd, is ported.)
#  * (The bite crumbs, emitAtTouchLocation: 0xA347C / addBiteParticles:
#    0xA3668, are plain UIImageView animations, not GL particles, and are
#    ported above.)
#  * viewWillAppear:'s startOver disable/enable pair (0xA22C8): it disables
#    the home button and re-enables it through enableStartOver in the same
#    breath, netting out to nothing observable.
#  * (The fromFreezer / TROPHY_CASE / FOOD_COLLAGE variants of
#    viewWillAppear: are ported: _view_will_appear_chrome.)
