extends SceneTree

# 开车探针：按住「前进」跑若干秒，打印真实车速、相机到车距离、FOV、车的位置。
#
# 什么情况下用：
#   - 改了 scripts/vehicle.gd 的动力参数（max_speed / engine_power / brake_power）
#   - 改了 scripts/view.gd 的机位参数（distance / height / fov_*）
# 这两个文件里全是「手感常数」，光看代码判断不了实际跑起来是多少，
# 跑一趟这个脚本就能拿到真实数字，不用一遍遍进编辑器手动踩油门。
#
# 用法：
#   godot --headless --path . --script res://tools/drive_probe.gd
#   godot --headless --path . --script res://tools/drive_probe.gd -- --scene=res://scenes/main.tscn
#   godot --headless --path . --script res://tools/drive_probe.gd -- --frames=180
#
# 已知坑：
#   1. SceneTree 的 _physics_process 签名必须是 `_physics_process(delta) -> bool`，
#      写成 `-> void` 会 Parse Error（父类是 SceneTree 不是 Node）。
#   2. 打印车速要用 get_vehicle_position()（车模位置），不要取 Vehicle 节点自己，
#      Vehicle 节点始终停在 tscn 里写的出生点不动，车动的是它的子节点 Container/Model。

var _root: Node
var _veh: Node = null
var _view: Node = null
var _ticks: int = 0
var _frames: int = 240
var _scene_path: String = "res://scenes/main.tscn"


func _initialize() -> void:

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scene="):
			_scene_path = a.substr(8)
		elif a.begins_with("--frames="):
			_frames = int(a.substr(9))

	var scene: PackedScene = load(_scene_path)
	if scene == null:
		print("探针：加载不了场景 %s" % _scene_path)
		quit()
		return

	_root = scene.instantiate()
	root.add_child(_root)
	_veh = _root.find_child("Vehicle", true, false)
	_view = _root.find_child("View", true, false)
	Input.action_press("forward")
	print("===== DRIVE PROBE (%s) =====" % _scene_path)
	print("[setup] Vehicle=%s  View=%s" % [str(_veh != null), str(_view != null)])


func _physics_process(delta: float) -> bool:

	_ticks += 1
	if _ticks % 30 == 0:
		_dump()

	if _ticks >= _frames:
		Input.action_release("forward")
		_dump()
		print("===== END =====")
		quit()
		return true
	return false


func _dump() -> void:

	if _veh == null:
		print("[t=%d] 没有 Vehicle 节点" % _ticks)
		return

	var ls: float = 0.0
	if "linear_speed" in _veh:
		ls = _veh.get("linear_speed")

	var mps: float = 0.0
	if "get_speed_mps" in _veh:
		mps = _veh.get_speed_mps()

	var line: String = "[t=%d] ls=%.3f  %.1f m/s (%.0f km/h)" % [_ticks, ls, mps, mps * 3.6]

	var carp: Vector3 = _veh.global_position
	if "get_vehicle_position" in _veh:
		carp = _veh.get_vehicle_position()
	line += "  car=(%.1f,%.1f,%.1f)" % [carp.x, carp.y, carp.z]

	if _view != null:
		# 子节点名叫 Camera（不是 Camera3D），find_child 是按名字找的
		var cam: Node = _view.find_child("Camera", true, false)
		if cam != null:
			var cp: Vector3 = cam.global_position
			line += "  camY=%.2f 距车=%.2fm fov=%.1f" % [cp.y, (carp - cp).length(), cam.get("fov")]

	print(line)
