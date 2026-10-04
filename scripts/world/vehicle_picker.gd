extends Node3D

## 进图后把玩家那台车换成车库里选中的那台。
##
## 【为什么是「换脚本 + 换模型」，不是「换整棵节点」】
## scenes/main.tscn 里的占位 Vehicle 是靠 NodePath("../Vehicle") 挂在
## scripts/camera/view.gd 的 target 上的 —— 这个引用在场景**实例化那一刻**就解析成
## 对象了（node_paths 导出不是懒加载）。所以整棵换掉旧节点 = 相机跟一台已经进垃圾桶的
## 车 = 视角当场卡死。
## 那就在**同一个节点对象**上动手：换掉它挂的脚本（车 / 摩托两套控制器）和
## Container/Model 里那台模型（皮卡 / 摩托 / 蜜蜂三个 glb）。节点对象不变，
## 任何地方拿着的引用都不会失效。
##
## 【顺序有讲究】
## 必须「先换模型、再换脚本」：新脚本的 @onready 是脚本挂上的那一刻求值的，
## 先换模型，@onready 抓到的才是新模型，否则拿到的是上一台车的残骸。
## 默认那台（黄皮卡，id="car"）就是场景里本来就有的占位，直接跳过，什么都不动。
##
## 【为什么换完模型还要缩放】
## 不同导出工具的单位完全不统一：Kenney 那几台是 UnityGLTF 出米的（车身 ~2m 长），
## 这窝蜜蜂是 Blender/微软导出器把模型按厘米建、再用根节点 scale=0.01 折算 ——
## 进 Godot 就是 18.8m 的巨物。所以每台车在 Garage 目录里带一个「len」（最长边目标，
## 单位米），picker 按它归一化；len<=0 表示这台模型本来就对，别乱动。

@export_group("找玩家车")
## 玩家那台车的节点路径，相对**本节点**解析（main.tscn 里本节点叫 Garage，
## 和 Vehicle 同级，所以是 "../Vehicle"）。
##
## 【为什么必须用 NodePath 而不是按名字 find_child】
## 场景里有 4 个节点都叫 Vehicle：玩家那台 + 3 辆装饰皮卡 GLB（vehicle-truck-green /
## purple / red 内部各有一套同名节点）。find_child 是按遍历顺序抓第一个的，
## 而装饰车在 .tscn 里排在玩家车前面 —— 结果蜜蜂被焊到装饰车上、玩家那台纹丝不动，
## 量出来的球心/射线全是假节点的，排查一天都查不出去。
## 和 scripts/camera/view.gd 的 target = NodePath("../Vehicle") 用同一套写法，
## 这个引用在场景实例化那一刻就实体化，不会有歧义。
@export var player_path: NodePath = NodePath("../Vehicle")

## 模型原点补偿（喂给 vehicle.gd 的 model_origin_y，见那边注释）。
## 默认值 0 = Kenney 皮卡的原厂站位；picker 换车时会按新模型实测重算。
@export var model_origin_y: float = 0.0

## 【球心静止高度 = 0.5，不是 1】
## vehicle.tscn 里 Sphere 摆在载具原点上方 0.5，而车是真的落在地面上：
## 探针实测球半径 = 0.5 ⇒ 静止球心 = 地面 0 + 半径 0.5 = 0.5。
## vehicle.gd 每帧把模型摆到 sphere.position - (0, 0.65 + model_origin_y, 0)，
## 底面对齐就按这个基准反推（写成 1 会让每台车都悬空 0.5）。
##
## 【别改成 0.5】早先版本把球心摆成 0.5（= 原版 vehicle.tscn 的值）而且关了重力，
## 结果球再也不会落到静止高度，模型整体陷进地里 0.5 —— 车看着像埋在路面下。
## 0.5 是**没落地时**的位置，1.0 才是落在地上之后的位置。
const SPHERE_REST_Y := 0.5
const MODEL_UP_OFFSET := 0.65

var _done: bool = false


func _ready() -> void:
	# 推迟一帧：等 GridMap 的 mapgen 把赛道铺完、把车摆到起跑线之后再换，
	# 这样换完不用重新算出生点
	call_deferred("_swap")


