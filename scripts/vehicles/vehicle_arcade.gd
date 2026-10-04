class_name ArcadeVehicle extends Node3D

# ---------------------------------------------------------------------------
# 极品飞车街机手感版（改造自官方 Starter Kit Racing 的遥控玩具车控制器）
#
# 【先说清楚现状，别照着错的文档改】
# 这个项目用的**不是** Godot 内置的 VehicleBody3D / VehicleWheel3D。
# scenes/vehicle.tscn 的真实结构是：
#     Vehicle(Node3D)
#       ├─ Ground        RayCast3D    —— 探地，拿到法线
#       ├─ Sphere        RigidBody3D  —— 只当碰撞体，mass=1000, gravity_scale=1.5
#       └─ Container/Model          —— vehicle-truck-*.glb 的实例化，纯视觉
# 车的"前进/转向"全在 scripts/vehicle.gd 里手算（linear_speed / angular_speed
# 两个标量），RayCast 只负责告诉脚本"地面法线是啥"。
#
# 【为什么 Sphere 的 gravity_scale 是 0】
# 下面 _physics_process 每帧把 sphere.linear_velocity 写成水平向量（y 恒为 0），
# 球体根本没有向下积累速度的能力 —— 只会在"一帧重力 + 立刻被清零"之间循环，
# 表现为开局缓慢下坠。既然重力对这个球没有任何用处，就直接关掉，
# 让「出生高度 = 静止高度」成立。出生高度由 mapgen.gd 的 CAR_Y 决定，
# 改那儿之前先看它那段注释（0.75 那个数字是错的，真实路面顶是 0.0625）。
#
# 所以网上那些「改 engine_force / brake / steering / mass」的 VehicleBody3D
# 建议，在本项目里没有对应属性可改。本文件把它们映射成下面的自研参数：
#
#     VehicleBody3D.mass           -> Sphere.mass（tscn 里已经是 1000）
#     VehicleBody3D.engine_force   -> engine_power（油门把速度推多快）
#     VehicleBody3D.brake          -> brake_power（反向输入时把速度压多快）
#     VehicleBody3D.steering       -> steer_authority + turn_rate（转向权限×转向速率）
#     VehicleBody3D.friction       -> lateral_grip（抓地力，见下面注释）
#
# 【街机手感的三个核心，缺一个就不像】
#   1. 方向盘渐进：input.x 不能直接当转向量用，先过一道一阶滞后（见 steer_*）。
#   2. 高速转向衰减：速度越高，方向盘能换来的转向越少（见 steer_falloff）。
#   3. 车头朝向 ≠ 行进方向：车头 yaw 立刻转，速度方向慢慢跟上，
#      两者差出来的角就是「甩尾角」。这就是"降低抓地力"的真正实现——
#      改 Sphere 的 friction 在本项目里根本没用（Sphere 只当碰撞体，
#      抓地力是 lateral_grip 这个数控制的）。
# ---------------------------------------------------------------------------

# Nodes
#
# 【这些引用为什么不用 @onready】
# vehicle_picker.gd 是**运行时**把 node.script 换掉的（车 / 摩托两套控制器），
# 而 @onready 只在 _ready() 里求值 —— 换脚本**不会**重跑 _ready，
# 新脚本实例里这些 onready 全是 null。后果实测：第一帧 handle_input 就
# "Cannot call method 'is_colliding' on a null value"，车纹丝不动（摩托速度恒 0）。
# 所以统一改成「var + bind_nodes()」：正常进图由 _ready() 调一次，
# picker 换完脚本再手动调一次。

var sphere: RigidBody3D = null
var raycast: RayCast3D = null

# Vehicle elements

var vehicle_model: Node3D = null
var vehicle_body: Node3D = null

# (Optional) wheels

var wheel_fl: Node3D = null
var wheel_fr: Node3D = null
var wheel_bl: Node3D = null
var wheel_br: Node3D = null

# Effects

var trail_left: Node3D = null
var trail_right: Node3D = null

# (Optional) 带骨骼动画的模型（现在只有蜜蜂那份 models/bee.glb）的动画播放器。
# 皮卡 / 摩托没有这个节点，保持 null，effect_anim() 会直接跳过。

var anim: AnimationPlayer = null

# Sounds

var screech_sound: AudioStreamPlayer3D = null
var engine_sound: AudioStreamPlayer3D = null
var impact_sound: AudioStreamPlayer3D = null

var input: Vector3
var normal: Vector3

var acceleration: float
var angular_speed: float
var linear_speed: float

var colliding: bool

var linear_velocity: Vector3
var prev_position: Vector3

var calculated_lean: float

# ===========================================================================
# 街机手感参数（对应提示词一「物理参数参考」那一段）
# ===========================================================================

@export_group("街机手感 · 转向")
## 方向盘进舵速度（1/s）。越小方向盘越"重"，打满要的时间越长。
## 遥控玩具车是 8~12（一打就到位）；街机车取 4~6 才有一丝迟滞。
@export var steer_response: float = 5.0
## 松手回中速度（1/s）。一般比进舵快一点，回正才干脆。
@export var steer_return: float = 7.0
## 低速时的最大转向权限（方向盘打死 = 这个倍率 × turn_rate）
@export var steer_authority: float = 1.0
## 从多大速度开始生效（归一化速度，1.0 = 表里的满速）
@export var falloff_start: float = 0.35

