extends Node3D

# 都市玩法总管（Phase 1）：人物 ↔ 车辆的「上下车」切换 + Esc 回选图。
#
# 设计约束（AGENTS.md / 总纲 R1 + 交互门控机制）：
# - 开车手感完全交给现成的 ArcadeVehicle + view.gd，这里只做「谁读键盘、哪个相机活着」的换轨。
# - 上车 = 人物隐身停算、车辆 is_player=true、view 相机接管；下车反向。
# - 高速不允许下车（exit_max_speed 以上只出提示不响应，由 VehicleInteractable 把关）。
# - 提示条与 E 键不再由本脚本直接判定，一律走 InteractionGate：
#   距离内 + 模型已实例化（mark_ready）+ 业务可用 三条件同时满足才出现提示。
#   本脚本只提供门控回调：can_exit_vehicle / enter_vehicle / exit_vehicle / is_vehicle_remote。

@export var enter_distance: float = 3.6
@export var exit_max_speed: float = 1.2

@onready var player: PlayerCharacter = $Player
@onready var view: Node3D = $View
@onready var view_camera: Camera3D = $View/Camera
@onready var terrain: Node3D = get_node_or_null("Terrain")
@onready var net: Node = get_node_or_null("Net")

var _driving: Node3D = null
var _prompt: Label = null
var _gate: InteractionGate = null


func _ready() -> void:
	view.set_physics_process(false)
	view.set("target", null)
	view_camera.current = false
	# 都市里的 Kenney 车只有 4.3 米长，view.gd 默认 2.9 米机位会咬进车尾
	# （用户实机反馈「开车只能看到大屁股」），这里拉到 6.5 米
	view.set("distance", 6.5)
	_build_prompt()
	player.set_active(true)
	_setup_gate()


func _build_prompt() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PromptLayer"
	layer.layer = 3
	add_child(layer)
	_prompt = Label.new()
	_prompt.name = "Prompt"
	_prompt.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_prompt.offset_left = 0.0
	_prompt.offset_top = -64.0
	_prompt.offset_right = 0.0
	_prompt.offset_bottom = -24.0
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 22)
	_prompt.add_theme_color_override("font_color", Color("#f4f7fb"))
	_prompt.add_theme_color_override("font_outline_color", Color("#10141c"))
	_prompt.add_theme_constant_override("outline_size", 6)
	# 可见性归 InteractionGate 独家管理，这里只定初值
	_prompt.visible = false
	layer.add_child(_prompt)


func _setup_gate() -> void:
	_gate = InteractionGate.new()
	_gate.name = "InteractionGate"
	add_child(_gate)
	_gate.player = player
	_gate.prompt = _prompt
	# City 是子节点，_ready 先于本脚本跑完，停放车已全部就位
	var list: Array = get_tree().get_nodes_in_group("vehicles")
	var i: int = 0
	while i < list.size():
		_bind_vehicle(list[i] as Node3D)
		i += 1


## 给一台车挂交互组件。车辆模型是同步 load+instantiate 的：_outfit_car 挂完
## Container/Model 后子节点立即存在，这里就是「实例化完成回调」——mark_ready
## 只许在这种确认模型真到位的地方调（断言 2）。量不到模型的车永远不亮提示。
func _bind_vehicle(car: Node3D) -> void:
	if car == null:
		return
	var it := VehicleInteractable.new()
	it.name = "VehicleInteractable"
	it.host = self
	it.interact_radius = enter_distance
	car.add_child(it)
	var model: Node = car.get_node_or_null("Container/Model")
	if model != null and not model.get_children().is_empty():
		it.mark_ready()
	else:
		push_warning("[urban] " + String(car.name) + " 没有可用模型，交互保持关闭")


func _interactable_of(car: Node) -> VehicleInteractable:
	if car == null:
		return null
	var list: Array = car.get_children()
	var i: int = 0
	while i < list.size():
		var it: VehicleInteractable = list[i] as VehicleInteractable
		if it != null:
			return it
		i += 1
	return null


# ------------------------------------------------------------ 门控回调

func can_exit_vehicle() -> bool:
	if _driving == null:
		return false
	return _car_speed(_driving) <= exit_max_speed


func is_vehicle_remote(car: Node) -> bool:
	if net == null or not net.has_method("is_remote_owned"):
		return false
	return net.call("is_remote_owned", car)


func enter_vehicle(car: Node3D) -> void:
	if _driving != null or car == null:
		return
	_driving = car
	var it := _interactable_of(car)
	if it != null:
		it.mode = VehicleInteractable.MODE_DRIVE
	car.set("is_player", true)
	car.set("input", Vector3.ZERO)
	view.set("target", car)
	view.set("_initialized", false)
	view.set_physics_process(true)
	view_camera.current = true
	player.set_active(false)
	# set_active(false) 会释放鼠标；驾驶中必须重新捕获，否则 view.gd 的鼠标环绕收不到 motion
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if net != null and net.has_method("claim_car"):
		net.call("claim_car", car)
	var eng: Node = car.get_node_or_null("Container/EngineSound")
	if eng != null:
		eng.play()
	var screech: Node = car.get_node_or_null("Container/ScreechSound")
	if screech != null:
		screech.play()
	# #20：通知 economy 模块把角色能力倍率写到这台车上（模块间只走事件，不互抓节点）
	var bus: Node = get_node_or_null("/root/EventBus")
	if bus != null:
		bus.vehicle_boarded.emit(String(car.name))


