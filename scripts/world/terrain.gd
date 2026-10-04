extends Node3D

## 低模素材装载器：把 Kenney GLB 拆成「部件变体」，供 MultiMesh 批量画。
## 装饰件（树/灌木/草/岩石/浮空岛）一律走它，禁止用 CylinderMesh/SphereMesh 现搓几何体。
const LowPolyProps := preload("res://scripts/world/lowpoly_props.gd")

## 纳格兰式草原地形 —— 真高度场，分块构建，视觉网格与碰撞共用同一点阵。
##
## 业界方案对比（2026-10 调研，务必看一眼再改这里）：
##   * Terrain3D（TokisanGames，MIT，GDExtension，业界事实标准）→ **本项目用不了**。
##     实测：v1.0.2-stable 在 Godot 4.7 上，`Terrain3D` 节点能实例化，
##     但核心类 `Terrain3DStorage` 在 4.7 上注册失败（ClassDB 报 Cannot get class），
##     没有 Storage 就建不出 region / 高度图，等于整个插件废掉。
##     官方 release 也只声明支持 4.4-4.6+。
##   * TerraBrush（spimort，GDExtension，4.5+）同理，4.7 二进制未知。
##   * Godot 内置方案：分块高度场 + `HeightMapShape3D`（4.7 属性是
##     `map_width` / `map_depth` / **`map_data`**，不是老版本的 `height_map`）。
##     零依赖、4.7 稳、对「车在坡上跑」这种需求完全够，本项目采用这条。
##
## 分块结构：整图 map_size × map_size，切成 (map_size / chunk_size)² 块，
## 每块 XZ 256m、点阵 65×65、格距 4m：
##   * 视觉：SurfaceTool 出 ArrayMesh（顶点色分层，卡通风不用贴图）
##   * 碰撞：HeightMapShape3D 65×65 + CollisionShape3D.scale=(256,1,256)
##            —— HeightMapShape3D 的地图永远是 1×1 的 extent，靠 shape 缩放撑开
## 关键对齐：碰撞采样点与视觉顶点落在**同一个世界坐标点**上
##   （shape 原点摆在 chunk 中心、采样点从 chunk 起点起算、格距 = chunk/(n-1)），
##   所以不会出现「看起来贴地、物理却浮空 2m」这种经典 bug。
##
## 地貌四层（全部是 _height_at 里的纯函数，分块之间天然无缝）：
##   1. 大尺度波浪 + fbm          草原绵延起伏
##   2. 岩石台地 mesa / 孤峰 butte 「平顶 + 陡肩」，pow(k, flat)，flat 越小顶越平
##   3. 外圈环形山脉               一圈天然墙，把车关在盆地里
##   4. 最外陡壁                   防止开出地图看到虚空

@export_group("尺寸")
@export_range(512.0, 4096.0, 256.0) var map_size: float = 2048.0
## 单块边长（米）。HeightMapShape3D 地图边长 = chunk_size / step + 1
@export_range(128.0, 512.0, 64.0) var chunk_size: float = 256.0
## 视觉 / 碰撞共用的格距（米）。越小越精细，生成越慢
@export_range(2.0, 16.0, 1.0) var step_size: float = 4.0
@export var seed_value: int = 20261003

@export_group("地貌（半径从中心往外算）")
## 中心平坦草原半径：这个圈内起伏被压到接近 0，一进场就是一整片平整草坪
@export_range(0.0, 900.0, 20.0) var plain_radius: float = 220.0
## 过了这个半径开始抬外圈山脉
@export_range(100.0, 1200.0, 20.0) var ridge_radius: float = 660.0
@export_range(0.0, 400.0, 10.0) var ridge_height: float = 190.0
## 丘陵整体幅度
@export_range(0.0, 80.0, 1.0) var hill_height: float = 26.0
## 高原基准抬升（米）：草原 y=0 起步，到山脉脚下整体抬高多少
@export_range(0.0, 200.0, 5.0) var plateau_rise: float = 70.0
## 全图都有的草皮细起伏（中心也保留，开起来有点颠）
@export_range(0.0, 30.0, 0.5) var micro_swell: float = 1.6
@export_range(0.0, 80.0, 1.0) var mesa_count: float = 26.0
@export_range(0.0, 60.0, 1.0) var butte_count: float = 22.0

@export_group("材质")
@export var grass_material: Material = null
@export var rock_material: Material = null
@export var tree_scene: PackedScene = null