@export_group("街机手感 · 惯性 / 抓地")
## 车身视觉朝向 = 车头方向 与 行进方向 的混合权重（0=车身永远指着车头，
## 1=车身永远顺着实际跑的方向）。调它才有"甩尾时车横过来"的造型。
@export var drift_blend: float = 0.55
## 低抓地力只在有一定速度后才松开（低速原地打方向不该飘）
@export var drift_min_speed: float = 0.12

@export_group("模型站位")
## 模型原点相对「球体中心 - 0.65」的补偿量，见 _physics_process 里那行
## vehicle_model.position 的注释。默认值 0 = Kenney 皮卡原厂站位；
## 换车（vehicle_picker.gd）时会按新模型的实测底沿重算，让车底刚好贴地。
@export var model_origin_y: float = 0.0

@export_group("模型动画")
## 【只在带骨骼动画的模型上生效】现在只有蜜蜂那份 models/bee.glb（动画列表：
## _bee_hover / _bee_idle / _bee_take_off_and_land）。皮卡摩托没有 AnimationPlayer，
## 这组参数自动失效，effect_anim() 直接 return。
## 跑起来播哪一段（留空 = 按关键词猜：hover / fly / flight / swing / move）。
@export var anim_move_clip: String = ""
## 停下来播哪一段（留空 = 猜 idle / rest / stop）。留空则两段相同 = 不切。
@export var anim_idle_clip: String = ""
## 超过这个速度（真实 m/s）才切到「跑起来」那段。
@export_range(0.0, 3.0, 0.05) var anim_switch_speed: float = 0.4
## 满速时动画播放速率的倍率（1.0 = 原速，越大扇翅膀扇得越急）。
@export_range(1.0, 6.0, 0.1) var anim_speed_boost: float = 2.4

@export_group("操控归属")
## 【谁是"被你开的那一台"】只有这一台读键盘。
## main.tscn 里四台车（Vehicle / Vehicle2 / Vehicle3 / Vehicle4）是同一个
## scenes/vehicle.tscn 的实例，全都挂着 vehicle.gd，而 handle_input 读的是
## 全局 Input —— 玩家一踩油门，四台会**同步**开走（实测三台对手车的 Sphere
## 位移和速度跟玩家车一模一样：1.06 / 7.58 / 16.58，速度 8.26 / 9.75）。
## 所以给每台车一个开关：玩家车在 main.tscn 里写 `is_player = true`，
## 剩下三台留 false，它们就变成「静止的对手车」，只有被撞才会挪一点。
## 想让它们动起来（AI 对手）就在子类里重写 handle_input()。
@export var is_player: bool = false

@export_group("街机手感 · 重量转移")
## 车身俯仰幅度：每 1.0 单位加速度对应多少弧度（加速抬头 / 刹车点头）
@export var pitch_gain: float = 0.030
## 车身侧倾幅度：每 1.0（方向量×速度）对应多少弧度
@export var roll_gain: float = 0.055
@export var pitch_response: float = 9.0
@export var roll_response: float = 7.0
## 俯仰/侧倾的上限（弧度），防止加速到底时车以后空翻过去
@export var pitch_clamp: float = 0.30
@export var roll_clamp: float = 0.38

# ---------------------------------------------------------------------------
# 运行时可调项
#
# 这一组**名字必须叫 "tunable"**：addons/gdtuner 的 AutoTunable 节点就是靠
# `get_property_list()` 里有没有一个名为 tunable 的分组，来决定给哪些变量
# 自动生成滑块的（见 addons/gdtuner/auto_tunable.gd 的 _scan_tunable_exports）。
# 想让某个 @export 变量能被 F12 面板拖，就把它放进这个组（或改组名都要一致）。
#
# @export_range 不只是给编辑器看的：GDTuner 会读 hint 当作滑块量程，
# 没有它的话自动范围是按当前值 ×3 瞎猜的（比如 28 → 0~84）。
# ---------------------------------------------------------------------------

