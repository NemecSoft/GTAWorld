extends Node3D

# urban 多人同步层（复用 autoload Lobby 的 ENet 会话，见 scripts/net/session.gd）。
#
# 模型：**驾驶者权威 + 快照广播**（无中心服务器时最简单且手感最好的一套，
# 和 session.gd 注释里「客户端只报意图」的远期服务端权威方向不冲突，Phase 2 可升级）。
# - 每人 20Hz 广播：自身位姿 + 动画 + 正在驾驶的车名/车位姿（unreliable_ordered）。
# - 远端玩家 = 一份 player.tscn 克隆（无输入、无物理、相机不 current），按快照插值。
# - 远端驾驶中的车：本地冻结其脚本与球体物理，直接照抄车位姿。
# - 车归属：_car_owners（车名 -> peer id），urban_game 靠它跳过别人正在开的车。
#
# Tab 键开关网络面板（开房 / 输 IP 加入 / 退出），面板出现时释放鼠标。

const TICK: float = 1.0 / 20.0
const LERP_POS: float = 12.0
const LERP_YAW: float = 10.0

var _acc: float = 0.0
var _avatars: Dictionary = {}      # peer_id -> {node, tpos, tyaw, tmyaw, tanim, driving}
var _car_owners: Dictionary = {}   # 车名 -> peer_id
var _car_targets: Dictionary = {}  # 车名 -> {node, tpos, tyaw}

var _panel: CanvasLayer = null
var _status: Label = null
var _ip_edit: LineEdit = null
var _view_menu: Control = null
var _view_join: Control = null
var _view_room: Control = null
var _room_info: Label = null
var _player_list: VBoxContainer = null
var _join_mode: bool = false
var _list_sig: String = ""
var _flash: String = ""


## 【坑】客机在 _ready 阶段（尚未连上）调 multiplayer.get_unique_id() 恒返回 1，
## 而服务端 sender id 恰是 1——缓存成 _my_id 会把房主发来的包全当「自己」丢掉。
## 必须每次实时读。
func _my_id_now() -> int:
	return multiplayer.get_unique_id()

## autoload 名在 4.7 场景编译时序里不一定注册成全局标识符（vehicle_picker 同款坑），
## 一律走 /root 路径取 Lobby 节点。
var _lobby: Node = null


func _ready() -> void:
	_lobby = get_node_or_null("/root/Lobby")
	multiplayer.peer_disconnected.connect(_on_peer_left)
	_build_panel()
	# 双实例冒测/快捷开局：--net-host / --net-join=127.0.0.1（放在引擎参数之后）
	for ua in OS.get_cmdline_user_args():
		var s: String = String(ua)
		if s == "--net-host":
			_on_host()
		elif s.begins_with("--net-join="):
			_ip_edit.text = s.substr(len("--net-join="))
			_on_join()


func _net_on() -> bool:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null:
		return false
	# 【#19 坑】单机默认 peer 是 OfflineMultiplayerPeer，它把自身状态报成 CONNECTED，
	# 不排掉的话单机 _net_on() 恒真：大厅 UI 一打开就误入「房间」视图，还每帧发幽灵快照
	if peer is OfflineMultiplayerPeer:
		return false
	# 客户端 create_client 之后 peer 就存在了，但「正在握手」的窗口期发 RPC 会报
	# "not connected"（实测），必须等状态真正 CONNECTED
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _physics_process(delta: float) -> void:
	if not _net_on():
		return
	_acc += delta
	if _acc >= TICK:
		_acc = 0.0
		_send_state()


func _process(delta: float) -> void:
	_refresh_net_ui()
	if not _net_on():
		return
	var k: float = 1.0 - exp(-LERP_POS * delta)
	var ky: float = 1.0 - exp(-LERP_YAW * delta)
	for id in _avatars.keys():
		var a: Dictionary = _avatars[id]
		var n: Node3D = a["node"]
		if not is_instance_valid(n):
			continue
		var driving: String = String(a["driving"])
		n.visible = driving == ""
		if driving == "":
			n.global_position = n.global_position.lerp(a["tpos"], k)
			var mp: Node3D = n.get_node("ModelPivot") as Node3D
			mp.rotation.y = lerp_angle(mp.rotation.y, float(a["tmyaw"]), ky)
			_play_clip(n, int(a["tanim"]))
	for cname in _car_targets.keys():
		var ct: Dictionary = _car_targets[cname]
		var car: Node = ct["node"]
		if not is_instance_valid(car):
			continue
		(car as Node3D).global_position = (car as Node3D).global_position.lerp(ct["tpos"], k)
		(car as Node3D).rotation.y = lerp_angle((car as Node3D).rotation.y, float(ct["tyaw"]), ky)