@export_group("装饰（全部来自素材库低模 GLB）")
@export_range(0, 1600, 20) var tree_count: int = 420
@export_range(0, 1600, 20) var grass_count: int = 1400
@export_range(0, 800, 20) var rock_count: int = 160
@export_range(0, 60, 1) var float_rock_count: int = 14
@export_range(0, 12, 1) var aurora_count: int = 4
## 装饰离中心多远开始放（出生点留白，车一出生不至于直接穿林子）
@export_range(0.0, 900.0, 10.0) var prop_min_radius: float = 26.0
## 装饰撒点外圈半径。
## 【别撒到山脚下】曾经这里跟着地图半径走（≈590m），420 件摊在 110 万平方米上，
## 车头前 60 米内只剩一两棵 —— 截图里一棵树都看不见，看起来像「装饰没生效」。
## 纳格兰是「近处有草有树、远处是山」，外圈收到 320m 才有近景密度。
@export_range(80.0, 900.0, 20.0) var prop_radius: float = 320.0
## 成簇：每处撒 1~clump 件、彼此相距 ±clump_radius 米。
## 均匀乱撒没有节奏（要么空要么挤），成簇才有疏密对比，同屏密度也上得去。
@export_range(1, 8, 1) var clump: int = 3
@export_range(2.0, 40.0, 1.0) var clump_radius: float = 14.0
## 装饰「目标高度」（米）。Kenney 的树原生只有 1~1.7m，直接 1:1 摆进 2048m 的草原
## 就是撒了一地把草，所以按目标高度统一归一，再乘随机系数。
@export_range(1.0, 30.0, 0.5) var tree_height: float = 8.0
@export_range(0.3, 8.0, 0.1) var bush_height: float = 1.8
@export_range(0.3, 8.0, 0.1) var grass_height: float = 1.2
@export_range(0.5, 20.0, 0.5) var rock_height: float = 4.0

## 装饰配色（线性空间，引擎会把它们当 sRGB 自己转）。
## 素材自带的 albedo 是纯白、也没有顶点色（见 scripts/world/lowpoly_props.gd），
## 颜色 100% 由这里决定。纳格兰是「深绿树 + 干黄草 + 暖灰岩」，这套是照着那片草原调的。
## 用 Color8 直接按「肉眼 sRGB」调，别写 0.0~1.0 的线性值：
## 线性 0.16 看着是「很暗的绿」，实际渲染出来比调色时暗一大截（第一版就是这么翻车的）。
const TINT_TREE := Color8(74, 122, 68)
const TINT_BUSH := Color8(88, 132, 62)
const TINT_GRASS := Color8(138, 156, 78)
const TINT_ROCK := Color8(122, 114, 98)

## 素材库（D:\AI\GodotProject\素材库\kenney_nature-kit）搬进项目的那一份。
## 想加新树/新岩石就往对应的数组里塞一行，别的都不用动。
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
	"res://models/nature/cliff_large_rock.glb",
]
## 浮空岛：上面盖草皮、下面坠岩石
const FLAT_GRASS_GLB: String = "res://models/nature/ground_grass.glb"
const FLAT_ROCK_GLB: String = "res://models/nature/cliff_large_rock.glb"

const CHUNK_N := 8

var _rng := RandomNumberGenerator.new()
var _mesas: Array = []
var _buttes: Array = []
var _built: bool = false
var _noise := FastNoiseLite.new()


func _ready() -> void:
	_noise.seed = seed_value
	_noise.frequency = 0.0016
	_build()
	# 车比地形晚一步 _ready（场景里 Terrain 排在 Vehicle 前面），
	# 所以落地这件事推到下一帧再做，那时 group 里的车已经注册好了
	call_deferred("_place_vehicles")


## 让 tools/ 下的探针能反复重算（改了幅度想立刻看效果就调它）
func rebuild() -> void:
	_build()
	call_deferred("_place_vehicles")


## 把玩家车丢到「地面 + 一个球半径」的高度。
## vehicle.gd 每帧覆写水平速度，物理不该把车吊在半空 —— 出生高度就是最终高度，
## 少了这一步，起步时车会悬在地形之上或者陷进坡里。
func _place_vehicles() -> void:
	for v in get_tree().get_nodes_in_group("player"):
		var sphere: RigidBody3D = v.get_node_or_null("Sphere")
		if sphere == null:
			continue
		var g: float = _height_at(sphere.position.x, sphere.position.z)
		sphere.position.y = g + 0.5
		sphere.linear_velocity = Vector3.ZERO
		sphere.force_update_transform()


# ------------------------------------------------------------------ 构建

func _build() -> void:
	var t0 := Time.get_ticks_msec()
	_rng.seed = seed_value
	_mesas = _make_mesas()
	_buttes = _make_buttes()
	for c in get_children():
		c.queue_free()
	_build_chunks()
	_spawn_props()
	_spawn_aurora()
	_built = true
	print("[terrain] 纳格兰生成完成 %d ms，块 %d，节点 %d"
		% [Time.get_ticks_msec() - t0, int(map_size / chunk_size) * int(map_size / chunk_size), get_child_count()])