@export_group("tunable")
## 【最高车速，主调速旋钮】单位 m/s。这里指的是**三档全开**的上限。
## 历史值 10.4 = Kenney 原版 Starter Kit 的遥控玩具车巡航速度（≈37 km/h），
## 用户反馈「车移动像有故障，太慢」—— 根因就是这个原厂值一直没人覆盖过。
## 2026-10-04 按拍板改 32.0 ≈ 115 km/h：街区只有 34 m、路口间距 46 m，
## 再往上（40 = 144 km/h）满速一秒就跨一个街区，转弯半径会大到贴不住路网。
## linear_speed 是 **0~1 的归一化油门量**，不是米/秒！
## 写进 RigidBody 之前必须乘上 max_speed 才是真实世界速度。
## 改造前这里漏了换算（直接 `velocity_dir * linear_speed`），
## 结果满油门只有 1 m/s ≈ 3.6 km/h，慢得像在散步。
@export_range(4.0, 60.0, 0.5) var max_speed: float = 32.0
## 油门响应（1/s，速度趋近满速的倒数时间常数）。
## 小 = 起步肉、加速过程看得见；大 = 一脚油门瞬间到顶。
## 1.1 大约 1 秒到七成、2 秒到九成，街机车的推背感靠这个数。
@export_range(0.2, 4.0, 0.05) var engine_power: float = 1.1
## 刹车响应（1/s，速度衰减到 0 的速率）。比油门大一点，刹车才有"压得住"的感觉。
@export_range(0.5, 8.0, 0.1) var brake_power: float = 3.5
## 抓地力：速度方向「追上」车头方向的速率（1/s）。
##   12+ = 轨道车，速度方向几乎立刻跟上车头
##   3~5 = 街机赛车（初值），能明显甩出去
##   1~2 = 漂移极限，没有开回正的趋势，很容易打转
## 【2026-10-04 随满速重标】3.2 是按满速 10.4 m/s 调的：τ=0.3s 时车只滑 3 m，
## 看着是「有点飘」。满速换成 32 m/s 后同样 0.3s 要滑 10 m —— 直接变成
## 「转了方向盘车还在往前直冲」，撞穿半个街区。提到 5.0 把滑移量压回可玩范围。
@export_range(0.5, 12.0, 0.1) var lateral_grip: float = 5.0
## 满舵时的基础角速度（rad/s）。大车小车给 2.5~4.5。
## 【2026-10-04 随满速重标】转弯半径 = 速度 ÷ 角速度。满速 32 m/s 时方向盘权限
## 被 steer_falloff 砍到 0.45，3.4 × 0.45 = 1.53 rad/s ⇒ 半径 21 m，
## 而城里车道只有 12 m 宽、路口间距 46 m —— 三档根本拐不进路口。
## 提到 4.2 ⇒ 半径约 17 m，一/二档（12、22 m/s）分别是 7.6 m、13 m，都还能原地绕圈。
@export_range(1.0, 6.0, 0.1) var turn_rate: float = 4.2
## 高速转向衰减：满速时方向盘权限剩多少（0=完全不衰减，0.8=只剩两成）。
## 这是"高速不好拐弯"手感的来源。
@export_range(0.0, 1.0, 0.05) var steer_falloff: float = 0.55
@export_group("")

@export_group("街机手感 · 动力")
## 是否把速度写回 RigidBody（关掉 = 纯视觉车，撞墙不会真的按速度方向弹开）
@export var drive_rigidbody: bool = true

@export_group("档位 · 三档手动（#31）")
## 【档位钳的是归一化油门量，不是 speed_cap()】这是本轮最容易写错的地方：
## 世界速度 = linear_speed × speed_cap()。要是把档位做成 speed_cap() 乘个档系数，
## 从 1 档跳到 2 档的那一帧，linear_speed 还是 1.0，世界速度就会从 12 m/s
## **瞬间**变成 22 m/s —— 用户看到的「车一抽一抽像故障」正是这种跳变。
## 钳归一化值则 linear_speed 连续，换挡后只是「还能继续往上爬」，一点不跳。
## 下标 0/1/2 = 一/二/三档上限占满速的比例（1.0 = max_speed）。
@export var gear_ratios: Array[float] = [0.375, 0.6875, 1.0]
## 各档扭矩倍率（乘在 engine_power 上）。低档加速猛、高档绵，才有「档」的性格。
@export var gear_torque: Array[float] = [2.0, 1.36, 1.0]
## 倒档上限占满速比例（0.16 × 32 ≈ 5.1 m/s ≈ 18 km/h，够揉库了）
@export_range(0.02, 0.5, 0.01) var reverse_ratio: float = 0.16
## 空档 / 松油门时的滑行减速速率（1/s）。比刹车（3.5）绵得多，车会自己慢慢溜停。
@export_range(0.05, 4.0, 0.05) var neutral_drag: float = 0.7
## 降档时的发动机制动速率（1/s）：当前速度高于本档上限时用这个，不用油门系数
## （油门 1.1 慢慢磨要 2 秒，降档不立刻咬住就会觉得「挂了档车还在往前溜」）。
@export_range(0.5, 8.0, 0.1) var downshift_brake: float = 2.4
## 上车时挂在哪一档（1..3）
@export_range(1, 3, 1) var start_gear: int = 1

# ===========================================================================
# 运行时状态（给 view.gd / 相机 / 特效读）
# ===========================================================================

## 车头朝向（绕世界 Y 轴，弧度）。0 = 朝 +Z。
var yaw: float = 0.0
## 平滑后的方向盘位置 [-1, 1]
var steer: float = 0.0
## 速度方向（世界空间、水平单位向量）。它和 yaw 的夹角就是甩尾角。
var velocity_dir: Vector3 = Vector3(0, 0, 1)
## 真实纵向加速度（速度的时间导数），用来做抬头/点头
var longitudinal_accel: float = 0.0
## 甩尾角（弧度，有符号）：车头方向 - 行进方向。相机会读它做横向偏移。
var drift_angle: float = 0.0
## 上面这些是不是初始化过了（第一帧别去改上一帧的向量）
var _spawned: bool = false

