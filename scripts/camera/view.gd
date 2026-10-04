extends Node3D

@export_group("Properties")
@export var target: ArcadeVehicle
## 跟随目标的路径。target 这个导出是 node_paths —— 它在场景**实例化那一刻**就解析成
## 对象引用了，之后节点被换掉（比如选了蜜蜂/摩托时 scripts/world/vehicle_picker.gd
## 在同个节点上换脚本+换模型，节点对象本身不变，但万一以后有整棵重建的做法）
## target 就会指向一个已经释放掉的东西。留着这条路径做自愈通道。
@export var target_path: NodePath = NodePath("../Vehicle")

@onready var camera: Camera3D = $Camera

# ---------------------------------------------------------------------------
# 运行时可调项（组名必须是 "tunable" 才会在 GDTuner 面板里出现，原因见 vehicle.gd）
# ---------------------------------------------------------------------------

@export_group("tunable")
## 相机停在车后方多远（米）—— 滚轮还没动过时的初始距离。
## 这个机位是照着参考截图（第三人称贴身赛车视角）定的：相机压在车尾后方 2.9 米、
## 离地 1.15 米，车占画面下半部中间一大块，灭点推到画面上三分之一，
## 前方的路一路收窄到远处 —— 也就是"贴着车屁股看"的那种。
## 拉到 6 米以上车就变小、变成看卫星图，那种视角不适合赛车。
@export_range(0.5, 12.0, 0.1) var distance: float = 2.9
## 相机比车身高多少（米）。压低 = 更贴地、速度感更冲。
## 取 1.15 ≈ 车顶高度，相机基本架在车屁股后面一层，车就能占住画面下半部中间一大块。
@export_range(0.3, 4.0, 0.05) var height: float = 1.15
## 视线落点：车身上方多少米（决定车在画面里的上下位置。调小 = 车往画面下方沉）
@export_range(0.0, 2.0, 0.05) var look_at_height: float = 0.55
## 视线往车头前方推多远（负值是往车尾看）。调大 = 视线更平、灭点更高。
@export_range(2.0, 30.0, 0.5) var look_ahead: float = 14.0
## 满速时相机额外往后退多少（速度感）。
## 【2026-10-03 按用户要求改为 0】「不论什么速度，相机都和启动时一样，不要拉远」
## —— 以前这里给 0.9，满油门时相机被推到车后 3.8 米，跟静止时的 2.9 米完全不是一个机位。
## 改成 0 后机位恒定在 distance，静止/中速/满速完全是同一个取景。
## 想恢复"速度拉远"的手感，把这里拖回 0.5~1.0 即可（F12 滑条直接调，不用改代码）。
@export_range(0.0, 3.0, 0.1) var distance_speed: float = 0.0
## 刹车时相机额外往前贴近多少。加速拉远、刹车拉近，是「重量感」最省成本的一招。
## 同为「相机随速度变」，本轮一并归 0 —— 刹车贴脸同样会打破「和启动时一样」。
@export_range(0.0, 3.0, 0.1) var distance_brake: float = 0.0
## 视野角度。近距离机位配大 FOV；但别超过 80，不然就是鱼眼、车反而被拉小了。
## 静止 = 满速恒定 70，全程不再变宽，取景框始终是同一块。
@export_range(55.0, 90.0, 1.0) var fov_base: float = 70.0
## 满速时额外的 FOV（速度感）。同为 0 —— 视野不随速度张开，
## 这样"速度感"只由车自身的移动提供，画面构图全程稳定。
@export_range(0.0, 20.0, 0.5) var fov_speed: float = 0.0
@export_group("")

