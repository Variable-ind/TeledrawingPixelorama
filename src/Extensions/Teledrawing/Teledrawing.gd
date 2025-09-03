extends AcceptDialog

@onready var api: Node
var menu_item_index: int
var port := 18819
var ip := "::1"
## The project that is currently selected when the user hosts a server,
## or the new project that gets created when the user connetcts to a server
var online_project: RefCounted:
	set(value):
		if online_project == value:
			return
		online_project = value
		if not is_instance_valid(value):
			return
		online_project.timeline_updated.connect(timeline_updated)

@onready var network_options := $NetworkOptions as VBoxContainer
@onready var disconnect_button := %Disconnect as Button


## Server Management


func _on_create_server_pressed() -> void:
	var server := ENetMultiplayerPeer.new()
	server.create_server(port, 32)
	multiplayer.multiplayer_peer = server
	online_project = api.project.current_project
	handle_connect()


func _on_join_server_pressed() -> void:
	var client := ENetMultiplayerPeer.new()
	client.create_client(ip, port)
	multiplayer.multiplayer_peer = client


func _on_disconnect_pressed() -> void:
	handle_disconnect()


func _on_ip_line_edit_text_changed(new_text: String) -> void:
	ip = new_text


func _on_port_line_edit_text_changed(new_text: String) -> void:
	if new_text.is_valid_int():
		port = new_text.to_int()


func _on_visibility_changed() -> void:
	if not visible:
		api.dialog.dialog_open(false)


func handle_connect() -> void:
	for child: Control in network_options.get_children():
		child.visible = child == disconnect_button
	api.signals.signal_project_data_changed(project_data_changed)


func handle_disconnect() -> void:
	for child: Control in network_options.get_children():
		child.visible = child != disconnect_button
	multiplayer.multiplayer_peer = null
	api.signals.signal_project_data_changed(project_data_changed, true)
	online_project = null


## Should run only on the server
func new_user_connected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var project_data: Dictionary = online_project.serialize()
	var images_data: Array = []
	for frame in online_project.frames:
		for cel in frame.cels:
			var cel_image: Image = cel.get_image()
			if is_instance_valid(cel_image) and cel.get_class_name() == "PixelCel":
				images_data.append(cel_image.get_data())
	receive_new_project.rpc_id(peer_id, project_data, images_data)


## Teledrawing UI management


func _enter_tree() -> void:
	api = get_node_or_null("/root/ExtensionsApi")  # Accessing the Api
	menu_item_index = api.menu.add_menu_item(api.menu.PROJECT, "Teledrawing", self)
	multiplayer.connected_to_server.connect(handle_connect)
	multiplayer.peer_connected.connect(new_user_connected)


func _exit_tree() -> void:
	handle_disconnect()
	api.menu.remove_menu_item(api.menu.PROJECT, menu_item_index)


func menu_item_clicked() -> void:
	popup_centered()
	api.dialog.dialog_open(true)


## General functions


## Called every time the project data changes
func project_data_changed(project: RefCounted) -> void:
	if project != online_project:
		return
	var data := {}
	var cels: Array = project.selected_cels
	for cel_indices in cels:
		var frame_index: int = cel_indices[0]
		var layer_index: int = cel_indices[1]
		var cel = project.frames[frame_index].cels[layer_index]
		if cel.get_class_name() != "PixelCel":
			continue
		var image: Image = cel.image
		data[cel_indices] = image.get_data()
	receive_changes.rpc(data)


func timeline_updated() -> void:
	var project_data: Dictionary = online_project.serialize()
	var images_data: Array = []
	for frame in online_project.frames:
		for cel in frame.cels:
			var cel_image: Image = cel.get_image()
			if is_instance_valid(cel_image) and cel.get_class_name() == "PixelCel":
				images_data.append(cel_image.get_data())
	receive_updated_timeline.rpc(project_data, images_data)


## RPC functions


## Called from the server to clients when they connect
@rpc("authority", "call_remote", "reliable")
func receive_new_project(project_data: Dictionary, images_data: Array) -> void:
	online_project = api.project.new_empty_project()
	online_project.deserialize(project_data)
	var image_index := 0
	for frame in online_project.frames:
		for cel in frame.cels:
			if cel.get_class_name() != "PixelCel":
				continue
			## Make an ImageExtended from the image data
			var image_data: PackedByteArray = images_data[image_index]
			var image_extended = api.project.new_image_extended(
				online_project.size.x,
				online_project.size.y,
				false,
				Image.FORMAT_RGBA8,
				online_project.is_indexed(),
				image_data
			)
			cel.image_changed(image_extended)
			image_index += 1
	api.project.current_project = online_project
	api.general.get_canvas().camera_zoom()


@rpc("any_peer", "call_remote", "reliable")
func receive_changes(data: Dictionary) -> void:
	for cel_indices in data:
		var frame_index: int = cel_indices[0]
		var layer_index: int = cel_indices[1]
		if frame_index >= online_project.frames.size() or layer_index >= online_project.layers.size():
			continue
		var cel = online_project.frames[frame_index].cels[layer_index]
		if cel.get_class_name() != "PixelCel":
			continue
		var image_extended: Image = cel.image
		var image_data: PackedByteArray = data[cel_indices]
		var image_size := image_extended.get_size()
		image_extended.set_data(
			image_size.x,
			image_size.y,
			image_extended.has_mipmaps(),
			image_extended.get_format(),
			image_data
		)
		api.general.get_canvas().update_texture(layer_index, frame_index, online_project)


@rpc("any_peer", "call_remote", "reliable")
func receive_updated_timeline(project_data: Dictionary, images_data: Array) -> void:
	online_project.frames.clear()
	online_project.layers.clear()
	online_project.deserialize(project_data)
	var image_index := 0
	for frame in online_project.frames:
		for cel in frame.cels:
			if cel.get_class_name() != "PixelCel":
				continue
			## Make an ImageExtended from the image data
			var image_data: PackedByteArray = images_data[image_index]
			var image_extended = api.project.new_image_extended(
				online_project.size.x,
				online_project.size.y,
				false,
				Image.FORMAT_RGBA8,
				online_project.is_indexed(),
				image_data
			)
			cel.image_changed(image_extended)
			image_index += 1
	# Check if a selected cel has been deleted
	# If it has, set the selected cel to the first one
	for cel_indices in online_project.selected_cels:
		var frame_index: int = cel_indices[0]
		var layer_index: int = cel_indices[1]
		if frame_index >= online_project.frames.size() or layer_index >= online_project.layers.size():
			online_project.selected_cels = [[0, 0]]
			online_project.current_frame = 0
			online_project.current_layer = 0
			break
	online_project.change_project()
