# DESIGN：极品飞车街机操控 + 红警2式随机赛道生成

> 本文档是 **Starter Kit Racing**（Godot 4.7）的结构化设计记录，目的不是写给人看，是写给下一个 AI 看：
> 结论在前、坑位在后、验收命令直接可粘。改代码前请先读第 0 节和第 9 节。
>
> 对应任务：#21 极品飞车操控改造、#22 闭合环路随机赛道生成器、#25 红警2 掩码拼接、#27 本文档。
> 相关文件：`scripts/vehicle.gd`、`scripts/view.gd`、`tools/track_generator.gd`、`tools/track_probe.gd(.tscn)`、`tools/check_materials.gd(.tscn)`。

---

## 0. 结论前置（30 秒版）

**你现有的 Starter Kit Racing 项目本身就是好基础，不用推倒重来。**

1. **车不要换成 `VehicleBody3D`。** 现有 `scripts/vehicle.gd` 是自研的 `Node3D` + RayCast3D + `RigidBody3D`（球体）控制器，手感像"遥控玩具车"的**根因不是物理引擎错，而是没有「车头朝向」和「速度方向」的分离**。把这两者拆开，加惯性、降抓地，极品飞车手感就出来了 —— 这恰恰就是 `VehicleBody3D` 内部在做的事，自研版本照样能做，而且更可控。
2. **极品飞车手感的三个开关，按顺序调**：降抓地（甩尾）→ 转向渐进 + 高速衰减 → 相机 FOV / 距离随速度变化。三者缺一，手感就"还是那台遥控车"。
3. **随机赛道不要另造路面网格，直接铺原项目的道路 tile。** 红警2 的"区块拼接（拼图法）"是成熟解法：每个块四边用 4-bit 连接掩码标记，相邻边必须两两对得上。本项目已按此重写 `tools/track_generator.gd`。
4. **"黑乎乎"是本项目最大的坑，共 6 条硬约束 + 1 个自动体检器**（见第 6 节）。其中最容易忽略的第 6 条：`GridMap` 的 `MeshLibrary` 只认**网格内部（MeshInstance3D 内）**的材质，挂在节点上的 `material_override` 会被忽略 —— 所以道路 tile **故意不给 material_override**。
5. **所有结论都跑过 headless 验证**，不是"应该能跑"。验收命令与实测结果见第 8 节。

---

## 1. 先说成熟方案（先找成熟方案，再动手）

按前置要求，动手前先检索了三块，结论如下。

### 1.1 红警2 随机地图 —— 拼图法（已采用）

* **事实标准**：RA2 RMA（Random Map Assets）社区生成器的原话 —— 「定义每个边的连接方式，相同的连接方式相邻的边之间其地形也是相连的」。
* **数据格式**：地形块文件名形如 `1,1,1,1,01.map`，四个连续数字 = 东北/西北/西南/东南四边的连通位，`1` = 连通、`0` = 断开。带 `spawn` 的块强制当出生点块，且**分量归零、不参与连通校验**。
* **通用算法同族**：UFO: Alien Invasion 的 RMA1/RMA2 组装算法用的是同一套 —— 明确用 **4-bit 位逻辑做连接测试**（原文 `bit logic for quicker connection tests`），先放固定块/必要块，再给剩余格打分挑选，走不通就回溯。

**这套算法为什么正好适合赛车赛道**：RA2 处理的是"地形连通"，赛车要的是"赛道连通"，**规则完全同构** —— 把"这块地能走到隔壁"换成"这段路能开到隔壁"，其余一字不改。这是本项目采用它的首要理由。

### 1.2 2D 轨道生成器 → 3D GridMap（已采用为"中心线来源"）

* `Greaby/godot-2d-track-generator`（GitHub，MIT，Godot 3.3）：`TrackGenerator` 节点，参数为 **Area / Min length / Max length / 直道优先度**（`straight_ratio`），`generate()` 返回一串 `Vector2` 格子。
* 本项目搬的是它的**三件事**，不是抄代码：参数语义照搬（`area_radius` / `min_length` / `max_length` / `straight_ratio`）；输出从 2D 格子换成 GridMap 三元组；落盘从 `Tilemap.set_cell` 换成 `GridMap.set_cell_item`。