var _prev_speed: float = 0.0

## 当前档位：-1 = R 倒档，0 = N 空档，1..3 = 前进档。
## 只有「被玩家开的那一台」会因按键改变；客机不读键盘（handle_input 里归零），
## 所以档位是本机状态，不进网络快照 —— 别人看你车只需要位置+yaw。
var gear: int = 1

# ---------------------------------------------------------------------------
# #20 最小车辆伤害模型 + 角色能力倍率
# 倍率由 economy 模块在 vehicle_boarded 事件里写入（能力：驾驶训练/钣金强化）。
# health 影响有效极速（最低扣到 60%），撞击扣血走 EventBus vehicle_damaged，
# 出租车任务订阅它做「撞击扣减」。
# ---------------------------------------------------------------------------

@export var health_max: float = 100.0
var health: float = 100.0
## 受伤倍率（1.0=未强化；钣金强化每级 -0.25）
var armor_mult: float = 1.0
## 极速倍率（驾驶训练每级 +0.10）
var ability_speed_mult: float = 1.0
var _dmg_cd: float = 0.0

# Public Functions

func get_vehicle_position() -> Vector3: return vehicle_model.global_position

## 有效极速（m/s）= 底盘极速 × 能力倍率 × 战损降速（血 0 → 60%）
func speed_cap() -> float:
	return max_speed * ability_speed_mult \
		* lerpf(0.6, 1.0, clampf(health / maxf(health_max, 1.0), 0.0, 1.0))

## 真实速度（米/秒）。linear_speed 是归一化的油门量（0~1），
## 换算成世界单位之后，撞墙反弹、镜头拉远、胎噪强度都该读这个而不是归一化值。
func get_speed_mps() -> float: return absf(linear_speed) * speed_cap()

func _speed_mps() -> float: return absf(linear_speed) * speed_cap()

# ---------------------------------------------------------------------------
# 档位（#31）：HUD 与 handle_input 都走这几个口，别在别处直接读 gear 算数
# ---------------------------------------------------------------------------

## 本档的归一化上限（N 档 = 0 = 断动力）
func gear_cap01() -> float:
	if gear > 0:
		return gear_ratios[clampi(gear - 1, 0, gear_ratios.size() - 1)]
	if gear < 0:
		return reverse_ratio
	return 0.0

## 本档扭矩倍率（乘在 engine_power 上）
func gear_torque_mult() -> float:
	if gear > 0:
		return gear_torque[clampi(gear - 1, 0, gear_torque.size() - 1)]
	if gear < 0:
		return 1.0
	return 0.0

## 本档实际能跑到的 m/s（已含能力倍率与战损降速，所以 HUD 用它而不是标称值，
## 否则血掉光时会显示「限速 32」却卡在 19 上不去）。
func gear_top_mps() -> float:
	return speed_cap() * gear_cap01()

## HUD 档位角标：R / N / 1 / 2 / 3
func gear_label() -> String:
	if gear < 0:
		return "R"
	if gear == 0:
		return "N"
	return str(gear)

## 挂档。越界钳到 [-1, 档位数]，同档直接返回（不重置任何东西）。
func shift_to(g: int) -> void:
	var top: int = gear_ratios.size()
	var want: int = clampi(g, -1, top)
	if want == gear:
		return
	gear = want

func gear_count() -> int:
	return gear_ratios.size()

## 重新抓一遍所有子节点引用。
## 正常进图时 _ready() 会调一次；picker 在运行时换完脚本**必须**再调一次，
## 否则新脚本实例的 node 引用全是 null（见上面 Nodes 的注释）。
func bind_nodes() -> void:

	sphere = $Sphere
	raycast = $Ground

	vehicle_model = $Container
	vehicle_body = get_node_or_null("Container/Model/body")

	wheel_fl = get_node_or_null("Container/Model/wheel-front-left")
	wheel_fr = get_node_or_null("Container/Model/wheel-front-right")
	wheel_bl = get_node_or_null("Container/Model/wheel-back-left")
	wheel_br = get_node_or_null("Container/Model/wheel-back-right")

	trail_left = get_node_or_null("Container/TrailLeft")
	trail_right = get_node_or_null("Container/TrailRight")

	# 动画播放器在模型子节点里（GLTF Sometimes 会埋在 Animations/ 下），
	# 每次换模型都得重抓一遍 —— 换模型不重跑 _ready，但 bind_nodes 会被 picker 调。
	anim = _find_anim(vehicle_model)
	_apply_anim_clips()

	screech_sound = $Container/ScreechSound
	engine_sound = $Container/EngineSound
	impact_sound = $Container/ImpactSound

	# 子类自己的那几个引用（摩托那套 wheel / fork）走 _bind_extra()，
	# 别去覆盖 bind_nodes —— 覆盖的话子类一改就漏掉 base 的绑定
	if has_method("_bind_extra"):
		call("_bind_extra")


func _ready() -> void:

	bind_nodes()

	# 认玩家的把手：纳格兰那种起伏地形要靠 group 找到车、把它放到地面上
	if is_player:
		add_to_group("player")


