# EatItem / DrinkItem, ported: a finished food as the freezer stores it.
#
# From the original binary:
#   +savePath                         0xBD70C  <Documents>/Saved, created on
#                                              first use.
#   +getImagesPath: / getThumbnailPath: / getCollageImagePath: /
#    getCollageThumbnailImagePath:    0xBD7E0.. <file> + ".ImagesPath" /
#                                              ".thumbnail" / ".collage" /
#                                              ".collage_thumbnail".
#   -initWithThumbnail:data:images:   0xBD8F0  what DecorateView createEatItem
#                                              (0xB1CE4) builds: thumbnail =
#                                              the decorate view drawn into a
#                                              73x110 context, data =
#                                              {CategoryProperties: {cat: props}},
#                                              images = {cat: full-screen image}.
#   -initWithContentsOfFile:loadImages: 0xBD974 data <- archive at <file>;
#                                              every stored path is re-rooted
#                                              in savePath by lastPathComponent;
#                                              itemName <- data.ItemName.
#   -loadImages                       0xBDB1C  images <- archive at imagesPath.
#   -writeToFile:                     0xBDE38  data dict = {FilePath, Class,
#                                              ItemName, ThumbnailPath} + data +
#                                              {ImagesPath}; archive it to
#                                              <file>, the images dict to
#                                              <file>.ImagesPath, the thumbnail
#                                              PNG to <file>.thumbnail; any
#                                              failure removes what was written
#                                              and answers NO.
#   -deleteFile                       0xBE14C  removes all five files.
#   -createCollageImage               0xBDB7C  an EatView of the item with every
#                                              category whose name contains
#                                              "Background" hidden, snapshot
#                                              resized to 80x120 (.collage) and
#                                              65x65 (.collage_thumbnail).
#   DrinkItem initWithContentsOfFile:loadImages: 0xCEB0C  liquidMaskFilename
#                                              <- savePath/lastPathComponent(
#                                              LiquidMaskFile); liquidCategoryName
#                                              <- [data objectForKey:
#                                              liquidCategoryName] -- read while
#                                              the ivar is still nil, so it is
#                                              always "%@" of nil = "(null)".
#   DrinkItem writeToFile:            0xCEC00  EatItem's write, then re-archive
#                                              the data with LiquidMaskFile and
#                                              LiquidCategory added.
#
# PORT CHOICES (the format is the port's own; the layout and names are not):
#   * user://Saved stands in for <Documents>/Saved. File names and suffixes are
#     the original's ("%f.plist" of the epoch time, + ".ImagesPath", ...).
#   * NSKeyedArchiver is replaced by JSON for the data dict and by
#     var_to_bytes({category: PNG bytes}) for the images dict.
#   * Headless runs (the dev harnesses) keep the files in memory, exactly as
#     core/Defaults.gd keeps user defaults, so a test can neither inherit nor
#     leave behind a freezer. `persist_override` lets a harness force either.
#
# The port's eat screen consumes a "pending" dictionary (EatViewController.gd
# header); to_pending()/from_pending() translate between that and this class.

extends RefCounted

const SAVE_DIR := "user://Saved"
const CLASS_EAT := "EatItem"
const CLASS_DRINK := "DrinkItem"

## createEatItem / createDrinkItem draw the decorate view into a 73x110
## context (CGSize 0x42DC000042920000) with drawInRect:(0,0,73,110).
const THUMBNAIL_SIZE := Vector2i(73, 110)
## createCollageImage: resizedImage:(80,120) and (65,65), quality 0.
const COLLAGE_SIZE := Vector2i(80, 120)
const COLLAGE_THUMB_SIZE := Vector2i(65, 65)
const SCREEN_SIZE := Vector2i(320, 480)

## FreezerViewController eat: 0xA489C re-points the liquid mask by itemName,
## because the stored path (savePath + the bundle file's name) never exists.
const FREEZER_LIQUID_MASKS := {
	"Milkshake": "Ice_Cream_Glass_Mask_Full.png",
	"Lemon Shake-Up": "lsu_cup_mask_full.png",
}

## -1 = decide by display server (headless -> memory), 0 = memory, 1 = disk.
static var persist_override: int = -1
## Headless store: path -> PackedByteArray.
static var _mem: Dictionary = {}

var filepath: String = ""
var images_path: String = ""
var thumbnail: Image = null
var item_name: String = ""
var thumbnail_path: String = ""
var data: Dictionary = {}
## category -> Image
var images: Dictionary = {}

## DrinkItem (the port folds the subclass in; `klass` is what NSStringFromClass
## would answer and what writeToFile: stores under "Class").
var klass: String = CLASS_EAT
var liquid_mask_filename: String = ""
var liquid_category_name: String = ""