### 1.3 曲线路线：`TheDuckCow/godot-road-generator`（**不采用**）

* 确实是 Godot 官方资源库收录（#3379，MIT）的成熟曲线路线方案，`RoadManager` / `RoadContainer` / `RoadPoint` 一键连成闭合环路。
* **不采用的原因**：它要**另造路面网格和材质**。本项目要求"材质必须复用原项目资源、禁止黑块"，自造网格等于把防黑最危险的环节重新引入一遍（每次改模型都要重挂材质）。所以走红警2 掩码 + 复用原项目 tile。

> 一句话总结：**中心线从 2D 轨道生成器借，块间规则从红警2 借，落盘复用原项目 tile；不借的是路面网格。**

---

## 2. 现项目事实纠偏（读文档最容易踩的地方）

**本项目没有用 `VehicleBody3D`。** 提示词里提的 `mass≈1000 / engine_force 25-50 / brake 25-30` 是 `VehicleBody3D` 体系的术语，在本项目里**没有同名属性**。真实结构：

```
Vehicle (Node3D, class_name Vehicle)
├── Ground         RayCast3D          —— 只负责取地面法线
├── Sphere         RigidBody3D        —— mass = 1000, gravity_scale = 1.5
└── Container/Model                   —— 车模型（vehicle-truck-*.glb）
```

前进/转向由脚本里的 `linear_speed` / `angular_speed` **标量手算**，RayCast 不参与力计算。

### 2.1 参数映射表（把提示词的 VehicleBody3D 术语翻译成本项目参数）

| 提示词 / VehicleBody3D | 本项目对应 | 备注 |
|---|---|---|
| `mass` | `Sphere.mass`（1000） | 已在 RigidBody3D 上，不用动 |
| `engine_force` | `engine_power`（默认 1.1，单位 1/s） | 手算加速度速率，不是力 |
| `brake` | `brake_power`（默认 3.5，单位 1/s） | 同上 |
| **（速度量纲 + 调过一轮）** | **`max_speed` = 28.0（m/s ≈ 101 km/h）** | **linear_speed 是 0~1 归一化量，写进 RigidBody 前必须乘它，原项目漏了 → 满油门只有 1 m/s**
| `steering` | `steer_authority` + `turn_rate` | 前者管"打多大"，后者管"转多快" |
| `friction` | `lateral_grip`（默认 3.2） | **降这个值 = 降抓地 = 有惯性 = 会甩尾** |
| `engine_force 25-50` 量级 | 不适用 | 见上，本体系是手算加速 |

> 所以收到"把 engine_force 调到 40"这类指令时，**先确认它指哪个体系**，否则改了个空气。

---

## 3. 极品飞车街机操控（`scripts/vehicle.gd`）

### 3.1 手感拆成三件事

| 目标 | 实现 | 关键参数 |
|---|---|---|
| ① 转向渐进 + 高速衰减 | 方向盘一阶滞后进舵；高速时转向权限按 `smoothstep` 衰减 | `steer_response=5.0`、`steer_return=7.0`、`steer_authority=1.0`、`steer_falloff=0.55`、`falloff_start=0.35`、`turn_rate=3.4` |
| ② 惯性 / 重量转移 | **车头 yaw 与速度方向 `velocity_dir` 分离**，两者差值就是甩尾角 | `lateral_grip=3.2`、`drift_blend=0.55`、`drift_min_speed=0.12`、`pitch_gain=0.030`、`roll_gain=0.055`、`pitch_clamp=0.30`、`roll_clamp=0.38` |
| ③ 速度感 | 相机 FOV 随速度扩大 + 加速拉远 / 刹车拉近 | `view.gd`：见第 4 节 |

**甩尾的核心就一行**（别写成"抓地力=0"）：
```gdscript
velocity_dir = velocity_dir.lerp(_forward_from_yaw(yaw), 1 - exp(-lateral_grip * delta))
```
`lateral_grip` 越小 → 速度方向越"跟不上"车头 → 甩尾越夸张。调这个数比调任何 friction 都直观。

### 3.15 速度量纲：linear_speed 不是米/秒

`linear_speed` 是 **0~1 的归一化油门量**（转向衰减、引擎音高、胎噪都按它算），
真实世界速度 = `linear_speed * max_speed`，对外用 `get_speed_mps()` 拿（单位 m/s）。