## 子类重写这个方法去绑自己的节点（摩托那几个 wheel / fork 就是），空的 = 没有额外节点。
func _bind_extra() -> void:

	pass


# Functions

## 速度驱动动画：跑起来播扇翅那段，停下来播待机那段，越快扇得越急。
## 放在 _process（渲染帧）而不是 _physics_process（物理帧）：动画是观感，
## 没必要跟着 60Hz 物理步长跳，而且 AnimationPlayer 本来就是渲染帧推进的。
func _process(delta: float) -> void:

	effect_anim(delta)


func effect_anim(delta: float) -> void:

	if anim == null:
		return

	var spd: float = _speed_mps()

	# 只用字符串比较决定播哪段 —— 别用动画是否播完做判断，
	# 循环动画（hover 本来就是循环）永远播不完。
	if anim_idle_clip != "" and spd < anim_switch_speed:
		if anim.current_animation != anim_idle_clip:
			anim.play(anim_idle_clip)
	elif anim_move_clip != "":
		if anim.current_animation != anim_move_clip:
			anim.play(anim_move_clip)

	# 播放速率跟着速度走：1.0（停着）→ anim_speed_boost（满速）
	var want: float = 1.0 + clampf(spd / maxf(max_speed, 0.001), 0.0, 1.0) * (anim_speed_boost - 1.0)
	# 4.7 上属性叫 speed_scale（playback_speed 是 AnimationTree 的那套，写上去会报错）
	# 缓一下，免得速度瞬间归零时翅膀卡死在半空一闪。
	anim.speed_scale = lerpf(anim.speed_scale, want, 1.0 - exp(-6.0 * delta))


## 第一次拿到动画播放器时，把「跑 / 停」两段的名字定下来。
## 名字写在 .tscn 里最稳；这里只是给个按关键词猜的兜底（蜜蜂那份列表顺序会变）。
func _apply_anim_clips() -> void:

	if anim == null:
		return
	var list: Array = anim.get_animation_list()
	if list.is_empty():
		return
	if anim_move_clip == "" or not list.has(anim_move_clip):
		anim_move_clip = _guess_clip(list, ["hover", "fly", "flight", "swing", "move"])
	if anim_idle_clip == "" or not list.has(anim_idle_clip):
		anim_idle_clip = _guess_clip(list, ["idle", "rest", "stop"])
	if anim_idle_clip == anim_move_clip:
		anim_idle_clip = ""
	print("[vehicle] 动画 跑=" + anim_move_clip + "  停=" + (anim_idle_clip if anim_idle_clip != "" else "(不切)"))


## 从动画列表里按关键词猜一个。多个关键词匹配同一个时，取列表里排序最靠前的。
func _guess_clip(list: Array, keys: Array) -> String:

	var best: String = ""
	for k in keys:
		for a in list:
			if String(a).to_lower().contains(k):
				best = String(a)
				break
		if best != "":
			break
	if best == "":
		best = String(list[0])
	return best


## 在模型子树里找 AnimationPlayer（GLTF 有可能把它塞在 Animations/ 子节点下面）。
func _find_anim(root_node: Node) -> AnimationPlayer:

	if root_node == null:
		return null
	for c in root_node.get_children():
		if c is AnimationPlayer:
			return c as AnimationPlayer
	return _find_anim_deep(root_node)


func _find_anim_deep(n: Node) -> AnimationPlayer:

	for c in n.get_children():
		if c is AnimationPlayer:
			return c as AnimationPlayer
		var sub: AnimationPlayer = _find_anim_deep(c)
		if sub != null:
			return sub
	return null