# ---------------------------------------------------------------- 对外 API

func claim_car(car: Node) -> void:
	_car_owners[String(car.name)] = _my_id_now()


func release_car(car: Node) -> void:
	_car_owners.erase(String(car.name))


func is_remote_owned(car: Node) -> bool:
	var owner_id: int = int(_car_owners.get(String(car.name), 0))
	return owner_id > 0 and owner_id != _my_id_now()


# ---------------------------------------------------------------- 快照收发

func _send_state() -> void:
	var game: Node3D = get_parent() as Node3D
	var player: PlayerCharacter = game.get_node("Player") as PlayerCharacter
	var driving: Node3D = game.get("_driving") as Node3D
	var anim: int = 0
	if not player.is_on_floor():
		anim = 2
	elif Vector2(player.velocity.x, player.velocity.z).length() > 0.3:
		anim = 1
	var cname: String = ""
	var cpos: Vector3 = Vector3.ZERO
	var cyaw: float = 0.0
	if driving != null:
		cname = String(driving.name)
		# 车根节点是出生锚点不会跟着开（#19），广播必须用模型真实位置与 yaw
		if driving.has_method("get_vehicle_position"):
			cpos = driving.call("get_vehicle_position")
		else:
			cpos = driving.global_position
		cyaw = float(driving.get("yaw"))
	var mp: Node3D = player.get_node("ModelPivot") as Node3D
	if multiplayer.is_server():
		# 服务端：直接广播给所有客机
		rpc("_rpc_state", player.global_position, mp.rotation.y, anim, cname, cpos, cyaw)
	else:
		# 客机：ENet 星型拓扑下客机之间没有直连，唯一路径是 客机→服务端→转发。
		rpc_id(1, "_rpc_relay", player.global_position, mp.rotation.y, anim, cname, cpos, cyaw)


@rpc("any_peer", "unreliable_ordered")
func _rpc_relay(pos: Vector3, myaw: float, anim: int, car_name: String, cpos: Vector3, cyaw: float) -> void:
	if not multiplayer.is_server():
		return
	var src: int = multiplayer.get_remote_sender_id()
	if src > 0:
		_apply_state(src, pos, myaw, anim, car_name, cpos, cyaw)
	for pid in multiplayer.get_peers():
		if pid != src:
			rpc_id(pid, "_rpc_state", pos, myaw, anim, car_name, cpos, cyaw)


@rpc("any_peer", "unreliable_ordered")
func _rpc_state(pos: Vector3, myaw: float, anim: int, car_name: String, cpos: Vector3, cyaw: float) -> void:
	var id: int = multiplayer.get_remote_sender_id()
	if id <= 0 or id == _my_id_now():
		return
	_apply_state(id, pos, myaw, anim, car_name, cpos, cyaw)


func _apply_state(id: int, pos: Vector3, myaw: float, anim: int, car_name: String, cpos: Vector3, cyaw: float) -> void:
	if not _avatars.has(id):
		_spawn_avatar(id)
	var a: Dictionary = _avatars[id]
	a["tpos"] = pos
	a["tmyaw"] = myaw
	a["tanim"] = anim
	a["driving"] = car_name
	if car_name != "":
		_car_owners[car_name] = id
		var car: Node = get_parent().find_child(car_name, true, false)
		if car != null and car is Node3D:
			_set_car_remote_authority(car as Node3D, true)
			var ct: Dictionary
			if _car_targets.has(car_name):
				ct = _car_targets[car_name]
			else:
				ct = {"node": car, "tpos": (car as Node3D).global_position, "tyaw": (car as Node3D).rotation.y}
				_car_targets[car_name] = ct
			ct["tpos"] = cpos
			ct["tyaw"] = cyaw


