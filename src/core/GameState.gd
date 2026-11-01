# State carried between the steps of one food.
#
# The original threaded this through initialisers -- msSelectFlavor passed its
# chosen colour into msScoopViewController::initWithMilk:, which passed milk +
# ice cream into the fruit screen, and so on, until msBlender combined
# milkColor, iceCreamColor and fruitAveColor into finalColor.
#
# A single per-run object is simpler than reproducing that chain and makes the
# decorate/eat screens (which need the finished item) trivial to feed.
#
# The colour pipeline here is the one the binary actually implements, which is
# not the one the port assumed. Two corrections:
#
#   1. Syrup is folded into the *milk* when it is poured (0.8 milk / 0.2 syrup,
#      -[msSelectSyrupViewController addSyrupColorToMilk:] 0x52994). It is not
#      a separate term at the end.
#   2. finalColor is the mean of exactly three colours and is unconditional --
#      milk, ice cream, and a fruit ratio that is a *grey*, not a colour
#      average (-[msBlenderViewController AverageAllColors] 0x562F8).

extends Node

signal changed

## The player's coins: a read/write view onto -[CoinManager totalCoins]
## (core/CoinManager.gd), which keeps them in the "TEMPORARY_COINS" user
## default (plus "COINS", never written by v1.27). Reading answers the total;
## assigning turns the difference into addCoins: / spendCoins:, so the value
## persists and the coins panel hears COIN_NOTIFICATION_VALUE_CHANGED.
## -[AppDelegate giveStartingAmounts] (0x1A070, core/AppDelegate.gd) grants
## the first 100. Prefer calling CoinManager directly in new code.
var coins: int:
	get:
		return CoinManager.total_coins()
	set(value):
		var delta := value - CoinManager.total_coins()
		if delta > 0:
			CoinManager.add_coins(delta)
		elif delta < 0:
			CoinManager.spend_coins(-delta)
## Arguments for the next PrizeViewController push (INTERFACE CONTRACT).
## The original allocs the controller and calls its setters
## (setPrizes:, setBackgroundFile:, ...) before pushing; Nav.push takes only a
## name, so the caller fills this with the snake_cased property names
## ({"prizes": ..., "background_file": ...}) and PrizeViewController reads it
## in on_enter. Same pattern for any other pushed controller that needs args:
## key = controller class name.
var screen_args: Dictionary = {}
## SUPERSEDED: core/Consumable.gd now reads and writes the
## original's "<key>_FIRST_TIME_ALERT" / "<key>_QUANTITY" user defaults
## through core/Defaults.gd. These two dictionaries are kept (API stability)
## but nothing reads them any more.
var consumable_first_time: Dictionary = {}
## (Superseded, see above.) The original kept "<key>_QUANTITY" in user
## defaults, so a mixer bought on one stir screen and not consumed by that
## screen's nextClick: (which zeroes it) was still active on the next stir
## screen of any food -- and still is, now across restarts too.
var consumable_quantity: Dictionary = {}

## Food prefix currently being made, e.g. "ms".
var food: String = ""

var milk_color: Color = Color.WHITE
var milk_texture: String = ""
var ice_cream_color: Color = Color.WHITE
var ice_cream_texture: String = ""
var ice_cream_scoops: int = 0
## Tag strings, as the original stored them ("0", "105", "201") -- not names.
var fruits: Array[String] = []
var syrup_color: Color = Color.WHITE
var syrup_poured: bool = false
var blended: bool = false

## The finished food, as it travels from the last making step through
## StickSelect to MakeViewController and on to EatViewController.
##
## This is the original's own infoDict shape, not a port invention: a
## dictionary keyed by layer name, each entry
##
##   { "Properties": { IsEdible, ViewIndex, Type, ItemCenterX, ItemCenterY,
##                     Rotation? },
##     "Image": Image or Texture2D }
##
## Either image type is accepted -- MakeViewController converts a Texture2D on
## the way in. This comment previously said Texture2D only, which was wrong in
## the other direction: Make required an Image and silently dropped anything
## else, so producers that followed this doc had their layers discarded.
##
## built by the last making screen (msBlender `nextClick:` 0x56608 emits
## MilkShake + MilkShakeGlass), extended by StickSelect `nextClick:` (0x646A0,
## which adds Straw / stickImg / packID), and consumed by MakeViewController as
## its `customCategories`.
##
## It replaces three mismatched `set_meta` carriers -- "stick_select_info",
## "decorate_info" and "custom_categories" -- that three separate screens had
## each invented because none of them owned this file. The names did not agree,
## so the chain was silently broken: MakeViewController read a key nothing ever
## wrote and fell back to rebuilding the bake itself.
var custom_categories: Dictionary = {}

## addExtra:tag:animate: (0x4F6B8) overwrites round-robin past 20 rather than
## growing the array.
const FRUIT_CAP := 20

