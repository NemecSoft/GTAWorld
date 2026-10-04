extends Node3D

## 城市外围地形 + 城内坡道（需求 #16：高低起伏的地形）。
##
## 方案沿用 scripts/world/terrain.gd（纳格兰图）验证过的内置分块高度场：
##   * 视觉：SurfaceTool 出 ArrayMesh，顶点色分层，卡通风不用贴图
##   * 碰撞：HeightMapShape3D 与视觉共用同一份高度数组采样点；
##     地图点距 1 米，靠 CollisionShape3D.scale=步长 撑到 4 米格距（详见 _add_chunk 注释）
##   * 前提是 Godot 内置物理 —— Jolt 后端会静默忽略 shape 缩放（详见 _add_chunk 注释）
## Terrain3D 插件在本机 4.7 上 Terrain3DStorage 注册失败，不可用（见 terrain.gd 头注）。
##
## 【和城市的共存规则】城市地面是 y=0 的 BoxShape（city_builder._build_ground，
## 半幅 198m，碰撞层 11）。城内建筑、马路、行人全部锁在 y≈0，所以：
##   * 切比雪夫距离 dc <= city_flat_half(205) 时高度恒为 -0.08 ——
##     地形整体沉在城市地面板底下 8cm，既不 z-fighting 也不抢碰撞；
##   * 205 → 300 是「城边坡道」过渡带，smoothstep 把自然高度抬出来，
##     开车出城会明显感觉上路开始起伏；
##   * 再往外是丘陵（fbm）、孤峰（butte）、外圈环形山脉、最外陡壁。
## 城内想要真正的坡道不能动地面（楼会飘），所以直接摆四段楔形坡道
## 在主干道上（x=±23 / z=±23），车可以开上去，视觉+凸包碰撞一体。
##
## 本脚本是全项目「城市地图高度」的唯一真值入口（ground_height），
## 植物贴地（#17）、以后的载具出生点都从这里取数，不要再写第二份。

const LowPolyProps := preload("res://scripts/world/lowpoly_props.gd")

@export_group("尺寸")
@export_range(1024.0, 2048.0, 128.0) var map_size: float = 1024.0
@export_range(128.0, 512.0, 64.0) var chunk_size: float = 256.0
@export_range(2.0, 16.0, 1.0) var step_size: float = 4.0
@export var seed_value: int = 20261003

@export_group("城市安全带")
## 切比雪夫半径内地形恒平（城市地面板半幅 198 + 7m 余量）
@export_range(198.0, 400.0, 1.0) var city_flat_half: float = 205.0
## 出了安全带后，再用这么长的过渡带把自然高度 smoothstep 抬满（= 城边坡道）
@export_range(20.0, 300.0, 5.0) var ramp_run: float = 95.0

@export_group("城外山岭")
## 【GUI 截图实录】24m 波高 / 280m 波长从地面视角看仍是「绿地毯」，
## 丘陵要看得见，振幅得 40m 起、波长压到 ~180m。
@export_range(0.0, 60.0, 1.0) var hill_height: float = 40.0
@export_range(0.0, 400.0, 10.0) var ridge_height: float = 260.0
## 环形山脉起始半径（360 起、470 满，正好贴着地图半幅 512 的内侧）
@export_range(100.0, 1024.0, 10.0) var ridge_radius: float = 360.0
@export_range(0.0, 40.0, 1.0) var butte_count: float = 14.0

@export_group("城内坡道（楔形，摆在主干道）")
@export_range(0.0, 4.0, 1.0) var city_ramps: float = 4.0
@export_range(0.6, 4.0, 0.1) var ramp_height: float = 1.6
@export_range(4.0, 20.0, 0.5) var ramp_len: float = 8.0
@export_range(3.0, 10.0, 0.5) var ramp_width: float = 5.0

@export_group("城外植被（需求 #17）")
@export_range(0, 800, 10) var tree_count: int = 260
@export_range(0, 800, 10) var bush_count: int = 220
@export_range(0, 1200, 20) var grass_count: int = 520
@export_range(0, 400, 10) var rock_count: int = 90
## 撒点环带：内圈贴着城边坡道尾（265），外圈到山脚（455）
@export_range(220.0, 500.0, 5.0) var prop_min_radius: float = 265.0
@export_range(280.0, 512.0, 5.0) var prop_max_radius: float = 455.0

