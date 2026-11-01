# The coins panel: "COINS <n>" plate at the left, GET COINS button at the
# right. One window-level view in the original, re-parented onto each screen
# by the app delegate; the port rebuilds it on every screen change.
#
# From the original binary (on the device it shows on stand select):
#
#   -[CoinInfoView init]  0x12E3CC   frame (0,0,320,60), layer zPosition 100.
#       coinButton      UIButton (0,0,94,64), image btn_get_coins.png
#                       (foreground: natural 94x63, centred), centre
#                       (320 - 47, 32) -> (273, 32); coinStoreClick:.
#       coinLabelImage  UIImageView lable_coins.png (94x68), centre (47, 34).
#       coinLabel       UILabel (0,0,76,20), Helvetica 20, centred, clear,
#                       text "%d" totalCoins, centre (labelImage.x + 2, 46).
#       Observes COIN_NOTIFICATION_VALUE_CHANGED -> coinValueChanged 0x12EBE4
#       (label <- "%d" totalCoins). Ported as the
#       CoinManager.coin_value_changed signal.
#   -[CoinInfoView coinStoreClick:] 0x12E9F0   "store" sound, then push
#       CoinStoreViewController (or an offline alert).
#   -[CoinManager totalCoins] 0x12F1BC   defaults "COINS" + temporaryCoins;
#   -[AppDelegate giveStartingAmounts] 0x1A070   addCoins:100 on first run.
#   -[AppDelegate navigationController:didShowViewController:animated:] 0x1AC3C
#       removes the view, then unless the new screen's class is in HIDDEN_ON
#       adds it to that screen's view (last subview, so on top) at:
#         StandSelectViewController  centre (160,30); plate centre (160,30);
#                                    label centre (162,46)
#         msFruitViewController      centre (380,367)   (mostly off screen:
#         scPourSyrupViewController  centre (380,367)    only the plate shows,
#         ccSugarPickerViewController centre (380,387)   at the right edge)
#         msScoopViewController      centre (380,306)
#         MakeViewController         centre (380,367), skipped when classStr
#                                    is "FOOD_COLLAGE"
#         everything else            centre (160,30); plate centre (47,34);
#                                    label centre (49,46)
#
# GET COINS pushes CoinStoreViewController as coinStoreClick: does (minus its
# reachability check and offline alert -- port choice: the store always opens).
#
# TIMING: the panel moves when the push / pop slide ENDS
# (Nav.transition_finished = navigationController:didShowViewController:
# animated:, which UIKit sends after the slide), not as it starts. During the
# slide the outgoing screen keeps the panel it had and slides out with it, as
# the one CoinInfoView does on the phone; the incoming screen gets it at the
# end. With transitions off Nav emits transition_finished at once (before
# screen_changed). The one-view rules didShow applies are kept: the panel
# that was on screen is dropped before it appears on the new one (so there
# is never more than one), it is re-shown at alpha 1 (setAlpha:1, 0x1AC3C),
# it is not added at all for a FOOD_COLLAGE MakeViewController, and the
# view's hidden flag -- which MakeViewController's viewDidAppear: /
# viewDidDisappear: (0xA54D4 / 0xA556C) set -- is a property of the one view
# that survives the move (`hidden`, set_hidden()).

extends Node
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const HIDDEN_ON := [
	"EatViewController", "StoreViewController", "CoinStoreViewController",
	"MainMenuViewController", "InfoViewController", "FreezerViewController",
	"bpTossDartVC", "ftTossBallVC", "ffTossFrogVC", "wsRaceVC",
	"PrizeViewController", "cdBatterSelectViewController",
	"cdRollDogViewController", "cdBatterCoatingViewController",
	"cdFryDogViewController", "ccMachineViewController",
	"msSelectFlavorViewController", "msBlenderViewController",
	"scScoopIceViewController", "lsuPourWaterViewController",
	"fcBatterSelectVC", "fcFryBatterVC", "fcSiftSugarVC",
	"kcShakeToFlattenKernelsViewController",
	"kcShakeToColorKernelsViewController", "ipFreezerViewController",
	"mb_ThrowBallVC", "wm_hitmole", "MoreGamesViewController",
	"fbtThrowballVC", "cffDustSalt",
]

const VIEW_SIZE := Vector2(320, 60)
const BUTTON_RECT := Rect2(226, 0, 94, 64)       # centre (273, 32)
const LABEL_SIZE := Vector2(76, 20)
const LABEL_FONT_SIZE := 20
const LABEL_Y := 46.0
const PLATE_ART := "lable_coins.png"
const BUTTON_ART := "btn_get_coins.png"

const DEFAULT_CENTER := Vector2(160, 30)
const OFF_RIGHT := Vector2(380, 367)
const PLACEMENT := {
	"StandSelectViewController": {"center": Vector2(160, 30), "plate": Vector2(160, 30), "label_x": 162.0},
	"msFruitViewController": {"center": OFF_RIGHT},
	"scPourSyrupViewController": {"center": OFF_RIGHT},
	"ccSugarPickerViewController": {"center": Vector2(380, 387)},
	"msScoopViewController": {"center": Vector2(380, 306)},
	"MakeViewController": {"center": OFF_RIGHT},
}

