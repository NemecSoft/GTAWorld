class_name PlayerCharacter extends CharacterBody3D

# 步行人物控制器（Phase 1：都市里的人物）。
# 操作：WASD 走、Shift 跑、空格跳、鼠标转视角、E 上下车（E 由 urban_game.gd 统一处理）。
# 模型：Kenney《Animated Characters Protagonists》——characterMedium.fbx 通用骨骼，
# idle/run/jump 是**独立的动画 FBX**（导入后不带 AnimationPlayer），_ready 里运行时合并；
# 皮肤用 skins/*.png 覆盖 albedo。

const GRAVITY: float = 19.6
const TARGET_HEIGHT: float = 1.6
const ANIM_DIR: String = "res://assets/animated-characters/"

@export_group("tunable")
@export var walk_speed: float = 4.0
@export var run_speed: float = 7.5
@export var jump_speed: float = 6.0
@export var mouse_sensitivity: float = 0.0028
@export_range(0.0, 360.0, 15.0) var model_yaw_offset: float = 0.0
@export var turn_speed: float = 12.0
@export_file("*.png") var skin_path: String = ANIM_DIR + "skins/criminalMaleA.png"
@export_group("")

@onready var yaw_pivot: Node3D = $YawPivot
@onready var pitch_pivot: Node3D = $YawPivot/PitchPivot
@onready var camera: Camera3D = $YawPivot/PitchPivot/Camera
@onready var model_pivot: Node3D = $ModelPivot

var anim: AnimationPlayer = null
var active: bool = false
## v1.5 战斗姿态：持枪待机用墓园包烘焙的 holding-right，开枪播一次性 shoot 片段
var combat_mode: bool = false
var _shoot_lock: float = 0.0
const CLIP_GUN_IDLE: String = "holding-right"
const CLIP_SHOOT: String = "holding-right-shoot"

var _yaw: float = 0.0
var _pitch: float = -0.12
var _model_yaw: float = 0.0
var _clip_idle: String = "idle"
var _clip_walk: String = "walk"
var _clip_jump: String = "jump"


func _ready() -> void:
	_merge_anim_library()
	_apply_skin()
	anim = _find_anim(self)
	if anim != null:
		var list: Array = anim.get_animation_list()
		_clip_idle = _guess(list, ["idle", "stand"])
		_clip_walk = _guess(list, ["walk", "run", "move"])
		_clip_jump = _guess(list, ["jump"])
		if _clip_idle != "":
			anim.play(_clip_idle)
	_fit_character()
	_apply_look()


## 动画 FBX 各带一个临时 AnimationPlayer；把 Root|Idle/Run/Jump 三份剪辑
## 复制进模型自己的 AnimationPlayer（骨骼路径同为 Root/Skeleton3D:*，直接可用）。
## 模型是 FBX 导入、不带 AnimationPlayer，这里现场建一个挂在实例根上。
func _merge_anim_library() -> void:
	if model_pivot.get_child_count() == 0:
		return
	var root: Node = model_pivot.get_child(0) as Node
	var host: AnimationPlayer = _find_anim(root)
	if host == null:
		host = AnimationPlayer.new()
		host.name = "Anim"
		host.root_node = NodePath("..")
		root.add_child(host)
		# 4.7 的 AnimationPlayer 没有 add_animation，剪辑必须挂在 AnimationLibrary 上
		var lib := AnimationLibrary.new()
		host.add_animation_library("", lib)
	var wanted: Array = ["idle", "run", "jump"]
	for clip_name in wanted:
		if host.has_animation(String(clip_name)):
			continue
		var ps: PackedScene = load(ANIM_DIR + String(clip_name) + ".fbx")
		if ps == null:
			push_warning("[player] 读不到动画 %s.fbx" % clip_name)
			continue
		var tmp: Node = ps.instantiate()
		var tap: AnimationPlayer = _find_anim(tmp)
		var found: Animation = null
		if tap != null:
			for an in tap.get_animation_list():
				if String(an).to_lower().contains(String(clip_name)):
					found = tap.get_animation(String(an))
					break
		if found != null:
			var lib2: AnimationLibrary = host.get_animation_library("")
			lib2.add_animation(String(clip_name), found)
			var liba: Animation = host.get_animation(String(clip_name))
			if String(clip_name) != "jump":
				liba.loop_mode = Animation.LOOP_LINEAR
		tmp.free()
	# 墓园包 holding/shoot 片段（Temp/bake_shoot.gd 一次性重定向烘焙的产物）
	var glib: AnimationLibrary = load(ANIM_DIR + "player_gun.tres") as AnimationLibrary
	if glib != null:
		for a in glib.get_animation_list():
			if not host.has_animation(String(a)):
				host.get_animation_library("").add_animation(String(a),
					glib.get_animation(String(a)))


func _apply_skin() -> void:
	if skin_path == "" or model_pivot.get_child_count() == 0:
		return
	var tex: Texture2D = load(skin_path) as Texture2D
	if tex == null:
		push_warning("[player] 皮肤贴图读不到：%s" % skin_path)
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	var list: Array = []
	_collect_meshes(model_pivot.get_child(0), list)
	for mi in list:
		(mi as MeshInstance3D).material_override = mat


