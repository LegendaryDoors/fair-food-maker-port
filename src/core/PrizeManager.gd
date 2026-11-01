# PrizeManager (0x12AD8..), ported. Autoload "PrizeManager".
#
# INTERFACE CONTRACT: one function per ObjC selector, named by snake_casing
# the selector parts and joining them with "_", with the same arguments in
# the same order. +sharedPM is the autoload itself. Do not rename these or
# change their arity; callers depend on them.
#
# A "prize" argument is the prize's IAPKey string (e.g. "FF_PRIZE_BP_LADYBUG");
# the random draws answer IAPKeys too.
#
# From the original binary (the weighting re-read in the disassembly):
#   init                     0x12B20  prizes <- Prizes.plist (an array of
#                                     {IAPKey, Name, Image, Thumbnail, Game,
#                                     Weight, Category?}); data/Prizes.json.
#   isPrizeValid:            0x12BDC  getPrizeDictionary: != nil.
#   isPrizeLocked:           0x12BF8  !boolForKey:<IAPKey>. (It NSLogs "prize
#                                     key is not valid" when the key IS valid
#                                     -- an inverted test, log only.)
#   unlockPrize: / lockPrize: 0x12C60 / 0x12CDC  setBool:YES/NO forKey:<IAPKey>
#                                     + synchronize. Unlocks persist through
#                                     core/Defaults.gd under the IAPKey itself.
#   getPrizeDictionary:      0x12D58  first entry whose IAPKey matches.
#   getPrizeImage:           0x12E50  imageNamed:(Image), else
#                                     imageWithContentsOfFile:.
#   getPrizeName:/Game:/Weight:/Category:  the entry's field (Weight intValue).
#   getPrizesForGame:        0x12F68  IAPKeys of the entries whose Game
#                                     matches, in table order; nil when none.
#   getRandomPrize           0x13120  uniform over the whole table.
#   getRandomLockedPrize     0x131B4  uniform over keys not set in defaults.
#   getRandomPrize:game:force: 0x13368
#       flag NO  -> uniform over the game's prizes.
#       flag YES -> a pool holding each prize `count` times, then uniform:
#           max   = the largest Weight in the game (at least 1)
#           count = Weight                                  if force < 0
#                 = (int)((float)Weight + (float)(1 - Weight/max) * force)
#                   with Weight/max an INTEGER division (___divsi3 at
#                   0x1352A): 0 below the top weight, 1 at it. So force adds
#                   `force` copies to every prize except the heaviest.
#   getRandomPrize:game:     0x1360C  ... force:-1.0 -> plain Weight.
#   getRandomPrizeByCategory:game:Categoried: 0x13634 -> the misspelled
#       getRandomPrizeByCategoy:...force:-1.0 (0x13660), which ignores force:
#           flag NO  -> uniform over the game's prizes.
#           flag YES -> count = (int)((double)Weight * 0.8) when the prize's
#                       Category equals the asked one, else
#                       (int)((double)Weight * 0.1) (doubles at 0x138B0/8).
#   arc4random() % n is the draw throughout; randi() % n here.
#
# Callers in v1.27 (selref xrefs): getRandomPrize:game: by balloon pop,
# football toss, fish toss, milk bottles, water race; getRandomPrize:game:force:
# by frog toss; getRandomPrizeByCategory:... by football toss and whack-a-mole;
# unlockPrize:, getPrizeName:, getPrizeImage: by all seven; getPrizesForGame:
# by their prize buttons. getRandomPrize, getRandomLockedPrize, lockPrize: and
# isPrizeLocked: have no caller.

extends Node

## The import cache's data/Prizes.json (Assets).
const PRIZES_TABLE := "Prizes"

## -[PrizeManager prizes] / setPrizes: -- the prize table (data/Prizes.json).
var prizes: Array = []


func _ready() -> void:
	# A first launch has no cache until the importer has run; read the table
	# then (Assets.invalidate() after the import).
	Assets.cache_changed.connect(_load_prizes)
	if Assets.is_ready():
		_load_prizes()


func _load_prizes() -> void:
	if not Assets.is_ready():
		return
	var parsed: Variant = Assets.json(PRIZES_TABLE)
	if parsed == null:
		push_error("PrizeManager: cannot open data/%s.json" % PRIZES_TABLE)
		return
	if parsed is Array:
		prizes = parsed
	else:
		push_error("PrizeManager: data/%s.json is not an array" % PRIZES_TABLE)


func is_prize_valid(prize: Variant) -> bool:
	return get_prize_dictionary(prize) != null


func is_prize_locked(prize: Variant) -> bool:
	return not Defaults.bool_for_key(str(prize))


func unlock_prize(prize: Variant) -> void:
	Defaults.set_bool_for_key(true, str(prize))
	Defaults.synchronize()


func lock_prize(prize: Variant) -> void:
	Defaults.set_bool_for_key(false, str(prize))
	Defaults.synchronize()