# -- file system (disk, or memory when headless) ------------------------

static func _persisting() -> bool:
	if persist_override >= 0:
		return persist_override == 1
	return DisplayServer.get_name() != "headless"


static func _fs_write(path: String, bytes: PackedByteArray) -> bool:
	if not _persisting():
		_mem[path] = bytes
		return true
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	return true


static func _fs_read(path: String) -> PackedByteArray:
	if not _persisting():
		return _mem.get(path, PackedByteArray())
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


static func fs_exists(path: String) -> bool:
	if not _persisting():
		return _mem.has(path)
	return FileAccess.file_exists(path)


static func _fs_remove(path: String) -> bool:
	if not _persisting():
		return _mem.erase(path)
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK


## contentsOfDirectoryAtPath: + pathsMatchingExtensions:@[@"plist"]. Only
## names whose LAST extension is "plist" -- the ".plist.thumbnail" etc.
## companions are excluded, as on iOS.
## INFERRED: the order. HFS+ (the iPhone's file system) lists a directory in
## name order, and the names are epoch timestamps, so oldest first; Godot's
## listing order is unspecified, hence the explicit sort.
static func list_saved() -> Array[String]:
	var dir := save_path()
	var names: Array[String] = []
	if not _persisting():
		for p: String in _mem.keys():
			if p.get_base_dir() == dir and p.get_extension() == "plist":
				names.append(p.get_file())
	else:
		for n in DirAccess.get_files_at(dir):
			if n.get_extension() == "plist":
				names.append(n)
	names.sort()
	return names


## Test hook: forget the in-memory freezer.
static func clear_memory_store() -> void:
	_mem.clear()


# -- paths (+savePath 0xBD70C and the four suffix helpers) ---------------

static func save_path() -> String:
	if _persisting() and not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	return SAVE_DIR


static func get_images_path(path: String) -> String:
	return path + ".ImagesPath"


static func get_thumbnail_path(path: String) -> String:
	return path + ".thumbnail"


static func get_collage_image_path(path: String) -> String:
	return path + ".collage"


static func get_collage_thumbnail_image_path(path: String) -> String:
	return path + ".collage_thumbnail"


## A stored image file (thumbnail / collage) as a texture, or null.
## (UIImage imageWithContentsOfFile: in GridItemView / setGridViewImage.)
static func load_texture(path: String) -> Texture2D:
	var img := _decode_png(_fs_read(path))
	return ImageTexture.create_from_image(img) if img != null else null


static func _decode_png(bytes: PackedByteArray) -> Image:
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	return img


# -- construction ----------------------------------------------------------

## -initWithThumbnail:data:images: (0xBD8F0).
static func init_with_thumbnail_data_images(thumb: Image, p_data: Dictionary,
		p_images: Dictionary) -> RefCounted:
	var item = load("res://core/EatItem.gd").new()
	item.data.merge(p_data, true)
	item.images.merge(p_images, true)
	item.thumbnail = thumb
	return item


## -initWithContentsOfFile:loadImages: (0xBD974); `as_drink` runs DrinkItem's
## override (0xCEB0C) on top, as FreezerViewController eat:/share: do once
## data.Class says "DrinkItem".
static func init_with_contents_of_file_load_images(path: String,
		p_load_images: bool, as_drink := false) -> RefCounted:
	var item = load("res://core/EatItem.gd").new()
	var parsed: Variant = JSON.parse_string(_fs_read(path).get_string_from_utf8())
	if parsed is Dictionary:
		item.data.merge(parsed, true)
	var root := save_path()
	item.filepath = root.path_join(path.get_file())
	item.images_path = root.path_join(str(item.data.get("ImagesPath", "")).get_file())
	item.thumbnail_path = root.path_join(str(item.data.get("ThumbnailPath", "")).get_file())
	item.item_name = _format_object(item.data.get("ItemName"))
	if p_load_images:
		item.load_images()
	if as_drink:
		item.klass = CLASS_DRINK
		item.liquid_mask_filename = root.path_join(
			str(item.data.get("LiquidMaskFile", "")).get_file())
		# objectForKey: of the still-nil ivar -> nil -> "%@" -> "(null)".
		item.liquid_category_name = _format_object(null)
	return item


## NSString initWithFormat:@"%@" -- nil prints as "(null)".
static func _format_object(v: Variant) -> String:
	return "(null)" if v == null else str(v)