## nature-kit 素材分组（和 terrain.gd 同一批文件，颜色由 prop_material 刷）
const TREE_GLBS: Array = [
	"res://models/nature/tree_default.glb",
	"res://models/nature/tree_oak.glb",
	"res://models/nature/tree_tall.glb",
	"res://models/nature/tree_pineDefaultA.glb",
	"res://models/nature/tree_blocks.glb",
	"res://models/nature/tree_cone.glb",
]
const BUSH_GLBS: Array = [
	"res://models/nature/plant_bushLarge.glb",
	"res://models/nature/plant_bush.glb",
]
const GRASS_GLBS: Array = [
	"res://models/nature/grass_large.glb",
	"res://models/nature/ground_grass.glb",
]
const ROCK_GLBS: Array = [
	"res://models/nature/cliff_rock.glb",
	"res://models/nature/cliff_half_rock.glb",
]

var _rng := RandomNumberGenerator.new()
var _buttes: Array = []
var _noise := FastNoiseLite.new()


func _ready() -> void:
	_noise.seed = seed_value
	_build()


func rebuild() -> void:
	_build()


## 全项目唯一的「城市地图地面高度」查询口（x, z 为世界坐标，返回 y 米）。
func ground_height(x: float, z: float) -> float:
	return _height_at(x, z)


# ------------------------------------------------------------------ 构建

func _build() -> void:
	var t0 := Time.get_ticks_msec()
	_rng.seed = seed_value
	_buttes = _make_buttes()
	for c in get_children():
		c.queue_free()
	_build_chunks()
	_build_city_ramps()
	_spawn_props()
	print("[urban_terrain] 建成 %d ms（块 %d²，孤峰 %d，坡道 %d）"
		% [Time.get_ticks_msec() - t0, int(map_size / chunk_size), _buttes.size(), int(city_ramps)])


func _make_buttes() -> Array:
	var out: Array = []
	for i in range(int(butte_count)):
		var a: float = _rng.randf() * TAU
		# 只在城边坡道之后（dc>300）、环形山脉之前（r<430）的环带立孤峰
		var rr: float = 320.0 + _rng.randf() * 90.0
		out.append({
			"x": cos(a) * rr,
			"z": sin(a) * rr,
			"r": 18.0 + _rng.randf() * 28.0,
			"h": 22.0 + _rng.randf() * 34.0,
			"flat": 0.25 + _rng.randf() * 0.18,
		})
	# 地标巨岩：固定方位，给玩家一个「朝那个方向开就出城」的参照
	var la: float = -0.7
	out.append({
		"x": cos(la) * 390.0,
		"z": sin(la) * 390.0,
		"r": 80.0,
		"h": 110.0,
		"flat": 0.45,
	})
	return out


func _build_chunks() -> void:
	var n: int = maxi(int(map_size / chunk_size), 1)
	var half: float = map_size * 0.5
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	## 碰撞层抄 city_builder._build_ground：layer 11 / mask 9，
	## 车的球（mask 含 bit1）和行人（mask 11）都天然踩得到。
	body.collision_layer = 11
	body.collision_mask = 9
	add_child(body)
	for cz in range(n):
		for cx in range(n):
			_add_chunk(cx, cz, n, half, body)


