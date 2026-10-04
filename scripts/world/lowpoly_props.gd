extends RefCounted
## 低模素材装载器 —— GTAWorld 的装饰件一律走「真低模 GLB」，不用代码现搓几何体。
##
## 素材来源（唯一权威，别再从别处找）：
##   D:\AI\GodotProject\素材库\kenney_nature-kit   （树 / 灌木 / 岩石 / 草）
##   D:\AI\GodotProject\素材库\kenney_car-kit      （车）
##   已搬进项目的 res://models/nature/ 与 res://models/cars/
##
## 为什么需要这一层：
##   一棵 Kenney 树是个 GLB，内部有「树干 + 树冠」两个 MeshInstance3D、两个材质。
##   直接 instantiate 会变成散落的节点，摆 300 棵就是 600 个节点，编辑器卡顿、draw call 爆炸。
##   这里把「一棵树的所有部件」拆成 N 个变体组（每个组 = 一个 mesh + 一个材质），
##   每个组各自挂一个 MultiMeshInstance3D，摆 N 棵也只占 N 个节点，
##   而且**原配色完整保留**（不合并、不重写顶点色，省掉一整套顶点数组读写）。
##
## 低多边形风格的关键还有一件事：flat_shading（平面着色）。
##   每个三角面一个法线 → 硬朗的折面感，这是低多边形的灵魂；
##   关掉它是「平滑着色地形」，看着就是普通地形而不是 low poly。

## 读一个 GLB，拆成「部件变体」数组。
## 返回 [{ mesh: Mesh, material: Material, xform: Transform3D }, ...]
##   * mesh / material 是该部件本身的东西，不要改
##   * xform 是该部件相对 GLB 根节点的位置（摆放时已经含进去，调用方只管缩放旋转）
## 找不到 / 解析失败返回空数组，调用方自己兜底，绝不抛错（装饰挂了不该拖垮整张图）。
static func variants(glb_path: String) -> Array:
	var out: Array = []
	var packed: PackedScene = load(glb_path) as PackedScene
	if packed == null:
		push_warning("[lowpoly_props] 素材读不到：" + glb_path)
		return out

	var root: Node = packed.instantiate()
	if root == null:
		return out
	# 给一个确定的名字，实例化出来的根节点名字可能是 @Node@2 这种，日志不好读。
	# 注意：实例化出来的这棵树**不用 add_child** —— PackedScene.instantiate()
	# 返回的已经是结构完整的节点树，变换在 instantiate 时就算好了，
	# RefCounted 也没资格 add_child。
	root.name = "PropRoot"

	var acc: Transform3D = root.transform
	_collect(root, acc, out)
	return out


## 递归收集 MeshInstance3D。父节点的变换先累乘到子件上，
## 这样所有部件最终都相对「GLB 根节点」，摆放时不用再算层级。
static func _collect(node: Node, parent_xform: Transform3D, out: Array) -> void:
	for c in node.get_children():
		if c is MeshInstance3D:
			var mi: MeshInstance3D = c
			if mi.mesh == null:
				continue
			var xf: Transform3D = parent_xform * c.transform
			# 材质：优先自己身上的，取不到就往上找父节点的，还没有就给一个纯白兜底
			var m: Material = mi.material_override
			if m == null:
				var p: Node = c.get_parent()
				while p != null and m == null:
					if p is MeshInstance3D:
						m = (p as MeshInstance3D).material_override
					p = p.get_parent()
			if m == null:
				m = _fallback_mat()
			out.append({
				"mesh": mi.mesh,
				"material": m,
				"xform": xf,
			})
		else:
			_collect(c, parent_xform * c.transform, out)


## 装饰件材质：复制原材质，把颜色刷成给定色板。
##
## 【为什么必须给颜色，光用素材自带的 albedo 不行】
## 探针（Temp/vcprobe.gd）查过 Kenney nature-kit 这 13 个 GLB：
##   * 材质 albedo 全是 (1,1,1) 白，roughness 0.9，**没有任何顶点色通道**
##   （surface_get_format 里 COLOR 位不存在）。
##   颜色不是像想象中那样「烘在顶点色里」，而是根本不存在 ——
##   不刷色，所有树/草/石头在灰蒙蒙的天空下就是一片灰白，
##   看起来很像「素材没接上」，其实只是没给颜色。
## 原材质**不能就地改** —— 同一个 GLB 摆多处，改一处会连坐，一律 duplicate。
static func prop_material(source: Material, tint := Color(0.55, 0.55, 0.5), rough := 0.92) -> Material:
	if source == null:
		return _fallback_mat(tint)
	var m: Material = source.duplicate() as Material
	if m is StandardMaterial3D:
		var sm: StandardMaterial3D = m
		sm.vertex_color_use_as_albedo = true
		sm.albedo_color = tint
		sm.roughness = rough
		sm.metallic = 0.0
	return m


## 把一个「目标高度」换算成缩放系数。
## Kenney 的树原生只有 1.2~1.7m（真实比例的小树），1:1 摆进 2048m 的草原里
## 等于撒了一地把草 —— 所以一律先按目标高度归一，再乘随机系数。
static func fit_scale(mesh: Mesh, target_height: float) -> float:
	if mesh == null or target_height <= 0.0:
		return 1.0
	var aabb: AABB = mesh.get_aabb()
	var h: float = aabb.size.y
	var w: float = maxf(aabb.size.x, aabb.size.z)
	## 扁平素材（草地片 / 地皮）的 size.y ≈ 0，按高度归一会除出一个上千倍的缩放：
	## 一片 1200m 见方的平板横躺在地面上，直接把半个屏幕糊成灰墙。
	## 扁平件改按「边长」归一 —— 目标高度本身就是给它当目标长度的。
	if h < 0.25 and w > 0.05:
		return target_height / w
	return target_height / maxf(h, 0.25)


static func _fallback_mat(tint := Color(0.55, 0.55, 0.5)) -> Material:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 0.9
	m.vertex_color_use_as_albedo = true
	return m