func _make_mesas() -> Array:
	var out: Array = []
	var span: float = maxf(plain_radius + 80.0, ridge_radius * 0.68)
	for i in range(int(mesa_count)):
		var a: float = _rng.randf() * TAU
		var rr: float = plain_radius * 0.55 + _rng.randf() * span
		out.append({
			"x": cos(a) * rr,
			"z": sin(a) * rr,
			"r": 34.0 + _rng.randf() * 62.0,
			"h": 14.0 + _rng.randf() * 40.0,
			"flat": 0.24 + _rng.randf() * 0.16,
		})
	return out


func _make_buttes() -> Array:
	var out: Array = []
	var span: float = maxf(plain_radius * 0.4, ridge_radius * 0.62)
	for i in range(int(butte_count)):
		var a: float = _rng.randf() * TAU
		var rr: float = 120.0 + _rng.randf() * span
		out.append({
			"x": cos(a) * rr,
			"z": sin(a) * rr,
			# 纳格兰的孤峰是「宽底 + 圆肩」，不是针状圆锥 —— 底部要撑得开，
			# 顶上再叠一层碎石，远看才像那种被风蚀过的巨岩
			"r": 18.0 + _rng.randf() * 34.0,
			"h": 34.0 + _rng.randf() * 62.0,
			"flat": 0.22 + _rng.randf() * 0.18,
		})
	# 地标：地图里那块公认的巨岩（对应纳格兰远景中央的尖峰），给玩家一个方位参照
	out.append({
		"x": cos(-0.7) * (plain_radius + 210.0),
		"z": sin(-0.7) * (plain_radius + 210.0),
		"r": 165.0,
		"h": 250.0,
		"flat": 0.55,
	})
	return out


## 地形本体换成 Terrain3D（连续高度场 + 自带 LOD + 内置碰撞 + 材质 splat）。
##
## 原来这套是「chunk_size 的 HeightMapShape3D 网格块」拼出来的，问题在：
##   * 块与块之间要凑齐接缝，边界法线/颜色对不上，大地图一远看就有网格纹；
##   * 碰撞是每段单独烘，块多了物理开销翻倍；
##   * 没有 LOD，800m 外还是满密网格。
## Terrain3D 一次给一张 2048² 的高度图 + clipmap LOD + 运行时 trimesh 碰撞，
## 装饰（下面那些 MultiMesh 低模树/草/岩）完全不动，还是走 _height_at() 摆。
##
## 高度图约定（跟 Terrain3D 的 HEIGHT_DATA 对齐）：
##   单通道 float（FORMAT_RF），存的是**归一化到 0..1 的高度**，
##   真正的米数由 import_images() 最后那个 height_scale 乘回去。
##   存归一化而不是存米，是为了跟官方 demo 的写法一致，也避免大高度值在
##   8 位通道里被量化成台阶。
func _build_chunks() -> void:
	var half: float = map_size * 0.5
	## 1 像素 = 4 米：2048m 图 -> 512² = 26 万次 _height_at，单趟两三秒。
	## （上一版写成 1 像素 1 米 = 420 万次，GDScript 要跑十几秒，卡在加载画面上）
	## 想更锐就把这个除数调小；地形是低频丘陵，4m/px 肉眼看不出台阶。
	var res: int = int(clampf(map_size / 4.0, 64.0, 1024.0))
	var img := Image.create_empty(res, res, false, Image.FORMAT_RF)

	# 最大高度：所有地形特征都不超过它，用它做归一化基准
	var span: float = ridge_height + plateau_rise + hill_height * 3.0 + micro_swell * 4.0
	var inv: float = 1.0 / maxf(span, 1.0)

	for j in range(res):
		var z: float = -half + map_size * float(j) / float(res - 1)
		for i in range(res):
			var x: float = -half + map_size * float(i) / float(res - 1)
			img.set_pixel(i, j, Color(_height_at(x, z) * inv, 0.0, 0.0, 1.0))

	var t := Terrain3D.new()
	if t == null:
		push_error("[terrain] Terrain3D 扩展没加载，退回内置分块高度场")
		_build_chunks_builtin()
		return
	## 【本 build 的硬事实】Terrain3DStorage 这个 class 没注册、Terrain3D 也没有 set_data，
	## 所以运行时拿不到可用的 data，import_images 必然是 null 调用 —— 直接回退，别硬刷。
	if t.data == null:
		push_warning("[terrain] Terrain3D.data 为 null（本 build 无 Terrain3DStorage），回退内置分块高度场")
		_build_chunks_builtin()
		return
	t.name = "Terrain3D"
	## region_size = 图片分辨率的整数倍分之一：2048 图 / region 1024 = 2×2 个 region
	t.region_size = 1024
	t.data.import_images([img, null, null], Vector3(-half, 0.0, -half), 0.0, span)

	# 碰撞：DYNAMIC_2D = 运行时按高度场现算 trimesh，开车/射线都能踩到
	## （注意是 terrain.collision_mode 属性，不是 collision.mode —— 后者在 4.7 上不存在）
	t.collision_mode = Terrain3DCollision.DYNAMIC_GAME
	t.collision_layer = 0xFFFFFFFF
	t.collision_mask = 0xFFFFFFFF

	# 材质：auto_shader 按高度/坡度自动混层，但颜色来自下面挂上去的 splat 贴图
	t.material.auto_shader = true
	t.material.set_shader_param("auto_slope", 14.0)
	t.material.set_shader_param("blend_sharpness", 0.55)

	add_child(t, true)
	_t3d_textures(t, span)
	print("[terrain] Terrain3D 高度图 %dx%d，region 1024，覆盖 %0.0f m，最大高 %0.0f m"
		% [res, res, map_size, span])


