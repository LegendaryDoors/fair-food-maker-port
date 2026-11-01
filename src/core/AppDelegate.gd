# AppDelegate, ported: launch-time user defaults and the per-screen
# bookkeeping it kept. Autoload "AppDelegate" (after Defaults/CoinManager).
#
# From the original binary (the first block read from the disassembly):
#
#   applicationDidFinishLaunching: 0x19610
#       CoinManager delegate = self; builds the coins panel (core/CoinHUD.gd);
#       if boolForKey FF_KEY_EVERYTHING: setBool YES FF_KEY_ICE_POP and
#       FF_KEY_KETTLE_CORN, synchronize. Everything else is ad / analytics /
#       store SDK setup (SponsorPay, AdColony, Chartboost, Flurry, Adjust,
#       Facebook) -- no port.
#
#   giveStartingAmounts 0x1A070 -- called once per launch from
#   -[IAPlistManager refreshIAPlistDidFinishSuccessfully:] 0x177378 whether
#   the refresh succeeded or not. Four one-time blocks:
#       NotFirstRun   DartCount               = GameData.BalloonStart  ?: 30
#                     FishTossBallCount       = GameData.FishbowlStart ?: 30
#                     MilkBottlePlayCountKey  = GameData.MilkBottleStart ?: 20
#                     WhackAMolePlayCountKey  = GameData.WhackAMoleStart ?: 10
#                     FootballTossPlayCountKey = GameData.FootballTossStart ?: 10
#                     (+ cancelAllLocalNotifications)
#       NotFirstRun2  FrogTossCountKey        = GameData.FrogStart  ?: 25
#                     WaterShooterCountKey    = GameData.WaterStart ?: 15
#       NotFirstRun3  each of the seven counts is raised to its GameData
#                     value if below it.
#       NotFirstRun4  CoinManager addCoins:100, syncCoins:YES.
#     (The ?: fallbacks are `IT EQ; MOVEQ R2,#imm` at 0x1A238..0x1A2C0.)
#
#   navigationController:willShowViewController:animated: 0x1A980
#       ccSugarPickerViewController -> previousScreen = "10Fill",
#                                      cottonStatusBool = YES;
#       Store / CoinStore / StickSelect / ccMachine / Make -> untouched;
#       anything else -> cottonStatusBool = NO. (Read back by the store
#       screens' logging and by the cotton-candy lock-state restore.)
#
#   navigationController:didShowViewController:animated: 0x1AC3C -- the coins
#       panel placement, already ported in core/CoinHUD.gd.
#
# PORT CHOICES:
#   * GameData comes from the "IAPlist" the app downloads from
#     central.sunstormserver.com; there is no bundled copy and the server is
#     gone, so iaplistDict is nil and every GameData value reads 0. The ?:
#     fallbacks are therefore the values a player gets today; NotFirstRun3
#     never raises anything. giveStartingAmounts runs at start-up instead of
#     after the (unreachable) refresh.
#   * The port ships every pack unlocked (see core/Screen.gd). That stance is
#     made visible to code that asks the original's question -- boolForKey:
#     "FF_KEY_..." -- by REGISTERING (registerDefaults:, never written to
#     disk) every IAPKey in data/IAP.json as YES. The binary itself never
#     calls registerDefaults:.

extends Node

## The import cache's data/IAP.json (Assets).
const IAP_TABLE := "IAP"

## GameData values from the (absent) IAPlist. Kept as a table so the reads
## stay visible; all 0 today.
var game_data: Dictionary = {}

## didShowViewController's analytics fields (setGameName:/setGameStep:/...).
var game_name: String = ""
var game_step: String = ""
var if_decorate := false
var class_name_str: String = ""
var should_show_ad := false


var _launched := false


func _ready() -> void:
	if Assets.is_ready():
		_register_unlocks()
		CoinManager.delegate = self
		_application_did_finish_launching()
		give_starting_amounts()
		_launched = true
	else:
		# First launch: the unlock table (IAP.json) arrives with the import.
		# Everything that reads it -- and the launch steps after it, in their
		# order -- waits for Assets.invalidate(); nothing can be played before.
		CoinManager.delegate = self
		Assets.cache_changed.connect(_finish_launching_after_import)
	Nav.screen_changed.connect(_navigation_controller_will_show)


func _finish_launching_after_import() -> void:
	if _launched or not Assets.is_ready():
		return
	_launched = true
	Assets.cache_changed.disconnect(_finish_launching_after_import)
	_register_unlocks()
	_application_did_finish_launching()
	give_starting_amounts()