**改造前这里是个 bug**：直接写进物理刚体的是归一化值，
也就是把 142 km/h 当成了 1 m/s ≈ 3.6 km/h，慢得像散步。
改车时要记住这条链路：`max_speed` 才是「多快」，`engine_power` 只是「多快到顶」。
反过来把 `linear_speed` 当速度用（比如做 HUD 显示 km/h）也会差 40 倍。

加速曲线是 `lerpf(v, target, 1-exp(-engine_power*dt))`，一阶指数趋近：
`engine_power` = 1.1 大约 1 秒到七成、2 秒到九成。

对外暴露的运行时量（相机要用）：
- `drift_angle`：甩尾角（弧度），`view.gd` 直接读它做横向让位；
- `longitudinal_accel`：真实纵向加速度，用来算抬头 / 点头；
- `visual_yaw`：`yaw` 与 `velocity_dir` 角度按 `drift_blend` 混合后的**视觉朝向** —— 车模型转这个角度，看起来就是在滑。

### 3.2 实现注意

- 视觉朝向每帧由 `steer_visual_yaw()` **从 yaw 反推变换**生成，不再用 `rotate_y` 累加 —— 累加会漂。
- `_yaw_transform()` 的基向量按右手系取 `x = y × z`。
- `effect_trails`（拖痕）改成看 `slip = abs(drift_angle) * abs(linear_speed)`，甩起来才有痕。

---

## 4. 相机（`scripts/view.gd`）

| 参数 | 默认 | 作用 |
|---|---|---|
| `distance` / `height` / `look_at_height` / `look_ahead` | 2.9 / 1.15 / 0.55 / 14.0 | 基础机位（贴身机位） |
| `distance_speed` | 0.9 | **加速拉远** |
| `distance_brake` | 0.75 | **刹车拉近** |
| `fov_base` / `fov_speed` | 70.0 / 8.0 | FOV 随速度扩大（满速 ≈ 78，再大就鱼眼了） |
| `position_smoothing` / `rotation_smoothing` / `distance_smoothing` | 7.0 / 5.0 / 9.0 | 弹簧跟随的三档阻尼 |
| `drift_offset` | 2.2 | **甩尾时相机横向让位**（镜头滞后于转向的效果） |
| `drift_smoothing` / `drift_clamp` | 4.0 / 0.85 | 横向让位的平滑与上限 |
| `wheel_zoom_*` / `zoom_min` / `zoom_max` / `zoom` | 见文件 | 滚轮缩放 |

甩尾那段的式子（这是"镜头滞后于转向"的来源）：
```gdscript
var right: Vector3 = forward.cross(Vector3.UP).normalized()
var lateral: Vector3 = right * (_drift_now * drift_offset)
eye = car_pos + Vector3(0, height, 0) - forward * _distance_now + lateral
```

---

## 5. 随机赛道生成：`tools/track_generator.gd`（红警2 掩码拼接）

### 5.1 流程（顺序不能换）

```
generate()
├─ 1. _audit_library()      扫 MeshLibrary，确认每个道路 item 有 mesh + 有材质（防黑第一道闸）
├─ 2. _build_loop()        星形多边形出闭环中心线（200 次重试 + 失败原因统计）
├─ 3. _pave_road()         中心线 → 4-bit 掩码 → 掩码匹配 tile → 铺满 track_width 宽
├─ 4. _verify_masks()      **反推**掩码做双向连通校验（断头路就重来）
├─ 5. _paint_finish_line() 首格换 finish tile（红警2 的 spawn 语义）
├─ 6. _scatter_decor()     路侧装饰，带 deco_margin 退让，禁止压路面
├─ 7. _build_floor()       兜底地面（防黑第二道闸）
└─ 8. _apply_to_gridmap()  GridMap.set_cell_item 批量落盘
```

### 5.2 4-bit 连接掩码

```
MASK_PX = 1   (+X)
MASK_PZ = 2   (+Z)
MASK_NX = 4   (-X)
MASK_NZ = 8   (-Z)
MASK_ALL = 15 （四边全通，RA2 的 1,1,1,1）
MASK_STRAIGHT_BASE = MASK_PZ | MASK_NZ = 10   （南北通 = 直道块）
MASK_CORNER_BASE   = MASK_PZ | MASK_PX = 3    （北东通 = 弯道块）
```