## 一块 256m 的网格：高度先算一遍存进 PackedFloat32Array，
## 视觉顶点和碰撞地图读同一份 —— 省一半 _height_at，且绝不对不齐。
func _add_chunk(cx: int, cz: int, n: int, half: float, body: StaticBody3D) -> void:
	var x0: float = -half + float(cx) * chunk_size
	var z0: float = -half + float(cz) * chunk_size
	var seg: int = maxi(int(chunk_size / maxf(step_size, 1.0)), 2)
	var step: float = chunk_size / float(seg)
	var mid_x: float = x0 + chunk_size * 0.5
	var mid_z: float = z0 + chunk_size * 0.5
	var stride: int = seg + 1

	var data := PackedFloat32Array()
	data.resize(stride * stride)
	for j in range(stride):
		for i in range(stride):
			data[j * stride + i] = _height_at(x0 + float(i) * step, z0 + float(j) * step)

	# ---- 视觉 ----
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(stride):
		for i in range(stride):
			var y: float = data[j * stride + i]
			st.set_color(_tint_at(y, x0 + float(i) * step, z0 + float(j) * step))
			st.set_uv(Vector2(float(i), float(j)) / float(seg))
			st.add_vertex(Vector3(x0 + float(i) * step, y, z0 + float(j) * step))
	for j in range(seg):
		for i in range(seg):
			var a: int = j * stride + i
			var b: int = a + 1
			var c: int = a + stride
			var d: int = c + 1
			## 【绕序 = 命】Godot 规定顺时针为正面：实测 terrain.gd 抄来的
			## (a,c,b) 顺序 generate_normals 出 -Y 法线，网格整个内侧翻 ——
			## 从上往下的射线和落球全部穿模（两个物理后端都一样）。
			## (a,b,c)+(b,d,c) 才是法线朝上、可碰撞的正面。
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(b)
			st.add_index(d)
			st.add_index(c)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "TerrainChunk_%d_%d" % [cx, cz]
	mi.mesh = st.commit()
	mi.material_override = _terrain_mat()
	add_child(mi)

	# ---- 碰撞：同一份 data 直接塞 HeightMapShape3D ----
	## 【坑位实录 2026-10-03】两条路都试过：
	##   * create_trimesh_shape()：射线能命中，但刚体接触会穿模（球一路陷进
	##     山体 15m），凹面网格本来就不该当可移动物体的地面用；
	##   * HeightMapShape3D：地图 extent 恒为 1×1，靠下面 CollisionShape3D.scale
	##     撑开 —— 这只在 Godot 内置物理上成立，Jolt 后端会静默忽略缩放
	##     （project.godot 已因此切回 GodotPhysics3D）。
	var hs := HeightMapShape3D.new()
	hs.map_width = stride
	hs.map_depth = stride
	hs.map_data = data
	## 【本机实测 2026-10-03】65×65 地图的点距是 1 米（extent = map_width 米，
	## 不是 terrain.gd 头注里说的恒为 1×1 —— 那句是错的）。
	## 想要 4 米格距就把 CollisionShape3D.scale 写成**步长**：
	## scale=chunk_size(256) 时整张图撑到 16km，全城被罩在 400m 高的巨_sheet_ 底下。
	## 采样点从 -stride/2 到 +stride/2 排布，shape 摆在块中心后恰好对齐 x0..x0+256。
	var cs := CollisionShape3D.new()
	cs.shape = hs
	cs.scale = Vector3(step, 1.0, step)
	cs.position = Vector3(mid_x, 0.0, mid_z)
	body.add_child(cs)


## 城内坡道：四段楔形摆在主干道（路中心线 x=±23 / z=±23，city_builder 的 PERIOD 公式）。
## 摆位都离路口远、离路口近无所谓 —— 坡宽 5m < 路宽 12m，车可以从旁边绕。
func _build_city_ramps() -> void:
	if int(city_ramps) <= 0:
		return
	## CollisionShape3D 只有装在 Body 里才生效 —— 直接挂 Node3D 是静默失效的老坑
	var ramps := StaticBody3D.new()
	ramps.name = "CityRamps"
	ramps.collision_layer = 11
	ramps.collision_mask = 9
	add_child(ramps)
	# (坡底位置, 爬升朝向 yaw)：yaw 是绕 Y 的角，局部 +z 为爬升方向
	var layout: Array = [
		[Vector3(23.0, -0.05, 70.0), 0.0],          # 竖路 x=23，往 +z 爬
		[Vector3(-23.0, -0.05, -70.0), PI],         # 竖路 x=-23，往 -z 爬
		[Vector3(70.0, -0.05, 23.0), PI * 0.5],     # 横路 z=23，往 +x 爬
		[Vector3(-70.0, -0.05, -23.0), -PI * 0.5],  # 横路 z=-23，往 -x 爬
	]
	for i in range(mini(int(city_ramps), layout.size())):
		_add_wedge(ramps, "Ramp%d" % i, layout[i][0], layout[i][1])