func _collect_meshes(n: Node, list: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		list.append(n)
	for c in n.get_children():
		_collect_meshes(c, list)


## 量一次**引擎全局**包围盒，把身高归一化到 TARGET_HEIGHT，脚底对齐人物原点。
## 【坑】带蒙皮的 FBX 只能用 global_transform*mesh.aabb 实测（本地 transform 累乘会算错），
## 且 _ready 时子树已在树里，正好满足前提。
func _fit_character() -> void:
	if model_pivot.get_child_count() == 0:
		return
	var m: Node = model_pivot.get_child(0) as Node
	var box: AABB = _world_box(m)
	if box.size.y <= 0.001:
		push_warning("[player] character 量不出高度，跳过归一化")
		return
	var s: float = TARGET_HEIGHT / box.size.y
	m.scale *= Vector3.ONE * s
	var box2: AABB = _world_box(m)
	m.position.y += model_pivot.global_position.y - box2.position.y


func _world_box(n: Node) -> AABB:
	var boxes: Array = []
	_collect_world(n, boxes)
	if boxes.size() == 0:
		return AABB()
	var box: AABB = boxes[0]
	for i in range(1, boxes.size()):
		box = box.merge(boxes[i])
	return box


func _collect_world(n: Node, list: Array) -> void:
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n as MeshInstance3D
		if mi.mesh != null:
			var ab: AABB = mi.global_transform * mi.mesh.get_aabb()
			if ab.size.length() > 0.0001:
				list.append(ab)
	for c in n.get_children():
		_collect_world(c, list)


func _find_anim(n: Node) -> AnimationPlayer:
	for c in n.get_children():
		if c is AnimationPlayer:
			return c as AnimationPlayer
		var sub: AnimationPlayer = _find_anim(c)
		if sub != null:
			return sub
	return null


func _guess(list: Array, keys: Array) -> String:
	for k in keys:
		for a in list:
			if String(a).to_lower().contains(k):
				return String(a)
	return ""


func set_active(v: bool) -> void:
	active = v
	visible = v
	set_physics_process(v)
	if v:
		camera.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		if camera.current:
			camera.current = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		_yaw -= mm.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - mm.relative.y * mouse_sensitivity, -1.2, 0.6)
		_apply_look()


func _apply_look() -> void:
	yaw_pivot.rotation.y = _yaw
	pitch_pivot.rotation.x = _pitch


func _physics_process(delta: float) -> void:
	if not active:
		return

	var input_dir: Vector2 = Input.get_vector("left", "right", "back", "forward")
	var local: Vector3 = Vector3(input_dir.x, 0.0, -input_dir.y)

	var want_speed: float = walk_speed
	if Input.is_key_pressed(KEY_SHIFT):
		want_speed = run_speed

	var move_dir: Vector3 = local
	if move_dir.length_squared() > 0.0001:
		move_dir = (yaw_pivot.global_basis * move_dir).normalized()
		move_dir.y = 0.0

	velocity.x = move_dir.x * want_speed
	velocity.z = move_dir.z * want_speed

	if is_on_floor():
		if velocity.y < 0.0:
			velocity.y = 0.0
		if Input.is_action_just_pressed("bounce"):
			velocity.y = jump_speed
	else:
		velocity.y -= GRAVITY * delta

	move_and_slide()

	# 模型转向：朝移动方向缓插（无移动输入时保持最后朝向）
	if move_dir.length_squared() > 0.0001:
		var target_yaw: float = atan2(move_dir.x, move_dir.z) + deg_to_rad(model_yaw_offset)
		_model_yaw = lerp_angle(_model_yaw, target_yaw, 1.0 - exp(-turn_speed * delta))
	model_pivot.rotation.y = _model_yaw

	_play_anim(want_speed, delta)


## 战斗姿态开关（守夜讨伐进/出战斗时由 defense_mission 调）
func set_combat_mode(v: bool) -> void:
	combat_mode = v


## 开枪一次性动画（烘焙自墓园包 holding-right-shoot）
func play_shoot() -> void:
	if anim != null and anim.has_animation(CLIP_SHOOT):
		anim.play(CLIP_SHOOT)
		_shoot_lock = 0.25


func _play_anim(want_speed: float, delta: float) -> void:
	if anim == null:
		return
	if _shoot_lock > 0.0:
		_shoot_lock -= delta
		return
	var clip: String = _clip_idle
	if not is_on_floor():
		clip = _clip_jump
	elif Vector2(velocity.x, velocity.z).length() > 0.3:
		clip = _clip_walk
	elif combat_mode and anim.has_animation(CLIP_GUN_IDLE):
		clip = CLIP_GUN_IDLE
	if clip == "" or anim.current_animation == clip:
		return
	anim.play(clip, 0.1)
	if clip == _clip_walk:
		anim.speed_scale = clampf(Vector2(velocity.x, velocity.z).length() / maxf(walk_speed, 0.001), 0.5, 2.2)
	else:
		anim.speed_scale = 1.0