**掩码不是"先算好再选 tile"，而是"先铺面、再由铺面反推掩码"。** 这是踩过坑才定下来的顺序：转角处横向带会部分重叠 + 外凸一格，按中心线推算的掩码跟实际铺出的格子对不上，校验出 29 条断边。**红警2 也是看实际相邻块，不看你设计意图。**

单格掩码（第 i 格）由出向决定：
```gdscript
mask = (1 << out_i) | (1 << ((out_i + 2) % 4))   # 出向 + 出向掉头 180°（即来向）
```
> 这里修正过一个真 bug：最初把"入口方向"写成了出口的反向，导致转角永远识别不出，391 格全是直道、corner 块 0 个。

### 5.3 MeshLibrary item 编号（`models/Library/mesh-library.tres` 实际顺序）

| id | 名字 | 用途 |
|---|---|---|
| 0 | decoration-empty | 空（探针用） |
| 1 | decoration-forest | 树 |
| 2 | decoration-tents | 帐篷 |
| 3 | track-corner | **弯道块** |
| 4 | track-finish | 起跑线 / 出生点块 |
| 5 | track-ramp | 坡道 |
| 6 | track-straight | **直道块** |

关键字识别沿用红警2「文件名带什么关键字就是什么块」的约定：名字含 `straight` → 强制直道块；含 `curve` / `corner` → 强制弯道块；含 `finish` / `start` / `ramp` → 视为**出生点块，掩码分量归零、不参与连通校验**。

### 5.4 主要参数（已配平）

```gdscript
# 赛道形状（对应成熟生成器的 Area / Min / Max length）
area_radius      = 22     # 面积半径（格）；1 格 = cell_size = 10 世界单位
min_length       = 60     # 闭环最短长度
max_length       = 160    # 闭环最长长度
straight_ratio   = 0.55   # 直道优先度，沿用 2D 轨道生成器同名参数
straight_span_min/max = 2 / 5
turn_chance      = 1.0
# 赛道尺寸
track_width      = 4      # < 3 会被强制抬到 3（提示词硬要求：至少 3 格可通行）
road_layer       = 0
clear_first      = true
pave_attempts    = 6      # 铺面 + 连通校验也纳入重试（转角错位偶发）
# 装饰物
decorate         = true
deco_margin      = 2      # 距路面至少留 2 格
deco_reach       = 4
deco_density     = 0.35
deco_items       = [1, 2]        # forest / tents
# 兜底地面（防黑第二道闸）
footer_floor     = true
floor_size       = 400.0
floor_color      = Color(0.42, 0.66, 0.36)
floor_y          = -0.35
# 随机
seed             = 0      # 0 = 用时间
# 场景引用
gridmap          = <拖进来的 GridMap>
```

> **参数之间量纲是绑死的**：`area_radius=34` 对应周长约 214 格，直接卡死 `max_length=130`，200 次全部「长度不达标」。改成 22/60/160 后 8/8 seed 通过。改这两个数之前先粗算一下周长。

### 5.5 闭合环路怎么保证

**随机游走 + BFS 回程是错的**（实测 120/120 失败）：游走从原点出发会把自己绕成一圈围墙，把回程目标封死在里面，BFS 进不去。

改用**星形多边形（star-shaped polygon）+ 曼哈顿 L 形连接**：先随机打 N 个方位角顶点、半径带扰动，相邻顶点用 L 形直连，几何上天然保证闭合且不自交，再校验长度与自交。

失败原因会统计并打印（`长度不达标` / `自交` / `末梢`），否则调参就是在黑屋里换 seed 撞运气。

---

## 6. 防黑乎乎：6 条强制约束 + 自动体检

### 6.1 六条硬约束（改任何东西都别破）