func get_prize_dictionary(prize: Variant) -> Variant:
	if prize == null:
		return null
	var key := str(prize)
	for p: Dictionary in prizes:
		if str(p.get("IAPKey", "")) == key:
			return p
	return null


func get_prize_image(prize: Variant) -> Variant:
	var d: Variant = get_prize_dictionary(prize)
	if d == null:
		return null
	var file := str((d as Dictionary).get("Image", ""))
	if file != "" and Assets.has_image(file):
		return Assets.texture(file)
	if file != "" and FileAccess.file_exists(file):
		var img := Image.load_from_file(file)
		if img != null:
			return ImageTexture.create_from_image(img)
	return null


func get_prize_name(prize: Variant) -> Variant:
	return _field(prize, "Name")


func get_prize_game(prize: Variant) -> Variant:
	return _field(prize, "Game")


func get_prize_weight(prize: Variant) -> int:
	var w: Variant = _field(prize, "Weight")
	return int(w) if w != null else 0


func get_prize_category(prize: Variant) -> Variant:
	return _field(prize, "Category")


func _field(prize: Variant, field: String) -> Variant:
	var d: Variant = get_prize_dictionary(prize)
	return (d as Dictionary).get(field) if d != null else null


## PORT CHOICE: the original answers nil for a game with no prizes; this
## answers an empty Array so GDScript callers can iterate it. Nil and an empty
## NSArray behave the same for every original caller.
func get_prizes_for_game(game: Variant) -> Variant:
	var out: Array = []
	var g := str(game)
	for p: Dictionary in prizes:
		if str(p.get("Game", "")) == g:
			out.append(p.get("IAPKey"))
	return out


func get_random_prize() -> Variant:
	if prizes.is_empty():
		return null
	return (prizes[randi() % prizes.size()] as Dictionary).get("IAPKey")


func get_random_locked_prize() -> Variant:
	var locked: Array = []
	for p: Dictionary in prizes:
		var key: Variant = p.get("IAPKey")
		if key != null and not Defaults.bool_for_key(str(key)):
			locked.append(key)
	if locked.is_empty():
		return null
	return locked[randi() % locked.size()]


## getRandomPrize:(BOOL) game:(id) force:(float)
func get_random_prize_game_force(flag: bool, game: Variant, force: float) -> Variant:
	var keys: Array = get_prizes_for_game(game)
	if keys.is_empty():
		return null
	if not flag:
		return keys[randi() % keys.size()]
	var top := get_prize_weight(keys[0])
	for k: Variant in keys:
		top = maxi(top, get_prize_weight(k))
	top = maxi(top, 1)
	var counts: Array[int] = []
	for k: Variant in keys:
		var count := get_prize_weight(k)
		if force >= 0.0:
			# 1 - w/max with C integer division (truncates toward zero).
			@warning_ignore("integer_division")
			var frac := 1 - count / top
			count = int(float(count) + float(frac) * force)
		counts.append(count)
	return _draw_from_pool(keys, counts)


## getRandomPrize:(BOOL) game:(id)
func get_random_prize_game(flag: bool, game: Variant) -> Variant:
	return get_random_prize_game_force(flag, game, -1.0)


## getRandomPrizeByCategory:(BOOL) game:(id) Categoried:(id)
func get_random_prize_by_category_game_categoried(flag: bool, game: Variant, categoried: Variant) -> Variant:
	return get_random_prize_by_categoy_game_categoried_force(flag, game, categoried, -1.0)


## getRandomPrizeByCategoy:(BOOL) game:(id) Categoried:(id) force:(float) -- the
## original's spelling. `force` is accepted and, as in the original, unused.
func get_random_prize_by_categoy_game_categoried_force(flag: bool, game: Variant, categoried: Variant, _force: float) -> Variant:
	var keys: Array = get_prizes_for_game(game)
	if keys.is_empty():
		return null
	if not flag:
		return keys[randi() % keys.size()]
	var counts: Array[int] = []
	for k: Variant in keys:
		var w := float(get_prize_weight(k))
		var cat: Variant = get_prize_category(k)
		if categoried != null and cat != null and str(categoried) == str(cat):
			counts.append(int(w * 0.8))
		else:
			counts.append(int(w * 0.1))
	return _draw_from_pool(keys, counts)


## The original fills an NSMutableArray with each key `count` times, in key
## order, and takes objectAtIndex:(arc4random() % count). Walking the
## cumulative counts with the same single draw picks the identical entry
## without building a pool of thousands per call.
func _draw_from_pool(keys: Array, counts: Array[int]) -> Variant:
	var total := 0
	for c in counts:
		total += maxi(c, 0)
	# arc4random() % 0 if every count came out 0; no table game does that.
	if total == 0:
		return null
	var r := randi() % total
	for i in keys.size():
		var c := maxi(counts[i], 0)
		if r < c:
			return keys[i]
		r -= c
	return null
