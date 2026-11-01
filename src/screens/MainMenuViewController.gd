# Main menu.
#
# Read from the v1.27 binary:
#
#   viewDidLoad       0x1ED08  eight circus balloons, 80x80 aspect-fit image
#                              views parked at (-999,-999) and added *after*
#                              the nib's views, so they float over the buttons;
#                              versionLabel = "Version: <CFBundleShortVersionString>".
#   viewWillAppear:   0x1F62C  hides buyAllBtn when FF_KEY_EVERYTHING; sets each
#                              button's foreground image (natural size, centred);
#                              loops title_loop if it is not playing; stops
#                              ambience_loop.
#   viewDidAppear:    0x1F2C0  every balloon jumps to (60+rand%200, 520+rand%50)
#                              and animates with UIViewAnimationCurveEaseIn for
#                              1.5+(rand%100)/100 s to (3x-320, y-650). The class
#                              has no animationDidStop:, so this runs once per
#                              appearance -- it is not a loop.
#   MakePumpkinClick: 0x1FDF8  button_press, stop title_loop, loop ambience_loop
#                              at volume 0.25, push StandSelectViewController.
#   FreezerClick:     0x1FF18  the same with the "freezer" sound -> Freezer.
#   StoreClick:       0x20038  the same with the "store" sound   -> Store.
#   BuyAllClick:      0x20158  IAP com.sunstorm.ff.all (see Screen.KEEPS_BUY_ALL).
#   privacyButton:    0x20514  openURL: http://www.sunstormgames.com/privacy
#   viewDidDisappear: 0x1F99C  nothing visible (see on_exit).
#
# Kept under every pushed screen: viewDidLoad runs once;
# viewWillAppear: / viewDidAppear: run again on every return (on_resume /
# on_did_appear). viewDidAppear:'s balloons start when the pop slide
# ends (Screen.on_did_appear), not as it begins.
#
# AudioManager (loopFile:ofType:withLoopCount: 0xE873C, createPlayerForFile:
# 0xE84E0) never sets a volume, so title_loop plays at AVAudioPlayer's default
# 1.0. The -6 dB this file used to apply was a guess and is gone.
#
# Destinations confirmed against the binary. The odd
# selector name is from the original -- PLAY is wired to a selector left over
# from a seasonal build.

# Extends by path, not `extends Screen`: the class_name registry is built by
# the editor, and this project is driven entirely from the CLI.
extends "res://core/Screen.gd"

const UIScrollSim := preload("res://core/UIScrollSim.gd")

## CFBundleShortVersionString of the port target (Info.plist).
const VERSION := "1.27"

## viewDidLoad's arrayWithObjects:, in order.
const BALLOON_ART := ["circus_ballbubble.png", "circus_clownbubble.png",
	"circus_greenbubble.png", "circus_pinkbubble.png", "circus_yellowbubble.png",
	"circus_yellowbubble.png", "circus_pinkbubble.png", "circus_greenbubble.png"]
const BALLOON_FRAME := 80.0            # initWithFrame:(0,0,80,80), contentMode 1
const BALLOON_PARK := Vector2(-999, -999)
const BALLOON_RISE := 650.0            # setCenter: y - 650
const BALLOON_SPREAD_X := 160.0        # x + 2*(x - 160)
const BALLOON_SECONDS_MIN := 1.5       # + (rand % 100) / 100
const AMBIENCE_VOLUME := 0.25          # setVolume: 0x3E800000

## privacyButton: opens http://www.sunstormgames.com/privacy in Safari. The
## site is gone; the port opens the Wayback Machine's copy of that exact page.
const PRIVACY_URL := "https://web.archive.org/web/20130526150343/http://www.sunstormgames.com/privacy"

var _balloons: Array[Sprite2D] = []
var _balloon_tweens: Array[Tween] = []


func on_enter() -> void:
	# viewDidLoad: the nib ships the placeholder text "Version Number Here".
	var label := outlet("versionLabel")
	if label is Label:
		label.text = "Version: " + VERSION
	_build_balloons()

	_view_will_appear()