func _physics_process(delta):

	handle_input(delta)

	# #20 伤害冷却计时 + 松油门缓慢回血（本轮不做修理厂，靠养）
	_dmg_cd = maxf(_dmg_cd - delta, 0.0)
	if absf(input.z) < 0.05 and health < health_max:
		health = minf(health + 0.8 * delta, health_max)

	var direction: float = signf(linear_speed)
	if direction == 0: direction = signf(input.z) if absf(input.z) > 0.1 else 1.0

	# ------------------------------------------------------------------
	# 1) 方向盘：先按速度衰减权限，再过一阶滞后。
	#    这样"打一下方向"不会瞬间把车头掰过来，而是渐进地咬进去。
	# ------------------------------------------------------------------

	var speed01: float = clampf(absf(linear_speed), 0.0, 1.0)

	# 用 smoothstep 曲线起步，低速段几乎不衰减、高速段衰减变陡
	var fall01: float = clampf((speed01 - falloff_start) / maxf(1.0 - falloff_start, 0.001), 0.0, 1.0)
	var authority: float = steer_authority * (1.0 - steer_falloff * fall01 * fall01)

	var target_steer: float = clampf(input.x, -1.0, 1.0) * authority
	var steer_k: float = steer_response if absf(input.x) > 0.01 else steer_return
	steer = lerpf(steer, target_steer, 1.0 - exp(-steer_k * delta))

	# ------------------------------------------------------------------
	# 2) 车头角速度：同样过一阶滞后，且乘上速度（静止时打方向不转）
	# ------------------------------------------------------------------

	var target_angular: float = -steer * turn_rate * clampf(absf(linear_speed), 0.2, 1.0) * direction
	angular_speed = lerpf(angular_speed, target_angular, 1.0 - exp(-6.0 * delta))
	yaw += angular_speed * delta

	# ------------------------------------------------------------------
	# 3) 速度方向「追」车头方向 —— 抓地力就在这行。
	#    grip 越小，速度方向越跟不上车头，车尾就滑得越出去。
	# ------------------------------------------------------------------

	if absf(linear_speed) > drift_min_speed:
		# 指数收敛：跟帧率无关，delta 变了手感也不漂。
		# grip 越小，速度方向越追不上刚转过去的车头 —— 车尾就滑出去了。
		var grip: float = lateral_grip * (1.0 - 0.35 * fall01)
		velocity_dir = velocity_dir.lerp(_forward_from_yaw(yaw), 1.0 - exp(-grip * delta))
		if velocity_dir.length_squared() < 0.0001:
			velocity_dir = _forward_from_yaw(yaw)
		else:
			velocity_dir = velocity_dir.normalized()
	else:
		velocity_dir = _forward_from_yaw(yaw)

	# 甩尾角 = 车头方向 减 行进方向
	var vel_yaw: float = atan2(velocity_dir.x, velocity_dir.z)
	drift_angle = -shortest_angle_delta(vel_yaw, yaw)

	# ------------------------------------------------------------------
	# 4) 车身朝向：视觉上是「车头」和「行进方向」的混合，
	#    所以甩尾时你能看到车身横过来，而车还是往前跑。
	# ------------------------------------------------------------------

	var visual_yaw: float = yaw + shortest_angle_delta(yaw, vel_yaw) * drift_blend
	steer_visual_yaw(visual_yaw)

	# Ground alignment

	if raycast.is_colliding():
		if !colliding:
			if vehicle_body != null: vehicle_body.position = Vector3(0, 0.1, 0) # Bounce
			input.z = 0

		normal = raycast.get_collision_normal()

		# Orient model to colliding normal

		if normal.dot(vehicle_model.global_basis.y) > 0.5:
			# 法线对齐别做太快（0.35 而不是 0.2），不然冲下坡时车身会抽搐
			var xform = align_with_y(vehicle_model.global_transform, normal)
			vehicle_model.global_transform = vehicle_model.global_transform.interpolate_with(xform, 0.35).orthonormalized()

	colliding = raycast.is_colliding()

	# ------------------------------------------------------------------
	# 5) 纵向速度：先由档位算出「这一档最多踩到多深、有劲没劲」，
	#    再走原来的油门 / 刹车分支。档位钳的是归一化量（见 gear_ratios 注释），
	#    所以换挡那一帧 linear_speed 不动、世界速度也不跳。
	# ------------------------------------------------------------------

	var cap01: float = gear_cap01()
	var tq: float = gear_torque_mult()
	var target_speed: float = 0.0
	if gear < 0:
		# 倒档：只有踩 S 有推力，W 当刹车用
		target_speed = minf(input.z, 0.0) * cap01
	else:
		target_speed = input.z * cap01
		if target_speed < 0.0:
			# 前进档里把 S 踩过头 = 低速倒车（沿用原来的半速规矩，别给满）
			target_speed *= 0.5

	if absf(target_speed) < 0.0001:
		# 空档 / 松油门：滑行溜停，比刹车绵得多（不然一摘档就点头）
		linear_speed = lerpf(linear_speed, 0.0, 1.0 - exp(-neutral_drag * delta))
	elif (target_speed < 0.0 and linear_speed > 0.01) or (target_speed > 0.0 and linear_speed < -0.01):
		# 想要的方向和当前行进方向相反 = 刹车，比油门狠
		linear_speed = lerpf(linear_speed, 0.0, 1.0 - exp(-brake_power * delta))
	elif absf(target_speed) < absf(linear_speed):
		# 高于本档上限（刚降档、或高档踩到低档）：发动机制动，
		# 用油门系数慢慢磨的话会「挂了低档车还在往前溜」
		linear_speed = lerpf(linear_speed, target_speed, 1.0 - exp(-downshift_brake * delta))
	else:
		linear_speed = lerpf(linear_speed, target_speed, 1.0 - exp(-engine_power * tq * delta))

	# 真实加速度（速度的时间导数）—— 抬头/点头靠它
	var inst_accel: float = (linear_speed - _prev_speed) / maxf(delta, 1e-5)
	longitudinal_accel = lerpf(longitudinal_accel, inst_accel, 1.0 - exp(-4.0 * delta))
	acceleration = longitudinal_accel

	_prev_speed = linear_speed

	# 把速度写回刚体：这样撞墙/撞楼时反弹方向才是真的按速度来的，
	# 而不是一个原地自转的球。想省性能或者手感调不好可以关掉 drive_rigidbody。
	if not is_player:
		# 对手车不读键盘，这里把水平速度钉死。
		# 不钉的话玩家撞一下它，它会被推开、然后顺着零摩擦的路面（GridMap 的
		# PhysicsMaterial friction=0）一路滑走，看着还是"黄车自己跟着跑"。
		# 只清 x/z 不清 y —— y 那一帧的接触顶托交回给物理求解器，见下面注释。
		sphere.linear_velocity.x = 0.0
		sphere.linear_velocity.z = 0.0

	if drive_rigidbody:
		# 【只写 x/z，别整个向量赋值】整个赋值会把 y 分量一起抹成 0，
		# 而接触求解器正是靠这一帧的 y 速度把车顶出地面 —— 抹掉它的后果是
		# 车以 gravity*dt 的速率**永久缓慢下沉**（实测每帧 4mm、约 0.24 m/s），
		# 开一分钟车就埋进路面里了。只覆盖水平方向，竖直交给物理求解器。
		var spd: float = _speed_mps() * direction
		sphere.linear_velocity.x = velocity_dir.x * spd
		sphere.linear_velocity.z = velocity_dir.z * spd

	# Match vehicle model to physics sphere

	# model_origin_y 是换车脚本（scripts/world/vehicle_picker.gd）按新模型实测底面反推出来的。
	# 别去直接改 vehicle_model.position —— 那玩意儿每帧都在这里被覆写，改了等于白改。
	# 0.65 是原版 Kenney 那台模型「球心到模型原点」的经验距离，见 vehicle_picker.gd。
	vehicle_model.position = sphere.position - Vector3(0, 0.65 + model_origin_y, 0)
	raycast.position = sphere.position

	# Calculate vehicle model linear velocity

	linear_velocity = (vehicle_model.position - prev_position) / delta
	prev_position = vehicle_model.position

	# Visual and audio effects

	effect_engine(delta)
	effect_body(delta)
	effect_wheels(delta)
	effect_trails()