func _swap() -> void:
	if _done:
		return
	_done = true

	# autoload 名（Garage）在 4.7 的场景编译时序里不一定注册成全局标识符，
	# 走 /root 路径取回来最稳
	var garage := get_node_or_null("/root/Garage")
	var def: Dictionary = (garage.current() if garage != null else {})
	if def.is_empty():
		return

	var node: Node3D = _find_player()
	if node == null:
		push_warning("[picker] 玩家节点路径解析不到：" + String(player_path) + "，换车跳过")
		return

	## 【别再给新射线悬挂车盖老街机脚本】
	## 这个 picker 是为老载具（Container/Model + 物理球 + 单根射线）写的。
	## scenes/nagrand.tscn 用的是新射线悬挂车 RayVehicle，两边同时挂会让
	## ArcadeVehicle._physics_process 和 RayWheel._physics_process 抢同一个节点，
	## 报 components / get_forward_speed 找不着（实测满屏 SCRIPT ERROR）。
	if node is RayVehicle:
		push_warning("[picker] 玩家车是 RayVehicle（新悬挂系统），picker 跳过")
		return

	var is_default: bool = String(def["id"]) == "car"
	var target_len: float = float(def.get("len", 0.0))
	var script_path: String = String(def["script"])

	# 1) 换模型：Container/Model 整个换掉。
	#    new_model 必须声明在块外：GDScript 的 var 是块作用域，
	#    写在 if 里的话块外（下面第 3 步播动画）拿不到这个标识符
	var new_model: Node = null
	if not is_default:
		var container: Node = node.find_child("Container", true, false)
		if container != null:
			var old_model: Node = container.find_child("Model", true, false)
			if old_model != null:
				container.remove_child(old_model)
				old_model.queue_free()
			var model_path: String = String(def["model"])
			var sc: PackedScene = load(model_path)
			if sc == null:
				push_warning("[picker] 读不到模型 " + model_path)
				return
			new_model = sc.instantiate()
			new_model.name = "Model"
			container.add_child(new_model)
		else:
			push_warning("[picker] Container 找不到，换模型跳过")

	# 2) 换控制器脚本
	var script: Script = load(script_path)
	if script == null:
		push_warning("[picker] 读不到控制器 " + script_path)
		return
	node.script = script

	# 【换脚本不会重跑 _ready】新脚本实例的 node 引用全是 null（raycast / sphere /
	# vehicle_model …），不补这一刀的话第一帧 handle_input 就
	# "Cannot call method 'is_colliding' on a null value"，车一动不动（实测摩托恒 0）。
	# bind_nodes() 会把 base 和子类（摩托）的引用一次性全抓一遍。
	if node.has_method("bind_nodes"):
		node.call("bind_nodes")

	# 3) 尺寸归一化 + 底面对齐，必须排在换脚本**之后**：
	#    给节点换脚本会重建 ScriptInstance，属性全部回默认值 ——
	#    在换脚本之前写 model_origin_y，一换到子类脚本（摩托 vehicle_motorcycle.gd）
	#    就被打回 0，模型底面直接沉 -0.3（探针实测）。
	#    「换进来先归一尺寸」这个诉求仍然成立：不然下一帧脚本读到的是没缩放过的巨物。
	#    默认那台（黄皮卡）也走这一步 —— 皮卡自己的底沿也不是 0。
	#    传 0 表示"这台长度本来就对" —— 只对齐底面，不缩放（摩托那条 len=0）。
	var final_model: Node = new_model
	if final_model == null:
		final_model = node.find_child("Model", true, false)
	if final_model != null:
		_fit_scale(final_model, target_len)

	# 4) 蜜蜂这类带骨骼动画的模型，让它的 idle 动起来（纯观感，不动物理）
	#    必须「返回」AnimationPlayer：GDScript 对象变量按值传参，
	#    往 _pick_anim(子节点, ap) 里塞 ap 人家拿到的是副本，外面永远 null（动画根本不播）
	if new_model != null:
		var ap: AnimationPlayer = _pick_anim(new_model)
		if ap != null:
			var list: Array = ap.get_animation_list()
			if list.size() > 0:
				ap.play(String(list[0]))

	print("[picker] 已换成 " + String(def["name"]) + " (" + String(def["id"]) + ")")