## -loadImages (0xBDB1C).
func load_images() -> void:
	if images_path == "":
		return
	var bytes := _fs_read(images_path)
	if bytes.is_empty():
		return
	var decoded: Variant = bytes_to_var(bytes)
	if not (decoded is Dictionary):
		return
	for cat in decoded:
		var img := _decode_png(decoded[cat])
		if img != null:
			images[str(cat)] = img


# -- writeToFile: (0xBDE38, DrinkItem 0xCEC00) -------------------------------

func write_to_file(path: String) -> bool:
	if path == "":
		push_error("EatItem.write_to_file: path must not be nil.")
		return false
	filepath = path
	images_path = get_images_path(path)
	thumbnail_path = get_thumbnail_path(filepath)
	var out := {}
	out["FilePath"] = path
	out["Class"] = klass
	if item_name != "":
		out["ItemName"] = item_name
	if thumbnail_path != "":
		out["ThumbnailPath"] = thumbnail_path
	out.merge(data, true)
	out["ImagesPath"] = images_path

	if not _fs_write(filepath, JSON.stringify(out, "\t").to_utf8_buffer()):
		return false
	var packed := {}
	for cat in images:
		var img := _as_image(images[cat])
		if img != null:
			packed[str(cat)] = img.save_png_to_buffer()
	if not _fs_write(images_path, var_to_bytes(packed)):
		_fs_remove(filepath)
		return false
	var thumb := _as_image(thumbnail)
	if thumb == null or not _fs_write(thumbnail_path, thumb.save_png_to_buffer()):
		_fs_remove(filepath)
		_fs_remove(images_path)
		return false
	data = out
	if klass != CLASS_DRINK:
		return true
	# DrinkItem: re-read what was just written and add the liquid fields.
	var reread: Variant = JSON.parse_string(_fs_read(path).get_string_from_utf8())
	var drink: Dictionary = reread if reread is Dictionary else {}
	if liquid_mask_filename == "":
		push_error("DrinkItem: liquidMaskFilename must not be nil.")
	if liquid_category_name == "":
		push_error("DrinkItem: liquidCategoryName must not be nil.")
	drink["LiquidMaskFile"] = liquid_mask_filename
	drink["LiquidCategory"] = liquid_category_name
	data = drink
	return _fs_write(path, JSON.stringify(drink, "\t").to_utf8_buffer())


## -deleteFile (0xBE14C).
func delete_file() -> bool:
	if filepath == "":
		return false
	images_path = get_images_path(filepath)
	thumbnail_path = get_thumbnail_path(filepath)
	if not _fs_remove(filepath):
		return false
	_fs_remove(images_path)
	_fs_remove(thumbnail_path)
	_fs_remove(get_collage_image_path(filepath))
	_fs_remove(get_collage_thumbnail_image_path(filepath))
	return true


# -- rendering ---------------------------------------------------------------

## The categories in EatView's stacking order (initWithFrame:eatItem: 0xC1830:
## keysSortedByValueUsingSelector:compare: on each category's ViewIndex, and
## only categories that have an image).
func ordered_categories() -> Array:
	var props: Dictionary = data.get("CategoryProperties", {})
	var names: Array = []
	for cat in props:
		if images.has(str(cat)):
			names.append(str(cat))
	names.sort_custom(func(a: String, b: String) -> bool:
		return float(props[a].get("ViewIndex", 0)) < float(props[b].get("ViewIndex", 0)))
	return names


## Every image composited full-screen in EatView order, optionally skipping
## categories (createCollageImage hides those containing "Background").
func composite(skip_backgrounds: bool) -> Image:
	var out := Image.create(SCREEN_SIZE.x, SCREEN_SIZE.y, false, Image.FORMAT_RGBA8)
	for cat: String in ordered_categories():
		if skip_backgrounds and cat.contains("Background"):
			continue
		var img := _as_image(images[cat])
		if img == null:
			continue
		if img.get_format() != Image.FORMAT_RGBA8:
			img = img.duplicate()
			img.convert(Image.FORMAT_RGBA8)
		out.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
	return out


## -createCollageImage (0xBDB7C).
## INFERRED: resizedImage:interpolationQuality:0 is kCGInterpolationDefault;
## bilinear is the nearest Godot filter.
func create_collage_image() -> bool:
	load_images()
	var snap := composite(true)
	var big := snap.duplicate()
	big.resize(COLLAGE_SIZE.x, COLLAGE_SIZE.y, Image.INTERPOLATE_BILINEAR)
	_fs_write(get_collage_image_path(filepath), big.save_png_to_buffer())
	var small := snap.duplicate()
	small.resize(COLLAGE_THUMB_SIZE.x, COLLAGE_THUMB_SIZE.y, Image.INTERPOLATE_BILINEAR)
	return _fs_write(get_collage_thumbnail_image_path(filepath), small.save_png_to_buffer())


