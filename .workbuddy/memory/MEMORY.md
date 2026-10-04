# Starter-Kit-Racing 项目长期笔记

> 项目名 = **GTAWorld**（2026-10-03 用户定名；`project.godot` 的 `config/name` 就是窗口标题 / 导出名，改它就行）。
> 基线是 Kenney *Starter Kit Racing*：素材 CC0 + 代码 MIT，改造成果版权归 GTAWorld。
> 目录名 `Starter-Kit-Racing` 是磁盘路径，不改（改名会动到脚本里的绝对路径）。
>

## AI 协作纪律（行为宪法，优先级高于任何单条任务）

- 根目录 **`AGENTS.md`** = 完整《AI 协作守则》，每次动手前先读。
- 核心 6 条：先调研后动手 / 多方案供选（2~5 套）/ 决策权归我 / 未确认不实现 / 少踩坑 / 一步到位二步更优。
- 流程：`需求 → 调研 → 我选 → 细化 → 实现 → 迭代`；**没拍板前不许写码**。
- 硬禁令：不做半成品交付；不输出「找原因 → 改 → 又白屏」的排查流水账（结论先行）；
  不重复踩已知坑（坑在本文档 / README「改配置前先看一眼这些坑」里，要**前置规避**）；
  同一问题 2 次不通就换路径或升级给用户，不无限循环。
- 交付三件套：做了什么 / 怎么验证（探针或截图，结果落盘再读）/ 改了哪些文件。

## 项目硬事实

- Godot **4.7 stable**，可执行 `C:\Tools\Godot\Godot_v4.7-stable_win64.exe`；项目根 `D:\AI\GodotProject\Starter-Kit-Racing`。
- 引擎路径 / 项目路径常被写成"照着抄"，但本机实际是上面这两条，别再猜。
- `run/main_scene` = `res://scenes/select.tscn`（启动先选地图）。
  地图 1 = `scenes/main.tscn`（原 Kenney Starter Kit 赛道）；地图 2 = `scenes/city.tscn`（迷你中国城，真实省界数据烘焙）。
- **车辆不是 `VehicleBody3D`**：`scripts/vehicle.gd`（`class_name Vehicle extends Node3D`）是
  `Node3D + Ground(RayCast3D) + Sphere(RigidBody3D, mass 1000, gravity_scale 1.5)` 自研控制器，
  前进/转向是 `linear_speed`/`angular_speed` 标量手算。
  → 收到 `engine_force / brake / friction / steering` 这类 VehicleBody3D 术语时先换算：
  `engine_power` / `brake_power` / `lateral_grip` / `steer_authority+turn_rate`。
- 街机手感核心 = **车头 yaw 与速度方向 `velocity_dir` 分离**，差值就是 `drift_angle`（甩尾角），相机读它做横向让位。
- **速度量纲：`linear_speed` 是 0~1 的归一化油门量，不是米/秒！**
  真实速度 = `linear_speed * max_speed`（`max_speed` 默认 40 m/s ≈ 144 km/h），对外取 `get_speed_mps()`。
  改造前把归一化值直接写进刚体，满油门只有 1 m/s（≈3.6 km/h），慢得像散步。
  `engine_power`（1.1）/ `brake_power`（3.5）是「1/s 趋近速率」，不是力，值大 = 一脚到顶。
- **当前机位（贴身赛车视角）**：`scripts/view.gd` 的 `distance=2.9 / height=1.15 /
  look_at_height=0.55 / look_ahead=14 / fov_base=70 / fov_speed=8`，稳态实测相机距车 ≈3.8 m。
  想再贴就调 `distance`，别超 `zoom_max` 20。
- 调速/调镜头后跑 `tools/drive_probe.gd` 实测（headless 按 W 跑 N 帧，
  打印 km/h / 车位置 / 相机距车 / fov），不要靠读代码猜。

## 防黑（本项目最大坑，六条硬约束）

1. 禁止裸网格（任何 MeshInstance3D 必须有材质），有 P0 一律 FAIL。
2. 复用 `materials/` 已有材质，不新建空材质。
3. 靠顶点色的必须开 `vertex_color_use_as_albedo`。
4. 道路必须用原项目地面/沥青材质，不能用引擎默认灰。
5. 场景必须有 `WorldEnvironment` + `ProceduralSkyMaterial` 兜底环境光。
6. **GridMap 的 MeshLibrary 只认网格内部（MeshInstance3D 内）的材质**，节点上的
   `material_override` 会被忽略 → 道路 tile **故意不加 material_override**。

体检器 `tools/check_materials.tscn`（P0 裸网格 / P1 反照色 <0.12 / P2 提示），
退出码 0 通过、1 有 P0、2 加载失败。跑法见文档第 6.3 节。

## 场景文件的静态写法坑

- **`.tscn` / `.tres` 里不许写「属性行尾 `#` 注释」**（例：`far = 4000.0   # 注释`）。
  只有**整行以 `#` 开头**才算注释。行尾 `#…` 会被算进属性值 → 赋值失败 →
  **该节点块之后的解析被静默中断，后面所有 `[node]` 整段丢失，且引擎不报错**。
  起因是 `city.tscn` 那一行行尾注释把 `[node name="Vehicle"]` 吞了，
  连锁导致追尾相机失效、画面只剩一条贴地地平线的模型带。写资源文件一律用「注释独占一行」。
- 手工改 `.tscn` 的 parse 结果可以用 `PackedScene.get_state().get_node_count()` 数节点自检，
  肉眼看到「节点少了但没报错」时先扫这条。

## 验收纪律

- **验收前先删 `.godot/script_cache.bin`** —— `--check-only` 走缓存，脏缓存会给假绿灯。
- headless 只能做体检/落盘验证；截图和建 GridMap 子网格必须 GUI 模式跑。
- PowerShell 通道常只回退出码、stdout 全丢 → 脚本结果一律 `WriteAllLines` 落盘再读。
- 两个场景连跑防黑扫描会写同一个报告文件互相覆盖，一次只跑一个。

## 地形插件：两个并存，各管一段（2026-10-03 定）

- **`addons/lowpolyterrain`**（78sForge，纯 GDScript）：`scenes/lowpoly.tscn` + `scripts/world/lowpoly_terrain.gd`
  驱动。分块 MeshInstance、一格一 quad，**天然低模折面**，渲染 mesh 直接当碰撞体。
  **它没有示例地图**（插件里只有 GUT 单测）。
- **`addons/terrain_3d`**（tokisan **v1.0.2**，`compatibility_minimum=4.4`，自带 windows dll）：
  C++ GDExtension，连续高度场 + clipmap 分级 LOD + 最多 32 层材质 splat + 运行时生成 trimesh。
  已在 `project.godot` 的 `editor/plugins` 里启用。
- **`ref/GodotVehicle`**（来自 `D:\AI\GodotProject\godot-vehicle`）：射线悬挂真车
  （`Vehicle extends RigidBody3D` + Wheel/Axle + Curve 调校 + 幽灵回放）。
  **`ref/Terrain3DDemo`**：Terrain3D 官方示例工程（`Demo.tscn` / `CameraManager.gd`）。
  **`ref/LowPolyTerrainBuilder`**：lowpolyterrain 作者仓库源码。
- **⚠️ gdextension 铁律：全项目只能有一份 `.gdextension`。**
  装第二份（哪怕是 `Temp/` 下的副本）会报
  `Attempt to register extension class 'Terrain3D', which appears to be already registered`，
  之后所有 Terrain3D* 类注册不上 —— **看起来像"引擎版本不支持"，实际是自己装重了**。
  排查口诀：`find . -name "<name>.gdextension" -not -path "./ref/*"`，必须只有一条输出。
  另外：**gdextension 只要 addons 下有文件就自动加载，跟 editor/plugins 启没启用无关。**

## 详细资料