## 把模型最长边缩到 target 米，并把缩放后的底面摆到 base_bottom_y。
##
## 【为什么不用 global_transform 量】
## GLTF instantiate 出来的整棵子树在本 build 上 is_inside_tree() 恒为 false，
## 走 global_transform() 只会拿到单位变换（还附带刷一排 "!is_inside_tree()" 报错），
## 量出来的尺寸全是 0。所以这里用「局部 transform 累乘」自己算世界 AABB。
##
## 【为什么要重新对齐底面】
## 各建模软件的原点位置不一样：Kenney 那几台原点在车身中间偏上（最低点 -0.469），
## 这窝蜜蜂原点在身体正中（最低点 -15.5，CM 单位模型）。等比缩完之后如果不动它，
## 蜜蜂会比皮卡矮一大截、大半截埋进地里。所以缩完按 base_bottom_y 重新摆一次站位。
## target <= 0 = 这台模型的长度本来就对，只做底面对齐、不缩放。
func _fit_scale(m: Node, target: float) -> void:
	var box: AABB = _measure_local(m)
	# 量不出任何尺寸（空 mesh / 全被非 Node3D 污染）就只告警，别把模型缩成 0
	if box.size.x <= 0.0 and box.size.y <= 0.0 and box.size.z <= 0.0:
		push_warning("[picker] " + m.name + " 量不出尺寸，跳过（别白白把它缩小成 0）")
		return

	var s: float = 1.0
	if target > 0.0:
		var r: float = maxf(box.size.x, maxf(box.size.y, box.size.z))
		if r <= 0.001:
			push_warning("[picker] " + m.name + " 量不出尺寸，跳过缩放（别白白把它缩小成 0）")
			return
		s = target / r

	m.scale *= Vector3.ONE * s

	# 模型底沿在「Container 空间」的位置 = 局部 AABB 下沿 × 模型自身缩放
	var bottom_c: float = box.position.y * m.scale.y
	# vehicle.gd 每帧强制 vehicle_model.position = sphere.position - (0, 0.65 + model_origin_y, 0)，
	# 所以这里**不能**去改模型自己的 position（下一帧就被覆盖回去）；
	# 要把底面顶到地面 y=0，只能反过来推 model_origin_y：
	#     0 = sphere.y - 0.65 - model_origin_y + bottom_c
	#   球心静止 SPHERE_REST_Y=1  =>
	model_origin_y = (SPHERE_REST_Y - MODEL_UP_OFFSET) + bottom_c
	var car: Node3D = _find_player()
	if car != null:
		car.set("model_origin_y", model_origin_y)


func _measure_local(n: Node) -> AABB:
	return _box_local(n, Transform3D.IDENTITY)


## 注意必须「返回 AABB」而不是「传 box 进去改」：
## GDScript 里 AABB / Vector3 / Transform3D 是值语义，按值传参，
## 函数里 box = box.merge(...) 改的是副本，外面读到的永远是初始值（全是 0）。
func _box_local(n: Node, base: Transform3D) -> AABB:
	# 必须先挡住非 Node3D 节点：AnimationPlayer / Animation / Skeleton 根本没有 transform
	# 属性，直接读会刷 "Invalid access to property 'transform'" 并让变换变成 null，
	# 整棵树量出来的包围盒直接报废（蜜蜂那种带骨骼动画的模型必踩）
	var tr: Transform3D = base if not (n is Node3D) else base * (n as Node3D).transform
	var box := AABB(Vector3.ZERO, Vector3.ZERO)
	var any := false
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			var lb: AABB = mi.mesh.get_aabb()
			if lb.size.x > 0.0 or lb.size.y > 0.0 or lb.size.z > 0.0:
				for ex in [-1, 1]:
					for ey in [-1, 1]:
						for ez in [-1, 1]:
							var lp: Vector3 = lb.position + Vector3(ex, ey, ez) * lb.size * 0.5
							var wp: Vector3 = tr.origin + tr.basis * lp
							var pt := AABB(wp, Vector3.ZERO)
							if any:
								box = box.merge(pt)
							else:
								box = pt
								any = true
	for c in n.get_children():
		box = _box_local(c, tr).merge(box)
	return box


## 注意：这里**不能**用 find_child("Vehicle") —— 场景里有 4 个同名节点（见 player_path 注释）。
func _find_player() -> Node3D:
	return get_node_or_null(player_path) as Node3D


func _pick_anim(n: Node) -> AnimationPlayer:
	var found: AnimationPlayer = null
	for c in n.get_children():
		if c is AnimationPlayer and found == null:
			found = c as AnimationPlayer
		var sub: AnimationPlayer = _pick_anim(c)
		if found == null:
			found = sub
	return found