const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans", "Liberation Sans", "Arial"]

## MakeViewController's classStr that the app delegate never adds the panel
## to (0x1AC3C: `isEqualToString:@"FOOD_COLLAGE"` -> skip addSubview:).
const NO_PANEL_CLASS_STR := "FOOD_COLLAGE"

var _view: Node2D
var _label: Label
## The one CoinInfoView's `hidden` (UIView setHidden:), kept across moves.
var hidden := false


func _ready() -> void:
	Nav.transition_finished.connect(_on_screen_shown)
	CoinManager.coin_value_changed.connect(_on_coin_value_changed)


## [[delegate coinsView] setHidden:]. `apply_now` false only records the
## flag (a screen leaving whose own panel must not change mid-slide).
func set_hidden(h: bool, apply_now: bool = true) -> void:
	hidden = h
	if apply_now and _view != null and is_instance_valid(_view):
		_view.visible = not h


## coinValueChanged (0x12EBE4).
func _on_coin_value_changed(_total: int) -> void:
	refresh()


## navigationController:didShowViewController:animated: (0x1AC3C), after the
## slide: [coinsView removeFromSuperview], then -- unless the shown class is
## in HIDDEN_ON or is a FOOD_COLLAGE Make -- setCenter: per PLACEMENT,
## setAlpha:1 and addSubview: onto the shown screen (last, so on top).
func _on_screen_shown(screen_name: String) -> void:
	var host := Nav.current_node()
	# removeFromSuperview: the panel leaves the screen it was on.
	if _view != null and is_instance_valid(_view) and _view.get_parent() != host:
		_view.queue_free()
	_view = null
	_label = null
	if host == null or HIDDEN_ON.has(screen_name):
		return
	if screen_name == "MakeViewController" \
			and str(host.get("_class_str")) == NO_PANEL_CLASS_STR:
		return
	# A screen brought back by Nav (keeps_state_on_push) may still carry the
	# panel built when it first appeared -- the original has ONE CoinInfoView
	# that the app delegate re-places on every navigation, never a second one.
	# Reuse it (unless the screen already queued it for deletion itself).
	var old := host.get_node_or_null("CoinInfoView")
	if old != null and not old.is_queued_for_deletion():
		host.move_child(old, -1)
		_view = old
		for c in old.get_children():
			if c is Label:
				_label = c
		refresh()
	else:
		_build(screen_name, host)
	_view.modulate.a = 1.0             # setAlpha:1
	_view.visible = not hidden


func refresh() -> void:
	if _label != null:
		_label.text = str(CoinManager.total_coins())


func _build(screen_name: String, host: Node) -> void:
	var place: Dictionary = PLACEMENT.get(screen_name, {})
	var center: Vector2 = place.get("center", DEFAULT_CENTER)

	_view = Node2D.new()
	_view.name = "CoinInfoView"
	_view.position = center - VIEW_SIZE * 0.5
	host.add_child(_view)

	var plate := _sprite(PLATE_ART)
	var plate_center: Vector2 = Vector2.ZERO
	if plate != null:
		var half: Vector2 = plate.texture.get_size() * 0.5
		plate_center = place.get("plate", half)
		plate.position = plate_center - half
		_view.add_child(plate)

	_label = Label.new()
	var label_x: float = place.get("label_x", plate_center.x + 2.0)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UILabelFrame.set_frame(_label, Rect2(Vector2(label_x, LABEL_Y) - LABEL_SIZE * 0.5,
		LABEL_SIZE))
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var font := SystemFont.new()
	font.font_names = PackedStringArray(FONT_NAMES)
	_label.add_theme_font_override("font", font)
	_label.add_theme_font_size_override("font_size", LABEL_FONT_SIZE)
	_label.add_theme_color_override("font_color", Color.BLACK)   # UILabel default
	_label.text = str(CoinManager.total_coins())
	_view.add_child(_label)

	var button := TextureButton.new()
	button.position = BUTTON_RECT.position
	button.size = BUTTON_RECT.size
	if Assets.has_image(BUTTON_ART):
		button.texture_normal = Assets.texture(BUTTON_ART)
	button.ignore_texture_size = true
	button.stretch_mode = TextureButton.STRETCH_KEEP_CENTERED
	button.mouse_filter = Control.MOUSE_FILTER_PASS   # see ConsumableButton
	button.pressed.connect(_on_get_coins)
	_view.add_child(button)


func _sprite(image_name: String) -> Sprite2D:
	if not Assets.has_image(image_name):
		return null
	var s := Sprite2D.new()
	s.texture = Assets.texture(image_name)
	s.centered = false
	return s


func _on_get_coins() -> void:
	Audio.play("store")
	Nav.push("CoinStoreViewController")