## The menu is the navigation root: every screen the player reaches is pushed
## over it and the controller is never released, so coming back (StandSelect's
## back, Store / Freezer back:, Eat's startOver: popToRoot) runs only
## viewWillAppear: and viewDidAppear: again -- title_loop back on, ambience off,
## and the balloons rise once more (0x1F2C0 runs per appearance).
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	_view_will_appear()


## viewDidAppear: timing -- Nav calls this when the push / pop slide is over
## (at once for the root screen and unanimated changes).
func on_did_appear() -> void:
	_view_did_appear()


## viewWillAppear: (0x1F62C), audio part: loopFile title_loop unless its player
## is already playing (Audio.loop is a no-op then), then stop ambience_loop.
## Its other half re-sets the button / backdrop images viewDidDisappear: nils
## (the port never clears them, see on_exit) and hides buyAllBtn under
## FF_KEY_EVERYTHING, which the port deliberately does not do on this screen
## (Screen.KEEPS_BUY_ALL).
func _view_will_appear() -> void:
	Audio.loop("title_loop")
	Audio.stop("ambience_loop")


## viewDidAppear: (0x1F2C0).
func _view_did_appear() -> void:
	_release_balloons()


## viewDidDisappear: (0x1F99C) cancels perform requests (the menu schedules
## none), removes SpriteSheetViews (it has none) and nils the nine button /
## backdrop images, which viewWillAppear: sets straight back -- nothing a
## player can see, so nothing to port. The balloons are left where they are.
##
## PORT CHOICE: title_loop stops here as well. Every way off this screen in
## the original is a click handler that stops it first (so this is a no-op on
## those paths); the port's dev screen browser (F1) can leave without one.
func on_exit() -> void:
	Audio.stop("title_loop")


## viewDidLoad: eight aspect-fit 80x80 image views, above the nib's views.
func _build_balloons() -> void:
	for art: String in BALLOON_ART:
		var s := Sprite2D.new()
		if Assets.has_image(art):
			s.texture = Assets.texture(art)
			var ts: Vector2 = s.texture.get_size()
			# UIViewContentModeScaleAspectFit inside an 80x80 frame.
			var k: float = minf(BALLOON_FRAME / ts.x, BALLOON_FRAME / ts.y)
			s.scale = Vector2(k, k)
		s.position = BALLOON_PARK
		add_child(s)
		_balloons.append(s)


## viewDidAppear: -- one rise per appearance. Each appearance starts every
## balloon afresh (setCenter: to a new start, then a new animation), so a rise
## still in flight from the previous appearance -- paused while the menu was
## covered -- is dropped first rather than left to fight the new one.
func _release_balloons() -> void:
	for t: Tween in _balloon_tweens:
		if t.is_valid():
			t.kill()
	_balloon_tweens.clear()
	for s: Sprite2D in _balloons:
		var start := Vector2(float(randi() % 200 + 60), float(randi() % 50 + 520))
		s.position = start
		var secs: float = float(randi() % 100) / 100.0 + BALLOON_SECONDS_MIN
		var target := Vector2(start.x + 2.0 * (start.x - BALLOON_SPREAD_X),
			start.y - BALLOON_RISE)
		# UIViewAnimationCurveEaseIn = (0.42, 0, 1, 1) (UIScrollSim.curve);
		# `t` is linear time.
		var tw := create_tween()
		tw.tween_method(func(t: float) -> void:
			s.position = start.lerp(target, UIScrollSim.curve(t, UIScrollSim.AnimCurve.EASE_IN)),
			0.0, 1.0, secs)
		_balloon_tweens.append(tw)


## Shared tail of the three click handlers.
func _leave_for(sound: String, screen: String) -> void:
	Audio.play(sound)
	Audio.stop("title_loop")
	Audio.loop("ambience_loop", linear_to_db(AMBIENCE_VOLUME))
	Nav.push(screen)


func _on_MakePumpkinClick() -> void:
	_leave_for("button_press", "StandSelectViewController")


func _on_StoreClick() -> void:
	_leave_for("store", "StoreViewController")


func _on_FreezerClick() -> void:
	_leave_for("freezer", "FreezerViewController")


func _on_privacyButton() -> void:
	OS.shell_open(PRIVACY_URL)
