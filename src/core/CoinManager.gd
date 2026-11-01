# CoinManager (0x12EDA8..), ported. Autoload "CoinManager".
#
# INTERFACE CONTRACT (fixed; same rule as core/PrizeManager.gd):
# one function per ObjC selector, snake_cased, same arguments in the same
# order; +sharedManager is the autoload itself. Do not rename or change arity.
#
# From the original binary:
#   addCoins:      0x12EE48  TEMPORARY_COINS += n; synchronize; post
#                            COIN_NOTIFICATION_VALUE_CHANGED {totalCoins}.
#   spendCoins:    0x12EF64  TEMPORARY_COINS -= n; the same notification.
#                            No floor: the callers check the total first.
#   updateCoins    0x12F080  empty.
#   syncCoins:     0x12F084  calls updateCoins only when temporaryCoins == 0
#                            -- i.e. nothing, ever. (The server sync that
#                            once folded TEMPORARY_COINS into COINS is gone
#                            from this build.)
#   showIndicatorView / removeIndicatorView  0x12F0C8 / 0x12F108
#                            UnityExternals "Syncing..." spinner; nothing
#                            calls either in this build.
#   temporaryCoins 0x12F13C  integerForKey "TEMPORARY_COINS".
#   currentCoins   0x12F17C  integerForKey "COINS" (never written by v1.27).
#   totalCoins     0x12F1BC  currentCoins + temporaryCoins.
#   total          0x12F1EC  totalCoins (ConsumableFundSource).
#   add:           0x12F1FC  sends add: to itself -- unbounded recursion; no
#                            caller exists in the binary (selref xrefs).
#   spend:         0x12F20C  spendCoins: (ConsumableFundSource).
#   isSyncing      0x12F21C  the ivar, never set -> NO.
#
# So every coin the player owns lives in TEMPORARY_COINS; the 100 starting
# coins are -[AppDelegate giveStartingAmounts] (core/AppDelegate.gd).
# GameState.coins is a read/write view onto total_coins() (see GameState.gd).

extends Node

## COIN_NOTIFICATION_VALUE_CHANGED, userInfo {totalCoins}. CoinHUD (the
## original's CoinInfoView coinValueChanged 0x12EBE4) listens to this.
signal coin_value_changed(total_coins: int)

const KEY_COINS := "COINS"
const KEY_TEMPORARY_COINS := "TEMPORARY_COINS"

## setDelegate: -- the AppDelegate in the original (coinSyncFailed /
## coinSyncSucceeded:, both empty).
var delegate: Variant = null


func add_coins(n: int) -> void:
	var temp := temporary_coins()
	Defaults.set_integer_for_key(temp + n, KEY_TEMPORARY_COINS)
	Defaults.synchronize()
	_post_value_changed()


func spend_coins(n: int) -> void:
	var temp := temporary_coins()
	Defaults.set_integer_for_key(temp - n, KEY_TEMPORARY_COINS)
	Defaults.synchronize()
	_post_value_changed()


func _post_value_changed() -> void:
	coin_value_changed.emit(total_coins())


## PORT CHOICE: the original's add: recurses into itself until the stack
## overflows; it has no caller. The port forwards to addCoins: instead of
## reproducing a crash.
func add(n: int) -> void:
	add_coins(n)


func spend(n: int) -> void:
	spend_coins(n)


func update_coins() -> void:
	pass


func sync_coins(_flag: bool) -> void:
	var temp := temporary_coins()
	if temp <= 0 and temp >= 0:
		update_coins()


## No spinner exists in the port and nothing in v1.27 calls these.
func show_indicator_view() -> void:
	pass


func remove_indicator_view() -> void:
	pass


func temporary_coins() -> int:
	return Defaults.integer_for_key(KEY_TEMPORARY_COINS)


func current_coins() -> int:
	return Defaults.integer_for_key(KEY_COINS)


func total_coins() -> int:
	return current_coins() + temporary_coins()


func total() -> int:
	return total_coins()


func is_syncing() -> bool:
	return false
