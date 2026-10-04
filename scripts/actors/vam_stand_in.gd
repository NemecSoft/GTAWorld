class_name VamStandIn extends Node3D

# #27 替身 NPC：把 Blender 绑好骨的写实素体（assets/vam/body_rigged.glb）放进游戏，
# 跑 Kenney 的 idle/run/持枪剪辑。骨骼同名，所以只需要三件事：
#   1) 补 Z-up→Y-up 的 −90°X（Kenney 的 FBX 导入后 Root 节点上挂的也是这一下）
#   2) 把动画轨道的节点路径改写到我们这份 Skeleton3D 上
#   3) 位置轨道存的是源骨架的绝对局部位置，平移成「我们的 rest + 它的相对起伏」
# 只做展示替身，不参与交互与战斗（那是 Kenney 主角的活）。

const GLB: String = "res://assets/vam/body_rigged.glb"
const ANIM_DIR: String = "res://assets/animated-characters/"
const TARGET_HEIGHT: float = 1.6
const CLIP_FBX: Array = ["idle", "run"]
const GUN_LIB: String = "player_gun.tres"
const TOON_SHADER: String = "res://materials/toon_body.gdshader"
const OUTLINE_SHADER: String = "res://materials/toon_outline.gdshader"
const OUTLINE_NAME: String = "ToonOutline"

@export_group("tunable")
@export var clip: String = "idle"
@export var facing_deg: float = 0.0
@export_group("toon")
@export var toon_enabled: bool = true
@export var skin_color: Color = Color(0.82, 0.62, 0.52)
@export_range(1, 8, 1) var toon_steps: int = 3
@export var outline_enabled: bool = true
## 描边宽度按世界毫米给，_apply_toon() 里再除以模型总缩放换成局部单位。
## 4.5mm 是实测挑的：6mm 在小臂/手指上会糊成两条，10mm 直接盖住肢体
@export_range(0.0, 0.05, 0.001) var outline_mm: float = 4.5
## 掠射裁剪，1.0 = 不裁（会看到整片背面糊在肩窝胯缝）
@export_range(0.1, 1.0, 0.01) var outline_grazing: float = 0.75
@export var outline_color: Color = Color(0.06, 0.04, 0.07)
@export_group("")

var _model: Node3D = null
var _sk: Skeleton3D = null
var _ap: AnimationPlayer = null
var _src_rest: Dictionary = {}


func _ready() -> void:
	rotation.y = deg_to_rad(facing_deg)
	var ps: PackedScene = load(GLB) as PackedScene
	if ps == null:
		push_warning("[vam] 读不到 %s" % GLB)
		return
	_model = ps.instantiate() as Node3D
	add_child(_model)
	_sk = _find_skel(_model)
	if _sk == null:
		push_warning("[vam] GLB 里没有 Skeleton3D（导出时 skin 丢了？）")
		return
	_stand_up()
	_fit()
	_build_anims()
	_apply_toon()
	if _ap != null and _ap.has_animation(clip):
		_ap.play(clip)
	else:
		push_warning("[vam] 没有剪辑 %s" % clip)


## GLB 按 Z-up 导出（与 Kenney 的 FBX 骨空间同轴），Godot 里要补一次 X 轴修正。
## 到底 −90 还是 +90 不靠推：拿头骨与脚骨的高度差当分数，谁正谁对。
func _stand_up() -> void:
	var box: AABB = _bind_box()
	if box.size.z <= box.size.y:
		return
	var best: float = -90.0
	var best_score: float = _up_score(-90.0)
	for deg in [90.0, 0.0, 180.0]:
		var s: float = _up_score(deg)
		if s > best_score:
			best_score = s
			best = deg
	_model.rotation_degrees = Vector3(best, 0.0, 0.0)
	if best_score <= 0.0:
		push_warning("[vam] 没有让头高于脚的根旋转，素体可能绑反了")


func _up_score(deg: float) -> float:
	var b: Basis = Basis.from_euler(Vector3(deg_to_rad(deg), 0.0, 0.0))
	return (b * _bone_pos("Head")).y - (b * _bone_pos("LeftFoot")).y