# ------------------------------------------------------------ 模块对外接口（#20）
#
# economy / missions 模块不进场景树抓人，只通过这几个公开方法操作都市场景。
# 返回的车节点已由本脚本挂好 VehicleInteractable 并 mark_ready（走同一门控契约）。

func get_driving() -> Node3D:
	return _driving


func get_game_player() -> Node3D:
	return player


## 在都市里生成一台命名车（商店发货 / 任务车）。stats 可选：
## {max_speed, engine_power, lateral_grip} 直接写进街机参数。
func spawn_city_car(node_name: String, model_path: String, pos: Vector3, yaw: float, stats: Dictionary = {}) -> Node3D:
	var city: Node = get_node_or_null("City")
	if city == null or not city.has_method("build_car"):
		push_warning("[urban] 找不到 City.build_car，无法生成 " + node_name)
		return null
	var car: Node3D = city.call("build_car", node_name, model_path, pos, yaw) as Node3D
	if car == null:
		return null   # 同名已存在或加载失败
	for k in stats.keys():
		car.set(String(k), float(stats[k]))
	_bind_vehicle(car)
	return car


func exit_vehicle() -> void:
	var car: Node3D = _driving
	if car == null:
		return
	_driving = null
	var it := _interactable_of(car)
	if it != null:
		it.mode = VehicleInteractable.MODE_BOARD
	car.set("is_player", false)
	car.set("input", Vector3.ZERO)
	if net != null and net.has_method("release_car"):
		net.call("release_car", car)
	view.set_physics_process(false)
	view.set("target", null)
	view_camera.current = false
	var off_eng: Node = car.get_node_or_null("Container/EngineSound")
	if off_eng != null:
		off_eng.stop()
	var off_sc: Node = car.get_node_or_null("Container/ScreechSound")
	if off_sc != null:
		off_sc.stop()
	var p: Vector3 = _exit_point(car)
	player.global_position = p
	player.velocity = Vector3.ZERO
	player.set_active(true)


## 下车落点：依次探测 车右 / 车左 / 车后 / 斜前后 候选位，取第一个不撞
## 建筑（层1）与其他车（层8）的点。以前固定「车右 2.4 米」，紧贴建筑停车时
## 会把人物塞进墙里——相机埋进墙体，画面一黑就像「人物消失了」。
## 【#19 坑·一】车根节点（Vehicle Node3D）只是出生锚点，物理在子节点 sphere 上，
## 根位置永远停在开车前的地方。拿 car.global_position 当车位，开多远下车就瞬移回
## 多远的「老窝」——用户反馈「下车人不知道哪里出现的」正是它。车实际位置一律走
## get_vehicle_position()（模型世界坐标）。
## 【#19 坑·二】高度绝不能写死 0.1：车停在城内坡道/城外山岭（ground_height 0~40 米）
## 时人会直接埋进山体里。候选位与落点按 Terrain.ground_height 唯一真值取地面。
func _exit_point(car: Node3D) -> Vector3:
	var base: Vector3 = _car_pos(car)
	var container: Node3D = car.get_node("Container") as Node3D
	var ax: Vector3 = container.global_transform.basis.x
	var az: Vector3 = container.global_transform.basis.z
	var cands: Array = [ax * 2.6, az * -2.6, ax * -2.6, az * 2.6,
		(ax + az).normalized() * 3.2, (ax - az).normalized() * 3.2,
		(ax * 3.6), (az * -3.6)]
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var sphere: Node = car.get_node_or_null("Sphere")
	for c in cands:
		var p: Vector3 = base + (c as Vector3)
		var gy: float = _ground_y(p.x, p.z)
		p.y = gy + 0.9
		var q := PhysicsShapeQueryParameters3D.new()
		var sh := SphereShape3D.new()
		sh.radius = 0.45
		q.shape = sh
		q.transform = Transform3D(Basis.IDENTITY, p)
		q.collision_mask = 11
		if sphere != null:
			q.exclude = [sphere.get_rid()]
		if space.intersect_shape(q, 1).size() == 0:
			return Vector3(p.x, gy + 0.05, p.z)
	var fx: float = base.x + ax.x * 2.6
	var fz: float = base.z + ax.z * 2.6
	return Vector3(fx, _ground_y(fx, fz) + 0.05, fz)


## 车的真实位置：模型世界坐标（根节点是出生锚点，不会跟着开，见 _exit_point 注释）
func _car_pos(car: Node) -> Vector3:
	if car.has_method("get_vehicle_position"):
		return car.call("get_vehicle_position")
	return (car as Node3D).global_position


## 车停靠处的地面高度（城内取 0 与地面板顶对齐，城外取地形真值）
func _ground_y(x: float, z: float) -> float:
	if terrain != null and terrain.has_method("ground_height"):
		return maxf(float(terrain.call("ground_height", x, z)), 0.0)
	return 0.0


func _car_speed(car: Node) -> float:
	if car.has_method("get_speed_mps"):
		return car.call("get_speed_mps")
	return 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed:
		if (event as InputEventKey).keycode == KEY_ESCAPE and _driving == null:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_tree().paused = false
			get_tree().change_scene_to_file("res://scenes/select.tscn")
