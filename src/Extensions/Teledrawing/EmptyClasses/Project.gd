# gdlint: ignore=max-public-methods
class_name Project
extends RefCounted
## A class for project properties.

signal serialized(dict: Dictionary)
signal about_to_deserialize(dict: Dictionary)
signal timeline_updated

var name := "":
	set(value):
		name = value
var size: Vector2i
var frames = []
var layers = []


func _init(_frames = [], _name := tr("untitled"), _size := Vector2i(64, 64)) -> void:
	return


func deserialize(dict: Dictionary, zip_reader: ZIPReader = null, file: FileAccess = null) -> void:
	return