1. **禁止裸网格**：任何 `MeshInstance3D` 必须有材质。有 P0 一律判 FAIL。
2. **复用项目已有材质**，不新建空材质。
3. **依赖顶点色的，必须开 `vertex_color_use_as_albedo`**，否则整片塌成一个色（看着就是"没贴图"）。
4. **道路 tile 用原项目的地面材质**，不能用 Godot 默认灰。
5. **场景必须有 `WorldEnvironment` + `ProceduralSkyMaterial` 兜底环境光**。
6. **GridMap 的 MeshLibrary 只吃"网格内部"的材质**：材质挂在 `MeshInstance3D` 内部才生效，挂在节点上的 `material_override` 会被忽略。
   → 因此**道路 tile 故意不加 `material_override`**，否则会把 tile 自带的 colormap 盖成纯白/纯黑。

外加两道兜底闸：`_audit_library()`（铺盘前机械断言每个 item 有 mesh 有材质）+ `footer_floor` 400×400 兜底地面。

### 6.2 是否需要临时防黑提示词原文（留给后来的 AI 直接抄）

**【通用防黑材质提示词】**
> 任何新加的 3D 物体必须有且只有一个明确来源的材质，禁止出现无材质的纯黑网格；所有材质必须复用项目 `materials/` 下已有的资源，不得新建空白材质；若模型的颜色来自顶点色，必须开 `vertex_color_use_as_albedo`；道路类物体必须使用项目原有的地面/沥青材质，禁止使用引擎默认灰材质；场景中必须有 `WorldEnvironment` + `ProceduralSkyMaterial` 作为环境光兜底；GridMap 的 MeshLibrary 材质必须挂在网格内部，节点上的 material_override 会被忽略。

**【最稳妥的避坑提示词（推荐）】**
> 生成任何网格前，先确认它的材质槽非空且反照色最亮通道 ≥ 0.12；如果是从 glb/fbx 导入的模型，材质内嵌在 mesh 里也算数，但要验内嵌材质的反照色；铺盘前对 MeshLibrary 的每个 item 做一次材质断言，缺材质直接报错而不是等画面出来才发现黑块。

### 6.3 体检器：`tools/check_materials.gd`

```
# 地图2（迷你中国城）
Godot.exe --headless --path . res://tools/check_materials.tscn
# 地图1（官方赛道）
Godot.exe --headless --path . res://tools/check_materials.tscn -- res://scenes/main.tscn
```

判定口径：
- **P0** 裸网格（无 `material_override` 且 mesh 无材质槽）→ FAIL；
- **P1** 反照色过暗（最亮通道 < `MIN_ALBEDO`=0.12），**包括 mesh 内嵌材质的反照色**；
- **P2** 提示项（纯白反照却没开顶点色开关、裸模型但内嵌材质已验不过黑）。

> 一个口径教训：最初只报"裸模型"不查内嵌材质，结果 24 个车模全挂 P2、真黑的反而被噪音盖住；改成"验内嵌材质反照色"之后才是有意义的分级。

* 退出码：0 = 通过，1 = 有 P0，2 = 场景加载失败（可接 CI）。

---

## 7. 验收方法与实测结果

### 7.1 赛道生成器探针 `tools/track_probe.tscn`

```
Godot.exe --headless --path . res://tools/track_probe.tscn
# 报告落 res://Temp/track_probe.txt
```

探针检查项（**不信生成器内部，只信写进 GridMap 的东西**）：
1. `[orient]` 24 项正交朝向表 + 往返一致性（用 `get_basis_with_orthogonal_index` 自证）；
2. `[mat]` 从 MeshLibrary 读 item 3/4/6 的材质槽，断言非空；
3. `[mask]` 反推掩码：路面格数、deg==1 的格（闭环里必须 0）、掩码直方图；
4. `[hist]` item 直方图 + orientation 直方图；
5. `[flood]` 从任意路面格 flood fill，确认整条路连通（无孤立碎片）；
6. `[decor]` 压在路面上的装饰物个数（必须 0）；
7. `[sweep]` 8 个 seed 的成环成功率。

**实测（seed 扫描 8 个）**：`generate()` 全绿；item 分布 `straight 340 + corner 51 + finish 1`；四个朝向（index 0/10/16/22 ↔ ±Z ±X）都出现；flood 连通 392/392；`deg==1` = 0；压路面的装饰物 0 个。

### 7.2 材质扫描实测