每轮改动与踩坑按日志写在 `.workbuddy/memory/YYYY-MM-DD.md`；
架构级设计文档在 `docs/`（`DESIGN_racing_rework.md` 为本次极品飞车操控 + 红警2掩码赛道生成）。

## 运行时调参（调手感别去改脚本默认值，来回三趟人就没脾气了）

- **GDTuner**（`addons/gdtuner/`，官方资源库 #4969，MIT，纯 GDScript）：脚本里要能调的变量收进
  `@export_group("tunable")` + 场景里挂 `AutoTunable`，自动变滑条。桌面端 **F12** 弹独立窗口，
  编辑器里跑走底部 `GDTuner` 面板；release 下 no-op。
  `.tscn` 里必须写 `type="Node"` + `script = ExtResource(...)` 指向 `addons/gdtuner/auto_tunable.gd`，
  **写 `type="AutoTunable"` 会退化成 placeholder、面板 0 控件**（4.7 的全局类检查）。
- **`scripts/tune_hud.gd`**：autoload 的屏幕小面板（**Tab** 收起），只给最常用的三根滑条
  （最高车速 / 镜头距离 / 镜头高度），值标签直接显示 km/h。要拖全部 14 项就按 F12。
- **默认 `max_speed = 28.0`（≈101 km/h）**，这是按「太快」反馈调下来的，别改回去。
- 调定了要永久保存就跑 `tools/bake_tuning.gd`（`--dry` 干跑，真写前备份到 `Temp/bak_<时间戳>/`；
  `--scene=` 换场景，`--set=属性=值` 注入读数）。
  **GDTuner 自带 Bake to Source 在 4.7 上是失效的**——正则只认两行式 `@export var`，而 4.7 两行式是 Parse Error。
- 4.7 语法备忘录：`@export_range(a,b,c) var x: float = 0` **必须单行**；`SceneTree._process` 必须 `-> void`；
  `Control.AUTOWrap` 不存在（换行枚举在 `TextServer` 下）；`Node` 类型变量用 `get()/set()` 取属性；
  正则里命名组也占编号，数值捕获要自己命名。
- 跑 Godot 一律走 PS 工具（bash 里的子进程 spawn 会莫名 EBUSY）；
  **整场景 headless（`--quit-after`）的输出管道偶发崩**，验证 autoload 行为改用 `--script` 探针
  自己 `load(script).new() + add_child()`。

## 随机赛道生成器（2026-10-03 起为主场景）

- 主场景 = `scenes/main.tscn`，GridMap 挂 `scripts/mapgen.gd`：进图现拼随机闭环赛道。
  `generate(seed)` 是纯函数（seed → cells/ascii/stats），tools 可直接 preload 调。
- 风格来自 vendor `models/Library/mesh-library.tres` 的 7 个 tile，**生成器只摆砖不碰材质**。
  item id：0 empty / 1 forest / 2 tents / 3 corner / 4 finish / 5 ramp / 6 straight。
- orientation 只有 0 / 16 / 22 / 10 四个「扶正」值；直道沿局部 Z，corner 接局部 X+Z，
  finish 拱门横跨局部 X（沿用被替换直道的朝向）。
- 校验工具：`godot --headless --path . --script res://tools/gen_map.gd -- --seed=7`
  → `Temp/gen_map_report.txt`（ASCII 闭环 + 统计）。
- 旧都市/真实省界生成器（city.gd、city_data.json、gen_city.py、city.tscn、city-environment.tres）
  已移出构建到 `Temp/removed_city/`；选图页只剩单卡「随机赛道」。

## 4.7 语法硬坑（必读）

- **`..` 区间语法在本 build 不可用**：`for x in a..b:` 直接 Parse Error
  （`Expected ":" after "for" condition`，连 `0..5` 都挂）。**一律写 `range(a, b+1)`**。
- 不存在：`Basis.orthogonalized`、`OS.get_cmdline()`、`GridMap.map_to_world()`、`has_cell()`、
  `get_item_transform()`、`get_cell_item_orientation_basis()`（用 `GridMap.get_cell_item_basis()`）、
  `ArrayMesh.get_surface_material()`（用 `surface_get_material(0)`）、`Basis.elements`。
- **`Object.get_meta(key, null)` 会报错**（Object.cpp:1052）⇒ 默认值必须给非 null，用 -1。
- `MainLoop._process` 返回 true = **立刻结束主循环** ⇒ 中间帧 return false。
- `--script` 模式主循环只跑 1 个 `_process` tick；正常场景 `--quit-after=N` 物理约 60 帧就停
  （headless 无渲染会休眠）⇒ 物理探针观测点放 55 帧以内，或做成临时 `.tscn + Node._physics_process`。
- `OS.get_cmdline_user_args()` 要靠 `--` 分隔才吃得到参数：
  `godot --headless --path . --script x.gd -- --seed=7`。

## 物理/车的两个陷阱

- **`BoxShape3D` 厚度 0 = 没有碰撞**（vendor 原兜底地板就这么写的）⇒ 兜底板必须给厚度，
  并用 CollisionShape3D 的 y 偏移把顶面摆回需要的高度。
- **`scripts/vehicle.gd` 每帧覆写 `sphere.linear_velocity`** ⇒ 车不会自由下落，**出生高度=最终高度**。
  路面顶 y=0.75、车模型比球心低 0.65 ⇒ 出生 y 取 1.3 时视觉正好贴地，取 0 就直接陷进路里。

## 随机赛道生成器（2026-10-03 起为主场景）_续

- **`max_speed` 默认 = 10.4（≈37 km/h）= Kenney 原版实测巡航速度**，别再往上调。
  原版是角速度驱动（angular_velocity += basis.x * linear_speed * 100 * delta，
  angular_damp=4.0），400 帧收敛 10.368 m/s。原版项目缺 models 跑不起来，
  复现方程在 `Temp/origspd.gd / origspd.tscn`。**60 帧处只有 27 km/h，别早下结论。**
- 起跑点校验探针 **`Temp/spawnchk.gd / spawnchk.tscn`**：车坐标 → GridMap 格，
  报 item>=3 的 ROAD / DECOR / VOID。改出生点就跑它。
- `place_cars` 从 finish 沿路回溯，**撞到 corner 要自动转向继续沿环走**（环只有 1 格宽），
  否则 slots 只有 1~2 个，三台车会叠在同一格。
- 暴力摩托设计文档 **`docs/DESIGN_road_rash.md`**（车+摩托、撞击/摔车/捡车/碎片/警车，
  素材全走 Kenney colormap 保持风格一致）。抽象基类命名 **`Racer`**（不能用 VehicleBody3D）。

## 相机机位锁定（用户：不论什么速度都不要拉远）

- `scripts/view.gd`：`distance_speed` 0.9→**0**、`distance_brake` 0.75→**0**、
  `fov_speed` 8.0→**0**；新增 `@export_range(0,1.5,0.05) var speed_lead: float = 1.0`。
- **一阶跟随的固有滞后是真凶**：`position_smoothing=7` 时匀速段相机稳态落后
  `v/7` 米（满速 10.4 → 1.49 m），实测机位 4.53 m（静止 3.12 m），看起来就是「越快越飘远」。
- 解法 = **速度前馈**：`lead = speed_mps / position_smoothing * speed_lead`，
  从 `distance_target` 里减掉它 ⇒ 稳态机位与速度无关。数学验证 v=0/5/10.4/20 → 3.12/3.08/3.04/2.97 m。
- 实测全程 `fov` 恒定 70.00（波动 0），`dist` max = 2.9710 m（前馈前 4.53 m）。
- 探针：`Temp/camchk.*`（真实场景统计 dist/fov min-max）、`Temp/lead_sim.*`（纯数学复现跟随方程）。

## 模块化骨架（2026-10-02 起，GTA5 开放世界总纲）

