extends Node3D

# 右上角小地图（GTA 雷达式）：SubViewport + 正交俯视相机实时渲染一片城区，
# 贴到 CanvasLayer 的 TextureRect 上。成熟做法（Godot 官方 SubViewport 示例、
# 大量第三人称教程同款），比手绘 2D 示意图省一套数据源，且联机队友/车辆自动在图上。

@export var map_size: int = 224
@export var view_span: float = 64.0
## 抬到 300：城外接了山岭（丘陵 ~50m、环山 ~150m），120 会被近处坡顶挡出一块黑
@export var cam_height: float = 300.0

var _vp: SubViewport = null
var _cam: Camera3D = null
var _game: Node3D = null
var _player: Node3D = null
var _rect: TextureRect = null
var _arrow: Polygon2D = null
var _arrow_edge: Polygon2D = null

## 箭头尖画在局部 -Y（= 屏幕正上），_process 里再按朝向转
const ARROW_POINTS: PackedVector2Array = [
	Vector2(0.0, -10.0), Vector2(7.0, 8.0), Vector2(0.0, 4.0), Vector2(-7.0, 8.0)]
const ARROW_COLOR := Color(1.0, 0.84, 0.25, 0.95)
const ARROW_EDGE_COLOR := Color(0.05, 0.06, 0.08, 0.85)


func _ready() -> void:
	_game = get_parent() as Node3D
	_player = _game.get_node("Player") as Node3D

	_vp = SubViewport.new()
	_vp.name = "MinimapViewport"
	_vp.size = Vector2i(map_size, map_size)
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)

	_cam = Camera3D.new()
	_cam.name = "MinimapCam"
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = view_span
	_cam.far = cam_height + 60.0
	_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_vp.add_child(_cam)

	var layer := CanvasLayer.new()
	layer.name = "MinimapLayer"
	layer.layer = 3
	add_child(layer)

	var frame := ColorRect.new()
	frame.color = Color(0.06, 0.08, 0.11, 0.85)
	frame.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	frame.offset_left = -float(map_size) - 16.0
	frame.offset_top = 8.0
	frame.offset_right = -8.0
	frame.offset_bottom = float(map_size) + 16.0
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(frame)

	var rect := TextureRect.new()
	rect.name = "Minimap"
	rect.texture = _vp.get_texture()
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	rect.offset_left = -float(map_size) - 12.0
	rect.offset_top = 12.0
	rect.offset_right = -12.0
	rect.offset_bottom = float(map_size) + 12.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	_rect = rect

	# 人物箭头：黑描边在下、黄箭头在上，两个 Polygon2D 同位置同旋转。
	# 画在 rect 之后 → CanvasLayer 按树序绘制，天然压在地图之上。
	_arrow_edge = _make_arrow(layer, ARROW_POINTS, ARROW_EDGE_COLOR, Vector2(1.3, 1.3))
	_arrow = _make_arrow(layer, ARROW_POINTS, ARROW_COLOR, Vector2.ONE)


func _make_arrow(parent: CanvasLayer, pts: PackedVector2Array, col: Color, scl: Vector2) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = pts
	p.color = col
	p.scale = scl
	parent.add_child(p)
	return p


## 小地图是「世界 +X → 屏幕右、世界 -Z → 屏幕上」的正交俯视（相机只绕 X 转 -90°，
## 没有偏航），所以世界水平朝向 f 落到屏幕就是 (f.x, f.z)（y 轴向下）。
## 箭头默认尖朝 -Y，绕屏幕顺时针转 r 后尖指向 (sin r, -cos r) ⇒ r = atan2(f.x, -f.z)。
func _heading() -> Vector3:
	var f: Vector3 = Vector3.ZERO
	var driving: Node3D = _game.get("_driving") as Node3D
	if driving != null:
		# 车头 = 车辆模型的局部 +Z（vehicle_arcade._forward_from_yaw 就是 basis.z）
		var vm: Node3D = driving.get("vehicle_model") as Node3D
		if vm != null:
			f = vm.global_basis.z
		else:
			f = driving.global_basis.z
	elif _player != null and is_instance_valid(_player):
		# 人物站向 = ModelPivot 的局部 +Z（player.gd 里 target_yaw = atan2(dir.x, dir.z)）
		var mp: Node3D = _player.get_node_or_null("ModelPivot") as Node3D
		if mp != null:
			f = mp.global_basis.z
	f.y = 0.0
	if f.length_squared() < 0.0004:
		return Vector3.ZERO
	return f.normalized()


func _process(_delta: float) -> void:
	var driving: Node3D = _game.get("_driving") as Node3D
	var t: Node3D = driving if driving != null else _player
	if t == null or not is_instance_valid(t):
		return
	# 【别再拿车辆根节点当位置】根节点是出生锚点，车开走了它不动（#19 的老坑，
	# 当时下车落点/交互距离/网络广播三处都栽过）——驾驶中必须读车辆模型的世界坐标。
	var p: Vector3 = t.global_position
	if driving != null and driving.has_method("get_vehicle_position"):
		p = driving.get_vehicle_position()
	_cam.global_position = Vector3(p.x, cam_height, p.z)

	var vs: Vector2 = get_viewport().get_visible_rect().size
	var center := Vector2(vs.x - 12.0 - float(map_size) * 0.5, 12.0 + float(map_size) * 0.5)
	_arrow.position = center
	_arrow_edge.position = center
	var f: Vector3 = _heading()
	if f != Vector3.ZERO:
		var r: float = atan2(f.x, -f.z)
		_arrow.rotation = r
		_arrow_edge.rotation = r
