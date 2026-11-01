# Player pool, standing in for the original AudioManager.
#
# The original kept an AVAudioPlayer per filename in a dictionary and addressed
# it by name. The bundle follows a consistent convention that we reuse:
#
#     .m4a  sustained loops   (ambience_loop, blend_loop, frying_hi_loop)
#     .mp3  one-shots         (button_press, pop_01, cheer)
#
# Godot cannot decode .m4a: the importer decodes each loop to a .wav in the
# import cache (a dev seed carries the old ffmpeg .ogg transcodes instead).
# Streams come from Assets.audio().
#
# Loops get a persistent named player so they can be stopped later; one-shots
# get a transient player that frees itself.

extends Node

var muted := false

var _loops: Dictionary = {}      # basename -> AudioStreamPlayer
var _one_shots: Array[AudioStreamPlayer] = []
## Newest one-shot player per basename. AudioManager (0xE873C) keeps every
## player it creates -- playFile: included -- in playerDict under its file
## name, newest wins, so stopPlayerForFile: (0xE87C8) can cut a one-shot short
## (dicMixIngredients "pouring", kcShakeToColor "shake_01", kcShakeToFlatten
## "slide_02" do). Older same-name one-shots play on, as they did there.
var _latest: Dictionary = {}


## **Godot cannot decode `.m4a`**, and the bundle ships every sustained loop in
## that format -- so for most of this port's life all 22 loops were silent
## while every one-shot played, which is why it went unnoticed. The decoded
## loop (.wav; .ogg in a dev seed) is preferred over a one-shot of the same
## name, as the .ogg always was. One shared stream per name (Assets caches it,
## as ResourceCache did), so loop() switching looping on sticks.
func _find(basename: String) -> AudioStream:
	return Assets.audio(basename)


## Fire and forget. Safe to call with a name that does not exist.
func play(basename: String, volume_db := 0.0) -> void:
	if muted:
		return
	var stream := _find(basename)
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = volume_db
	add_child(p)
	p.finished.connect(func() -> void:
		_one_shots.erase(p)
		if _latest.get(basename) == p:
			_latest.erase(basename)
		p.queue_free())
	_one_shots.append(p)
	_latest[basename] = p
	p.play()


func loop(basename: String, volume_db := 0.0) -> void:
	if _loops.has(basename):
		return
	var stream := _find(basename)
	if stream == null:
		return
	# Godot honours the loop flag on the stream resource, not the player.
	Assets.enable_loop(stream)
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = volume_db
	add_child(p)
	_loops[basename] = p
	if not muted:
		p.play()


## stopPlayerForFile: stops the loop of that name, or the newest
## one-shot of that name: the original's playerDict held both. A stop() on a
## one-shot used to be silently ignored.
func stop(basename: String) -> void:
	var p: AudioStreamPlayer = _loops.get(basename)
	if p != null:
		p.stop()
		p.queue_free()
		_loops.erase(basename)
		return
	var o: AudioStreamPlayer = _latest.get(basename)
	_latest.erase(basename)
	if o != null and is_instance_valid(o):
		o.stop()
		_one_shots.erase(o)
		o.queue_free()


## [[playerDict objectForKey:name] isPlaying] (MainMenu viewWillAppear: 0x1F62C,
## EatView touchesBegan: 0xC2354 ask this before starting a loop).
func is_playing(basename: String) -> bool:
	var p: AudioStreamPlayer = _loops.get(basename)
	if p == null:
		p = _latest.get(basename)
	return p != null and is_instance_valid(p) and p.playing


func stop_all() -> void:
	for key in _loops.keys():
		stop(key)


func set_muted(value: bool) -> void:
	muted = value
	for p: AudioStreamPlayer in _loops.values():
		if muted:
			p.stop()
		else:
			p.play()