- 总纲 = `docs/DESIGN_gta_openworld.md`（洛圣都计划）。旧的 `DESIGN_road_rash.md` 降级为「L2 载具缠斗子系统规格」。
- 三层玩法皮层：**L1 自由行驶（主干）→ L2 载具缠斗 → L3 RTS 阵营战争**。
  L3 触发是 F5 战术视角，**开车时必须禁用**（不能抢走驾驶手感）。四个剧本：帮派火并 / 警察剿匪 / 军方剿毒 / 自由团战。
- `scripts/` 已按域拆子目录：`core/ net/ world/ vehicles/ camera/ hud/ actors/ combat/ heat/ faction/ territory/ economy/ events/ mission/ persistence/ audio/`。
  老文件去向：vehicle.gd、vehicle-motorcycle.gd → `vehicles/`；view.gd → `camera/`；minimap.gd、tune_hud.gd → `hud/`；mapgen.gd → `world/`。
- **三个 autoload（别再增删别的）**：
  - `EventBus` = `scripts/core/event_bus.gd`（模块间只许走事件，不许互抓节点）
  - `Modules` = `scripts/core/modules.gd`（扫 `modules/<name>/mod.cfg`，拓扑排序后实例化 + `mod_setup(ctx)`）
  - `Lobby` = `scripts/net/session.gd`（房型 Solo/Invite/Crew/Public、host/join、玩家表）
  - **autoload 名字不能叫 `Net`**（撞引擎内置全局类 `Net` = NetworkedMultiplayerAPI），`Multiplayer` 也撞。
- 示范模块 `modules/fps_stats/`（默认 enabled，右下角显示 FPS/节点数/在线人数/模块数）——想验证模块系统就调它的 `mod.cfg` 里 `enabled`。
- 新增模块 = 建 `modules/<name>/` + `mod.cfg`（字段 script/deps/enabled/version）+ 入口脚本（有 `mod_setup(ctx)` 即可）。

## 移动文件后必做的缓存清理（否则报 File not found）

Godot 4.7 移动/改名 `.gd` 后，`.godot/uid_cache.bin` 和 `.godot/global_script_class_cache.cfg`
里的 **uid→path 映射还指向旧路径**，引擎会拿旧 path 去 ext_resource，报
`Attempt to open script 'res://scripts/xxx.gd' resulted in error 'File not found'`，而文件里其实已经改对了。

**解法（按顺序来，两分钟搞定）**：
1. 删 `.godot/uid_cache.bin`、`.godot/global_script_class_cache.cfg`、`.godot/script_cache.bin`
2. `godot --headless --path . --import` 重建文件系统与全局类
3. 再跑 `--check-only` 或 headless 启动场景确认

## 4.7 又确认缺的几个 API

- `DirAccess.dir_exists()` **不是静态函数** → 用 `DirAccess.open(p) == null` 判目录是否存在。
- `Engine.get_exit_code()` 不存在（别在 `_ready` 里想查退出码）。
- `var sig: Dictionary = Signal(self, name)` 类型不对 → `var sig := Signal(self, name)`；
  查重用 `sig.get_connections()`，别对 Dictionary 调 `connect()`。
- **`AABB` 上没有 `merged()` / `distance_to()` / `encloses_point()`**（#31 用
  `Temp/aabb_api.gd` 逐行喂 `--check-only` 问编译器实测，三个全报 "not found in base AABB"）。
  能用的是 `merge()`（**原地改、返回 void**，所以 `var c = box.merge(x)` 会得到 null）、
  `has_point()`、`intersects()`、`get_center()`、`has_volume()`、`grow()`。
  点到盒的距离自己算：把点三个轴 clamp 进盒得到最近点，再 `distance_to` 那个点。
- **`BoxShape3D` 没有 `offset`，只有 `size`**（盒心就是节点原点）。写成 `bs.offset - bs.size*0.5`
  不会在 `--check-only` 报错（属性访问是运行期解析），运行时抛
  `Invalid access to property or key 'offset'`。
- **协程里抛运行期错误 = `_run()` 静默死掉**：探针既不 `_finish()` 也不 `quit()`，
  引擎就以 28% CPU 空转十几分钟，看着像「物理炸了/卡住了」。
  防法两条：① `_log()` 每行立刻刷盘（卡在哪儿一眼看见）；
  ② 启动加 `--quit-after N`（帧数）当看门狗，N=9000 ≈ 100 s 到点自己退。

## Phase 1 都市（scenes/urban.tscn，2026-10-03 落地）

- 入口：选图页第 2 张卡「洛圣都城区」（select.gd scene_map2），或直接跑 scenes/urban.tscn。
- 步行人物：scripts/actors/player.gd（CharacterBody3D，WASD/Shift跑/空格跳/鼠标转视角），
  模型 models/characters/character.glb（Kenney Starter Kit，动画 idle/walk/jump）。
- 第三人称相机在 scenes/player.tscn 里是 YawPivot/PitchPivot/Camera，
  **local z 必须是 +3.2（人在 -Z 前方，相机要落在人后面）**——写成 -3.2 相机就站到人前面，人物永远不入画（实测踩过）。
- 上下车：urban_game.gd 按 E（input action `interact`，physical_keycode 69），
  换 is_player 标记 + 切相机轨道，不重建节点。
- 停放车贴地：city_builder.gd `_ground_bottom()` 按**轮子网格**（名字含 wheel）下沿对齐，
  不能按整体 AABB——Kenney 部分车 body 带贴地裙边，比轮底低 ~0.2m，按 AABB 对齐轮子会悬空（橙色轿车实测）。