func _play_clip(n: Node, anim: int) -> void:
	var ap: AnimationPlayer = _find_anim(n)
	if ap == null:
		return
	var clip: String = "idle"
	if anim == 1:
		clip = "walk"
		if not ap.has_animation("walk"):
			clip = "run"
	elif anim == 2:
		clip = "jump"
	if ap.has_animation(clip) and ap.current_animation != clip:
		ap.play(clip)


func _find_anim(n: Node) -> AnimationPlayer:
	for c in n.get_children():
		if c is AnimationPlayer:
			return c as AnimationPlayer
		var sub: AnimationPlayer = _find_anim(c)
		if sub != null:
			return sub
	return null


## 远端有人开始/停止开这台车：本地冻结或解冻它的控制器脚本与物理球。
func _set_car_remote_authority(car: Node3D, remote: bool) -> void:
	car.set_physics_process(not remote)
	var sphere: RigidBody3D = car.get_node_or_null("Sphere") as RigidBody3D
	if sphere != null:
		sphere.freeze = remote
		if remote:
			sphere.linear_velocity = Vector3.ZERO
			sphere.angular_velocity = Vector3.ZERO


func _spawn_avatar(id: int) -> void:
	var s: PackedScene = load("res://scenes/player.tscn")
	if s == null:
		push_warning("[net] 读不到 scenes/player.tscn")
		return
	var a: Node3D = s.instantiate() as Node3D
	a.name = "Peer%d" % id
	# 场景里 Camera.current=true，必须在 add_child 前掐掉，否则抢走本地相机
	var cam: Camera3D = a.find_child("Camera", true, false) as Camera3D
	if cam != null:
		cam.current = false
	var tag := Label3D.new()
	tag.text = "P%d" % id
	tag.position = Vector3(0, 2.1, 0)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 40
	tag.outline_size = 8
	tag.no_depth_test = true
	a.add_child(tag)
	get_parent().add_child(a)
	_avatars[id] = {"node": a, "tpos": a.global_position, "tyaw": 0.0, "tanim": 0, "driving": ""}


func _on_peer_left(id: int) -> void:
	if not _avatars.has(id):
		return
	var a: Dictionary = _avatars[id]
	var n: Node = a["node"] as Node
	var driving: String = String(a["driving"])
	if driving != "":
		_car_owners.erase(driving)
		var car: Node = get_parent().find_child(driving, true, false)
		if car != null and car is Node3D:
			_set_car_remote_authority(car as Node3D, false)
		_car_targets.erase(driving)
	_avatars.erase(id)
	if is_instance_valid(n):
		n.queue_free()


# ---------------------------------------------------------------- 大厅 UI
#
# Tab 呼出的居中面板，三个视图：
#   菜单：创建大厅 / 加入大厅 / 关闭
#   加入：IP 输入 + 连接 + 返回
#   房间：身份与我方 peer id +（房主显示本机 IP 供好友输入）+ 在线玩家列表 + 退出房间
# 视图切换全在 _refresh_net_ui() 一处算，别在按钮回调里藏 visible 赋值。