| 场景 | MeshInstance3D | P0 | P1 | P2 | 判定 |
|---|---|---|---|---|---|
| `res://scenes/city.tscn` | 11 | 0 | 0 | 0 | PASS |
| `res://scenes/main.tscn` | 24 | 0 | 0 | 24（车模内嵌材质已验不过黑） | PASS |

### 7.3 跑之前先清脚本缓存

```
Remove-Item .godot\script_cache.bin -Force
```
`--check-only` 会走 `.godot` 的脚本缓存，缓存脏的时候它报"通过"，实际跑起来才是 Parse Error。**验收前不清缓存 = 假绿灯。**

---

## 8. 坑位清单（按踩坑次数排序）

| # | 坑 | 症状 | 解法 |
|---|---|---|---|
| 1 | `GridMap.set_cell_item(cell, item, orientation)` 第 3 参是 **int** 不是 Basis | 照 4.0 老教程传 Basis → `should be int but is Basis` | 传 int；4.7 也没有 `Basis.get_orthogonal_index()` |
| 2 | 想拿这个 int，网上能查到的 `_ortho_bases` 24 项是引擎实现细节，抄进来版本一换就静默错位 | 路面朝错方向，还不报错 | 用公开 API `GridMap.get_basis_with_orthogonal_index(i)` / `get_orthogonal_index_from_basis(b)` 自证（官方 4.x 文档里就是这两个口子） |
| 3 | `GridMap.INVALID_ITEM` 不存在 | `Cannot find member INVALID_ITEM in base GridMap` | 直接 `set_cell_item(cell, -1, 0)` 或清格用 `clear()` |
| 4 | **headless 下 GridMap 不建子网格**（`get_child_count()=0`，且 `GridMap.update()` 不存在） | 运行期读不到子 transform，别想"跑起来探测朝向" | 用静态表 / 公开 API 换算 |
| 5 | Godot 4.7 的 `MeshInstance3D` **没有** `get_material_slot_count()`；`Mesh/ArrayMesh` 也**没有** | `Nonexistent function ... in base MeshInstance3D`，整个体检崩掉 | 用 `mesh.get_surface_count()` 和 `mesh.surface_get_material(i)` |
| 6 | GDScript 里 `%` 优先级 **高于** `+` | 写 `"a" + "b" % args` → 格式化只作用在最后一段，报 `not all arguments converted`，极难定位 | 整段拼接套括号再 `%` |
| 7 | 函数内声明嵌套函数（内嵌 lambda） | `Standalone lambdas cannot be accessed` → Parse Error | 抽成独立方法（`_walk_push` 就是这么来的） |
| 8 | `_process(dt) -> bool` 签名不匹配父类 | Parse Error | 必须 `-> void` |
| 9 | `const X: PackedStringArray = PackedStringArray([...])` | Parse Error（const 不是常量表达式） | 改成成员 `var` 或在方法里初始化 |
| 10 | `var gen: TrackGenerator = ...`（class_name 未注册时） | `Could not find type TrackGenerator` | 去掉类型注解，用 `var gen = ...` |
| 11 | 同一循环里 `var in_dir` 声明两次 | `Already declared as variable` | 合并声明 |
| 12 | LCG 状态 mask 到 63 位后 `_s >> 11` 最大只能到 2^52-1，除以 2^53 → `_rnd()` **永远 < 0.5** → `_ri(2)` 恒为 0 | 帐篷一个都铺不出来、角点数全被压在低段（症状是"形状变小变呆"） | RNG 位移取高位时同步换除数 |
| 13 | 探针脚本自己挂场景上，`.tscn` 里 `NodePath(".")` 绑 `gridmap` 常静默变 null | 报错信息很有迷惑性 | 脚本直接挂在 GridMap 上时自己认自己；或用 `get_node_or_null()` 取 |
| 14 | `self` 静态类型是自定义脚本，赋给 `GridMap` 类型变量过不了静态检查 | 编译错 | 走 `var v: Variant = self` 中转 |
| 15 | 两个场景连跑防黑扫描，报告写同一个文件 | 后一次覆盖前一次，看不到 main 的结果 | 一次只跑一个，或读对应报告 |
| 16 | 转角处横向带部分重叠 + 外凸一格，中心线推算的掩码对不上实际铺面 | 校验出 29 条断边 | **先铺面、再由铺面反推掩码** |
| 17 | `@export_range(...)` 写成两行（下一行再 `@export var`） | 4.7 Parse Error：`Annotation "@export" cannot be used with another "@export" annotation` | **必须单行**：`@export_range(4.0, 60.0, 0.5) var max_speed: float = 28.0` |
| 18 | `.tscn` 属性行尾写 `#` 注释 | Godot 不认行尾注释，会**静默丢弃该行之后所有 `[node]`**（连报错都没有）→ `View.target` 解析成 null、相机不接管、整城压成地平线那条线 | 注释必须独占一行 |
| 19 | 正则里属性名用 `/` 连接，或用数字下标取捕获组 | `/` 不是"或"，整串被当字面量 → **0 命中且不报错**；命名组在 PCRE 里**也占编号**，`get_string(2)` 取到的是属性名不是值 | 用 `|` 连接；两个捕获都命名：`(?P<name>…)(?P<old>…)` |
| 20 | `Control.AUTOWrap`、或直接点 `Node` 类型的 `.max_speed` | `Cannot find member "AUTOWrap" in base "Control"`；`Node` 静态类型下访问未知属性过不了静态检查 | 换行枚举在 `TextServer` 下；一律用 `node.get("max_speed")` / `node.set(prop, v)` |
| 21 | `.tscn` 里写 `type="AutoTunable"` | headless `Cannot get class 'AutoTunable'`；编辑器 `Class "AutoTunable" hides a global script class`，节点退化 placeholder、面板控件 0 个 | 写 `type="Node"` + `script = ExtResource(...)` 指向 `auto_tunable.gd` |
| 22 | `--script` 探针里跑不了 autoload | "明明挂了 autoload 却不生效"，容易误判成插件坏了 | 探针里手动 `load(script).new()` + `root.add_child()`，或先 `root.add_child(DebugTuner)` 再实例化场景 |