func _register_unlocks() -> void:
	var table: Variant = Assets.json(IAP_TABLE)
	if not (table is Dictionary):
		return
	var reg := {}
	for k in table:
		var entry: Variant = table[k]
		if entry is Dictionary:
			var key := str((entry as Dictionary).get("IAPKey", ""))
			if key.begins_with("FF_KEY_"):
				reg[key] = true
	Defaults.register_defaults(reg)


## The user-defaults part of applicationDidFinishLaunching: (0x19610).
func _application_did_finish_launching() -> void:
	if Defaults.bool_for_key("FF_KEY_EVERYTHING"):
		Defaults.set_bool_for_key(true, "FF_KEY_ICE_POP")
		Defaults.set_bool_for_key(true, "FF_KEY_KETTLE_CORN")
		Defaults.synchronize()
	should_show_ad = false


func _game_data(key: String) -> int:
	return int(game_data.get(key, 0))


## -[AppDelegate giveStartingAmounts] (0x1A070).
func give_starting_amounts() -> void:
	if not Defaults.bool_for_key("NotFirstRun"):
		var balloon := _game_data("BalloonStart")
		var fishbowl := _game_data("FishbowlStart")
		var milk := _game_data("MilkBottleStart")
		var mole := _game_data("WhackAMoleStart")
		var football := _game_data("FootballTossStart")
		Defaults.set_integer_for_key(balloon if balloon != 0 else 30, "DartCount")
		Defaults.set_integer_for_key(fishbowl if fishbowl != 0 else 30, "FishTossBallCount")
		Defaults.set_integer_for_key(milk if milk != 0 else 20, "MilkBottlePlayCountKey")
		Defaults.set_integer_for_key(mole if mole != 0 else 10, "WhackAMolePlayCountKey")
		Defaults.set_integer_for_key(football if football != 0 else 10, "FootballTossPlayCountKey")
		Defaults.set_bool_for_key(true, "NotFirstRun")
		Defaults.synchronize()
	if not Defaults.bool_for_key("NotFirstRun2"):
		var frog := _game_data("FrogStart")
		var water := _game_data("WaterStart")
		Defaults.set_integer_for_key(frog if frog != 0 else 25, "FrogTossCountKey")
		Defaults.set_integer_for_key(water if water != 0 else 15, "WaterShooterCountKey")
		Defaults.set_bool_for_key(true, "NotFirstRun2")
		Defaults.synchronize()
	if not Defaults.bool_for_key("NotFirstRun3"):
		var raise := {
			"DartCount": _game_data("BalloonStart"),
			"FishTossBallCount": _game_data("FishbowlStart"),
			"FrogTossCountKey": _game_data("FrogStart"),
			"WaterShooterCountKey": _game_data("WaterStart"),
			"MilkBottlePlayCountKey": _game_data("MilkBottleStart"),
			"FootballTossPlayCountKey": _game_data("FootballTossStart"),
			"WhackAMolePlayCountKey": _game_data("WhackAMoleStart"),
		}
		for key: String in raise:
			if Defaults.integer_for_key(key) < int(raise[key]):
				Defaults.set_integer_for_key(int(raise[key]), key)
		Defaults.set_bool_for_key(true, "NotFirstRun3")
		Defaults.synchronize()
	if not Defaults.bool_for_key("NotFirstRun4"):
		CoinManager.add_coins(100)
		CoinManager.sync_coins(true)
		Defaults.set_bool_for_key(true, "NotFirstRun4")
		Defaults.synchronize()


## navigationController:willShowViewController:animated: (0x1A980), the
## user-defaults part. Nav announces a screen after it is built, which is
## also after the original's readers (their init / viewDidLoad) ran.
const COTTON_STATUS_UNTOUCHED := [
	"StoreViewController", "CoinStoreViewController",
	"StickSelectViewController", "ccMachineViewController",
	"MakeViewController",
]


func _navigation_controller_will_show(screen_name: String) -> void:
	if screen_name == "ccSugarPickerViewController":
		Defaults.set_object_for_key("10Fill", "previousScreen")
		Defaults.set_bool_for_key(true, "cottonStatusBool")
	elif not COTTON_STATUS_UNTOUCHED.has(screen_name):
		Defaults.set_bool_for_key(false, "cottonStatusBool")
	Defaults.synchronize()


## CoinManagerDelegate (0x1BD88 / 0x1BD8C): both empty.
func coin_sync_failed() -> void:
	pass


func coin_sync_succeeded(_info: Variant) -> void:
	pass
