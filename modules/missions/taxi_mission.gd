extends "res://modules/missions/mission_base.gd"
## modules/missions/taxi_mission.gd —— 出租车任务（单人，设计 §3-A 方案 A）
##
## 状态机：OFF → COOLDOWN →（路边刷乘客）→ HAILING →（E 载客）→ PICKED_UP
##         →（目的地 E 送达 / 超时）→ SETTLE 发金币 → COOLDOWN
## 门控契约：乘客/目的地都是 Interactable 子类，can_interact 里查
##   「就绪 ∧ 状态匹配 ∧ 正开出租车 ∧ 车停稳 ∧ 距离」——提示与 E 全走全局 InteractionGate。
## 招手（拍板 §7-2）：优先程序摆臂（Skeleton3D 里找 right 侧 arm/shoulder/elbow 骨骼，
##   停掉 idle 逐帧摆），找不到骨骼走保底「弹跳 + 头顶 !」。
## 4.7 坑：无 `..`；本类继承 mission_base（RefCounted 系），节点生命周期全交给 mod。

const TAXI_PATH := "res://models/cars/taxi.glb"
const TAXI_NAME := "TaxiMission"
const STAND := Vector3(-26.4, 0.0, 24.0)
const SKINS: Array = [
	"res://assets/animated-characters/skins/skaterMaleA.png",
	"res://assets/animated-characters/skins/skaterFemaleA.png",
	"res://assets/animated-characters/skins/cyborgFemaleA.png",
	"res://assets/animated-characters/skins/criminalMaleA.png",
]
const PLAYER_SCENE := "res://scenes/player.tscn"

const BASE_FARE: int = 50
const TIME_BONUS: int = 50
const HIT_CUT: int = 5
const HIT_CUT_MAX: int = 30
const CRUISE_REF: float = 8.0
const TIME_PAD: float = 1.6

var taxi: Node3D = null
var passenger: Node3D = null
var pass_spot: PassengerSpot = null
var dest: Node3D = null
var drop_spot: DropSpot = null

var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _wave_t: float = 0.0
var _arm_idx: int = -1
var _skeleton: Skeleton3D = null
var _impacts: int = 0
var _time_left: float = 0.0
var _time_limit: float = 1.0
var _result: String = ""
var _result_t: float = 0.0
var _wired: bool = false


class PassengerSpot extends Interactable:
	var owner_m: RefCounted = null

	func can_interact(player_pos: Vector3) -> bool:
		if not (is_ready and is_interactable) or owner_m == null:
			return false
		return owner_m.can_pickup(player_pos)

	func get_prompt(_player_pos: Vector3) -> String:
		return tr("按 E 请乘客上车")

	func on_interact(_player_pos: Vector3) -> void:
		if owner_m != null:
			owner_m.do_pickup()


class DropSpot extends Interactable:
	var owner_m: RefCounted = null

	func can_interact(player_pos: Vector3) -> bool:
		if not (is_ready and is_interactable) or owner_m == null:
			return false
		return owner_m.can_drop(player_pos)

	func get_prompt(_player_pos: Vector3) -> String:
		return tr("按 E 送达乘客")

	func on_interact(_player_pos: Vector3) -> void:
		if owner_m != null:
			owner_m.do_drop()


# ---------------------------------------------------------------- 生命周期

func enter(g: Node3D) -> void:
	leave()
	game = g
	if mod == null or game == null:
		return
	if mod.net_on():
		return   # 拍板：出租车是单人玩法；联机局不摆任务车
	if not _wired:
		var bus: Node = mod.bus()
		if bus != null:
			bus.vehicle_damaged.connect(_on_vehicle_damaged)
		_wired = true
	_rng.seed = 20261003
	taxi = game.call("spawn_city_car", TAXI_NAME, TAXI_PATH, STAND, PI, {}) as Node3D
	state = "COOLDOWN"
	_t = 3.0


func leave() -> void:
	state = "OFF"
	_t = 0.0
	_result = ""
	_result_t = 0.0
	_arm_idx = -1
	_skeleton = null
	_clear_passenger()
	_clear_dest()
	taxi = null
	game = null


func tick(delta: float) -> void:
	if _result_t > 0.0:
		_result_t -= delta
	match state:
		"COOLDOWN":
			_t -= delta
			if _t <= 0.0:
				_spawn_passenger()
		"HAILING":
			_wave_t += delta
			_drive_wave()
		"PICKED_UP":
			_time_left -= delta
			if _time_left <= 0.0:
				_fail(tr("超时了，乘客中途下了车"))