- models/cars/*.glb 曾全白：.import 生成时 Textures/colormap.png 还不存在，
  补贴图后必须删对应 .glb.import 再 `--headless --import` 才会重新绑定（实测踩过）。
- 4.7 Image.crop() 签名是 (x, y, w, h) 且对 Region 支持差，截图裁剪用 `get_region(Rect2i(...))` 稳。

## 都市 v1.1（2026-10-03 用户实机反馈后修）

- 驾驶机位：urban_game._ready 里 `view.set("distance", 6.5)`（view.gd 默认 2.9 是给大皮卡的，Kenney 小车 4.3m 会被怼脸）。
- **测量包围盒一律用引擎 `global_transform * mesh.get_aabb()`（节点须在树内）**：
  自制 transform 累乘的 _box_local 实测会把 AABB 整体往下错算约半个楼高 → 楼底悬空 11 米（截图实证）。
  vehicle_picker.gd 里那套 _box_local 只在「实例化后、未进树」时用，别照抄到已进树的节点。
- 建筑碰撞：StaticBody layer=11 mask=9；车球 collision_mask 从默认 1 改成 2049（1|11），
  否则车直接穿楼（sphere 只和 layer1 碰）。楼盒用缩放后世界 AABB 精确摆位。
- 多人：scripts/net/urban_net.gd（scenes/urban.tscn 的 Net 节点），复用 autoload Lobby（ENet 7777）。
  驾驶者权威 + 20Hz unreliable_ordered 快照；远端车 set_physics_process(false)+sphere.freeze 照抄位姿。
  Tab 开面板（开房/输IP加入/退出）；命令行 `-- --net-host` / `-- --net-join=IP` 双实例冒测通过。
  坑：create_client 后到 CONNECTED 前的窗口期发 RPC 报 "not connected"，
  发前必须查 `multiplayer.multiplayer_peer.get_connection_status() == CONNECTION_CONNECTED`。
  坑：`multiplayer.multiplayer_peer as SceneMultiplayer` 解析期就报 Invalid cast，用基类 MultiplayerPeer 接。

## 都市 v1.2 地形与植被（2026-10-03，#16/#17 实测坑库）

- **物理后端已切 GodotPhysics3D**（project.godot `3d/physics_engine`）：Jolt 会**静默忽略
  CollisionShape3D.scale**，HeightMapShape3D 的 65×65 地图被压成 1×1m 方块，全城射线恒返回同一值。
- **HeightMapShape3D 实测**：格点间距恒 1 米、extent = map_width 米（terrain.gd 头注「extent 恒 1×1」是错的）；
  要 4m 格距 → `CollisionShape3D.scale = (步长,1,步长)` 摆块中心。AGENTS 硬约束 6 是对的。
- **三角绕序 = 命**：`(a,c,b)+(c,d,b)`（terrain.gd 抄来的）generate_normals 出 **-Y 法线**，
  网格内侧翻，射线和刚体接触从上方全部穿模，两个物理后端表现一致。正确：`(a,b,c)+(b,d,c)`。
  ⚠️ nagrand 的 terrain.gd `_add_chunk` 仍是错误绕序，未修（该场景已知问题）。
- **trimesh（create_trimesh_shape）别给刚体当地面**：射线能命中，球体接触会陷进山体 15m+。
- **Color8 直接喂渲染管线会被当线性值**：sRGB 104 的草绿渲成 168 的淡薄荷（整张地形发白），
  深绿 tint 又渲成黑斑。一律先 sRGB→线性（urban_terrain.gd `_srgb8`）再喂 set_color/albedo。
- **射线 mask 与车自身层重叠**：车 sphere 在 layer 8，mask 11 含 bit8 → 验证射线先 `q.exclude=[sphere.get_rid()]`，
  否则 diff 恒 -1.00（打到自己车顶）。
- **地形与城市共存**：dc≤205 恒 -0.08 沉在城市地面板（顶 0.0）底下，不 z-fight 不抢碰撞；
  高度真值唯一入口 `Terrain.ground_height(x,z)`，植被/出生点都从它取数。
- **壁脚不能早于 452**：曾 smoothstep(292,452)，可驾驶丘陵下藏 55m 壁高，车一出城顺壁滑 11m。
- **纳格兰 `_spawn_kind` 没把 TINT_* 传给 prop_material**，props 全渲成默认灰 —— urban 版已修，nagrand 未动。
- SceneTree 探针里自定义 helper 别依赖 `_fa` 已开（首轮 _log 没跑就 store_line → null 调用，静默丢整段日志）。

## 交互门控 InteractionGate（2026-10-03，用户指定机制，#18）

- 规则：**C1 距离 ∧ C2 模型已实例化(is_ready) ∧ C3 业务可用** 三条同时满足才显示 E 提示、才响应 E。
- 三件套：`scripts/core/interactable.gd`（基类，进树自动加 "interactable" 组，mark_ready 只许在
  模型实例化回调处调）、`scripts/vehicles/vehicle_interactable.gd`（车侧：MODE_BOARD 卡距离/远程归属，
  MODE_DRIVE 只卡刹停不卡距离——**驾驶中人在车里，player 坐标停在登车点，距离判定必须旁路**）、
  `scripts/core/interaction_gate.gd`（全局唯一：_process 选最近合法目标写 prompt.visible/text，
  _unhandled_input 二次校验后分发 on_interact）。
- urban_game 不再自己判距离/读 E 键，只提供 can_exit_vehicle / enter_vehicle / exit_vehicle /
  is_vehicle_remote 四个回调；prompt 初值 visible=false，可见性只许 gate 写。
- 坑：门控用 **_unhandled_input 而不是 _input**——网络面板 LineEdit 要先吃掉按键，否则输 IP 时每敲一个
  e 都触发上下车。
- 探针坑：交互距离类测试点**别放在城外山坡**（人物落地即滑走，距离断言假失败），城内平坦角
  (±110,±110) 距最近车 87m，是现成的「远离所有车」负例位。验证器 `Temp/v18_shot.gd`
  → `Temp/v18_report.txt`（8 项断言 + 幽灵车 mark_ready 负例）。

## 都市 v1.3（2026-10-03，#19 下车落点 + 联机大厅）

- **车辆根节点 = 出生锚点，永远不会跟着开！** vehicle_arcade 物理在子节点 Sphere 上，
  模型每帧 `vehicle_model.position = sphere.position - 偏移`（根局部坐标）。
  凡是要「车现在在哪」的地方（下车落点、交互距离、门控排序、网络广播）**一律用
  `get_vehicle_position()`（模型世界坐标），不许读 `car.global_position`**。
  「下车后人不知道出现在哪」= 拿锚点当车位 + 落点高度写死 0.1 两个 bug 叠加。
- 下车落点：候选位按 `Terrain.ground_height` 取真实地面（城内 max(gh,0) 对齐地面板），
  探测球心放 gh+0.9（半径 0.45，别贴地否则自碰地面全判占用）；落点 y=gh+0.05。
- **OfflineMultiplayerPeer 把自身状态报成 CONNECTED**：`_net_on()` 必须
  `peer is OfflineMultiplayerPeer → false`，否则单机恒"已连接"（UI 误入房间视图 + 幽灵广播）。
- 玩家表是服务端权威：`_rpc_roster` 整表广播（有人进出就重发）；客机 _on_peer_connected
  直接 return（以前客机自己拼出个假 "1:P1"）；connected_to_server 里 erase(1) 再登记真 id。
- 大厅 UI（urban_net，Tab 呼出）：菜单/加入/房间三视图切换**只在 _refresh_net_ui() 一处算**；
  房主视图显示 IPv4 本机 IP（get_local_addresses 第一个含 "." 的，别拿 fe80:: 给好友）。
- 双实例冒测探针 `Temp/v19_net.gd`（host 要比 cli 多活 400 帧，否则客机末段采样自己断线）；
  下车/UI 截图探针 `Temp/v19_shot.gd` → v19_exit/menu/join/room.png。

## 都市 v1.4（2026-10-03，#20 金币/出租车/货运/车行商店）

- **驾驶中所有距离判定必须量「被驾驶车模型」的位置**：gate 传进来的 player_pos 停在登车点（#18 铁律），
  taxi 的 can_pickup/can_drop、HUD 剩余距离都改走 `_car_pos(_driver())`（= get_vehicle_position 兜底
  global_position）。货运同理：装/卸判定按车位置，不按人位置。
- **interact_priority**（interactable.gd 新字段，gate 先比优先级再比距离）：任务点=10，上下车=0。
  没有它，驾驶中「按 E 下车」永远比任务点近（人就在车上），所有zone交互被下车抢走。
- **`--script`（SceneTree 脚本）里联机引导时序**：`multiplayer` 标识符不存在；`_initialize` 里
  `root.get_multiplayer()` 是 null；`root.multiplayer` 只读；Window 没有 set_multiplayer_peer。
  正确姿势：`await` 两帧 → `var mp = root.get_multiplayer()`（自动建 SceneMultiplayer）→
  `mp.multiplayer_peer = peer` → 信号挂 mp.peer_connected/peer_disconnected。
- 4.7 解析怪癖：`tr("…%d").arg(x)` 报「Cannot find member arg in base String」→ 用 `tr("…%d") % x`。
- 4.7 `Node3D.visible` 实测存在（use=6），经济货箱/世界标记、货堆子箱显隐都可直接用。
- **车斗货堆必须两遍扫描**：第一遍给 loaded_by 里每辆缺堆的车建堆；第二遍遍历全部 `_bed_piles`
  把子箱 `visible = k < n`。只扫 loaded_by 会漏「卸货后该玩家不再有记录」的堆，货卸了箱子还顶着。
- 探针可重入：v20_probe 复用内存钱包，跑前必须清 economy 的 `_owned`/`_abil`，否则第二次价格断言全歪。
- host 权威结算链：客机 only 发 `_rpc_*_intent`；host 改钱包后整表 `_rpc_snapshot` + 3s/4s 心跳补晚进者；
  客机掉线 → host 把它的已装量回退（stock 恢复、loaded_by 剔除），双实例实测 0 fail。
- 验证：`Temp/v20_probe.gd` 单机全流程 50 断言全过；`Temp/v20_host.gd`+`v20_client.gd` 双实例
  （装货→卸货领薪→二次装货→掉线回退）；`Temp/v20_shot.gd` 4 张 GUI 截图（招手/送达光柱/车行面板/货堆）。

## 都市 v1.5（2026-10-04，#21 任务框架 + 僵尸波次防守）

- **DirectionalLight3D 没有 `directional_light_color`**（那是 Environment 的属性名），太阳染色用
  `light_color`。写错会每帧报 Invalid assignment，且 GDScript 运行时错误只中止当帧调用栈——
  _apply_night 里排在它后面的环境插值全都不执行，表现为「天黑只暗不蓝」。
- **`_zombies.keys()` 是快照**：循环内咬人→server_damage→死满 3→server_fail 会 `_zombies.clear()`，
  下一圈旧 eid 直接 Invalid access key '9'。同循环里可能清表的一律先 `has(eid)` 再取。
- **Hitscan 判定与探针数学**：server_gun 的命中圆柱中心在 `pos+(0,0.9,0)`、半径 0.55——
  探针若把射线终点设在脚边（+0.9−0.9 抵消），d²=0.81>0.3025 永远脱靶，波次看似「打不死」。
  本轮 10 连 FAIL 的元凶就是探针自身瞄准错，不是游戏逻辑。
- **Interactable extends Node（不是 Node3D）**：`spot as Node3D` 得 null；距离判定把 world 坐标
  直接喂 can_interact 即可。
- **rpc 不回首发包（沿用 #20）**：host 的 broadcast_defense 在联机要 rpc + 本地照样 apply_state，
  否则 host 自己的视角停在旧阶段；单机（net off）只走本地 apply。
- **墓园包 GLB 有 root motion**：内层模型每帧把 x/z 钳 0，世界位移只写外层 Node3D；
  原始 AABB 高约 0.6m，统一缩到 1.7m。
- **DAWN 天亮是 4 秒插值**：探针在切相位当帧读 night 会拿到 0.79 的中间值，断言必须等插值走完。
- 验证：`Temp/v21_probe.gd` 单机 25 断言全过（BOARD→5 波→交付+1000→死 3 次扣 100 全流程）；
  `Temp/v21_host.gd`+`v21_client.gd` ENet 双实例 0 fail（客机射击由 host 判杀、快照对齐钱包、
  掉线后 host 存活继续）；v20 回归 0 fail（mission_base 抽基类未伤出租车/货运）。

### 都市 v1.5 试玩修复轮（2026-10-04，#22~#24，照抄 Starter-Kit-FPS）
- **Control 的 PRESET_CENTER 锚点预设不改 offsets** → 0×0 控件，Label 文字根本不绘制
  （「准星没有显示」真凶）。修法：TextureRect + 显式 offset ±24 + crosshair.png。
- **车碰墙飞天根因**：handle_input 每帧给球体 angular_velocity 灌 abs(linear_speed)*100 顶部旋转
  （轮子是纯视觉的，这行毫无用处）+ tscn PhysicsMaterial friction=5 → 撞墙变网球弹射。
  修法：`sphere.angular_velocity = Vector3.ZERO` + 两个 tscn friction 归 0。
- **射击反馈全部零额外 RPC**：攻击动画状态塞进 10Hz 状态包 a[7]（0待机/1步行/2攻击窗口），
  host 开咬时 z["atka"]=0.6；复制品据此播 graveyard 的 attack-melee-* 片段。
- **玩家射击动画**：工作区三套 animated-characters 都只有 idle/run/jump，没有 shoot 片段；
  照抄 demo 的做法是「枪口火光(burst.png 两帧图集取一帧) + 枪身后坐上跳 + 镜头 _pitch 上跳」，
  不是骨骼动画。要真射击姿势需 Mixamo/外部动画 → 走 AGENTS.md §3.5 审批流程再定。
- **GameAgent 参考路径 D:\AI\UnityProject\ 不存在**；用户改口直接照抄
  `参考项目\KenneyNLDemos\Starter-Kit-FPS`（准星/枪模/burst 火光/blaster 音效已搬入
  `assets/kenney-fps/`）。
- **AGENTS.md 新增 §3.5**：新功能先搜工作区现成 demo→审批；无则网搜下载到 Workspace/Download→二次审批。
- 验证：v21 单机 31 断言 0 fail（新「阶段 2.5」：attack 片段实播/MuzzleFx/镜头后坐/准星贴图）；
  v22 撞车探针 7/7（怼 6m 高楼 y 恒 0.00、自旋 0.000、街树 128+树 260+岩 90 碰撞体全挂）；
  MP host/client 对 0 fail；GUI 4 连截图（v21_shot_2_muzzle / 2b_attack 准星+火光+攻击+血条同框）。

### #25 持枪/射击动画重定向烘焙（2026-10-04，方案 A 落地）
- **墓园包（graveyard）的 holding-*/shoot 是「刚体部件」动画**：动画驱动的是 glb 里的
  arm-left/arm-right/torso/head/leg-* 节点，不是骨骼；holding-* 是单键静态姿势，shoot 是 5 键
  （0→0.033→0.10→0.133→0.20，臂 X 轴偏角峰值≈7.5°）。部件节点默认变换是 **T-pose（identity）**，
  垂手 45° 姿势藏在它的 `idle` 片段里 → 拿部件静止态当对齐基准必错。
