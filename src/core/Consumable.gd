# Port of Consumable (0x12F24C): a coin-priced one-shot such as the mystery
# stick pick, paid from the CoinManager.
#
# From the original binary:
#   purchaseConsumable (0x12F77C) -> purchaseConsumableShowFirstTimeMessage:YES
#   (0x12F5A0): if the "<key>_FIRST_TIME_ALERT" default is unset, set it and
#   show the consumable's first-time message with a single "Cool" button;
#   "Cool" -> doPurchase:NO isFree:YES (0x12F8F0): no coins spent, delegate
#   consumablePurchased:. Otherwise doPurchase:NO -> if total coins < cost,
#   the original shows a MediaBrix ad for location "Food" instead of buying;
#   else spend cost, delegate consumablePurchased:. The delegate's
#   consumablePurchaseFailed:error: 2 path shows "You do not have enough
#   coins." (0x133C24).
#
# PORT CHOICE: the not-enough-coins ad is replaced by that alert text.
#
# Sounds: neither alert makes one. The first-time
# message's delegate is the Consumable, whose alertView:clickedButtonAtIndex:
# (0x12FB38) only calls doPurchase:isFree: for "Cool"; the no-coins alert has
# delegate nil on every food screen (and MakeViewController's own, delegate
# self, plays nothing either, 0xA8C70). Screen.show_alert plays button_press
# unless told not to, so the first-time alert passes click_sound = false and
# a not-enough-coins alert that a caller's on_failed puts up is made silent
# here (_silence_no_coins_alerts) -- the 35 screens that build it keep their
# code.
#
# Persistence: the first-time flag and the quantity are the
# original's user defaults again -- firstTimeAlertKey (0x12FAF8)
# "<key>_FIRST_TIME_ALERT" and quantityKey (0x12FAB8) "<key>_QUANTITY",
# through core/Defaults.gd -- and the fund source is CoinManager (total /
# spend:, ConsumableFundSource), so all three survive a restart.

# Loaded by path (the class_name registry is editor-built; see Screen.gd).
extends RefCounted

var key: String
var name: String
var cost: int
var first_time_message: String = ""

## quantity / setQuantity: (0x12F808 / 0x12F790): the "<key>_QUANTITY"
## default. Shared by key across screens, as in the original.
var quantity: int:
	get:
		return Defaults.integer_for_key(key + "_QUANTITY")
	set(value):
		Defaults.set_integer_for_key(value, key + "_QUANTITY")
		Defaults.synchronize()

## Called with `free: bool` when the purchase went through.
var on_purchased: Callable
## Called when the buyer cannot afford it.
var on_failed: Callable

const FIRST_TIME_BUTTON := "Cool"
const NO_COINS_MESSAGE := "You do not have enough coins."


func _init(p_key: String, p_name: String, p_cost: int) -> void:
	key = p_key
	name = p_name
	cost = p_cost


## The Screen that last asked to buy (alerts go there).
var _host: Node = null


## purchaseConsumable. `host` is the Screen that shows alerts.
func purchase(host: Node) -> void:
	_host = host
	if first_time_message != "" and not Defaults.bool_for_key(key + "_FIRST_TIME_ALERT"):
		Defaults.set_bool_for_key(true, key + "_FIRST_TIME_ALERT")
		Defaults.synchronize()
		# purchaseConsumableShowFirstTimeMessage: (0x12F5A0): title @"",
		# cancel nil, other "Cool", delegate self -- silent (0x12FB38).
		host.call("show_alert", first_time_message, [FIRST_TIME_BUTTON],
			func(_choice: String) -> void: _do_purchase(true), false)
		return
	_do_purchase(false)


func _do_purchase(free: bool) -> void:
	if not free:
		if CoinManager.total() < cost:
			if on_failed.is_valid():
				var before := _alerts_on(_host)
				on_failed.call()
				_silence_no_coins_alerts(before)
			return
		CoinManager.spend(cost)
	if on_purchased.is_valid():
		on_purchased.call(free)


## The UIAlertViews (Screen.show_alert's layers) currently on `host`.
static func _alerts_on(host: Node) -> Array:
	var out: Array = []
	if host == null or not is_instance_valid(host):
		return out
	for c in host.get_children():
		if c is CanvasLayer and c.get("message_text") != null:
			out.append(c)
	return out


## Any not-enough-coins alert the failure callback just put up stays silent
## (its delegate makes no sound -- header).
func _silence_no_coins_alerts(before: Array) -> void:
	for a in _alerts_on(_host):
		if not before.has(a) and str(a.get("message_text")) == NO_COINS_MESSAGE:
			a.set("click_sound", false)


## The no-coins alert as the food screens build it (delegate nil, one OK),
## for callers that want it without writing it out.
static func show_no_coins_alert(host: Node) -> void:
	if host != null and host.has_method("show_alert"):
		host.call("show_alert", NO_COINS_MESSAGE, ["OK"], Callable(), false)