---

## 8.5 运行时调参 UI：GDTuner（全参数）+ 屏幕小面板（三根滑条）

**为什么要两套**：`车速太快` / `镜头太远` 这类手感问题，改一次脚本默认值就要重开一次，来回三趟人就没脾气了。按"先找成熟方案"的要求检索过，结论是：**运行时调参这件事 Godot 生态有标准解，别自己造**。

* **GDTuner**（Godot 官方资源库 #4969，MIT，纯 GDScript 零依赖）：`AutoTunable` 节点挂在目标节点下，扫出父节点上**分组名必须是 `tunable`** 的 `@export` 变量自动变滑条；桌面端 **F12** 弹独立窗口，编辑器里跑走 `EditorDebuggerPlugin` 底部面板 `GDTuner`，移动端弹底部 sheet；`release` 下 `OS.is_debug_build()` 直接 no-op。
    * 不选 `GDebugPanelGodot`（C#）和 `imgui-godot`（要 GDExtension 编译）的理由很实在：这两个都得为本项目再拉一条编译链，GDTuner 复制目录即可，MIT 随便改。
* **屏幕小面板 `scripts/tune_hud.gd`**（autoload，Tab 收起）：只放最常用的三根 —— 最高车速 / 镜头距离 / 镜头高度，拖完立刻生效，值标签直接显示 km/h。存在的理由很土：**F12 不是每个人都知道要按，一个参数调三回就烦了**。

分工一句话：**日常微调看屏幕小面板，翻参数表按 F12 开 GDTuner 调全部 14 项，定稿跑 `tools/bake_tuning.gd` 把值写回脚本默认值。**

### 接线（照抄即可）

1. `addons/gdtuner/` 是解压好的插件本体（MIT，别删），`project.godot` 的 `[editor]` 段已有 `plugins=PackedStringArray("gdtuner")`，插件启动时自动注册 `DebugTuner` autoload。
2. 三个场景各挂一个 `AutoTunable`：`scenes/main.tscn` 挂在 `View` 下，`scenes/city.tscn` 挂在 `View` 下，`scenes/vehicle.tscn` 挂在 `Vehicle` 下。
3. **`.tscn` 里必须写成 `type="Node"` + `script = ExtResource("...")` 指向 `res://addons/gdtuner/auto_tunable.gd`**，别写 `type="AutoTunable"`（见坑 21）。
4. 脚本里要能调的变量收进 `@export_group("tunable")`；`AutoTunable._ready` 时靠父节点 `get_property_list()` 里**组名等于 `tunable`** 的属性建滑条。**autoload 要先于场景进树**，否则该节点永久放弃注册。