## Weights from addSyrupColorToMilk: 0x3F4CCCCD and 0x3E4CCCCD.
const SYRUP_MILK_WEIGHT := 0.8
const SYRUP_WEIGHT := 0.2

## Tags that do NOT increment fruitAveColor's numerator.
##
## FULLY GROUNDED. initFlavors (0x54A7C) zeroes the accumulator d10 at 0x54D48
## with an addend d12 = 1.0, divides by [fruits count] at 0x5546E, and feeds
## the single quotient to all three channels at 0x5548C -- hence a grey ratio.
##
## The dispatch at 0x5501C splits three ways: tag > 199 -> nut switch,
## tag > 99 -> candy switch, tag <= 6 -> fruit switch, anything else -> the
## default block at 0x552B0. All 21 jump-table targets land 4 bytes before a
## `vadd.f32 d10, d10, d12`; the default block only builds the ingredient art
## and never touches d10.
##
## So exactly one tag is excluded: 7 (ms_Blueberry), via `cmp r0,#6; bhi`.
## Fruit 0-6, all candy 100-109 and all nuts 200-203 count. The result is
## therefore white unless Blueberry was used.
const FRUIT_AVE_UNCOUNTED := ["7"]

var _fruit_count := 0


func begin(food_prefix: String) -> void:
	food = food_prefix
	milk_color = Color.WHITE
	milk_texture = ""
	ice_cream_color = Color.WHITE
	ice_cream_texture = ""
	ice_cream_scoops = 0
	fruits.clear()
	_fruit_count = 0
	syrup_color = Color.WHITE
	syrup_poured = false
	blended = false
	custom_categories = {}
	changed.emit()


## The fruit screen's initFlavors empties addedFruits and zeroes fruitCount on
## every appearance (0x4E2D8), so re-entering that screen starts the ingredient
## list over rather than adding to it.
func reset_fruits() -> void:
	fruits.clear()
	_fruit_count = 0
	changed.emit()


## Record one added ingredient by tag. Past FRUIT_CAP the original keeps
## writing at fruitCount % 20, so the array holds the last 20 in a rotating
## order rather than the first 20.
func add_fruit(tag: String) -> void:
	# -[msFruitViewController addFruitWithImage:..]: fruitCount is incremented
	# FIRST; past 20 the slot at fruitCount % 20 is replaced (the 21st item
	# lands at index 1, not 0).
	_fruit_count += 1
	if _fruit_count > FRUIT_CAP and fruits.size() >= FRUIT_CAP:
		fruits[_fruit_count % FRUIT_CAP] = tag
	else:
		fruits.append(tag)
	changed.emit()


## Fold a poured syrup into the milk. The blender never sees syrup as its own
## component -- by the time it runs, this has already happened.
func add_syrup_color_to_milk(syrup: Color) -> void:
	syrup_color = syrup
	syrup_poured = true
	milk_color = Color(
		milk_color.r * SYRUP_MILK_WEIGHT + syrup.r * SYRUP_WEIGHT,
		milk_color.g * SYRUP_MILK_WEIGHT + syrup.g * SYRUP_WEIGHT,
		milk_color.b * SYRUP_MILK_WEIGHT + syrup.b * SYRUP_WEIGHT)
	changed.emit()


## fruitAveColor: a grey whose level is (counted tags / total tags). It is
## white whenever every added tag counts, which is the common case.
##
## Divergence: with no fruit at all the original computes 0/0 and builds a
## UIColor from NaN. What that renders as was never verified, so the port
## returns white -- the value it would have taken for any all-counting list --
## rather than propagating NaN into final_color().
func fruit_ave_color() -> Color:
	if fruits.is_empty():
		return Color.WHITE
	var counted := 0
	for tag in fruits:
		if not FRUIT_AVE_UNCOUNTED.has(tag):
			counted += 1
	var ratio := float(counted) / float(fruits.size())
	return Color(ratio, ratio, ratio)


## AverageAllColors (0x562F8): the mean of exactly three colours, always all
## three, with no syrup term and no test for whether fruit was added.
func final_color() -> Color:
	var m := _quantise(milk_color)
	var i := _quantise(ice_cream_color)
	var f := _quantise(fruit_ave_color())
	return Color(
		(m.r + i.r + f.r) / 3.0,
		(m.g + i.g + f.g) / 3.0,
		(m.b + i.b + f.b) / 3.0)


## Each component is filled into an 8-bit 1x1 bitmap and read back before the
## mean is taken, so it lands on a 1/255 step. Reproduced for fidelity; the
## rounding mode is assumed to be round-to-nearest and was not verified.
static func _quantise(c: Color) -> Color:
	return Color(
		roundi(c.r * 255.0) / 255.0,
		roundi(c.g * 255.0) / 255.0,
		roundi(c.b * 255.0) / 255.0)


func describe() -> String:
	return "%s milk=%s scoops=%d fruits=%s syrup=%s blended=%s" % [
		food, milk_color.to_html(false), ice_cream_scoops,
		str(fruits), str(syrup_poured), str(blended)]