- **【最大的坑】characterMedium.fbx 的骨架局部系是 FBX 源 Z-up**：`Root` 节点挂了 100×缩放 + −90°X
  修正（`Temp/axis_probe.gd` 实测），所以 `get_bone_global_pose()` 读到的方向是「局部系」的。
  换算 **world(x,y,z) → local(x,−z,y)**；方向常量不换算就会「举枪变举手」（手臂指向 +Y）。
- **跨模型绝对映射 A = 骨idle世界基 · 部件idle世界基⁻¹ 有绕轴 twist 歧义**：躯干勉强能用，
  手臂会把抬臂映到身后、骨盆 180° 翻面。定稿写法：躯干/头/腿直接保持人物 idle 姿势，
  只有手臂 4 骨（RightArm/RightForeArm/LeftArm/LeftForeArm）给「世界系指向」+ 最小弧旋转构造，
  后坐角从源片段臂轨道采样（×2 放大）再 `_pitch` 抬枪。
- **人物模型与僵尸都面向 +Z**（pose_front 相机在 +Z 侧拍到胡子脸）；两侧 right 骨在 −X 侧。
  人物臂骨 local **Y 轴 = 沿臂方向**（bake_check 实测）。
- **枪模不用 BoneAttachment3D**（实测其下 glb 不渲染）：挂 model_pivot + 每帧
  `_gun.global_transform = 手骨全局变换(正交化) · GUN_IN_HAND`，手骨 Y 轴 = 指向 → 枪管 +Z 映到手 Y；
  这样后坐时枪跟手一起抬（固定偏移会在 shoot 的 0.2s 里脱手）。
- **Godot 4.7 API 实测**：`Basis.xform()`/`affine_inverse()` 已删（用 `*` 与 `inverse()`）；
  `get_animation_list()` 返回 PackedStringArray（不能 `.keys()`）；AnimationPlayer **没有**
  `get_playback_position()`，取当前进度用 `get_current_animation_position()`；
  `add_animation()` 在 AnimationLibrary 上，AnimationPlayer 只有 `add_animation_library()`。