# ---------------------------------------------------------------- 乘客

func _spawn_passenger() -> void:
	if game == null:
		return
	var ppos: Vector3 = Vector3.ZERO
	var pl: Node3D = _find_player()
	if pl != null:
		ppos = pl.global_position
	var spot: Vector3 = _sample_point(ppos, 40.0, 120.0)
	var sc: PackedScene = load(PLAYER_SCENE)
	if sc == null:
		push_warning("[taxi] 读不到 scenes/player.tscn")
		_t = 5.0
		return
	var n: Node3D = sc.instantiate() as Node3D
	n.name = "TaxiPassenger"
	n.set("skin_path", String(SKINS[_rng.randi_range(0, SKINS.size() - 1)]))
	game.add_child(n)
	n.global_position = Vector3(spot.x, 0.05, spot.z)
	n.rotation.y = _rng.randf_range(0.0, TAU)
	# 客串乘客：不吃输入、不参与碰撞、相机让位
	var cam: Camera3D = n.find_child("Camera", true, false) as Camera3D
	if cam != null:
		cam.current = false
	n.call("set_active", false)
	# set_active(false) 会顺手释放鼠标（那是给下车切步行用的），乘客客串要抢回来
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	n.visible = true
	n.set_physics_process(false)
	n.set("collision_layer", 0)
	n.set("collision_mask", 0)
	_skeleton = _find_skeleton(n)
	_arm_idx = _find_right_arm(_skeleton)
	var ap: AnimationPlayer = _find_anim(n)
	if ap != null and _arm_idx >= 0:
		ap.stop()   # 停 idle，摆臂独占骨骼
	var bang := Label3D.new()
	bang.text = "!"
	bang.position = Vector3(0, 2.3, 0)
	bang.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bang.font_size = 64
	bang.outline_size = 10
	bang.modulate = Color("#ffd45e")
	n.add_child(bang)
	pass_spot = PassengerSpot.new()
	pass_spot.name = "PassengerSpot"
	pass_spot.owner_m = self
	pass_spot.interact_radius = 5.0
	pass_spot.interact_priority = 10   # 压过「按 E 下车」（开车接载场景）
	n.add_child(pass_spot)
	pass_spot.mark_ready()   # 乘客模型同步实例化完成（C2）
	passenger = n
	state = "HAILING"
	_wave_t = 0.0
	if mod != null:
		mod.emit_mission_state("taxi", "hailing")


func _drive_wave() -> void:
	if passenger == null:
		return
	if _skeleton != null and _arm_idx >= 0:
		# 举手挥动：绕骨骼局部 Z 往复；骨骼局部轴朝向没保证，幅度先看截图再调
		var a: float = 1.9 + sin(_wave_t * 6.5) * 0.55
		_skeleton.set_bone_pose_rotation(_arm_idx, Basis(Vector3(0, 0, 1), a))
	else:
		# 保底（拍板 §7-2）：原地弹跳，头顶「!」一直在
		passenger.position.y = 0.05 + 0.22 * absf(sin(_wave_t * 5.0))


func _clear_passenger() -> void:
	if pass_spot != null and is_instance_valid(pass_spot):
		pass_spot.owner_m = null
	pass_spot = null
	if passenger != null and is_instance_valid(passenger):
		passenger.queue_free()
	passenger = null


# ---------------------------------------------------------------- 载客 / 送达

func _driver() -> Node3D:
	if game == null:
		return null
	return game.call("get_driving") as Node3D


## #20 坑（和 cargo_mission 同款）：开车时人物节点停在上车点不跟车走，
## 门控传进来的 player_pos 不能用，距离一律量「正在开的车的真实位置」（基类 _car_pos）。
func can_pickup(_player_pos: Vector3) -> bool:
	if state != "HAILING" or passenger == null:
		return false
	var car: Node3D = _driver()
	if car != taxi or not _stopped(car):
		return false
	return passenger.global_position.distance_to(_car_pos(car)) <= pass_spot.interact_radius


func do_pickup() -> void:
	if passenger == null:
		return
	var from: Vector3 = passenger.global_position
	_clear_passenger()
	var spot: Vector3 = _sample_point(from, 90.0, 240.0)
	var dist: float = from.distance_to(spot)
	_build_dest(spot)
	_time_limit = maxf(dist / CRUISE_REF * TIME_PAD, 20.0)
	_time_left = _time_limit
	_impacts = 0
	state = "PICKED_UP"
	if mod != null:
		mod.emit_mission_state("taxi", "picked_up")