func _build_panel() -> void:
	_panel = CanvasLayer.new()
	_panel.name = "NetUI"
	_panel.layer = 5
	add_child(_panel)
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.01, 0.02, 0.04, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(center)
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#10141c")
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(24)
	sb.border_color = Color(0.35, 0.42, 0.55)
	sb.set_border_width_all(2)
	box.add_theme_stylebox_override("panel", sb)
	box.custom_minimum_size = Vector2(400, 0)
	center.add_child(box)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	box.add_child(vb)
	var title := Label.new()
	title.text = "联机大厅"
	title.add_theme_font_size_override("font_size", 26)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	_status = Label.new()
	_status.text = "单机模式"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", Color("#9fb0c8"))
	vb.add_child(_status)
	# ---- 视图 1：主菜单
	_view_menu = VBoxContainer.new()
	(_view_menu as VBoxContainer).add_theme_constant_override("separation", 10)
	vb.add_child(_view_menu)
	_view_menu.add_child(_make_button("创建大厅（端口 7777）", _on_host))
	_view_menu.add_child(_make_button("加入大厅（输入 IP）", _show_join))
	_view_menu.add_child(_make_button("关闭", _close_panel))
	# ---- 视图 2：加入
	_view_join = VBoxContainer.new()
	(_view_join as VBoxContainer).add_theme_constant_override("separation", 10)
	vb.add_child(_view_join)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	_view_join.add_child(hb)
	_ip_edit = LineEdit.new()
	_ip_edit.text = "127.0.0.1"
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ip_edit.custom_minimum_size = Vector2(0, 36)
	hb.add_child(_ip_edit)
	var b_go := _make_button("连接", _on_join)
	b_go.custom_minimum_size = Vector2(96, 36)
	hb.add_child(b_go)
	_view_join.add_child(_make_button("返回", _show_menu))
	# ---- 视图 3：房间
	_view_room = VBoxContainer.new()
	(_view_room as VBoxContainer).add_theme_constant_override("separation", 10)
	vb.add_child(_view_room)
	_room_info = Label.new()
	_room_info.add_theme_color_override("font_color", Color("#cfd9e8"))
	_view_room.add_child(_room_info)
	var cap := Label.new()
	cap.text = "在线玩家"
	cap.add_theme_color_override("font_color", Color("#9fb0c8"))
	_view_room.add_child(cap)
	_player_list = VBoxContainer.new()
	_view_room.add_child(_player_list)
	_view_room.add_child(_make_button("退出房间", _on_leave))
	_view_room.add_child(_make_button("关闭", _close_panel))
	_panel.visible = false


func _make_button(text: String, target: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(352, 40)
	b.pressed.connect(target)
	return b


func _show_join() -> void:
	_join_mode = true
	_flash = ""


func _show_menu() -> void:
	_join_mode = false
	_flash = ""


func _close_panel() -> void:
	_panel.visible = false
	_join_mode = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _refresh_net_ui() -> void:
	if _panel == null or not _panel.visible:
		return
	var connected: bool = _net_on()
	_view_room.visible = connected
	_view_join.visible = (not connected) and _join_mode
	_view_menu.visible = (not connected) and (not _join_mode)
	if connected:
		var role: String = "房主" if multiplayer.is_server() else "玩家"
		var info: String = "%s ｜ 我 = peer %d" % [role, _my_id_now()]
		if multiplayer.is_server():
			var ips: PackedStringArray = IP.get_local_addresses()
			var v4: String = ""
			for a in ips:
				if String(a).contains("."):
					v4 = String(a)
					break
			if v4 != "":
				info += "\n本机 IP：%s（端口 7777，发给好友即可加入）" % v4
		_room_info.text = info
		var names: Array = []
		var players: Dictionary = {}
		if _lobby != null:
			players = _lobby.get("players")
		for k in players.keys():
			names.append("%d：%s" % [int(k), String(players[k]["name"])])
		names.sort()
		var sig: String = ",".join(PackedStringArray(names))
		if sig != _list_sig:
			_list_sig = sig
			for c in _player_list.get_children():
				c.queue_free()
			for n2 in names:
				var li := Label.new()
				li.text = "•  " + String(n2)
				_player_list.add_child(li)
		_status.text = "已连接 ｜ %d 人在线" % names.size()
	elif _lobby != null and multiplayer.multiplayer_peer != null \
			and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		_status.text = "连接中…"
	elif _flash != "":
		_status.text = _flash
	else:
		_status.text = "单机模式"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed and (event as InputEventKey).keycode == KEY_TAB:
		_panel.visible = not _panel.visible
		if _panel.visible:
			_join_mode = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()


func _on_host() -> void:
	if _lobby == null:
		return
	var err: Error = _lobby.call("host", 2)  # RoomMode.PUBLIC
	if err != OK:
		_flash = "开房失败 %d" % err


func _on_join() -> void:
	if _lobby == null:
		return
	var err: Error = _lobby.call("join", _ip_edit.text)
	if err != OK:
		_flash = "连接失败 %d" % err
	else:
		_flash = ""


func _on_leave() -> void:
	# 把所有远端状态清干净再退
	for id in _avatars.keys():
		_on_peer_left(int(id))
	if _lobby != null:
		_lobby.call("leave")
	_join_mode = false
	_flash = "已退出，回到单机"