- **idle.fbx 片段名是 `Root|Idle`**（不是 idle），轨道路径 `Root/Skeleton3D:骨名`，骨名在冒号后。
- 验证：`Temp/bake_check.gd`（离线把烘焙值灌回骨骼读世界方向，臂指向 == 常量）+
  `Temp/shoot_apply.gd`（headless 真 AnimationPlayer：hand_dir y 从 −0.004→+0.245→回 0，后坐确实烘进片段）+
  GUI `Temp/pose_shot.gd` 三图（pose_hold / pose_front / pose_shoot 峰值帧枪随手抬）；
  v21 单机 0 fail、v20 0 fail、MP host/client 各 0 fail（host 首轮那条「4 只=3」是 0.25s 轮询与
  客机首杀的竞态 flake，复跑 0 fail）。

### 外部 Unity 素材拆包 + 骨架 API 补充（2026-10-04，#26/#27 勘察）

- **Unity .assetbundle 拆包管线可用**：venv 在工程外 `D:/AI/GodotProject/vam-tools/.venv`（`pip install UnityPy`，
  1.25.4，**不再依赖 numpy**，脚本里别 import numpy）。`obj.read()` 出来的类名才是真类型（`obj.type` 给 int、
  `object_info` 常为 None）；`Mesh.export(path)` 签名是 `export(format="obj")` 返回**字符串**不是写文件。
- **Unity 左手系 → Godot 右手系**：顶点 X 取反 + **三角形绕序必须反转**，否则整个模型法线朝内（`Temp` 外的
  `vam-tools/fix_obj.py` 已实现；`UnityPy.export/MeshExporter.export_mesh_obj` 内部也是这两步一起做）。
- **Godot 4.7 Skeleton3D/Skin 真实 API**（本机 dump，见 `Temp/skel_api_report.txt`）：取 rest 用
  `get_bone_rest(i)` / `get_bone_global_rest(i)`（**没有** `get_bind_pose`/`get_bone_bind_pose`）；
  `Skin` 用 `get_bind_count()`（**没有** `get_bind_pose_count`），加绑用 `add_named_bind`/`set_bind_bone`/`set_bind_pose`。
- **`-s` 探针脚本入口必须是 `_initialize()`**，写 `_init()` 会卡在 SceneTree 启动里直到看门狗超时（exit=124，
  且报告文件不生成，容易误判成"没输出"）。
- characterMedium 骨架实测 **58 骨**（Hips/Spine/Chest/UpperChest/Neck/Head + 左右 Shoulder/Arm/ForeArm/Hand
  + Index1-3/Thumb1-2 + UpLeg/Leg/Foot/Toes，另有一批 FootCtrl/HeelRoll/KneeCtrl/IK 控制器骨和 `*_end` 叶骨），
  蒙皮网格 binds=45；清单落盘 `Temp/rig_probe_report.txt`（自动绑骨方案对齐关节位置就用这份）。

### Blender headless 绑骨 + 「绝对局部旋转」这条硬事实（2026-10-04，#27）

- **Blender 5.2.2 LTS**（`C:/Tools/blender/blender.exe -b --factory-startup --python x.py`）API 断代清单：
  `bpy.ops.import_scene.obj` **已删**（OBJ 必须先转 GLB，见 `vam-tools/obj2glb.py`）；`Action.fcurves` **已删**
  → 走 `action.layers[].strips[].channelbag(slot)` + `action.slots`；`bpy.ops.object.parent_clear(type_clear=…)`
  **关键字不认** → 父子关系用矩阵自己记（`matrix_parent_inverse = arm.matrix_world.inverted()`）；
  `EditBone` **没有 `direction`** 属性（用 `tail - head`）。
- **bone heat weighting 在 0.01 尺度直接 `failed to find solution`**：结果是 0 权重 → GLB 里 `skins: []` →
  Godot 报「没有 Skeleton3D」。顺序必须是**原尺寸绑骨 → 再缩到 0.01 → transform_apply**。
- 【**最重要**】**Kenney 的 idle/run 轨道值是「绝对局部旋转」，不是相对 rest 的增量**（实测 run 里
  `HipsCtrl` 的四元数 = 180°绕(0,1,−1)，正好等于它自己 rest 的朝向）。所以往新骨架搬剪辑时，
  **同名骨的 rest 朝向必须和源骨架一致**，否则同一批四元数落到差 180° 的轴系上，整个人在髋部翻面
  （而 idle 因为几乎不动，看起来是好的——最容易骗人的假绿灯）。
  修法：拟合关节位置后，把每根骨的 `direction` + `roll` 按 FBX 原值写回（head 位置与骨长保留我们量的），
  **顶点权重不用重算**（权重只认骨名，不认 roll）。
- **GLB 必须 `export_yup=False`**（保住 FBX 源的 Z-up 骨空间），Godot 导入后在根节点补 −90°X 站直；
  导成 Y-up 的话同一批旋转曲线会把人物直接放倒。
- **Godot 4.7 `Skeleton3D` 没有 `get_transformed_aabb()`**（3.x 的 API 已删）；posed 外框只能自己按骨位推算，
  或退用绑定姿势的网格盒（站姿下等价，够定身高/落地）。
- **Animation 轨道类型编号**（本机 dump）：`0=VALUE 1=POSITION_3D 2=ROTATION_3D 3=SCALE_3D 4=CUBIC
  5=WEIGHT 6=NODE_3D`，**没有 TYPE_TRANSFORM_3D**。查错表会得出「idle/run 只有位移」这种整个方向都歪的假结论。
- GDScript 两条小坑：没有 `String * int`（用 `.repeat(n)`）；`Vector3` 没有 `deg_to_rad()`（逐分量转）。
- 位置轨道同样存绝对值（源骨架比我们的矮胖）→ 逐键平移成「我们的 rest origin + 它的相对起伏」，
  否则髋会整段沉进地里。
- 验证口径：`Temp/body_shot.gd` 把 −90/+90/0/180 等**四种根旋转候选全扫一遍**，用「头骨 y − 脚骨 y」
  当分数自动择优（轴向这种事先量出来再下结论，别再靠推）；`Temp/run_shot.gd` 出真实 `urban.tscn` 图。

### 卡通着色 + 反壳描边（2026-10-04，#28）

- **4.7 材质 API 实测**（dump 见 `Temp/mat_probe_report.txt`）：`BaseMaterial3D` **没有** `SHADING_TOON`
  （`ShadingMode` 只有 UNSHADED/PER_PIXEL/PER_VERTEX），也**没有** `outline_enabled`/`outline_size`/
  `toon_diffuse_expand`/`rim_size`；`rim_enabled/rim/rim_tint` 倒是有。结论：色阶靠
  `diffuse_mode=DIFFUSE_TOON` 或自写 `light()`，**描边只能自己写**。
- 自写 `light()` 只写 `DIFFUSE_LIGHT` 时**不吃环境光**（本项目的 sky/ambient 进不来），必须自己补一条
  `ALBEDO * fill_light` 底光，否则背光面纯黑。色阶算法照抄工作区
  `ref/GodotVehicle/Material/Paint/Toon.gdshader`：`floor(ndotl*steps)` + 档间 `smoothstep`。
- 【**别再上当**】Godot 里量「三角形法线 vs 顶点绕序叉乘」，**接近 100% 反向才是健康的**：
  glTF/OBJ 用逆时针正面、Godot 用顺时针正面，导入时整体翻绕序，所以正常面一律与叉乘反向。
  真正的毛病是**少数派**（本项目实测 44474 个三角里有 84 个朝向与其余不同）。
  上一轮把 99.8% 当成 bug，白跑一次 Blender 往返。
- **Blender 修法顺序有硬约束**：`customdata_custom_splitnormals_clear()` + `normals_make_consistent(inside=False)`
  必须放在 `parent_set(type="ARMATURE_AUTO")` **之后**。放前面会在非流形处把网格搞成
  `Mesh Body is not valid`，heat 求解跟着少算 304 个顶点（weighted 24675/24675 → 24371/24675）。
