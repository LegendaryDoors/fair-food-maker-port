# The white / pink mixer consumable pair every stir screen carries.
#
# Read from ccbStirIngredients (initWithNibName: 0x1BEA0,
# viewDidLoad 0x1C16C, buyClick: 0x1E258, buyPinkClick: 0x1E2C4,
# consumablePurchased: 0x1DF68, consumablePurchaseFailed:error: 0x1E184,
# nextClick: 0x1E410); caStir / cdStir / dicStir / fcStir repeat it with their
# own names and rates.
#   keys DM_CONSUMABLE_MIXER (cost table ToolWhiteMixer, fallback 6) and
#   DM_CONSUMABLE_PINK_MIXER (ToolPinkMixer, fallback 11);
#   badges btn_IAP_mixer at centre (50, 250.5) and btn_IAP_pink_mixer at
#   (50, 350.5), offsets (0,-25) / (65,3);
#   click: "store" sound, purchaseConsumable;
#   purchased: quantity += 1, bubbles alpha 0, and if the spoon is showing and
#   the quantity just became 1, showSpoon (the tool swaps in place; showSpoon
#   then hides both badges);
#   the pink mixer wins when both are owned (draggableTouchMoved:);
#   nextClick: zeroes both quantities.

extends RefCounted

const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const ToolKind := preload("res://core/StirTool.gd").Kind

const WHITE_KEY := "DM_CONSUMABLE_MIXER"
const PINK_KEY := "DM_CONSUMABLE_PINK_MIXER"
const WHITE_COST := 6
const PINK_COST := 11
const WHITE_ART := "btn_IAP_mixer.png"
const PINK_ART := "btn_IAP_pink_mixer.png"
const WHITE_CENTER := Vector2(50, 250.5)
const PINK_CENTER := Vector2(50, 350.5)
const WHITE_MESSAGE := "Try out the automatic mixer! Mix faster, make a mess, and cook like a pro! Try it for FREE now!"
const PINK_MESSAGE := "Try out the ultra deluxe pink mixer! Mix the fastest, make the ultimate mess, and cook in style! Try it for FREE now!"

var white: RefCounted
var pink: RefCounted
var white_button: TextureButton
var pink_button: TextureButton

## Called after a purchase with the Consumable that was bought.
var on_purchased: Callable


## `white_name` / `pink_name` are the screen's consumable names
## ("Mixer_50Mix" / "PinkMixer_50Mix" on the banana stir).
func setup(screen: Node, white_name: String, pink_name: String, p_on_purchased: Callable) -> void:
	on_purchased = p_on_purchased
	white = ConsumableScript.new(WHITE_KEY, white_name, WHITE_COST)
	white.set("first_time_message", WHITE_MESSAGE)
	pink = ConsumableScript.new(PINK_KEY, pink_name, PINK_COST)
	pink.set("first_time_message", PINK_MESSAGE)
	for c: RefCounted in [white, pink]:
		c.set("on_failed", func() -> void:
			screen.call("show_alert", ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	white.set("on_purchased", func(_free: bool) -> void: _bought(white))
	pink.set("on_purchased", func(_free: bool) -> void: _bought(pink))

	white_button = _badge(screen, "buyMixer", WHITE_ART, WHITE_COST, WHITE_CENTER,
		func() -> void:
			Audio.play("store")
			white.call("purchase", screen))
	pink_button = _badge(screen, "buyPinkMixer", PINK_ART, PINK_COST, PINK_CENTER,
		func() -> void:
			Audio.play("store")
			pink.call("purchase", screen))


func _badge(screen: Node, node_name: String, art: String, cost: int, center: Vector2,
		on_press: Callable) -> TextureButton:
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = node_name
	b.call("setup", art, 0, -25, cost, 65, 3)
	b.position = center - b.size * 0.5
	b.pressed.connect(on_press)
	screen.add_child(b)
	return b


func _bought(c: RefCounted) -> void:
	c.set("quantity", int(c.get("quantity")) + 1)
	if on_purchased.is_valid():
		on_purchased.call(c)


## draggableTouchMoved:'s precedence: pink, then white, then the spoon.
func kind() -> int:
	if int(pink.get("quantity")) > 0:
		return ToolKind.PINK_MIXER
	if int(white.get("quantity")) > 0:
		return ToolKind.WHITE_MIXER
	return ToolKind.SPOON


func any_owned() -> bool:
	return kind() != ToolKind.SPOON


func set_badges_visible(v: bool) -> void:
	if white_button != null:
		white_button.visible = v
	if pink_button != null:
		pink_button.visible = v


## nextClick: setQuantity:0 on both.
func reset_quantities() -> void:
	white.set("quantity", 0)
	pink.set("quantity", 0)
