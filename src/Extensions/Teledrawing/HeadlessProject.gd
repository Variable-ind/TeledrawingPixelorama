# gdlint: ignore=max-public-methods
extends Project


func _init(_frames = [], _name := tr("untitled"), _size := Vector2i(64, 64)) -> void:
	# Do nothing
	return


func clone_frames(p_frames: Array[Frame], p_layers):
	layers = p_layers
	frames.clear()
	for frame: Frame in p_frames:
		var cels: Array[BaseCel] = []
		for cel in frame.cels:
			if cel.get_class_name() != "PixelCel":
				cels.append(cel)
				continue
			cels.append(PixelCel.new(cel.copy_content(), cel.opacity))
		frames.append(Frame.new(cels))