func _add_wedge(root: Node3D, name: String, base: Vector3, yaw: float) -> void:
	var L: float = ramp_len
	var H: float = ramp_height
	var W: float = ramp_width
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 局部坐标：低沿在 z=0，高沿在 z=L；底面 y=0（整块下沉 0.05 贴进路面）
	var vs: PackedVector3Array = [
		Vector3(-W * 0.5, 0.0, 0.0), Vector3(W * 0.5, 0.0, 0.0),
		Vector3(W * 0.5, 0.0, L), Vector3(-W * 0.5, 0.0, L),
		Vector3(-W * 0.5, H, L), Vector3(W * 0.5, H, L),
	]
	# 底(2) / 后背(2) / 斜面(2) / 左三角(1) / 右三角(1)
	var tris: Array = [
		[0, 1, 2], [0, 2, 3],
		[3, 2, 5], [3, 5, 4],
		[0, 1, 5], [0, 5, 4],
		[0, 3, 4],
		[1, 2, 5],
	]
	for t in tris:
		for k in range(3):
			st.add_vertex(vs[int(t[k])])
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()

	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.material_override = _concrete_mat()
	mi.transform = Transform3D(Basis(Vector3.UP, yaw), base)
	root.add_child(mi)

	var cs := CollisionShape3D.new()
	cs.name = name + "Col"
	## 楔形是凸体，create_convex_shape 就够，比凹面网格便宜得多
	cs.shape = mesh.create_convex_shape()
	cs.transform = mi.transform
	root.add_child(cs)


# ------------------------------------------------------------------ 城外植被（#17）
## 抄 scripts/world/terrain.gd 的 MultiMesh 撒点模式（同一批 Kenney nature-kit），
## 两处不同：
##   1. 落点走本图的环形带 + 本脚本的 _height_at（唯一真值，树和地形永不脱节）；
##   2. tint 真的传进 prop_material —— terrain.gd 的 _spawn_kind 压根没把
##      TINT_* 常量传下去，纳格兰的树全渲成默认灰（那边远景将就，近景不行）。
## v1.5：树/岩石按 solid 参数挂实体碰撞（用户反馈「给物体做好碰撞」）；
##      灌木/草仍是纯视觉零碰撞（小件挂碰撞只会莫名其妙绊住车）。

const CLUMP := 3
const CLUMP_R := 8.0


func _spawn_props() -> void:
	if tree_count + bush_count + grass_count + rock_count <= 0:
		return
	var props := Node3D.new()
	props.name = "Props"
	add_child(props)
	_spawn_kind(props, "Trees", TREE_GLBS, tree_count, 7.0, _srgb8(74, 122, 68), "tree")
	## 【GUI 截图实录】灌木/草沿用纳格兰那组深绿时，在开阔草地上渲成黑斑。
	## 撒在阳光平地上的小件要比地形底色亮一档才分得开。
	_spawn_kind(props, "Bushes", BUSH_GLBS, bush_count, 1.7, _srgb8(126, 172, 92))
	_spawn_kind(props, "Grass", GRASS_GLBS, grass_count, 1.1, _srgb8(162, 190, 100))
	_spawn_kind(props, "Rocks", ROCK_GLBS, rock_count, 2.6, _srgb8(132, 124, 108), "rock")


## 撒点：环形带 [prop_min_radius, prop_max_radius] 内随机；
## 抽 20 次全失败返回 ZERO（调用方见原点即收工，不空转）。
func _pick_spot() -> Vector2:
	for _i in range(20):
		var a: float = _rng.randf() * TAU
		var r: float = prop_min_radius + _rng.randf() * maxf(prop_max_radius - prop_min_radius, 1.0)
		var x: float = cos(a) * r
		var z: float = sin(a) * r
		# 城市安全带里不摆（地面在 -0.08，树会插进马路底板）
		if maxf(absf(x), absf(z)) <= city_flat_half + 8.0:
			continue
		# 陡坡不摆：6m 采样高差 >4.5m（约 37°）以上，树歪草穿帮
		var g0: float = _height_at(x, z)
		if absf(_height_at(x + 6.0, z) - g0) > 4.5 or absf(_height_at(x, z + 6.0) - g0) > 4.5:
			continue
		return Vector2(x, z)
	return Vector2.ZERO


