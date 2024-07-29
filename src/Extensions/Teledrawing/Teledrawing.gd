extends AcceptDialog

enum { CREATE, JOIN }

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
		if not online_project.timeline_updated.is_connected(timeline_updated):
			online_project.timeline_updated.connect(timeline_updated)

var broadcaster: PacketPeerUDP
var listener := PacketPeerUDP.new()
var listen_port: int = 8911
var broadcast_port: int = 8912
var available_servers: Dictionary

@onready var listener_timer: Timer = $ListenerTimer
@onready var broadcast_timer: Timer = $BroadcastTimer
@onready var network_options := $NetworkOptions as VBoxContainer
@onready var disconnect_button := %Disconnect as Button
@onready var available_servers_list: ItemList = $NetworkOptions/AvailableServers


func _enter_tree() -> void:
	menu_item_index = ExtensionsApi.menu.add_menu_item(ExtensionsApi.menu.EDIT, "Teledrawing", self)
	multiplayer.connected_to_server.connect(handle_connect)
	multiplayer.peer_connected.connect(new_user_connected)

	var err = listener.bind(listen_port)
	if err == OK:
		print("Successful Bound of Listener")
		# For easy identification (for testing only). When we open multiple instances of pixelorama
		# on the same machine, only "one" can be bound successfully.
		get_tree().root.mode = Window.MODE_MINIMIZED
	else:
		print("Bound Unsuccessful of Listener: %s" % error_string(err))


func _exit_tree() -> void:
	listener.close()
	handle_disconnect()
	ExtensionsApi.menu.remove_menu_item(ExtensionsApi.menu.EDIT, menu_item_index)


## Method to show the Teledrawing interface (called when the menu item representing it gets clicked)
func menu_item_clicked() -> void:
	popup_centered()
	ExtensionsApi.dialog.dialog_open(true)


func _on_tab_bar_tab_changed(tab: int) -> void:
	var ip_label: Label = $NetworkOptions/GridContainer/IPLabel
	var ip_line_edit: LineEdit = $NetworkOptions/GridContainer/IPLineEdit
	var create_join_button: Button = $NetworkOptions/CreateJoinServer
	match tab:
		CREATE:
			ip_label.visible = false
			ip_line_edit.visible = false
			available_servers_list.visible = false
			create_join_button.pressed.disconnect(_on_join_server_pressed)
			create_join_button.pressed.connect(_on_create_server_pressed)
			create_join_button.text = "Create"
		JOIN:
			ip_label.visible = true
			ip_line_edit.visible = true
			available_servers_list.visible = true
			create_join_button.pressed.disconnect(_on_create_server_pressed)
			create_join_button.pressed.connect(_on_join_server_pressed)
			create_join_button.text = "Join"


## Called after the user has connected to server successfully.
func handle_connect() -> void:
	for child: Control in network_options.get_children():
		child.visible = child == disconnect_button
	ExtensionsApi.signals.signal_project_data_changed(project_data_changed)


## Called after user is disconnected.
func handle_disconnect() -> void:
	if broadcaster != null:
		broadcaster.close()
	for child: Control in network_options.get_children():
		child.visible = child != disconnect_button
	multiplayer.multiplayer_peer = null
	ExtensionsApi.signals.signal_project_data_changed(project_data_changed, true)
	online_project = null
	broadcast_timer.stop()


## Called on all users when a new User joins.
## NOTE: As this method also does a [code]multiplayer.is_server()[/code], the code below only runs
## on the server.
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


## Called from the server to clients when they connect
@rpc("authority", "call_remote", "reliable")
func receive_new_project(project_data: Dictionary, images_data: Array) -> void:
	online_project = ExtensionsApi.project.new_empty_project()
	online_project.deserialize(project_data)
	var image_index := 0
	for frame in online_project.frames:
		for cel in frame.cels:
			if cel.get_class_name() != "PixelCel":
				continue
			var image_data: PackedByteArray = images_data[image_index]
			var image := Image.create_from_data(
				online_project.size.x, online_project.size.y, false, Image.FORMAT_RGBA8, image_data
			)
			cel.image_changed(image)
			image_index += 1
	ExtensionsApi.project.current_project = online_project
	ExtensionsApi.general.get_canvas().camera_zoom()


## Called every time the project data changes
func project_data_changed(project: RefCounted) -> void:
	if project != online_project:
		return
	var data := {}
	var cels: Array = project.selected_cels
	if online_project.undo_redo.get_current_action_name() == "Scale":  # If project got resized
		for f in project.frames.size():
			for l in project.frames[f].cels.size():
				var cel_indices = [f, l]
				var cel = project.frames[f].cels[l]
				if cel.get_class_name() != "PixelCel":
					continue
				var image: Image = cel.image
				data[cel_indices] = image.get_data()
	else:
		for cel_indices in cels:
			var frame_index: int = cel_indices[0]
			var layer_index: int = cel_indices[1]
			var cel = project.frames[frame_index].cels[layer_index]
			if cel.get_class_name() != "PixelCel":
				continue
			var image: Image = cel.image
			data[cel_indices] = image.get_data()
	receive_changes.rpc(data, project.size)


