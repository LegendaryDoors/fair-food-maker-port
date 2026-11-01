# The outlet/action map recovered from the original nibs: for every screen,
# outlet name -> node path and the target/action pairs. Built from the import
# cache by core/import/SceneBuilder.gd (Assets.all_bindings()), exactly what
# the scene generator used to write to its bindings file.
#
# Screens use this instead of hardcoding node paths, so regenerating the scenes
# after a tooling fix does not break behaviour scripts.

extends Node

## Every screen's bindings, keyed like the old bindings file. Assets builds
## them on first use and keeps them until invalidate() (a first launch has an
## empty cache until the importer has run).
var _data: Dictionary:
	get:
		return Assets.all_bindings()


## A few screens ship only as iOS device variants -- `dicFrostingViewController`
## and `dicScoopIceCreamViewController` exist solely as `~iphone` / `~ipad`,
## with no plain key at all.
##
## `Nav.resolve()` already falls back this way when loading the *scene*, but
## this file did not, so those two screens loaded their scene under the variant
## name while `Screen._ready()` looked their bindings up under the plain name
## and got an empty dictionary -- every outlet and every action silently
## missing, with no error. Both `dic` screens had to patch around it locally.
##
## Keep this candidate order identical to `Nav.resolve()`; if the two disagree
## a screen gets one file's geometry and another's wiring.
const VARIANTS := ["", "~iphone", "~ipad"]


## The key `screen` is actually stored under, or "" if it is absent entirely.
func resolve_key(screen: String) -> String:
	for suffix: String in VARIANTS:
		var k := screen + suffix
		if _data.has(k):
			return k
	return ""


func has_screen(screen: String) -> bool:
	return resolve_key(screen) != ""


## Canonical screen names -- variant suffixes stripped and de-duplicated, so
## callers iterate the names `Nav` actually takes rather than raw JSON keys.
func screen_names() -> PackedStringArray:
	var seen := {}
	for k: String in _data.keys():
		seen[k.split("~")[0]] = true
	var names := PackedStringArray(seen.keys())
	names.sort()
	return names


## Outlet name -> node path, for one screen.
func outlets(screen: String) -> Dictionary:
	return _data.get(resolve_key(screen), {}).get("outlets", {})


## [{selector, node, events}] for one screen.
func actions(screen: String) -> Array:
	return _data.get(resolve_key(screen), {}).get("actions", [])


## Resolve an original outlet name against a live scene instance.
func node_for(root: Node, screen: String, outlet: String) -> Node:
	var path: String = outlets(screen).get(outlet, "")
	if path == "":
		return null
	if path == ".":
		return root
	return root.get_node_or_null(NodePath(path))