- **`Skeleton3D` 的直接子节点是按顺序当骨头用的** → 蒙皮网格的描边副本**不能 `add_sibling`**（会被丢到
  某根骨的变换上）。正确做法：`src.add_child(twin)`，且 `twin.skeleton = NodePath("../" + src 到骨架的相对路径)`。
- **反壳厚度是「模型局部单位」**：本项目素体 fit 后总缩放约 42 倍，直接写 0.01 会变成 42cm。
  按世界毫米给值，再除以「网格节点→本节点」链路上的缩放乘积（`_chain_scale()`，
  别读 `global_transform`，`_ready` 当帧它是旧的）。
- **反壳在四肢空档会露出整片背面**（肩窝、胯缝的大黑斑，与厚度无关）。解法：fragment 里做掠射裁剪
  `if (abs(dot(normalize(NORMAL), VIEW)) > grazing_cut) discard;`，默认 0.75。
  阈值不能太小：保留带是 r > cos(asin?)≈0.714R，cut=0.35 时描边会**脱离剪影**浮在空中。
- 反壳跑在 `vertex()` 里 = 位移发生在**蒙皮之前**，所以权重差的关节（自动权重在腋窝）会把壳拉成膜；
  这是反壳法在蒙皮角色上的固有代价，不是 bug。
- **透视分层别用 `visible=false`**（壳是本体的子节点，藏父连子一起藏，白测一轮）。
  把另一层的 `mesh` 临时摘成 null 即可。另：4.7 的 `Camera3D` **没有 `enabled`、也没有 `visibility_mask`**
  （是 `current` / `camera_cull_mask`），赋错属性会让 `_run()` 整段中止、GUI 挂死不退。
- 验证口径：`Temp/toon_shot.gd`（灰模/4.5mm/8mm 三对照）+ `Temp/hull_only.gd`（本体、反壳、叠加三张
  分层透视，直接看壳的几何对不对）+ `Temp/toon_game.gd`（不 new 任何东西，只拍 `urban.tscn` 里出厂节点）；
  回归 `Temp/v21_probe.gd` 39 断言 0 fail。

### 小区挂载 + 一次性生成器（2026-10-04，#29）

- 【**headless `--script` 里 `_initialize()` 阶段 `add_child` 之后读不到真变换**】
  `global_transform` / `global_position` 一律返回单位阵，只对 `!is_inside_tree()` 有意义。
  两条出路：① 一次性生成器自己算变换（局部盒 × scale → 绕 Y 转 → 加位移），不碰引擎全局矩阵；
  ② 体检/截图脚本走 `change_scene_to_file()` + `await`，进真场景树之后才敢读 `global_transform`。
- 【**`PackedScene.pack()` 只收 `owner != null` 的节点**】生成器里 `add_child` 完直接 `save()` 会得到
  一个 76 字节的空壳（只剩根节点），而且 `ResourceSaver.save()` 返回 0，**不报错**。
  补 `owner` 时只许填 `owner == null` 的那些：把 FBX 实例内部节点的 owner 抢过来会破坏实例覆盖关系。
- 【**`AABB()` 默认 size 是 `(-1,-1,-1)`**】空盒用 `size.length() <= 0.001` 挡不住，会把盒子中心污染成
  垃圾值。判空一律用 `box.has_volume()`。
- 【**旋转体的世界 AABB 角不是物体上的点**】院落旋转 24° 后，世界 AABB 的最近角是「空气」，
  量出来 39.6 m 像是压路；换成院落自己的 4 个局部 XZ 角经 `global_transform` 换算，真实最近角 127.9 m。
  量净距必须用**角点**，不能用 AABB 边。
- 【**别把 scale 乘两次**】从实例根算局部盒时若连根的 `scale` 一起收（`get_aabb()` 已含），
  后面再乘一次 S=4.8 就是 S²=23 倍虚胖（实测 46 m 院落被算成 225 m）。起点要取**子节点**，
  且 `inv * vi.global_transform` 已经是「vi 局部 → n 局部」的完整变换，再乘一次世界坐标就是同一个错。
- **Kenney City Kit Suburban 2.0 事实**：40 个 FBX（building-type-a…u、9 种 fence、2 车道、5 小径、
  planter、2 树），网格基准 1 tile ≈ 0.42 单位 ⇒ **S=4.8 时 tile ≈ 2.0 m**；住宅 5.94 m、围栏 1.30 m、
  树 3.7 m，对 1.60 m 人物 = 3.71 倍（两层住宅正常比）。FBX 里贴图写的是 `Textures\colormap.png`
  相对路径 ⇒ `models/suburban/` **必须连 `Textures/` 子目录一起搬**，否则全部渲成白模。
  本项目 `project.godot` 默认关 FBX 导入，这次是 `--headless --import` 现开的，别误以为 FBX 一直可用。
- **urban 地图的硬边距常量**（落位判据，别再量错）：路网占 ±121 m、街树环 124 m、草地板 ±198 m、
  地形起坡 205 m；`_height_at` 在 Chebyshev ≤ 205 恒为 **-0.08**（平底），所以小区底 y=0 是贴地不是悬空。
- **随机落位必须固定 seed**：静态几何不进 `urban_net` 的复制通道（它只同步位姿 20 Hz），
  两端各 `randf()` 就会出现「host 见小区在西北、访客见在东南」。`suburb_placer.gd` 用
  `RandomNumberGenerator.seed` + 64 次候选 + 兜底位，纯函数式可复现。
- 验证口径：`Temp/suburb_verify.gd`（headless 落位体检，8 行判据）+ `Temp/suburb_shot.gd`
  （GUI 三图：远观城乡关系 / 门口 1.60 m 人视读比例 / 大门洞外视）。

### 小地图人物箭头 + 驾驶跟随（2026-10-04，#30）

- 【**同一根因修一处不够**】「车辆根节点是出生锚点、不跟车动」这条（#19）当时改了下车落点 / 交互距离 /
  网络广播三处，**`scripts/ui/minimap.gd` 的驾驶分支漏了**，于是「一开车小地图就定住」。
  实测：开 3.5 s 后根节点位移 **0.0 m**、车辆模型位移 **29.9 m**。
  统一读法只有 `get_vehicle_position()`（= `vehicle_model.global_position`）；`urban_net._send_state()`
  里那段 `if driving.has_method("get_vehicle_position")` 就是标准写法，以后凡是要拿「车在哪」照抄它。
- **正交俯视小地图的屏幕映射**（相机只绕 X 转 -90°、无偏航）：世界 +X → 屏幕右，世界 **+Z → 屏幕下**。
  所以世界水平朝向 `f` 的箭头旋转角 `r = atan2(f.x, -f.z)`（Polygon2D 尖朝 -Y、rotation 顺时针为正）。
- **前向都是局部 +Z**：人物 = `Player/ModelPivot` 的 `global_basis.z`（`player.gd` 里
  `target_yaw = atan2(dir.x, dir.z)` 已经把 `model_yaw_offset` 烘进 _model_yaw）；
  车 = `vehicle_model.global_basis.z`（`_forward_from_yaw(y) = (sin y, 0, cos y)`）。
  别用相机 yaw（`YawPivot`）当朝向 —— 那是镜头方向，不是站向。
- 验证：`Temp/mm_arrow_shot.gd`（GUI，四个站向 0/90/180/270° → 箭头 下/右/上/左 四张图 +
  驾驶 3.5 s 后「小地图↔模型偏差 0.00 m」断言）；回归 `Temp/v21_probe.gd` 断言失败数 0。

### 驾驶三档 + 速度 HUD（2026-10-04，#31）

- **档位钳的是归一化油门量 `linear_speed`（`gear_cap01()`），不是 `speed_cap()`**。钳后者的话换挡那一帧
  世界速度直接跳变，就是用户说的「车像有故障」。低档用大扭矩（`gear_torque`）补回加速感，
  于是「1 档提速猛、上限低」这个真车规律白送。