func _fit() -> void:
	var box: AABB = _rot_box(Basis.from_euler(_model.rotation), _bind_box())
	if box.size.y < 0.001:
		return
	var s: float = TARGET_HEIGHT / box.size.y
	box = AABB(box.position * s, box.size * s)
	_model.scale *= Vector3.ONE * s
	_model.position.y = -box.position.y


# ---------- 动画搬运 ----------
func _build_anims() -> void:
	_ap = AnimationPlayer.new()
	_ap.name = "Anim"
	_ap.root_node = NodePath("..")
	_model.add_child(_ap)
	var lib := AnimationLibrary.new()
	_ap.add_animation_library("", lib)
	var skel_path: String = String(_model.get_path_to(_sk))
	for clip_name in CLIP_FBX:
		var ps: PackedScene = load(ANIM_DIR + String(clip_name) + ".fbx") as PackedScene
		if ps == null:
			push_warning("[vam] 读不到动画 %s.fbx" % clip_name)
			continue
		var tmp: Node = ps.instantiate()
		var tap: AnimationPlayer = _find_player(tmp)
		_src_rest_map(_find_skel(tmp))
		var found: Animation = _pick_clip(tap, String(clip_name))
		var dup: Animation = null if found == null else found.duplicate() as Animation
		tmp.free()
		if dup == null:
			continue
		_retarget(dup, skel_path)
		dup.loop_mode = Animation.LOOP_LINEAR
		lib.add_animation(String(clip_name), dup)
	var glib: AnimationLibrary = load(ANIM_DIR + GUN_LIB) as AnimationLibrary
	if glib != null:
		for a in glib.get_animation_list():
			var d2: Animation = glib.get_animation(String(a)).duplicate() as Animation
			_retarget(d2, skel_path)
			lib.add_animation(String(a), d2)


func _pick_clip(tap: AnimationPlayer, want: String) -> Animation:
	if tap == null:
		return null
	for an in tap.get_animation_list():
		var l: String = String(an).to_lower()
		if l.contains(want) and not l.contains("targeting"):
			return tap.get_animation(String(an))
	return null


func _retarget(a: Animation, skel_path: String) -> void:
	for i in range(a.get_track_count()):
		var p: NodePath = a.track_get_path(i)
		if p.get_subname_count() == 0:
			continue
		var sub: String = ""
		for s in range(p.get_subname_count()):
			sub += ":" + String(p.get_subname(s))
		a.track_set_path(i, NodePath(skel_path + sub))
		if a.track_get_type(i) != Animation.TYPE_POSITION_3D:
			continue
		var bn: String = String(p.get_subname(0))
		var mine: int = _sk.find_bone(bn)
		if mine < 0 or not _src_rest.has(bn):
			continue
		var delta: Vector3 = _sk.get_bone_rest(mine).origin - (_src_rest[bn] as Vector3)
		for kk in range(a.track_get_key_count(i)):
			var v: Vector3 = a.track_get_key_value(i, kk)
			a.track_set_key_value(i, kk, v + delta)


func _src_rest_map(skel: Skeleton3D) -> void:
	if skel == null:
		return
	for i in range(skel.get_bone_count()):
		_src_rest[skel.get_bone_name(i)] = skel.get_bone_rest(i).origin


# ---------- 卡通化（#28） ----------
## 给每块蒙皮网格换材质：本体换成硬色阶着色器，另加一份「反壳」副本只画背面当描边。
## 反壳必须是独立节点：Godot 一个几何体只能有一套材质，描边要靠第二层网格。
## 可重复调用（先清掉上一次的 ToonOutline，再重建）。
func _apply_toon() -> void:
	var toon_mat: ShaderMaterial = _make_mat(TOON_SHADER)
	if toon_enabled and toon_mat != null:
		toon_mat.set_shader_parameter("skin_color", skin_color)
		toon_mat.set_shader_parameter("steps", float(toon_steps))
	var meshes: Array = _mesh_list(_model)
	for mi in meshes:
		var m: MeshInstance3D = mi as MeshInstance3D
		for old in m.get_children():
			if String(old.name) == OUTLINE_NAME:
				m.remove_child(old)
				old.free()
		if toon_enabled:
			m.material_override = toon_mat
		if outline_enabled:
			_make_outline_twin(m)