### 当前可调的 13 项（headless 实测已确认绑定生效）

| 脚本 | 参数（滑条范围） | 当前默认值 |
|---|---|---|
| `scripts/vehicle.gd` | `max_speed` 4~60 | 28.0 ≈ **101 km/h** |
| | `engine_power` 0.2~4 / `brake_power` 0.5~8 | 1.1 / 3.5 |
| | `lateral_grip` 0.5~12 / `turn_rate` 1~6 / `steer_falloff` 0~1 | 3.2 / 3.4 / 0.55 |
| `scripts/view.gd` | `distance` 0.5~12 / `height` 0.3~4 | 2.9 / 1.15 |
| | `look_at_height` 0~2 / `look_ahead` 2~30 | 0.55 / 14.0 |
| | `distance_speed` 0~3 / `distance_brake` 0~3 / `fov_base` 55~90 | 0.9 / 0.75 / 70.0 |

### 固化：把面板上定好的值写回脚本默认值

```
# 干跑：只列要改什么，不动文件
godot --headless --path . --script res://tools/bake_tuning.gd -- --dry
# 真写：先备份到 res://Temp/bak_<时间戳>/ 再改源码
godot --headless --path . --script res://tools/bake_tuning.gd
# 读别的场景 / 强行注入一个读数
godot --headless --path . --script res://tools/bake_tuning.gd -- --scene=res://scenes/city.tscn --set=max_speed=33
```

**为什么不用 GDTuner 自带的 Bake to Source**：它的正则只认两行式 `@export var x: float = 0`，而 4.7 里两行式是 Parse Error（必须单行 `@export_range(...)`），自带 bake 一条都匹配不到、点了没反应。自研 `tools/bake_tuning.gd` 两种写法都认，且**按数值比较**（源码写 `28.0`、格式化出 `28.00` 不算改动）。

### 验收

headless 实测：面板注册 **14 个控件**（13 项 tunable + misc）；`_set_value("vehicle/max_speed", 14.0)` 后脚本真值变 14.00；`view/distance` 设 6 → 6.00。`tune_hud` 实测：拖 `max_speed` 到 18 → 车的 `max_speed` 变 18.0、标签显示 65 km/h；拖 `distance` 到 6.5 → 相机距离变 6.5；Tab 收起/展开正常。

---

## 9. 后续待办（未完成项，别以为已经做完）

- [x] **运行时调参 UI**：GDTuner（F12，14 项）+ `scripts/tune_hud.gd` 屏幕小面板（3 项，Tab 收起，autoload）
- [ ] 相机/车体的**运行时实机验证**（GUI 模式跑一次，看 F12 窗口与屏幕小面板的实际外观）（headless 只能体检，截图需要 GUI 模式跑 Godot，本机 GUI 可用）
- [ ] 把 `track_generator` 正式接进 `scenes/` 的随机地图场景（当前只在 `tools/track_probe.tscn` 里验证）
- [ ] 动态模糊：目前只做了 FOV 随速度扩大，没做后处理动态模糊（Needle / 自定义 shader）
- [ ] 装饰物目前只有 forest / tents，按提示词的"护栏、路灯"还得补
- [ ] `scenes/city.tscn` 相关任务（#14~#18：地面 UV 噪声、光照提亮、沥青颗粒、路侧道具、相机机位）仍 pending
- [ ] 任务 #19 的设计文档 `docs/DESIGN_city_map.md` 还没写（本次只写了本文档 #27）
- [ ] 临时探针 `Temp/orient_probe.gd/.tscn`、`Temp/classdb_probe.*` 可清理（`Temp/` 整体是临时目录，别混进交付物）

---

## 10. 环境备忘

- Godot：`C:\Tools\Godot\Godot_v4.7-stable_win64.exe`（4.7 stable）
- 项目根：`D:\AI\GodotProject\Starter-Kit-Racing`
- 本机 PowerShell 通道常常只回退出码、stdout 全丢 → **脚本一律把结果 `WriteAllLines` 落盘再读**
- 文档行尾：CRLF