## 给 Terrain3D 挂两层 splat 贴图（草 + 岩），让 auto_shader 画出来的是
## 纳格兰的干燥草原而不是出一版默认绿草地。
##
## 贴图是这样炼出来的：Gradient 定色 + FastNoiseLite 出噪声 -> NoiseTexture2D
## 烘成 albedo（颜色）/ normal（噪声当高度算出来的法线）/ rough（A 通道写粗糙度），
## 三层打包成一个 Terrain3DTextureAsset 塞进 terrain.assets。
## 官方 demo 也是这么干的 —— auto_shader 只是决定「什么时候显示哪一层」，
## 层里长什么样完全由这些贴图说了算。
func _t3d_textures(t: Terrain3D, span: float) -> void:
	# 0 号槽 = 低处（草），1 号槽 = 高处/陡坡（岩石）
	var grass_asset := _t3d_texture_asset("Grass", Color8(104, 138, 66), Color8(140, 156, 82), 0.06)
	var rock_asset := _t3d_texture_asset("Rock", Color8(136, 126, 108), Color8(156, 150, 138), 0.04)

	var assets := Terrain3DAssets.new()
	assets.set_texture(0, grass_asset)
	assets.set_texture(1, rock_asset)
	t.assets = assets


func _t3d_texture_asset(name: String, c0: Color, c1: Color, uv_scale: float) -> Terrain3DTextureAsset:
	var fnl := FastNoiseLite.new()
	fnl.frequency = 0.006

	var ramp := Gradient.new()
	ramp.set_color(0, c0)
	ramp.set_color(1, c1)

	var alb_tex := NoiseTexture2D.new()
	alb_tex.width = 512
	alb_tex.height = 512
	alb_tex.seamless = true
	alb_tex.noise = fnl
	alb_tex.color_ramp = ramp
	var alb: Image = alb_tex.get_image()

	# 法线：拿同一份噪声当高度场求导 -> 转成切线空间法线；粗糙度塞 A 通道
	var nrm_tex := NoiseTexture2D.new()
	nrm_tex.width = 512
	nrm_tex.height = 512
	nrm_tex.seamless = true
	nrm_tex.noise = fnl
	nrm_tex.as_normal_map = true
	var nrm: Image = nrm_tex.get_image()
	for x in nrm.get_width():
		for y in nrm.get_height():
			var clr: Color = nrm.get_pixel(x, y)
			clr.a = 0.85
			nrm.set_pixel(x, y, clr)

	var asset := Terrain3DTextureAsset.new()
	asset.name = name
	asset.uv_scale = uv_scale
	asset.albedo_texture = ImageTexture.create_from_image(alb)
	asset.normal_texture = ImageTexture.create_from_image(nrm)
	return asset

# ------------------------------------------------------------------ 装饰层

## 全图唯一的高度真值。
##
## 【为什么全项目只能有这一个实现】
## Terrain3D 的高度图、低模装饰的贴地、车辆的出生高度，三处都从这里取数。
## 一旦出现第二份（比如视觉用解析式、碰撞用采样），症状就是「树浮在半空 /
## 车陷进坡里 / 相机钻地」，而且从画面上完全看不出是哪一套数对不上 ——
## 本项目专门吃过这个亏，所以这里写死成唯一入口。
##
## 四层地貌按从大到小叠加，全是纯函数，所以任何分块之间天然无缝：
##   1. 大尺度 fbm 波浪        草原绵延起伏（中心平原段压到接近 0）
##   2. 岩石台地 mesa / 孤峰    平顶 + 陡肩，pow(k, flat)，flat 越小顶越平
##   3. 外圈环形山脉            一圈天然墙，把车关在盆地里
##   4. 最外陡壁                防止开出地图看到虚空
func _height_at(x: float, z: float) -> float:
	var d: float = sqrt(x * x + z * z)
	var h: float = _fbm2(x, z) * hill_height
	# 中心平原：起伏压到 0，一进场就是一整片平整草坪给玩家起步
	if d < plain_radius:
		h *= smoothstep(0.0, plain_radius, d)
	h = h * 0.55 + plateau_rise
	# 2) 台地 / 孤峰
	h += _peaks(_mesas, x, z)
	h += _peaks(_buttes, x, z)
	# 3) 外圈环形山脉
	if d > ridge_radius:
		var kr: float = smoothstep(ridge_radius, ridge_radius + 300.0, d)
		h += kr * kr * ridge_height
	# 4) 最外陡壁
	var wall: float = smoothstep(map_size * 0.5 - 300.0, map_size * 0.5 - 40.0, d)
	h += wall * wall * 460.0
	# 全图都有的草皮细起伏（中心也留一点，开起来有点颠）
	h += _fbm2(x * 3.7, z * 3.7) * micro_swell
	return maxf(h, 0.0)