func _make_outline_twin(src: MeshInstance3D) -> void:
	var mat: ShaderMaterial = _make_mat(OUTLINE_SHADER)
	if mat == null:
		return
	# thickness 是局部单位：反壳的顶点位移跟着骨骼一起被外层缩放放大，
	# 所以「世界几毫米」要除以这条链上的总缩放（实测约 42 倍）。
	var s: float = _chain_scale(src)
	if s <= 0.000001:
		return
	mat.set_shader_parameter("thickness", outline_mm * 0.001 / s)
	mat.set_shader_parameter("outline_color", outline_color)
	mat.set_shader_parameter("grazing_cut", outline_grazing)
	var twin := MeshInstance3D.new()
	twin.name = OUTLINE_NAME
	twin.mesh = src.mesh
	twin.skin = src.skin
	# 挂在原网格【下面】，不能 add_sibling：Skeleton3D 的直接子节点是按顺序当骨头用的，
	# 多塞一个进去，这层壳就会被丢到某根骨头的变换上，描边就飘在肩膀外面。
	twin.skeleton = NodePath("../" + String(src.get_path_to(_sk)))
	twin.material_override = mat
	twin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	src.add_child(twin)


## 从网格节点往上到本节点，把各级缩放乘起来（不碰 global_transform，它在 _ready 当帧是旧的）
func _chain_scale(n: Node) -> float:
	var acc: float = 1.0
	var cur: Node = n
	while cur != null and cur != self:
		if cur is Node3D:
			acc *= (cur as Node3D).scale.length() / sqrt(3.0)
		cur = cur.get_parent()
	return acc


func _make_mat(path: String) -> ShaderMaterial:
	var sh: Shader = load(path) as Shader
	if sh == null:
		push_warning("[vam] 读不到着色器 %s" % path)
		return null
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


## 收集所有带蒙皮的网格；ToonOutline 自己不算，否则递归调用会套娃。
func _mesh_list(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null \
				and String(n.name) != OUTLINE_NAME:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


# ---------- 小工具 ----------
func _bone_pos(bn: String) -> Vector3:
	var i: int = _sk.find_bone(bn)
	return Vector3.ZERO if i < 0 else _sk.get_bone_global_pose(i).origin


## 绑定姿势下的网格外框，算在 _model 的局部空间里（不碰 global_transform，
## 因为 _ready 当帧它是旧的，会骗人）。
func _bind_box() -> AABB:
	var out := AABB()
	var first: bool = true
	var stack: Array = []
	for c in _model.get_children():
		stack.append([c, (c as Node3D).transform if c is Node3D else Transform3D.IDENTITY])
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: Node = e[0]
		var xform: Transform3D = e[1]
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var b: AABB = xform * (n as MeshInstance3D).get_aabb()
			out = b if first else out.merge(b)
			first = false
		for ch in n.get_children():
			var cx: Transform3D = ch.transform if ch is Node3D else Transform3D.IDENTITY
			stack.append([ch, xform * cx])
	return out


func _rot_box(b: Basis, a: AABB) -> AABB:
	var out := AABB(b * a.position, Vector3.ZERO)
	for i in range(8):
		var p := Vector3(
				a.position.x + (a.size.x if i & 1 else 0.0),
				a.position.y + (a.size.y if i & 2 else 0.0),
				a.position.z + (a.size.z if i & 4 else 0.0))
		out = out.expand(b * p)
	return out


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var r: Skeleton3D = _find_skel(c)
		if r != null:
			return r
	return null


func _find_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r: AnimationPlayer = _find_player(c)
		if r != null:
			return r
	return null