func _spawn_kind(root: Node3D, node_name: String, paths: Array, count: int, target_h: float, tint: Color, solid: String = "") -> void:
	if count <= 0 or paths.is_empty():
		return
	var buckets: Array = []
	var bucket_owner: Array = []
	var bucket_scale: Array = []
	var bucket_ground: Array = []
	for p in paths:
		var vs: Array = LowPolyProps.variants(p)
		var bottom: float = 99999.0
		for v in vs:
			bottom = minf(bottom, float(v["xform"].origin.y))
		for v in vs:
			bucket_owner.append(v)
			buckets.append([])
			bucket_scale.append(LowPolyProps.fit_scale(v["mesh"], target_h))
			bucket_ground.append(bottom)

	var placed: int = 0
	var guard: int = 0
	var col_pts: Array = []   # solid != "" 时收集 (落点, 缩放)，摆完挂实体碰撞
	while placed < count and guard < count * 4:
		guard += 1
		var spot := _pick_spot()
		if spot == Vector2.ZERO:
			break
		var per: int = 1 + int(_rng.randi() % maxi(CLUMP, 1))
		for k in range(per):
			if placed >= count:
				break
			var x: float = spot.x + _rng.randf_range(-CLUMP_R, CLUMP_R)
			var z: float = spot.y + _rng.randf_range(-CLUMP_R, CLUMP_R)
			var bi: int = int(_rng.randi() % bucket_owner.size())
			var v: Dictionary = bucket_owner[bi]
			var xf: Transform3D = v["xform"]
			var s: float = float(bucket_scale[bi]) * (0.78 + _rng.randf() * 0.5)
			var rot := Basis.IDENTITY.rotated(Vector3.UP, _rng.randf() * TAU)
			var gy: float = _height_at(x, z)
			## 贴地三件套：部件偏移乘缩放 s、减模型底 bottom、加地面高 gy。
			## 少乘 s → 树冠塌地；不减 bottom → 整株浮空（terrain.gd 同款坑）。
			var g: float = float(bucket_ground[bi])
			buckets[bi].append(Transform3D(rot.scaled(Vector3(s, s, s)),
				Vector3(x + xf.origin.x * s, gy + (xf.origin.y - g) * s, z + xf.origin.z * s)))
			if solid != "":
				col_pts.append([Vector3(x, gy, z), s])
			placed += 1

	for i in range(buckets.size()):
		if buckets[i].is_empty():
			continue
		var v2: Dictionary = bucket_owner[i]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = v2["mesh"]
		mm.instance_count = (buckets[i] as Array).size()
		for j in range(mm.instance_count):
			mm.set_instance_transform(j, buckets[i][j])
		var mi := MultiMeshInstance3D.new()
		mi.name = node_name + str(i)
		mi.multimesh = mm
		mi.material_override = LowPolyProps.prop_material(v2["material"], tint)
		root.add_child(mi)
	if solid != "" and not col_pts.is_empty():
		var body := StaticBody3D.new()
		body.name = node_name + "Cols"
		body.collision_layer = 11
		body.collision_mask = 9
		for pt in col_pts:
			var p: Vector3 = pt[0]
			var s2: float = float(pt[1])
			var cs := CollisionShape3D.new()
			if solid == "rock":
				var sph := SphereShape3D.new()
				sph.radius = 1.0 * s2
				cs.shape = sph
				cs.position = Vector3(p.x, p.y + 0.35 * s2, p.z)
			else:
				var cyl := CylinderShape3D.new()
				cyl.radius = 0.45
				cyl.height = 3.0
				cs.shape = cyl
				cs.position = Vector3(p.x, p.y + 1.5, p.z)
			body.add_child(cs)
		root.add_child(body)
	print("[urban_terrain] 植被 %s 摆了 %d 件" % [node_name, placed])


# ------------------------------------------------------------------ 高度真值

