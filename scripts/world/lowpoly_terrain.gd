@tool
extends Node3D

## LowPolyTerrain —— GTAWorld 的插件化低多边形地形（Low Poly Terrain Builder）
##
## 本节点在 _ready 时拉起一个 LowPolyTerrainManager，按下面的剖面参数现算高度矩阵，
## 交给插件去 Delaunay 化网格 + 烘焙碰撞。参数改完刷新即生效，不需要烘资产。
##
## 剖面（从地图中心往外）：
##   中心平原（起伏几乎为零，给人飙车）→ 丘陵 → 环形山脉 → 最外缘陡壁（挡视线边界）

# ---------- 世界尺寸 ----------
@export var world_chunks: Vector2i = Vector2i(8, 8)
@export_range(4, 32, 1) var chunk_size: int = 16
@export_range(0.5, 12.0, 0.5) var cell_size: float = 4.0

# ---------- 地形塑形 ----------
@export var seed: int = 20261003
@export_range(0.0, 30.0, 0.5) var hill_height: float = 7.0
@export_range(0.0, 200.0, 1.0) var plains_radius: float = 110.0
@export_range(0.0, 300.0, 1.0) var ring_start: float = 170.0
@export_range(0.0, 120.0, 1.0) var ring_height: float = 62.0
@export_range(0.0, 200.0, 1.0) var rim_height: float = 70.0
@export_range(0.0, 1.0, 0.05) var jitter_strength: float = 0.3
@export_range(0.05, 3.0, 0.05) var jitter_slope_threshold: float = 1.5

# ---------- 配色 ----------
@export var grass_color: Color = Color(0.40, 0.50, 0.22)
@export var cliff_color: Color = Color(0.46, 0.42, 0.36)
@export_range(0.0, 1.0, 0.05) var cliff_roughness: float = 0.85

var _manager: Node = null


func _ready() -> void:
	_build()


## 重新拉起整张地形（改参数后手动调一次，或重载场景）
func regenerate() -> void:
	if is_instance_valid(_manager):
		_manager.queue_free()
		_manager = null
	_build()


func _build() -> void:
	var Script = load("res://addons/lowpolyterrain/LowPolyTerrainManager.gd") as GDScript
	if Script == null:
		push_warning("[LowPolyTerrain] 插件脚本找不到，地形未生成")
		return

	var m: Node = Script.new()
	m.name = "LowPolyTerrain"
	m.preview_world_chunks = world_chunks
	m.preview_chunk_size = chunk_size
	m.preview_cell_size = cell_size
	m.world_chunks = world_chunks
	m.chunk_size = chunk_size
	m.cell_size = cell_size
	m.jitter_strength = jitter_strength
	m.jitter_slope_threshold = jitter_slope_threshold
	add_child(m)
	_manager = m

	# 网格骨架与高度矩阵
	m._initialize_empty_grid()
	_fill_heights(m)

	# 让插件按新数据重建所有 chunk 网格
	m.rebuild_chunks_structure()

	# 碰撞只烘焙一次：编辑器里不烘（会往场景树里塞物理体），运行时烘
	if not Engine.is_editor_hint():
		m._bake_live_collisions_as_child()

	assign_material(m)


## 核心：按剖面往 global_height_data 里写高度
func _fill_heights(m: Node) -> void:
	var nx: int = m._total_vertices_x
	var nz: int = m._total_vertices_z
	var data: PackedFloat32Array = m.global_height_data
	if data.size() != nx * nz:
		return

	var n1 := FastNoiseLite.new()
	n1.seed = seed
	n1.noise_type = FastNoiseLite.TYPE_PERLIN
	n1.frequency = 0.0075

	var n2 := FastNoiseLite.new()
	n2.seed = seed + 7717
	n2.noise_type = FastNoiseLite.TYPE_PERLIN
	n2.frequency = 0.03

	var n3 := FastNoiseLite.new()
	n3.seed = seed + 4231
	n3.noise_type = FastNoiseLite.TYPE_CELLULAR
	n3.frequency = 0.09

	var half_x: float = float(nx - 1) * 0.5
	var half_z: float = float(nz - 1) * 0.5
	var flat_end: float = plains_radius * 2.0
	var ring_end: float = ring_start + 90.0
	var rim_end: float = ring_start + 150.0

	for z in range(nz):
		for x in range(nx):
			var wx: float = float(x) - half_x
			var wz: float = float(z) - half_z
			var d: float = sqrt(wx * wx + wz * wz)

			# 三层噪声叠出丘陵
			var h: float = n1.get_noise_2d(wx, wz) * hill_height
			h += n2.get_noise_2d(wx, wz) * hill_height * 0.35
			h += n3.get_noise_2d(wx, wz) * hill_height * 0.12

			# 中心压平：车能不能跑得爽全看这一段
			h *= smoothstep(plains_radius, flat_end, d)

			# 环形山脉（地图外圈的视觉边界）
			h += ring_height * smoothstep(ring_start, ring_end, d)

			# 最外缘陡壁，把视线收住
			h += rim_height * smoothstep(ring_end, rim_end, d)

			data[z * nx + x] = h

	m.global_height_data = data


## 用插件自带的地形着色器（它原生支持「没画过的地形」这一路）
func assign_material(m: Node) -> void:
	var sp = load("res://addons/lowpolyterrain/shader/fast_terrain_and_cliff.gdshader") as Shader
	if sp == null:
		return
	var sm := ShaderMaterial.new()
	sm.shader = sp
	sm.set_shader_parameter("base_color", grass_color)
	sm.set_shader_parameter("cliff_base_color", cliff_color)
	sm.set_shader_parameter("cliff_roughness", cliff_roughness)
	sm.set_shader_parameter("noise_strength", 0.0)
	sm.set_shader_parameter("noise_scale", 0.02)
	sm.set_shader_parameter("color_steps", 3)
	sm.set_shader_parameter("slope_threshold", 0.75)
	sm.set_shader_parameter("slope_blend_softness", 0.3)
	m.custom_material = sm