- **提速必须连带重标转向三参数**：转弯半径 ≈ v/ω。满速从 10.4 抬到 32 m/s 后，`turn_rate` 3.4→4.2、
  `lateral_grip` 3.2→5.0 同步抬，否则 115 km/h 一打方向就是原地打转 / 甩尾推不出弯。
- **HUD 做成 `scenes/urban.tscn` 下的 CanvasLayer 脚本**（`scripts/hud/drive_hud.gd`），不改 `urban_game.gd`：
  摘挂档是玩家界面的规矩，`_process` 里读 `_driving` 自己决定显隐即可，场景总管不该被塞进车辆内部状态。
- 【**探针坑·大**】**`Input.action_press("interact")` 只改动作状态、不派发 InputEvent**，而 InteractionGate
  是在 `_unhandled_input` 里 `event.is_action_pressed("interact")` ⇒ 门控根本收不到。要拼
  `InputEventAction` + `Input.parse_input_event()`（v20/v21 探针一直这么写，新探针却又踩了一遍）。
  上一版直呼 `game.enter_vehicle()` 且把人瞬移到 `get_vehicle_position()`（y≈-0.5，地面下），
  于是观测到「驾驶相机 1.5 s 后被翻回人物相机」的**假 bug**；改成真实按 E 路径（人放 y=0.9、
  站车侧 1.8 m）后，150 帧逐帧采样 **0 次翻转**，视口稳定在 `/root/Urban/View/Camera`。
  ⇒ 探针造出来的 bug 先怀疑探针自己，别急着改产品代码。
- **`get_vehicle_position()` 的 y 不能当人物落点**：车模型原点在地面下 ≈0.5 m，瞬移人会掉进地里。
- **PanelContainer 会被内容撑宽，且只往右下长**：右下角 HUD 的键位提示一行 240 px > `panel_w` 208 ⇒
  整块面板往屏幕外移、档位数字被切一半。修法：常驻文字拆独立一行 +
  `_panel.offset_left = -margin - maxf(panel_w, _panel.get_combined_minimum_size().x)`。
- **右下角只有一个位置**：`modules/fps_stats` 的调试行原先也挂右下，和玩家 HUD 叠成糊字，已挪左下。
  以后加 HUD 元素前先扫一眼 `scripts/ui/*` + `modules/fps_stats/module.gd` 占了哪个角。
- 数值表（`vehicle_arcade.gd`）：`gear_ratios [0.375, 0.6875, 1.0]` ⇒ 43/79/115 km/h；
  `gear_torque [2.0, 1.36, 1.0]`；`reverse_ratio 0.16`、`neutral_drag 0.7`、`downshift_brake 2.4`、
  `start_gear 1`。输入动作 `gear_1/2/3/r/n`（键 1/2/3/Z/X）在 `project.godot`。
  摩托 `vehicle_motorcycle.gd` 本轮**未接档位**（只有 ArcadeVehicle 有 `gear_*`）。
- 跑道选法：headless 量速度用 `x=-150` 草原（路网 ±121 之外、草地板 ±198 之内、平底区高度恒 -0.08，
  撞不到楼）；GUI 看机位用 `x=+69` 直街（两侧 23 m 外才是楼，且不是主干道、没有城内坡道楔形）。
- 验证：`Temp/gear_probe.gd`（headless，0 fail）+ `Temp/drive_hud_shot.gd`（GUI 五图 + 逐帧相机采样）
  + 回归 `Temp/v21_probe.gd`（提速后重跑，断言失败数 0）。

## 都市 v1.6 程序天空（2026-10-04，#32 方案 A）

- **动手前的实测事实**：urban 一直没有天空盒。`scenes/main-environment.tres` 的
  `background_mode=1`（=BG_COLOR 纯色填充），文件里那颗 `Sky` 是没人读的死资源。
  枚举以本机打印为准（别背文档）：`BG_CLEAR_COLOR=0 BG_COLOR=1 BG_SKY=2 BG_CANVAS=3`；
  `AMBIENT_SOURCE_BG=0 DISABLED=1 COLOR=2 SKY=3`。
- **背景资源分家**：`scenes/urban-environment.tres`（新建，`background_mode=2` +
  `ProceduralSkyMaterial` 四色）；`scenes/urban.tscn` 只把 `id="2_env"` 那行 ext_resource 换过去。
  **不能直接改 `main-environment.tres`**：它被老地图 `scenes/main.tscn` 与 `urban.tscn` 共用，
  用户已裁定「其他地图先不要管」。
- **昼夜必须跟着换轨**：#21 起夜色是 `_apply_night()` 硬 lerp `background_color` 得到的。
  背景一旦换成真天空，只改 `background_color` 就变成「地暗了、天还是白天」⇒ 现在改成驱动
  `ProceduralSkyMaterial` 的 `sky_top_color / sky_horizon_color / ground_horizon_color /
  ground_bottom_color` 四色，`background_color` 继续同步改（雾、SSIL 反射仍读它）。
- **`Resource.duplicate()` 是浅复制**：`Environment.duplicate()` 之后 `.sky` 和 `.sky_material`
  还是共享 .tres 里那一个对象，夜色一改就把资源文件涂脏（运行时看不出来，重启才恢复）⇒
  `_cache_daynight()` 里逐层各自 duplicate：`_env.sky = sky.duplicate()`、
  `_env.sky.sky_material = m.duplicate()`。
- **`SkyMaterial` 不是可写的 GDScript 类型名**（4.7 只暴露 `ProceduralSkyMaterial` /
  `PanoramaSkyMaterial` / `PhysicalSkyMaterial`）⇒ 声明 `var x: SkyMaterial` 直接 parse error；
  先接成 `Resource` 再 `as ProceduralSkyMaterial`。同理 `Color` **没有** `distance_to()`，
  比色差异要手写 `absf(dr)+absf(dg)+absf(db)`。
- **任务对象不在场景树**：`modules/missions/module.gd:32` 是 `_defense = DefenseMission.new()`
  ⇒ RefCounted。探针想拿它得先找到挂 `missions/module.gd` 的 Node，再 `get("_defense")`；
  变量类型写 `Object` 而不是 `Node`，否则运行期报类型不匹配、协程静默死掉（报告连 FAIL 行都不写）。
- **相机朝向探针坑**：`scripts/actors/player.gd` 的 `_apply_look()` **只在 `_unhandled_input`
  收到鼠标事件时才调用**，不是每帧写回 ⇒ 探针 `set("_yaw")` / `set("_pitch")` 之后必须自己
  `pl.call("_apply_look")`，否则画面纹丝不动。俯仰 clamp 是 `[-1.2, 0.6]`，**正 pitch = 抬头**。
- **`_night` 不能只 set**：`tick()→_night_logic()` 每帧按 `_phase` 算 want 值往回拽 ⇒
  强制入夜要连 `_phase="DUSK"` 一起设（副作用：会顺带起第一波怪，出图时 HUD 有「讨伐 1/5」是正常的）。
- **验证**：`Temp/sky_check.gd`（headless，取枚举与实况）+ `Temp/sky_shot.gd`（GUI 五图：
  城外平视 / 城外抬头 / 街谷抬头 / 强制入夜 / 天亮恢复；报告含「运行时 vs 共享 .tres」对照读数
  证明没涂脏资源）+ 回归 `Temp/v21_probe.gd`（0 fail，新增 3 断言：Sky 私有、SkyMaterial 私有、
  天亮后天空回到白天一侧）。
- **已知限制 / 下一步候选**：① 天空无云、无星、无可见太阳盘（B 方案范围）② 城外那座「大碗」
  的碗壁在抬头镜头里非常抢眼，天空只占顶部一小块（地形问题，不是天空问题）③ 老地图 `main.tscn`
  仍是纯色背景，按用户指令未动。