## 四层噪声叠加（fbm）。返回值约 -1..1，不是米 —— 乘 amplitude 的地方自己管单位。
func _fbm2(x: float, z: float) -> float:
	var v: float = 0.0
	var amp: float = 1.0
	var sum: float = 0.0
	var f: float = 1.0
	for _i in range(4):
		v += _noise.get_noise_2d(x * f * 0.001, z * f * 0.001) * amp
		sum += amp
		amp *= 0.5
		f *= 2.0
	return v / maxf(sum, 0.0001)


## 台地 / 孤峰叠加：圆心处抬满，边缘衰减到 0。
## k = 1 - d/r 从圆心 1 掉到边缘 0，pow(k, flat) 就是「陡肩 + 平顶」那道曲线。
func _peaks(list: Array, x: float, z: float) -> float:
	var h: float = 0.0
	for p in list:
		var dx: float = x - float(p["x"])
		var dz: float = z - float(p["z"])
		var d: float = sqrt(dx * dx + dz * dz)
		var r: float = float(p["r"])
		if d >= r:
			continue
		var k: float = 1.0 - d / r
		h += float(p["h"]) * pow(k, float(p["flat"]))
	return h


## 撒一个落点（x, z）。
## 抽不到（一直落在留白圈 / 陡坡上）就返回 Vector2.ZERO —— 调用方看到原点
## 直接收工，比再空抽 800 次便宜得多（_spawn_kind 里有 guard 兜底）。
func _pick_spot(lim: float) -> Vector2:
	var rmin: float = maxf(prop_min_radius, 0.0)
	var rmax: float = maxf(lim, rmin + 1.0)
	for _i in range(20):
		var a: float = _rng.randf() * TAU
		var r: float = rmin + _rng.randf() * (rmax - rmin)
		var x: float = cos(a) * r
		var z: float = sin(a) * r
		# 陡坡不摆装饰：树会歪、草会穿帮，而且贴地y差一大截会被看出浮空
		var g0: float = _height_at(x, z)
		var gx: float = _height_at(x + 6.0, z)
		var gz: float = _height_at(x, z + 6.0)
		var lim_slope: float = maxf(hill_height * 0.5, 6.0)
		if absf(gx - g0) > lim_slope or absf(gz - g0) > lim_slope:
			continue
		return Vector2(x, z)
	return Vector2.ZERO