## Called on all connected users after any of the users change project data.
@rpc("any_peer", "call_remote", "reliable")
func receive_changes(data: Dictionary, p_size: Vector2i) -> void:
	if p_size != online_project.size:
		ExtensionsApi.general.get_drawing_algos().resize_canvas(
			p_size.x, p_size.y, 0, 0
		)
	for cel_indices in data:
		var frame_index: int = cel_indices[0]
		var layer_index: int = cel_indices[1]
		if frame_index >= online_project.frames.size() or layer_index >= online_project.layers.size():
			continue
		var cel = online_project.frames[frame_index].cels[layer_index]
		if cel.get_class_name() != "PixelCel":
			continue
		var image: Image = cel.image
		var image_data: PackedByteArray = data[cel_indices]
		var image_size := image.get_size()
		image.set_data(
			image_size.x, image_size.y, image.has_mipmaps(), image.get_format(), image_data
		)
		ExtensionsApi.general.get_canvas().update_texture(layer_index, frame_index, online_project)


func timeline_updated() -> void:
	var project_data: Dictionary = online_project.serialize()
	var images_data: Array = []
	for frame in online_project.frames:
		for cel in frame.cels:
			var cel_image: Image = cel.get_image()
			if is_instance_valid(cel_image) and cel.get_class_name() == "PixelCel":
				images_data.append(cel_image.get_data())
	receive_updated_timeline.rpc(project_data, images_data)


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
			var image_data: PackedByteArray = images_data[image_index]
			var image := Image.create_from_data(
				online_project.size.x, online_project.size.y, false, Image.FORMAT_RGBA8, image_data
			)
			cel.image_changed(image)
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


func broadcast() -> void:
	var room_info: Dictionary = {
		"name": online_project.name,
		"player_count": multiplayer.get_peers().size() + 1,
		"port": port,
	}
	var data = JSON.stringify(room_info)
	broadcaster.put_packet(data.to_ascii_buffer())


## Gets called when the "Create server" button is pressed.
## A new server is created on a specified port, with a maximum of 32 user capacity.
## The current project of the user who creates the server becomes the main focus.
func _on_create_server_pressed() -> void:
	var server := ENetMultiplayerPeer.new()
	var error = server.create_server(port, 32)
	if error == OK:
		multiplayer.multiplayer_peer = server
		online_project = ExtensionsApi.project.current_project

		broadcaster = PacketPeerUDP.new()
		broadcaster.set_broadcast_enabled(true)
		broadcaster.set_dest_address("255.255.255.255", listen_port)
		var err = broadcaster.bind(broadcast_port)
		if err == OK:
			print("Successful bound of broadcaster")
		else:
			print("Bound unsuccessful for broadcaster")
		broadcast_timer.start()
		listener_timer.stop()
		handle_connect()


func _on_join_server_pressed() -> void:
	var client := ENetMultiplayerPeer.new()
	var error = client.create_client(ip, port)
	if error == OK:
		multiplayer.multiplayer_peer = client
		listener_timer.stop()


func _on_disconnect_pressed() -> void:
	handle_disconnect()
	listener_timer.start()


func _on_ip_line_edit_text_changed(new_text: String) -> void:
	ip = new_text


func _on_port_line_edit_text_changed(new_text: String) -> void:
	if new_text.is_valid_int():
		port = new_text.to_int()


func _on_visibility_changed() -> void:
	if not visible:
		ExtensionsApi.dialog.dialog_open(false)


func _on_broadcast_timer_timeout() -> void:
	broadcast()


func _on_listener_timer_timeout() -> void:
	if listener.get_available_packet_count() > 0:
		var server_ip = listener.get_packet_ip()
		var data = str_to_var(listener.get_packet().get_string_from_ascii())
		if typeof(data) == TYPE_DICTIONARY:
			if server_ip != "":
				available_servers[server_ip] = data
				_refresh_list()


func _on_available_servers_item_selected(index: int) -> void:
	var server_ip := available_servers_list.get_item_tooltip(index)
	var data: Dictionary = available_servers[server_ip]
	if data.has("port"):
		port = data["port"]
		$NetworkOptions/GridContainer/PortLineEdit.text = str(port)
	$NetworkOptions/GridContainer/IPLineEdit.text = server_ip


func _on_available_servers_empty_clicked(_at_position: Vector2, _mouse_button_index: int) -> void:
	available_servers_list.deselect_all()


func _on_refresh_timer_timeout() -> void:
	available_servers.clear()
	available_servers_list.clear()


func _refresh_list() -> void:
	available_servers_list.clear()
	for server_ip in available_servers.keys():
		var text = str(
			"Name: ",
			available_servers[server_ip]["name"] ,
			" (",
			server_ip,
			")",
			"  %s/32" % available_servers[server_ip]["player_count"]
		)
		var idx = available_servers_list.add_item(text)
		available_servers_list.set_item_tooltip(idx, server_ip)