func _build_dest(pos: Vector3) -> void:
	dest = Node3D.new()
	dest.name = "TaxiDest"
	dest.position = pos
	game.add_child(dest)
	var pillar := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.3
	cm.bottom_radius = 1.3
	cm.height = 30.0
	pillar.mesh = cm
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1.0, 0.83, 0.37, 0.32)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.83, 0.37)
	m.emission_energy_multiplier = 1.4
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pillar.material_override = m
	pillar.position = Vector3(0, 15, 0)
	dest.add_child(pillar)
	var tag := Label3D.new()
	tag.text = tr("乘客目的地")
	tag.position = Vector3(0, 3.2, 0)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 48
	tag.outline_size = 10
	tag.modulate = Color("#ffd45e")
	dest.add_child(tag)
	drop_spot = DropSpot.new()
	drop_spot.name = "DropSpot"
	drop_spot.owner_m = self
	drop_spot.interact_radius = 9.0
	drop_spot.interact_priority = 10
	dest.add_child(drop_spot)
	drop_spot.mark_ready()


func _clear_dest() -> void:
	if drop_spot != null and is_instance_valid(drop_spot):
		drop_spot.owner_m = null
	drop_spot = null
	if dest != null and is_instance_valid(dest):
		dest.queue_free()
	dest = null


func can_drop(_player_pos: Vector3) -> bool:
	if state != "PICKED_UP" or dest == null:
		return false
	var car: Node3D = _driver()
	if car == null or not _stopped(car):
		return false
	return dest.global_position.distance_to(_car_pos(car)) <= drop_spot.interact_radius


func do_drop() -> void:
	if state != "PICKED_UP":
		return
	var bonus: int = int(clampf(_time_left / maxf(_time_limit, 0.001), 0.0, 1.0) * float(TIME_BONUS))
	var cut: int = mini(_impacts * HIT_CUT, HIT_CUT_MAX)
	var amount: int = maxi(BASE_FARE + bonus - cut, 10)
	var bus: Node = mod.bus()
	if bus != null:
		bus.coin_earn.emit(mod.my_id(), amount, "taxi")
	_result = "%s +%d %s（准时 +%d，撞击 -%d）" % [tr("送达"), amount, tr("金币"), bonus, cut]
	_result_t = 6.0
	_clear_dest()
	state = "COOLDOWN"
	_t = 8.0
	if mod != null:
		mod.emit_mission_state("taxi", "settle")


func _fail(msg: String) -> void:
	_result = msg
	_result_t = 6.0
	_clear_passenger()
	_clear_dest()
	state = "COOLDOWN"
	_t = 6.0


func _on_vehicle_damaged(car_name: String, _amount: float, _health: float) -> void:
	if state == "PICKED_UP" and car_name == TAXI_NAME:
		_impacts += 1


# ---------------------------------------------------------------- 点位采样

## 路网点采样 + 城内坡道规避（坡道楔高 1.6m，人站上去会穿帮）。
## 坡道带按 urban_terrain 的 layout：|x±23|<5 且 66<|z|<82（x 向），镜像同。
func _sample_point(origin: Vector3, dmin: float, dmax: float) -> Vector3:
	var city: Node = game.get_node("City")
	for i in range(24):
		var p: Vector3 = city.call("sample_road_point_away", _rng, origin, dmin, dmax) as Vector3
		if not _near_ramp(p):
			return p
	return city.call("sample_road_point_away", _rng, origin, dmin, dmax) as Vector3


func _near_ramp(p: Vector3) -> bool:
	var same_sign: bool = p.x * p.z > 0.0
	if absf(absf(p.x) - 23.0) < 5.0 and absf(p.z) > 66.0 and absf(p.z) < 82.0 and same_sign:
		return true
	if absf(absf(p.z) - 23.0) < 5.0 and absf(p.x) > 66.0 and absf(p.x) < 82.0 and same_sign:
		return true
	return false


# ---------------------------------------------------------------- HUD

func hud_line() -> String:
	match state:
		"HAILING":
			if passenger == null:
				return ""
			# 参照点和 can_pickup 一致：出租车此刻的真实位置（没上车时就是停放点）
			var d: float = passenger.global_position.distance_to(_car_pos(taxi))
			return "%s ｜ %s %.0fm" % [tr("出租车：路边有乘客招手，开车靠近接载"), tr("乘客"), d]
		"PICKED_UP":
			return "%s ｜ %s %ds" % [tr("出租车：送乘客到光柱处"), tr("剩余"), int(_time_left)]
		"COOLDOWN":
			if _result_t > 0.0:
				return _result
			return ""
		_:
			return ""