@export_group("Follow camera")
## 跟随平滑度（越大跟得越紧）
@export var position_smoothing: float = 7.0
@export var rotation_smoothing: float = 5.0
## 跟车距离本身的平滑度（滚轮调距离时过渡用，越大变越快）
@export var distance_smoothing: float = 9.0
## 速度前馈补偿（0~1.5）。一阶跟随时相机会在匀速段稳态落后 v/smoothing 米 ——
## 本项目满速 10.4 m/s、smoothing=7，就是约 1.5 米，表现出来正是「车一快相机就被甩远」。
## 这里按当前速度把这段滞后提前补回 desired，机位就锁死在 distance 米不动。
## 1.0 = 完全补偿（推荐）；0 = 关掉，恢复旧的「越快越远」。
@export_range(0.0, 1.5, 0.05) var speed_lead: float = 1.0
## 甩尾时相机横向让开多少米/弧度：车头转过去、相机还留在老路上，
## 于是画面里车是「横着冲」的 —— 这就是提示词要的「滞后于转向的镜头偏移感」。
@export var drift_offset: float = 2.2
@export var drift_smoothing: float = 4.0
## 甩尾让位的上限（弧度），超过这个角度就不继续让了，免得镜头飞出去
@export var drift_clamp: float = 0.85

@export_group("Mouse wheel zoom")
## 是否允许滚轮调距离
@export var wheel_zoom_enabled: bool = true
## 每滚一格改变多少米
@export var wheel_zoom_step: float = 0.4
## 距离下限（米）：贴到车尾最近能到多少
@export var zoom_min: float = 0.9
## 距离上限（米）：最多能拉多远
@export var zoom_max: float = 20.0
## 滚轮的目标距离；保持 -1 表示「先用 distance，滚轮一动就自己接管」
@export var zoom: float = -1.0

@export_group("Mouse orbit")
## 驾驶时按住鼠标转视角的灵敏度（和人物状态一致：鼠标动 = 机位绕车转）。
## 俯仰范围刻意偏「俯视友好」：向上转有限（机位最低也贴地 0.4 米），向下可抬到俯视。
@export var orbit_sensitivity: float = 0.0035
@export_group("")

var _initialized: bool = false
var _distance_now: float = 0.0
var _drift_now: float = 0.0      # 平滑后的甩尾角，喂给横向让位
var _speed_prev: float = 0.0      # 上一帧速度，用来判断「正在刹车」
var _orbit_yaw: float = 0.0       # 鼠标环绕偏航（相对车头），不自动回正（GTA 式）
var _orbit_pitch: float = 0.0     # 鼠标环绕俯仰：正=机位升高俯视

## Functions

## 造一个「站在 eye、朝 look 看」的变换（Godot 4.7 的 Transform3D.looking_at
## 已经不是静态构造函数了，这里手搓基向量：三轴满足 X = Y × Z，相机看向 -Z）

func make_look_transform(eye: Vector3, look: Vector3) -> Transform3D:

	var z_axis: Vector3 = -(look - eye).normalized()
	var y_axis: Vector3 = Vector3.UP
	var x_axis: Vector3 = y_axis.cross(z_axis).normalized()
	y_axis = z_axis.cross(x_axis).normalized()

	return Transform3D(Basis(x_axis, y_axis, z_axis), eye)

func _ready() -> void:

	camera.fov = fov_base
	_distance_now = distance

## 滚轮调跟车距离：往前滚（MOUSE_WHEEL_UP）= 拉近，往后滚 = 拉远

func _unhandled_input(event: InputEvent) -> void:

	if target == null:
		return

	# 鼠标环绕：只在驾驶（本节点在算物理）且鼠标被捕获时生效，
	# 与人物状态的自由转视角手感一致。
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		_orbit_yaw -= mm.relative.x * orbit_sensitivity
		_orbit_pitch = clampf(_orbit_pitch + mm.relative.y * orbit_sensitivity, -0.18, 0.6)
		return

	if not wheel_zoom_enabled:
		return

	if not (event is InputEventMouseButton):
		return

	var mb: InputEventMouseButton = event as InputEventMouseButton

	if mb.button_index != MOUSE_BUTTON_WHEEL_UP and mb.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return

	if not mb.pressed:
		return

	# 第一次滚滚轮时从当前实际距离接管，避免突然跳一下

	if zoom < 0.0:
		zoom = _distance_now

	var step: float = -wheel_zoom_step if mb.button_index == MOUSE_BUTTON_WHEEL_UP else wheel_zoom_step
	zoom = clampf(zoom + step, zoom_min, zoom_max)

	get_viewport().set_input_as_handled()