# Handle input when vehicle is colliding with ground

func handle_input(delta):

	if is_player:
		# 换挡放在落地判定之外：腾空时也该能预先摘空档/挂倒档。
		# 数字键直选（按几就是几档），Z = 倒档 R，X = 空档 N。
		if Input.is_action_just_pressed("gear_1"):
			shift_to(1)
		if Input.is_action_just_pressed("gear_2"):
			shift_to(2)
		if Input.is_action_just_pressed("gear_3"):
			shift_to(3)
		if Input.is_action_just_pressed("gear_r"):
			shift_to(-1)
		if Input.is_action_just_pressed("gear_n"):
			shift_to(0)
		if raycast.is_colliding():
			input.x = Input.get_axis("left", "right")
			input.z = Input.get_axis("back", "forward")
	else:
		# 对手车（发车格上那三台）：不读键盘，油门/方向永远归零。
		# 不这样写的话玩家一踩油门四台同步跑，画面里所有黄车一起跟着走。
		input.x = 0.0
		input.z = 0.0
		return

	# 【坑·v1.5】这里原来是 `sphere.angular_velocity += basis.x * speed * 100 * delta`
	# （官方玩具车让球物理滚动的残留）。本项目的轮子是纯视觉（effect_wheels 自己转），
	# 球体自旋只会带来一个灾难：撞墙时高摩擦接触点把自旋换算成向上的摩擦力，
	# 球像上了强烈上旋的网球一样被弹上天（用户反馈「车一碰就上天」）。
	sphere.angular_velocity = Vector3.ZERO

## 车身每帧「重新摆」到指定的车头朝向（替代原来 rotate_y 的累积式旋转）。
## 原来那句 vehicle_model.rotate_y(angular_speed * delta) 是增量累加，
## 一旦中途对不齐法线就会永久偏掉；这里每帧从 yaw 反推，不会漂。

func steer_visual_yaw(target_yaw: float) -> void:

	var up: Vector3 = normal if (raycast.is_colliding() and normal.dot(Vector3.UP) > 0.0) else Vector3.UP
	var want: Transform3D = _yaw_transform(vehicle_model.global_position, target_yaw, up)

	if not _spawned:
		vehicle_model.global_transform = want
		_spawned = true
	else:
		vehicle_model.global_transform = vehicle_model.global_transform.interpolate_with(want, 0.5).orthonormalized()

## 世界朝向 -> 车身前向：yaw=0 时朝 +Z，绕 +Y 正向转 yaw
func _forward_from_yaw(y: float) -> Vector3:
	return Vector3(sin(y), 0.0, cos(y))

## 造一个「位置在 pos、up 轴贴着 up、车头朝向 yaw」的变换。
## 基向量必须满足右手系 x = y × z，否则模型会被镜像。
func _yaw_transform(pos: Vector3, yaw_: float, up: Vector3) -> Transform3D:

	var z_hat: Vector3 = _forward_from_yaw(yaw_)
	var y_hat: Vector3 = up - z_hat * z_hat.dot(up)
	if y_hat.length_squared() < 0.0001:
		y_hat = Vector3.UP
	else:
		y_hat = y_hat.normalized()
	# x = y × z
	var x_hat: Vector3 = y_hat.cross(z_hat).normalized()
	z_hat = x_hat.cross(y_hat).normalized()

	return Transform3D(Basis(x_hat, y_hat, z_hat), pos)

