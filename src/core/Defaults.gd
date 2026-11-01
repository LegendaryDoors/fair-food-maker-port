# NSUserDefaults, ported. Autoload "Defaults".
#
# The original keeps every persistent fact in [NSUserDefaults standardUserDefaults]
# (coins, prize unlocks, high scores, one-time notices, consumable counts...).
# Port code that reads or writes a key should call the method named after the
# selector it is porting, snake_cased, with the same argument order:
#
#   [d boolForKey:k]            -> Defaults.bool_for_key(k)
#   [d setBool:v forKey:k]      -> Defaults.set_bool_for_key(v, k)
#   [d integerForKey:k]         -> Defaults.integer_for_key(k)
#   [d setInteger:v forKey:k]   -> Defaults.set_integer_for_key(v, k)
#   [d floatForKey:k] / setFloat:forKey: / doubleForKey: / setDouble:forKey:
#   [d objectForKey:k] / setObject:forKey: / stringForKey: / arrayForKey: /
#   dictionaryForKey: / removeObjectForKey: / synchronize / registerDefaults:
#
# Missing keys answer like Foundation does: false / 0 / 0.0 / null.
# registerDefaults: values are a fallback layer and are never written to disk,
# exactly as on iOS.
#
#   [d valueForKey:k] / setValue:forKey: (KVC; NSUserDefaults answers them as
#   objectForKey: / setObject:forKey:) -> value_for_key / set_value_for_key
#
# Storage is user://defaults.json, written on every set (the data is tiny).
# Headless runs (the dev harnesses) never touch the disk, so a test can't
# inherit or leave behind a saved state. A harness that needs to exercise the
# disk round trip points use_storage_for_test() at a scratch file.
#
# Who writes what: coins (CoinManager:
# "TEMPORARY_COINS", "COINS"), prize unlocks (PrizeManager: the prize's
# IAPKey -> YES), consumables (Consumable: "<key>_QUANTITY",
# "<key>_FIRST_TIME_ALERT"), launch flags and minigame play counts
# (AppDelegate: "NotFirstRun".."NotFirstRun4", "DartCount", ...), and the
# per-screen keys each screen's own port writes.

extends Node

const PATH := "user://defaults.json"

var _values: Dictionary = {}
var _registered: Dictionary = {}
var _persist := true
var _path := PATH


func _ready() -> void:
	_persist = DisplayServer.get_name() != "headless"
	_load()


func _load() -> void:
	_values = {}
	if _persist and FileAccess.file_exists(_path):
		var f := FileAccess.open(_path, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				_values = parsed


func _save() -> void:
	if not _persist:
		return
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_values, "\t"))


## Dev harnesses only: switch the backing store (and whether it is written),
## then reload from it -- a simulated app restart. Pass PATH and the display
## server's default to restore normal behaviour.
func use_storage_for_test(path: String, persist: bool) -> void:
	_path = path
	_persist = persist
	_load()


func _get_value(key: String) -> Variant:
	if _values.has(key):
		return _values[key]
	return _registered.get(key, null)


func has_key(key: String) -> bool:
	return _values.has(key) or _registered.has(key)


func register_defaults(dict: Dictionary) -> void:
	for k in dict:
		_registered[str(k)] = dict[k]


func object_for_key(key: String) -> Variant:
	return _get_value(key)


func set_object_for_key(value: Variant, key: String) -> void:
	if value == null:
		remove_object_for_key(key)
		return
	_values[key] = value
	_save()


func value_for_key(key: String) -> Variant:
	return object_for_key(key)


func set_value_for_key(value: Variant, key: String) -> void:
	set_object_for_key(value, key)


func remove_object_for_key(key: String) -> void:
	if _values.erase(key):
		_save()


func string_for_key(key: String) -> Variant:
	var v: Variant = _get_value(key)
	return null if v == null else str(v)


func array_for_key(key: String) -> Variant:
	var v: Variant = _get_value(key)
	return v if v is Array else null


func dictionary_for_key(key: String) -> Variant:
	var v: Variant = _get_value(key)
	return v if v is Dictionary else null


func bool_for_key(key: String) -> bool:
	var v: Variant = _get_value(key)
	if v == null:
		return false
	if v is bool:
		return v
	if v is String:
		return (v as String).to_lower() in ["yes", "true", "1"]
	return float(v) != 0.0


func set_bool_for_key(value: bool, key: String) -> void:
	_values[key] = value
	_save()


func integer_for_key(key: String) -> int:
	var v: Variant = _get_value(key)
	if v == null:
		return 0
	if v is bool:
		return 1 if v else 0
	return int(float(v)) if (v is String or v is float) else int(v)


func set_integer_for_key(value: int, key: String) -> void:
	_values[key] = value
	_save()


func float_for_key(key: String) -> float:
	var v: Variant = _get_value(key)
	if v == null:
		return 0.0
	if v is bool:
		return 1.0 if v else 0.0
	return float(v)


func set_float_for_key(value: float, key: String) -> void:
	_values[key] = value
	_save()


func double_for_key(key: String) -> float:
	return float_for_key(key)


func set_double_for_key(value: float, key: String) -> void:
	set_float_for_key(value, key)


func synchronize() -> bool:
	_save()
	return true