## 一个变体（=一个素材的一个部件）的所有实例压进同一个 MultiMesh：
## 上千件装饰只占十来个节点，draw call 数跟件数无关。
func _multimesh_node(node_name: String, mesh: Mesh, xforms: Array, mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	## transform_format 默认是 TRANSFORM_2D —— 不显式写这行，摆 3D 变换会整块错位
	mm.transform_format = MultiMesh.TRANSFORM_3D
	## 4.7 的 MultiMesh 属性叫 mesh，不是老版本的 geometry
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	## 4.7 的节点没有 material 属性，只有 material_override
	mi.material_override = mat
	return mi


## 有多少个桶真的用了（只用来打日志，一眼看出是不是全被坡/留白刷掉了）
func _buckets_used(buckets: Array) -> int:
	var n: int = 0
	for b in buckets:
		if (b as Array).size() > 0:
			n += 1
	return n


## 绕 Y 轴转 a 弧度的基。4.7 没有 Basis.from_yaw，只能拿恒等基绕轴旋。
func _yaw(a: float) -> Basis:
	return Basis.IDENTITY.rotated(Vector3.UP, a)


## 撒 count 件装饰：每轮抽一个落点，然后在它周围成簇摆 1~clump 件。
## 同一素材同一部件的实例合并进同一个 MultiMesh —— 上千件装饰只占十来个节点。
## 参数：paths = 候选素材，count = 件数，lim = 落点半圈半径，target_h = 目标高度（米）
func _spawn_kind(node_name: String, paths: Array, count: int, lim: float, target_h: float) -> void:
	if count <= 0 or paths.is_empty():
		return
	# 先按「变体」分桶：同一个变体的所有实例画在同一个 MultiMesh 上
	var buckets: Array = []
	var bucket_owner: Array = []      # 桶里存的是 {mesh, material}，不是 transform
	var bucket_scale: Array = []      # 每个变体归一到目标高度需要的缩放
	var bucket_ground: Array = []     # 每个变体（=一个素材）的「模型底」局部 y
	for p in paths:
		var vs: Array = LowPolyProps.variants(p)
		# 一个素材往往有多个部件（树干 y=0 / 树冠 y=1.2）。
		# 底部是哪个部件决定了整株模型的贴地基准，先把这个基准找出来。
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
	# guard 是防死循环的保险：_pick_spot 在留白圈/陡坡上抽不到点会返回原点，
	# 那就没必要再抽 800 次空枪，直接收工
	while placed < count and guard < count * 4:
		guard += 1
		var spot = _pick_spot(lim)
		if spot == Vector2.ZERO:
			break
		var cx: float = spot.x
		var cz: float = spot.y
		var per: int = 1 + (_rng.randi() % maxi(clump, 1))
		for k in range(per):
			if placed >= count:
				break
			var x: float = cx + _rng.randf_range(-clump_radius, clump_radius)
			var z: float = cz + _rng.randf_range(-clump_radius, clump_radius)
			# 每件随机挂到一个变体：换素材、换部件都会自然形成杂色林子
			var bi: int = _rng.randi() % bucket_owner.size()
			var v: Dictionary = bucket_owner[bi]
			var xf: Transform3D = v["xform"]
			# 归一尺寸 × 随机系数：树高 8m 上下，每棵略有出入才不呆板
			var s: float = float(bucket_scale[bi]) * (0.78 + _rng.randf() * 0.5)
			var rot := _yaw(_rng.randf() * TAU)
			var gy: float = _height_at(x, z)
			## 贴地计算（这里最容易错，写错就是「树整株沉进地里 / 悬在半空」）：
			##   * 部件在模型内部的偏移 xf.origin 是**素材单位**，摆出去必须乘缩放 s
			##   * 再减掉该素材的模型底 bottom —— 多部件模型（树干 y=0、树冠 y=1.2）
			##     靠这个项让「底部那个部件」正好落在地面上
			## 少乘 s → 树冠塌到地面高度；不减 bottom → 整株浮空（5m 高的空树，平视看不见）
			var g: float = float(bucket_ground[bi])
			var ox: float = xf.origin.x * s
			var oy: float = (xf.origin.y - g) * s
			var oz: float = xf.origin.z * s
			buckets[bi].append(Transform3D(rot.scaled(Vector3(s, s, s)),
				Vector3(x + ox, gy + oy, z + oz)))
			placed += 1

	for i in range(buckets.size()):
		if buckets[i].is_empty():
			continue
		var v2: Dictionary = bucket_owner[i]
		var im := _multimesh_node(node_name + str(i), v2["mesh"], buckets[i],
			LowPolyProps.prop_material(v2["material"]))
		add_child(im)
	if placed > 0:
		print("[terrain] 低模装饰 %s 摆了 %d 件 / %d 个变体节点"
			% [node_name, placed, _buckets_used(buckets)])


## 装饰摆哪儿、摆多少。
##
## 【这三个数之间是有耦合的，改之前先算一遍密度】
## 摆在半径 R、留白 r0 的圆环里，件数 N，那么近景（0~100m）大约能看到
##   N / (π·R²) × π·(100² − r0²) = N × (10000 − r0²) / R²  件
## 也就是「件数 ∝ R² 才保得住同一密度」。把 R 从 590 收到 320 密度直接翻 3.4 倍，
## 项数却没动 —— 那才会又变成空旷草原。
## 同理 prop_min_radius（出生留白）别设太大：55m 留白时出生点正前方本来就是个空洞。
func _spawn_props() -> void:
	_spawn_kind("Trees", TREE_GLBS, tree_count, prop_radius, tree_height)
	_spawn_kind("Bushes", BUSH_GLBS, maxi(int(float(tree_count) * 0.8), 0), prop_radius, bush_height)
	_spawn_kind("Grass", GRASS_GLBS, grass_count, prop_radius, grass_height)
	_spawn_kind("Rocks", ROCK_GLBS, rock_count, prop_radius, rock_height)
	_spawn_float_islands()


## 浮空岛：草原上那些「悬在半空的岩石台」，上面盖草皮、下面坠岩石。
## 摆法跟 _spawn_kind 不一样 —— 它们是**贴着已知地标长出来的**，不是撒点，
## 所以直接拿 mesa/butte 的中心 + 峰高当落点，每台一块岩体 + 一块草帽。
func _spawn_float_islands() -> void:
	if float_rock_count <= 0:
		return
	var spots: Array = []
	for m in _mesas:
		spots.append(Vector3(float(m["x"]), float(m["h"]) + float(m["r"]) * 0.55, float(m["z"])))
	for b in _buttes:
		spots.append(Vector3(float(b["x"]), float(b["h"]) + float(b["r"]) * 0.5, float(b["z"])))
	if spots.is_empty():
		return
	## Kenney 的岩石/草皮原生就 1~2m 大，摆进 2048m 的图里等于撒了粒沙子，
	## 所以先按「一座岛想要多大」归一一次，每个岛上再叠一点随机抖动。
	var rv: Dictionary = LowPolyProps.variants(FLAT_ROCK_GLB)[0]
	var gv: Dictionary = LowPolyProps.variants(FLAT_GRASS_GLB)[0]
	var rock_base: float = LowPolyProps.fit_scale(rv["mesh"], 60.0)
	var grass_base: float = LowPolyProps.fit_scale(gv["mesh"], 60.0)

	var rng2 := RandomNumberGenerator.new()
	rng2.seed = seed_value ^ 0x5f3a1
	var rock_xf: Array = []
	var grass_xf: Array = []
	var used: int = 0
	var guard: int = 0
	while used < float_rock_count and guard < float_rock_count * 6:
		guard += 1
		var base: Vector3 = spots[rng2.randi() % spots.size()]
		var x: float = base.x + rng2.randf_range(-60.0, 60.0)
		var z: float = base.z + rng2.randf_range(-60.0, 60.0)
		var s: float = 0.6 + rng2.randf() * 1.4
		var y: float = _height_at(x, z) + base.y * 0.5 + 18.0 * s
		var rot := _yaw(rng2.randf() * TAU)
		var rock_s: float = s * rock_base
		rock_xf.append(Transform3D(rot.scaled(Vector3(rock_s, rock_s, rock_s)),
			Vector3(x, y, z)))
		# 草帽压在岩体正上方、压扁一点 —— 纳格兰那些岛就是「薄薄一层绿皮盖住一坨石头」
		var gs: float = s * grass_base * 0.9
		grass_xf.append(Transform3D(rot.scaled(Vector3(gs, gs * 0.22, gs)),
			Vector3(x, y + rock_s * 0.42, z)))
		used += 1
	if rock_xf.is_empty():
		return
	add_child(_multimesh_node("FloatRocks", rv["mesh"], rock_xf,
		LowPolyProps.prop_material(rv["material"], TINT_ROCK, 0.9)))
	add_child(_multimesh_node("FloatGrass", gv["mesh"], grass_xf,
		LowPolyProps.prop_material(gv["material"], TINT_GRASS, 0.95)))
	print("[terrain] 浮空岛 %d 座" % [used])


## 极光带：纳格兰天边那道绿色光幕。
## 不做成体积/后处理（开销大且 4.7 的屏幕空间方案跟这儿的美术不搭），
## 用一层双面加色平面 + 自发光，挂在山脊外圈的空中，转一转就够出味儿。
func _spawn_aurora() -> void:
	if aurora_count <= 0:
		return
	var band: Array = []
	for i in range(aurora_count):
		var a: float = float(i) / float(aurora_count) * TAU + _rng.randf() * 0.4
		var r: float = ridge_radius * 0.82 + _rng.randf() * 90.0
		var x: float = cos(a) * r
		var z: float = sin(a) * r
		var h: float = _height_at(x, z) + 150.0 + _rng.randf() * 90.0
		band.append({
			"pos": Vector3(x, h, z),
			"rot": a,
			"w": 420.0 + _rng.randf() * 380.0,
			"h": 120.0 + _rng.randf() * 160.0,
		})

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	## 4.7 的 StandardMaterial3D 没有 flat_shading；硬边加色带直接走 unshaded
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color8(96, 255, 168)
	mat.emission_energy_multiplier = 0.5
	mat.albedo_color = Color(0.0, 0.0, 0.0, 0.45)
	mat.render_priority = 2

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _aurora_plane()
	mm.instance_count = band.size()
	for i in range(band.size()):
		var b: Dictionary = band[i]
		## 带上 yaw：光幕应该跟山脊同向，否则从车里看是一道斜着劈过来的怪片
		var basis: Basis = _yaw(float(b["rot"])).scaled(
			Vector3(float(b["w"]), float(b["h"]), 1.0))
		mm.set_instance_transform(i, Transform3D(basis, b["pos"]))
	var mi := MultiMeshInstance3D.new()
	mi.name = "Aurora"
	mi.multimesh = mm
	mi.material_override = mat
	add_child(mi)
	print("[terrain] 极光带 %d 道" % [band.size()])


func _aurora_plane() -> PlaneMesh:
	var pm := PlaneMesh.new()
	pm.size = Vector2(1.0, 1.0)
	return pm

## 内置分块高度场 —— Terrain3D 用不了时候的兜底。
##
## 【为什么还要留这一手】Terrain3D v1.0.2 的 DLL 在 4.7 上把 Terrain3DStorage 类
## 注册漏了（ClassDB.class_exists == false），Terrain3D 也没有 set_data，
## 于是运行时 t.data 恒为 null，import_images 无从调用 —— 这条路的地形只能在
## 编辑器里烘成 .res 落盘（见 ref/Terrain3DDemo/data/terrain3d_*.res 的做法）。
## 在烘出来之前，游戏得能跑，所以保留 Godot 内置的 HeightMapShape3D 分块方案。
##
## 关键对齐（做错就是「看着贴地、物理浮空 2m」这个经典 bug）：
##   * 视觉顶点和碰撞采样点落在**同一个世界坐标点**上
##   * HeightMapShape3D 的地图永远是 1×1 的 extent，靠 shape 缩放撑开
##   * 所以 CollisionShape3D 要摆到 chunk 中心、scale = (chunk_size, 1, chunk_size)
func _build_chunks_builtin() -> void:
	var n: int = maxi(int(map_size / chunk_size), 1)
	var half: float = map_size * 0.5
	var t0: int = Time.get_ticks_msec()
	for cz in range(n):
		for cx in range(n):
			_add_chunk(cx, cz, n, half)
	print("[terrain] 内置高度场 %dx%d 块（每块 %0.0fm），%d ms"
		% [n, n, chunk_size, Time.get_ticks_msec() - t0])


func _add_chunk(cx: int, cz: int, n: int, half: float) -> void:
	var x0: float = -half + float(cx) * chunk_size
	var z0: float = -half + float(cz) * chunk_size
	var seg: int = maxi(int(chunk_size / maxf(step_size, 1.0)), 2)
	var step: float = chunk_size / float(seg)
	var mid_x: float = x0 + chunk_size * 0.5
	var mid_z: float = z0 + chunk_size * 0.5

	# ---- 视觉：SurfaceTool 出 ArrayMesh，顶点色分层（卡通风不用贴图） ----
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(seg + 1):
		for i in range(seg + 1):
			var x: float = x0 + float(i) * step
			var z: float = z0 + float(j) * step
			var y: float = _height_at(x, z)
			st.set_color(_tint_at(y, x, z))
			st.set_uv(Vector2(float(i), float(j)) / float(seg))
			st.add_vertex(Vector3(x, y, z))
	var stride: int = seg + 1
	for j in range(seg):
		for i in range(seg):
			var a: int = j * stride + i
			var b: int = a + 1
			var c: int = a + stride
			var d: int = c + 1
			st.add_index(a)
			st.add_index(c)
			st.add_index(b)
			st.add_index(b)
			st.add_index(c)
			st.add_index(d)
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()

	var mi := MeshInstance3D.new()
	mi.name = "Chunk_%d_%d" % [cx, cz]
	mi.mesh = mesh
	mi.material_override = grass_material if grass_material != null else _fallback_terrain_mat()
	mi.transform = Transform3D(Basis.IDENTITY.scaled(Vector3(1, 1, 1)), Vector3(mid_x, 0.0, mid_z))
	add_child(mi)

	# ---- 碰撞：同一批采样点烘 HeightMapShape3D ----
	var data := PackedFloat32Array()
	for j in range(seg + 1):
		for i in range(seg + 1):
			data.append(_height_at(x0 + float(i) * step, z0 + float(j) * step))
	var hs := HeightMapShape3D.new()
	hs.map_width = stride
	hs.map_depth = stride
	hs.map_data = data
	## 【4.7 的 HeightMapShape3D 没有 scale】地图 extent 恒为 1×1，
	## 撑开边长这件事只能交给挂它的 CollisionShape3D —— 写在 shape 上会报
	## Invalid assignment of property 'scale'。
	var cs := CollisionShape3D.new()
	cs.shape = hs
	cs.scale = Vector3(chunk_size, 1.0, chunk_size)
	cs.transform = Transform3D(Basis.IDENTITY.scaled(Vector3(1, 1, 1)), Vector3(mid_x, 0.0, mid_z))
	add_child(cs)


## 顶点色分层：低处草绿、高处/陡坡转岩灰，跟 Terrain3D 那两套 splat 一个意思。
## 用 Color8 按「肉眼 sRGB」调，别写 0~1 线性值（线性值渲出来暗一大截）。
func _tint_at(y: float, x: float, z: float) -> Color:
	var grass := Color8(104, 138, 66)
	var rock := Color8(136, 126, 108)
	var snow := Color8(226, 232, 236)
	var h: float = clampf(y / maxf(ridge_height + plateau_rise, 1.0), 0.0, 1.0)
	var c: Color = grass.lerp(rock, smoothstep(0.42, 0.72, h))
	c = c.lerp(snow, smoothstep(0.88, 1.0, h))
	# 细噪声打散色块边界，免得俯视图看出一层层等高线
	return c.lerp(grass, _fbm2(x * 0.06, z * 0.06) * 0.12 + 0.06)


func _fallback_terrain_mat() -> Material:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	m.metallic = 0.0
	return m