## 唯一高度实现（理由见文件头；第二份实现 = 「树浮空/车陷地」的开始）。
func _height_at(x: float, z: float) -> float:
	var dc: float = maxf(absf(x), absf(z))
	if dc <= city_flat_half:
		return -0.08
	var r: float = sqrt(x * x + z * z)
	# 丘陵：两层 fbm，粗波 + 细波；负半轴压平，草原只鼓不陷。
	## 【GUI 截图实录】原频率 0.0016（波长 ~625m）在 1024m 地图上渲不成「丘」，
	## 城外 300~430 环带看着是一整张绿地毯。×2.2 后波长 ~280m，开车能看见浪。
	var h: float = _fbm2(x * 3.4, z * 3.4) * hill_height + _fbm2(x * 8.8, z * 8.8) * hill_height * 0.3
	h = maxf(h, 0.0)
	# 孤峰（含地标巨岩）
	h += _peaks(_buttes, x, z)
	# 外圈环形山脉：一整圈天然墙，把车关在盆地里。
	## 高度乘低频噪声出峰谷 —— 不乘就是一条等高的光滑圆弧，像碗不像山。
	if r > ridge_radius:
		var kr: float = smoothstep(ridge_radius, ridge_radius + 110.0, r)
		var ridge_n: float = 0.5 + 0.5 * (_fbm2(x * 1.9, z * 1.9) * 0.5 + 0.5)
		h += kr * kr * ridge_height * ridge_n
	# 最外陡壁：防止开出地图看到虚空。
	## 【GUI 截图实录】壁脚不能早于 452：曾写 smoothstep(292,452)，
	## 结果 300~430 的「可驾驶丘陵」底下藏了 55m 壁高，车一出城就顺壁滑 11m。
	## 现在 468 起、506 满，卡在地图半幅 512 内侧，被环形山脉挡在身后。
	## 高度再乘一层低频噪声：不然从城里看是一整个光滑白色圆顶，不像山脉。
	var wall: float = smoothstep(map_size * 0.5 - 44.0, map_size * 0.5 - 6.0, r)
	h += wall * wall * 420.0 * (0.72 + 0.28 * (_fbm2(x * 3.1, z * 3.1) * 0.5 + 0.5))
	# 过渡带：从城边开始把整段自然高度 smoothstep 抬出来（= 城外坡道）
	var t: float = smoothstep(city_flat_half, city_flat_half + ramp_run, dc)
	return lerpf(-0.08, h, t)


## 四层 fbm，返回约 -1..1（照抄 terrain.gd 的采样系数，本机验证过的波形）。
func _fbm2(x: float, z: float) -> float:
	var v: float = 0.0
	var amp: float = 1.0
	var sum: float = 0.0
	var f: float = 1.0
	for _i in range(4):
		v += _noise.get_noise_2d(x * f * 0.0016, z * f * 0.0016) * amp
		sum += amp
		amp *= 0.5
		f *= 2.0
	return v / maxf(sum, 0.0001)


## 孤峰叠加：pow(k, flat) 的「宽底圆肩」，k 从圆心 1 掉到边缘 0。
func _peaks(list: Array, x: float, z: float) -> float:
	var h: float = 0.0
	for p in list:
		var dx: float = x - float(p["x"])
		var dz: float = z - float(p["z"])
		var d: float = sqrt(dx * dx + dz * dz)
		var rr: float = float(p["r"])
		if d >= rr:
			continue
		h += float(p["h"]) * pow(1.0 - d / rr, float(p["flat"]))
	return h


# ------------------------------------------------------------------ 材质/配色

## 顶点色分层：草绿 → 岩灰 → 山顶浅岩，色阶边界拿噪声打散。
## 【GUI 截图实录】Color8 直接喂 SurfaceTool.set_color 会被当**线性值**：
## sRGB 104 的"草绿"渲出来是 168 的淡薄荷，整张地形像被水洗过。
## 必须先 sRGB→线性 再喂，渲出来才是肉眼要的数。
func _tint_at(y: float, x: float, z: float) -> Color:
	var grass := _srgb8(104, 138, 66)
	var dry := _srgb8(140, 150, 84)
	var rock := _srgb8(136, 126, 108)
	var c: Color = grass.lerp(dry, smoothstep(0.0, 8.0, y))
	c = c.lerp(rock, smoothstep(22.0, 60.0, y))
	## 山顶色不能太亮：GUI 实测 (178,172,160) 在阳光+冷环境光+glow 下渲成
	## 一坨「白云」，整个远山像棉球。压到岩灰偏暖才像石头。
	c = c.lerp(_srgb8(148, 140, 126), smoothstep(120.0, 240.0, y))
	return c.lerp(grass, _fbm2(x * 0.06, z * 0.06) * 0.10 + 0.05)


## sRGB 字节值 → 线性 Color（Godot 4 渲染管线内部走线性空间）
static func _srgb8(r: int, g: int, b: int) -> Color:
	return Color(_srgb1(r / 255.0), _srgb1(g / 255.0), _srgb1(b / 255.0))


static func _srgb1(v: float) -> float:
	if v <= 0.04045:
		return v / 12.92
	return pow((v + 0.055) / 1.055, 2.4)


func _terrain_mat() -> Material:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	m.metallic = 0.0
	return m


func _concrete_mat() -> Material:
	var m := StandardMaterial3D.new()
	m.albedo_color = _srgb8(148, 146, 138)
	m.roughness = 0.9
	m.metallic = 0.0
	return m