func effect_body(delta):

	calculated_lean = lerp_angle(calculated_lean, -steer * absf(linear_speed) * 2.0, 1.0 - exp(-5.0 * delta))

	if vehicle_body != null:

		# 抬头/点头：用真实加速度（accel>0 加速 -> 车头抬起 -> 绕 X 负向转）
		var pitch_target: float = clampf(-longitudinal_accel * pitch_gain, -pitch_clamp, pitch_clamp)
		var roll_target: float = clampf(-calculated_lean * roll_gain, -roll_clamp, roll_clamp)

		vehicle_body.rotation.x = lerp_angle(vehicle_body.rotation.x, pitch_target, 1.0 - exp(-pitch_response * delta))
		vehicle_body.rotation.z = lerp_angle(vehicle_body.rotation.z, roll_target, 1.0 - exp(-roll_response * delta))

		vehicle_body.position = vehicle_body.position.lerp(Vector3(0, 0.2, 0), 1.0 - exp(-5.0 * delta))

func effect_wheels(delta):

	# Rotate wheels based on acceleration

	for wheel in [wheel_fl, wheel_fr, wheel_bl, wheel_br]:
		if wheel != null:
			wheel.rotation.x += acceleration

	# Rotate front wheels based on steering direction

	if wheel_fl != null: wheel_fl.rotation.y = lerp_angle(wheel_fl.rotation.y, -steer, 1.0 - exp(-10.0 * delta))
	if wheel_fr != null: wheel_fr.rotation.y = lerp_angle(wheel_fr.rotation.y, -steer, 1.0 - exp(-10.0 * delta))

# Engine sounds

func effect_engine(delta):

	var speed_factor = clampf(absf(linear_speed), 0.0, 1.0)
	var throttle_factor = clampf(absf(input.z), 0.0, 1.0)

	var target_volume = remap(speed_factor + (throttle_factor * 0.5), 0.0, 1.5, -15.0, -5.0)
	engine_sound.volume_db = lerp(engine_sound.volume_db, target_volume, 1.0 - exp(-5.0 * delta))

	var target_pitch = remap(speed_factor, 0.0, 1.0, 0.5, 3)
	if throttle_factor > 0.1: target_pitch += 0.2

	engine_sound.pitch_scale = lerpf(engine_sound.pitch_scale, target_pitch, 1.0 - exp(-2.0 * delta))

# Show trails (and play skid sound)
## 打滑强度改成看甩尾角：车身横得越多、速度越快，胎噪越响
## （原来是 abs(linear_speed - acceleration)，那是个伪量，全速直线时也会响）

func effect_trails():

	var slip: float = absf(drift_angle) * absf(linear_speed)
	var should_emit: bool = slip > 0.06

	if trail_left != null: trail_left.emitting = should_emit
	if trail_right != null: trail_right.emitting = should_emit

	var target_volume = -80.0
	if should_emit: target_volume = remap(clampf(slip, 0.06, 1.2), 0.06, 1.2, -10.0, 0.0)

	screech_sound.pitch_scale = lerpf(screech_sound.pitch_scale, clampf(absf(linear_speed), 1.0, 3.0), 0.1)
	screech_sound.volume_db = lerpf(screech_sound.volume_db, target_volume, 10.0 * get_physics_process_delta_time())

# ---------------------------------------------------------------------------
# 角度工具
# ---------------------------------------------------------------------------

## 两个角之间最短的有符号差（结果落在 -PI ~ PI）。
## shortest_angle_delta(a, b) 读作「从 a 转到 b 最短要转多少」= wrap(b - a)。
## 显式写一份而不是直接调全局：甩尾角的正负号全看这里，
## 换个引擎版本全局函数的语义万一变了，车身朝向和相机会一起反。
func shortest_angle_delta(a: float, b: float) -> float:

	var d: float = b - a
	while d > PI:
		d -= TAU
	while d < -PI:
		d += TAU
	return d

# Align vehicle with normal

func align_with_y(xform, new_y):

	xform.basis.y = new_y
	xform.basis.x = -xform.basis.z.cross(new_y)
	xform.basis = xform.basis.orthonormalized()
	return xform

# Detect collisions and play impact sound

func _on_sphere_body_entered(_body: Node) -> void:

	if vehicle_body == null: return

	var impact_velocity: float = absf(linear_velocity.dot(vehicle_body.global_basis.z))

	if not impact_sound.playing:
		# 量程跟着 max_speed 走：满速 40 m/s 撞墙要能到 0 dB，慢速蹭一下才压得住
		var impact_range: float = maxf(6.0, max_speed * 0.5)
		impact_sound.volume_db = clampf(remap(impact_velocity, 0.0, impact_range, -20.0, 0.0), -20.0, 0.0)
		impact_sound.play()

	# #20 最小伤害模型：相对速度 > 3 m/s 才扣血，0.3s 冷却防一次接触逐帧扣
	if _dmg_cd <= 0.0 and impact_velocity > 3.0:
		var dmg: float = (impact_velocity - 3.0) * 1.5 * armor_mult
		health = maxf(health - dmg, 0.0)
		_dmg_cd = 0.3
		var bus: Node = get_node_or_null("/root/EventBus")
		if bus != null:
			bus.vehicle_damaged.emit(String(name), dmg, health)
