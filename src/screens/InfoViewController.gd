# The info / about screen.
#
# Read from the 1.27 binary:
#   viewDidLoad  0x27FF8  versionLabel = "Version: <CFBundleShortVersionString>"
#   info:        0x27EE8  button_press, popViewControllerAnimated:
#   aboutClick:  0x27F58  button_press, openURL: http://www.sunstormgames.com
#
# UNREACHABLE in 1.27: MainMenuViewController viewDidLoad (0x1ED08) allocs an
# InfoViewController into mInfoViewController, but no action, selector or
# method ever pushes it -- the menu's nib has no info button wired, and the
# only other reference is AppDelegate's list of screens that hide the coins
# panel. It is ported only so the dev screen browser (F1) shows it working.

extends "res://core/Screen.gd"

## CFBundleShortVersionString of the port target (Info.plist), as on the menu.
const VERSION := "1.27"
## PORT CHOICE: the original opens http://www.sunstormgames.com, which is gone.
## As with the menu's privacy button, the Wayback
## Machine stands in; the bare-year form lets the archive pick the nearest
## capture rather than the port inventing a timestamp.
const ABOUT_URL := "https://web.archive.org/web/2013/http://www.sunstormgames.com"


func on_enter() -> void:
	var label := outlet("versionLabel")
	if label is Label:
		(label as Label).text = "Version: " + VERSION


## Opted in for uniformity. The class has no
## viewWillAppear: / viewDidAppear: / view*Disappear: overrides, and nothing
## pushes over it, so there is nothing to re-run.
func keeps_state_on_push() -> bool:
	return true


func _on_info() -> void:
	Audio.play("button_press")
	Nav.back()


func _on_aboutClick() -> void:
	Audio.play("button_press")
	OS.shell_open(ABOUT_URL)