func _physics_process(delta: float) -> void:

	if target == null or not is_instance_valid(target):
		# 自愈：按路径重找。换车 / 换场景 / 节点被回收都能自己爬起来，
		# 不用为了它专门去通知谁
		target = get_node_or_null(target_path) as ArcadeVehicle
		if target == null:
			return

	var car_pos: Vector3 = target.get_vehicle_position()

	# 车头方向：只取水平分量，这样车翻坑或者上坡时相机不会跟着一起翻

	var forward: Vector3 = target.vehicle_model.global_transform.basis.z
	forward.y = 0.0

	if forward.length_squared() < 0.0001:
		forward = Vector3(0, 0, 1)
	else:
		forward = forward.normalized()

	var speed: float = abs(target.linear_speed)
	var speed_factor: float = clampf(speed, 0.0, 1.0)

	# 甩尾角：从车上读，过一道平滑（相机不能跟着方向盘抖）
	if "drift_angle" in target:
		_drift_now = lerpf(_drift_now, clampf(target.drift_angle, -drift_clamp, drift_clamp), 1.0 - exp(-drift_smoothing * delta))

	# 正在减速 = 刹车：对比前后两帧速度就知道，不用去翻车的内部状态。
	# 注意这里必须用**真实米/秒**而不是归一化的 linear_speed：
	# 归一化值每帧只掉 1/60，乘个常数永远到不了 1，相机根本不会贴进来。
	# 换成 (Δv/Δt) 得到真减速度（m/s²），再除以一个满刹车量级（60 m/s²）归一化。
	var speed_mps: float = target.get_speed_mps()
	var decel: float = (maxf(_speed_prev, speed_mps) - speed_mps) / maxf(delta, 1e-5)
	var brake_factor: float = clampf(decel / 60.0, 0.0, 1.0)
	_speed_prev = speed_mps

	# 滚轮设的目标距离（没滚过就用 distance），再叠加满速拉远、刹车拉近，
	# 最后统一做一次平滑，这样滚轮一格一格改不会猛冲

	# 速度前馈：匀速时一阶跟随的稳态滞后是 v / position_smoothing，
	# 直接从目标距离里减掉它，稳态机位就与速度无关（见 speed_lead 注释）。

	var lead: float = speed_mps / maxf(position_smoothing, 0.001) * speed_lead

	var zoom_target: float = distance if zoom < 0.0 else zoom
	var distance_target: float = zoom_target + distance_speed * speed_factor - distance_brake * brake_factor - lead
	_distance_now = lerpf(_distance_now, distance_target, 1.0 - exp(-distance_smoothing * delta))

	# 车的右手方向（forward × up）。甩尾时让相机顺着这个方向挪开一点，
	# 画面里车头就「甩到画面外」了，甩尾姿态一眼看得出来。
	# 环绕：先把车头方向按鼠标偏航旋转，再按俯仰抬高/压低机位（贴地下限 0.4 米）。
	var yaw_b := Basis(Vector3.UP, _orbit_yaw)
	var h: Vector3 = yaw_b * forward
	var d_horiz: float = _distance_now * cos(_orbit_pitch)
	var eye_y: float = maxf(0.4, height + _distance_now * sin(_orbit_pitch))
	var right: Vector3 = h.cross(Vector3.UP).normalized()
	var lateral: Vector3 = right * (_drift_now * drift_offset)

	var eye: Vector3 = car_pos + Vector3(0, eye_y, 0) - h * d_horiz + lateral
	var look: Vector3 = car_pos + Vector3(0, look_at_height, 0) + h * look_ahead
	var desired: Transform3D = make_look_transform(eye, look)

	if _initialized:

		var t := global_transform
		t.origin = t.origin.lerp(desired.origin, 1.0 - exp(-position_smoothing * delta))
		t.basis = t.basis.orthonormalized().slerp(desired.basis.orthonormalized(), 1.0 - exp(-rotation_smoothing * delta))
		global_transform = t

	else:

		global_transform = desired
		_initialized = true

	# 相机不再额外偏移，位置完全由这个节点的 origin 决定（见上面 eye 的推算），
	# 否则会在这里又往后退一次、把相机甩到车后上方

	camera.position.z = 0.0
	camera.fov = lerpf(camera.fov, fov_base + fov_speed * speed_factor, 1.0 - exp(-3.0 * delta))
