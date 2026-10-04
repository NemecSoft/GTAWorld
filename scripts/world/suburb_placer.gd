extends Node3D

## #29 小区挂载器：把 scenes/suburb.tscn（Kenney City Kit Suburban 摆的院落）放到城外草地环带上。
##
## 为什么用【固定 seed 的随机】而不是 randf()：静态几何不走网络复制（urban_net 只同步位姿），
## 两端各自实例化，随机源不一致就会出现「_host 看到小区在西北，访客看到在东南」。
## 沿用项目既有约定（city_builder / urban_terrain 都用 seed_value=20261003 那套）。
##
## 落位区的算法依据（实测，见 Temp/gen_suburb_report.txt）：
##   院落局部占地 x -21.0..25.3（+X 是出入口和接入道）、z ±15.1
##   城内路网占 ±121，街树环在 124，城市草地板边缘 198，地形在 Chebyshev 205 才开始起坡
##   ⇒ 圆心距 r 取 [152, 168]：内侧边 152-25.3=126.7 不压路不压街树，外侧边 168+21=189 还在草地板上

## 院落场景路径
@export var suburb_scene: String = "res://scenes/suburb.tscn"
## 随机源；改这个数就换一版落位（联机两端必须一致）
@export var seed_value: int = 20261004
@export_range(125.0, 195.0, 1.0) var radius_min: float = 152.0
@export_range(125.0, 195.0, 1.0) var radius_max: float = 168.0
## 与任务点/商店的圆心最小距离，防止小区把装货区压没
@export_range(10.0, 80.0, 1.0) var clearance: float = 34.0
## 兜底位（正西，实测四周没有任务点）：候选全被拒时用
@export var fallback_angle_deg: float = 180.0
@export var fallback_radius: float = 160.0

## 已有的绝对坐标任务点：出租车停靠 / 装货 / 卸货 / 守夜公告板 / 车行
const RESERVED: Array = [
	Vector2(-26.4, 24.0),
	Vector2(46.0, 136.0),
	Vector2(-46.0, -136.0),
	Vector2(100.0, 122.0),
	Vector2(92.0, 128.0),
]


func _ready() -> void:
	var c: Vector2 = _pick_center()
	var angle: float = atan2(c.y, c.x)
	var sc: PackedScene = load(suburb_scene)
	if sc == null:
		push_warning("[suburb] 场景加载不到 " + suburb_scene)
		return
	var inst: Node3D = sc.instantiate() as Node3D
	# 出入口（局部 +X）转向城心：绕 Y 转 φ 后本地 +X 落在 (cosφ, -sinφ)，解得 φ = π - θ
	inst.rotation.y = PI - angle
	inst.position = Vector3(c.x, 0.0, c.y)
	add_child(inst)
	print("[suburb] 落位 (%.1f, %.1f) 朝向 %.0f° 半径 %.1f 角度 %.0f°" % [
		c.x, c.y, rad_to_deg(PI - angle), sqrt(c.x * c.x + c.y * c.y), rad_to_deg(angle)])


func _pick_center() -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var attempt: int = 0
	while attempt < 64:
		var r: float = rng.randf_range(radius_min, radius_max)
		var a: float = rng.randf_range(0.0, TAU)
		var c := Vector2(cos(a) * r, sin(a) * r)
		if _clear(c):
			return c
		attempt += 1
	push_warning("[suburb] 候选位都被任务点占了，用兜底位")
	var fa: float = deg_to_rad(fallback_angle_deg)
	return Vector2(cos(fa) * fallback_radius, sin(fa) * fallback_radius)


## 圆心到每个任务点的距离都要够；且院落的内/外边不能出环带
func _clear(c: Vector2) -> bool:
	var rr: float = sqrt(c.x * c.x + c.y * c.y)
	if rr - 25.5 < 124.0 or rr + 21.5 > 196.0:
		return false
	for p in RESERVED:
		if c.distance_to(p) < clearance:
			return false
	return true