static func _as_image(v: Variant) -> Image:
	if v is Image:
		return v
	if v is Texture2D:
		var img := (v as Texture2D).get_image()
		if img != null and img.is_compressed():
			img.decompress()
		return img
	return null


# -- bridges to the port's eat screen ----------------------------------------

## The EatItem/DrinkItem MakeViewController.next: (0xA9294) builds, from the
## port's pending dict ({class_str, item_name, drink, liquid_mask,
## liquid_category, layers: [{name, edible, image, view_index?, properties?}],
## thumbnail?}).
##
## PORT CHOICE: CategoryProperties keeps what the port's layers carry -- a
## layer's own "properties" dict when present, else {IsEdible, ViewIndex}
## with ViewIndex = the layer's "view_index" or, failing that, its position
## in the (already ViewIndex-ordered) list. EatView only reads IsEdible and
## orders by ViewIndex, so nothing it uses is lost.
## INFERRED: the thumbnail. createEatItem snapshots the whole decorate view;
## when the pending dict brings no "thumbnail", the composite of its category
## layers -- the decorate view's content -- drawn into 73x110 stands in.
static func from_pending(item: Dictionary) -> RefCounted:
	var props := {}
	var imgs := {}
	var layers: Array = item.get("layers", [])
	for i in layers.size():
		var layer: Dictionary = layers[i]
		var cat := str(layer.get("name", ""))
		var img := _as_image(layer.get("image"))
		if cat == "" or img == null:
			continue
		var p: Dictionary = (layer.get("properties", {}) as Dictionary).duplicate()
		if not p.has("IsEdible"):
			p["IsEdible"] = bool(layer.get("edible", false))
		if not p.has("ViewIndex"):
			p["ViewIndex"] = int(layer.get("view_index", i))
		props[cat] = p
		imgs[cat] = img
	var thumb := _as_image(item.get("thumbnail"))
	var eat = init_with_thumbnail_data_images(null,
		{"CategoryProperties": props}, imgs)
	if thumb == null:
		thumb = eat.composite(false)
		thumb.resize(THUMBNAIL_SIZE.x, THUMBNAIL_SIZE.y, Image.INTERPOLATE_BILINEAR)
	eat.thumbnail = thumb
	eat.item_name = str(item.get("item_name", ""))
	if bool(item.get("drink", false)):
		eat.klass = CLASS_DRINK
		eat.liquid_mask_filename = str(item.get("liquid_mask", ""))
		eat.liquid_category_name = str(item.get("liquid_category", ""))
	return eat


## The pending dict EatViewController consumes, for an item coming out of the
## freezer (FreezerViewController eat: 0xA489C). The original creates that
## EatViewController with initWithNibName: -- no classStr -- and sets
## fromFreezer YES and previousViewControllerClass "FreezerViewController".
func to_pending() -> Dictionary:
	var layers: Array = []
	var props: Dictionary = data.get("CategoryProperties", {})
	for cat: String in ordered_categories():
		var p: Dictionary = props.get(cat, {})
		layers.append({
			"name": cat,
			"edible": bool(p.get("IsEdible", false)),
			"image": _as_image(images[cat]),
			"view_index": int(float(p.get("ViewIndex", 0))),
			"properties": p,
		})
	var drink := klass == CLASS_DRINK
	var mask := liquid_mask_filename
	if drink and FREEZER_LIQUID_MASKS.has(item_name):
		mask = FREEZER_LIQUID_MASKS[item_name]
	return {
		"class_str": "",
		"item_name": item_name,
		"drink": drink,
		"liquid_mask": mask if drink else "",
		"liquid_category": liquid_category_name if drink else "",
		"layers": layers,
		"filepath": filepath,
		"from_freezer": true,
		"previous_view_controller_class": "FreezerViewController",
	}


## EatViewController store: (0xA324C), the part that is storage: an item that
## has no file yet is written to savePath/"%f.plist" (timeIntervalSince1970).
## Answers whether writeToFile: succeeded; the caller shows "Success!" /
## "Saved to freezer!" or "" / "Unable to save image.". Returns false without
## writing when the item already has a file (store: then does nothing at all).
static func store_pending(item: Dictionary) -> bool:
	if str(item.get("filepath", "")) != "":
		return false
	var eat = from_pending(item)
	var name := "%f.plist" % Time.get_unix_time_from_system()
	var path := save_path().path_join(name)
	var ok: bool = eat.write_to_file(path)
	if ok:
		item["filepath"] = path
	return ok
