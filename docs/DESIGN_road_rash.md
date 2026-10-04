# 暴力驾驶（Road Rash 式）设计文档 —— L2 载具缠斗子系统规格

> ⚠️ **本文档已降级为子系统规格。项目总纲见 `docs/DESIGN_gta_openworld.md`**
> （GTA5 式开放世界 / 多人联机 / RTS 化阵营战争）。
> 本文保留原文，只作为总纲 §2.3「L2 载具缠斗」与 §3.6「载具体系」两节的细化实现依据。
> 接线规则以总纲为准。

> 目标：**在现有「随机赛道 + 原版 Kenney 风格」地图上，加入暴力摩托式的暴力驾驶**——
> 摩托车和汽车两种载具都能开，能撞人、能打人、会被撞飞、会摔车，撞完会掉零件。

---

## 0. 一句话定义

竞速只是外壳，**“贴身缠斗”才是核心**。Road Rash 的精髓不是“跑得快”，
而是“为了领先一两名，值得跟对手同归于尽一下”这个决策成本。
所以本项目的暴力驾驶设计围绕一个原则：

> **每一次高速接触都要付出看得见的代价，但这个代价要能靠操作挽回。**

---

## 1. 业界成熟方案调研（动手前先找轮子）

### 1.1 标杆拆解：EA《Road Rash》（1991, Mega Drive）

先查权威资料（Sega Retro / Fextralife 回顾），把机制拆到底：

| 维度 | 原作机制 | 对本项目的启发 |
|---|---|---|
| **核心循环** | 竞速 + 近身格斗，两者同时占用注意力 | 攻击必须“顺手”，不能停下来打 |
| **三套数值** | rider stamina（车手格斗耐久）、bike damage（车损）、money（修理/罚款） | 我们只保留前两条：stamina（人）+ damage（车），钱换成“名次/重开” |
| **攻击手段** | 拳 / 后勾拳 / 踢；武器 club → crowbar → nunchaku → cattle prod；**可以打掉对手武器自己捡** | 我们做 拳 / 踢 + 一种可掉落武器（用 debris 当道具也行） |
| **stamina 归零** | **wipeout**：车手被甩飞出车，落地后要跑回车边才能继续，此时是全场最脆的时候 | 这是“暴力”最值钱的一秒，必须做 |
| **damage 归零** | bike wrecked，退出本场，结算扣修理费 | 我们 = 原地 wrecked，短暂黑屏后重生在赛道上 |
| **环境危险** | 坡道起跳大跳、路牌 / 树 / 牛、油渍、碎石打滑、**警察摩托（motor officer）抓到就 busted** | 坡道（vendor 有 track-ramp）、障碍、油渍、警车都可复用现有 tile |
| **打击感** | 高速撞击会把人甩出很远；撞击 = 掉速 + 失控几秒 | 撞击必须有“掉速 + 输入锁定 + 镜头抖”三件套 |

一句话总结原作：**crash 的代价要足够疼，疼到玩家会绕着打，而不是硬冲。**

### 1.2 Godot 侧的开源参考（查到 4 个）

| 项目 | 适用部分 | 不适用/原因 |
|---|---|---|
| **Godot Engine Asset Library #4670**《Godot Simple Motorcycle Physics》(MIT, 4.5) | RayCast 双轮（前轮转向 / 后轮驱动）、steering→lean 映射 | 只有“能骑”，没有战斗 |
| **Bontsie/godot_vehicle_arcade** | Raycast 悬挂 + `ArcadeCar.tscn` / `ArcadeMotorcycle.tscn` **双载具 + Tab 切换**，结构跟我们要的几乎一样 | 战斗层没有 |
| **ssebs/moto-player-controller-godot** | 摔车状态机、wheelie、counter-steer、落地判定 | 偏拟真，代码量大 |
| **flaviakim/Godot-Easy-Vehicle-Physics** | raycast 车辆 + countersteer / traction control / ABS 全套 assists | 过重，我们会自己写街机层 |

### 1.3 结论（重要）

**“暴力驾驶”本身没有成熟的开源成品**——Road Rash 原作无源码，Godot 生态里能查到的
都是“摩托车物理层”，战斗/状态机部分全是各厂自研。

所以采用**分层取用**：

- **物理层 → 抄开源**：摩托用 RayCast 双轮（#4670 / Bontsie 的路子）；
  汽车直接复用我们已经调稳的 `scripts/vehicle.gd` 街机控制器（yaw 与 velocity_dir 分离 → drift_angle）。
- **战斗层 → 自己设计**：本设计第 4、5 章。

### 1.4 我们已经有的东西（别重复造）

| 已有资产 | 用途 |
|---|---|
| `scripts/vehicle.gd` 街机控制器（yaw / velocity_dir 分离 → drift_angle，相机读它做横向让位） | **汽车物理层，已稳定** |
| `max_speed = 10.4`（实测 Kenney 原版巡航 10.37 m/s ≈ 37.3 km/h，见第 4.1 节） | **所有载具的速度基准** |
| `scripts/mapgen.gd` 随机闭环赛道（只用 vendor 7 个 tile） | 场景，风格由 vendor 保证 |
| `models/vehicle-motorcycle.glb` **已随 vendor 导入项目** | 摩托模型现成，不用新找 |
| `scripts/view.gd` 相机（含 drift 让位） | 摩托再加一层 lean 让位 |
| `addons/gdtuner` + `scripts/tune_hud.gd` | 调参面板，新参数直接进 `@export_group("tunable")` |

---

## 2. 素材选型：风格一致性怎么保证

**一致性的硬指标（不是“看起来像”，是可验证的）：**

1. 所有新增模型统一只用 Kenney 通用调色板贴图 **`Textures/colormap.png`**——
   就是 vendor 主地图那张，字体/树/帐篷/赛道全是它。
2. **不新增任何自定义材质**。项目有防黑体检（`tools/check_materials.tscn`），
   P0 = 裸网格必须有材质、P1 = 反照色 < 0.12。复用 colormap 天然过检。
3. 沿用原地图 10 单位一格（`cell_size = 9.99`）的空间尺度。

### 素材清单

| 用途 | 素材 | 来源 |
|---|---|---|
| 玩家 / 对手**摩托** | `vehicle-motorcycle.glb` | **项目已有**（vendor） |
| 玩家 / 对手**汽车** | `vehicle-truck-{green,purple,red}.glb` | **项目已有** |
| **撞击碎片**（暴力驾驶的灵魂） | `debris-bolt / bumper / door / door-window / drivetrain / drivetrain-axle / nut / plate-a / plate-b / plate-small-a / plate-small-b / spoiler-a / spoiler-b / tire` | 素材库 `kenney_car-kit/Models/FBX format/` |
| **警车**（busted 威胁） | `police.fbx`、`tractor-police.fbx` | 同上 |
| **民用车**（路上的移动障碍） | `sedan / sedan-sports / hatchback-sports / suv / suv-luxury / taxi / delivery / ambulance / firetruck / garbage-truck / race / race-future / kart-*` | 同上 |
| 路边静态障碍（撞了直接飞） | 树、石头、灌木 | 素材库 `kenney_nature-kit/Models/` |
| 路边建筑（里程感 / 掩体） | 低多边形楼体 | 素材库 `kenney_retro-urban-kit/Models/` |
| 车手被甩出后“跑回去” | 先用 `PrimitiveMesh` 胶囊 + 姿态切换（**不引入人物动画**，省一个资源依赖） | — |
| 更多路型 / 路口 / 坡道 | `kenney_3d-road-tiles.zip`（当前是 zip，需解压后导入） | 素材库根目录 |

> 备注：`kenney_car-kit` 的贴图目录里就是 `colormap.png`，和我们主地图同一个文件，
> 所以碎片飞出来的一瞬间风格不会跳——这是选它的首要理由，不是“凑合”。

---

## 3. 载具抽象：一个基类，两种手感

**命名警告**：不要叫 `VehicleBody3D`（跟引擎内置类撞名，Godot 会报 hides global class）。
本项目统一叫 **`Racer`**。

```
Racer (Node3D)                     ← 抽象基类：状态机 + 数值 + 物理接口
├── Ground (RayCast3D)             ← 落地判定（沿用现有 vehicle.gd 结构）
├── Sphere (RigidBody3D)           ← 物理体
├── Container
│   └── Model                      ← 视觉模型（car / motorcycle）
├── stamina / damage / state        ← Road Rash 双血条
└── 子类：
    ├── CarRacer   ← 复用现有 scripts/vehicle.gd 的街机控制器
    └── BikeRacer  ← 新增：RayCast 双轮 + lean
```

### 3.1 汽车（CarRacer）

- 直接复用现有 `scripts/vehicle.gd`，**不动物理**。
- 关键约束（既有，必须保持）：`linear_speed` 是 **0~1 的归一化油门量**，
  真实速度 = `linear_speed * max_speed`；`sphere.linear_velocity` 每帧被覆写，
  所以**出生高度 = 最终高度**（`CAR_Y = 1.3`）。
- 撞墙反弹、镜头拉远、胎噪都读 `get_speed_mps()`，不读归一化值。

### 3.2 摩托（BikeRacer，新增）

按 #4670 / Bontsie 的成熟思路，但用**我们自己的街机层**：

- 物理：Sphere 刚体 + 前后两个 RayCast3D 测地（前轮转向、后轮驱动），
  不用真实悬挂弹簧，用“射线命中 → 贴地对齐 + 悬挂偏移”的街机做法，稳且好调。
- **lean（车身倾斜）是摩托的灵魂**：
  `lean_target = steering * speed_factor * LEAN_MAX + lateral_velocity * LEAN_DRIFT`
  车身绕**本地 Z 轴**倾（不是绕世界 Y），这是车和摩托手感最大的区别。
- `view.gd` 相机在 lean 角基础上再叠一层横向让位（摩托比车更晃）。
- 倒车 / 空中 / 落地判定沿用现有 Ground RayCast 那套逻辑。

---

## 4. 暴力驾驶机制（核心）

### 4.1 速度基准（先钉死）

原版车速**实测**（见 `Temp/origspd_out.txt`）：Kenney 原版 `vehicle.gd` 是角速度驱动
（`angular_velocity += basis.x * linear_speed * 100 * delta`，`angular_damp = 4.0`，
Sphere `radius` 默认 1.0），满油门 400 帧后收敛到：

```
ORIG_STEADY_MPS = 10.368   (= 37.33 km/h)
```

（原版项目缺 `models/` 资源跑不起来，所以是在本项目里原样复现方程实测的。）

我们把 `scripts/vehicle.gd` 的 `max_speed` 从 28.0 调到 **10.4**，
满油门实测 `10.400 m/s = 37.44 km/h`——与原版对齐（差 0.3%）。

> 本项目实测：`Temp/spdchk_out.txt` 输出 `SETTLED_MPS = 10.400 / 37.44 km/h`。
> **后续所有载具、所有新机制的速度都要以 10.4 m/s 这个基准去缩放**，
> 否则摩托会比车快一倍，或撞击伤害按 40 m/s 算失衡。

### 4.2 机制清单

| # | 机制 | 判定 | 反馈 | Road Rash 对应 |
|---|---|---|---|---|
| 1 | **接触撞击** | 两 Racer 距离 < r1+r2 且相对速度 > 阈值；撞击方用「相对速度方向 · 车头方向」判定 | 被撞方 `damage -x` + 横向 impulse + 输入锁 0.25s + 镜头抖 | 撞车 |
| 2 | **拳脚** | 近战键，前方 60° 扇形 / 3.5 m 内有对手 | 对手 `stamina -20` + 击退 + 命中音；**间隔 0.6s**，连按无效 | 拳 / 踢 |
| 3 | **武器抢夺** | 对手持械且被拳命中 → 武器掉落，我方拾取 | 掉落物用 `debris-*` 当模型（素材现成） | crowbar / nunchaku |
| 4 | **击飞 wipeout** | `stamina <= 0` 或 高速撞静态障碍 | 车手脱离模型 → 抛物线飞出；车失控滑行；慢镜 0.4s | 原作核心 |
| 5 | **捡车** | wipeout 后车手以走路速度（≈2 m/s）跑回车边 | 碰到车恢复 RIDING，stamina 回到 30% | 原作核心 |
| 6 | **车损** | 撞墙 / 撞车 / 撞树 → `damage -x` | damage ≤ 0 → WRECKED（重生） | bike wrecked |
| 7 | **碎片喷射** | 撞击瞬间按冲击方向喷 6~10 个 `debris-*` | 一次性 RigidBody，2 s 后回收（防卡帧） | 视觉爽点 |
| 8 | **警车 / 警察摩托** | 落地后长时间（> 6 s）未上车 或 严重违反（可后续加） | 追击 → 抓到 → BUSTED（罚时 / 重开） | motor officer |
| 9 | **氮气冲刺** | 撞飞对手 / 贴地高速行驶攒 energy | Shift 短促冲刺（1.5 s，上限 1.5 倍 max_speed） | 原作没有，街机化补 |
| 10 | **路面障碍** | 油渍（抓地力骤降）、碎石（抖动 + 掉速）、路牌 / 树（撞了直接 wipeout） | — | 原作 |
| 11 | **坡道起飞** | vendor 已有 `track-ramp`（item 5） | 空中无转向权限 → 落地按姿态判定摔/稳 | 原作 hill |

### 4.3 数值初值（全部挂 `tunable` 走 GDTuner，运行时可调）

```
stamina_max        = 100     bike_damage_max = 100
stamina_per_hit    = 20      damage_per_hit  = 12
wipeout_lock       = 1.2 s   pickup_time     = 3.0 s (跑回+上车)
melee_range        = 3.5 m   melee_fov       = 60°
melee_cooldown     = 0.6 s   hit_stun        = 0.25 s
bike_max_speed     = 12~14   (车 10.4，摩托略快)
lean_max           = 0.5 rad (摩托)
debris_per_hit     = 6~10
```

---

## 5. 状态机

```
                 ┌──────────────► HIT_STUN (0.25s, 输入锁定+抖屏)
                 │                    │
                 ▼                    │
   [RIDING] ──stamina<=0 / 高速撞障碍──► [EJECTED] ──跑回车──► [RIDING]
      │  │                                  │
      │  └──damage<=0──► [WRECKED]──► 重生在赛道最近直道
      │
      └──被警察抓到──► [BUSTED]──► 罚时 / 重开

   任意状态 + 撞击触发 HIT_STUN；HIT_STUN 结束后回到 RIDING/EJECTED
```

| 状态 | 行为 | 可输入 | 时长 |
|---|---|---|---|
| RIDING | 正常驾驶 | 全 | — |
| HIT_STUN | 被撞/被打，转向权限 30%，速度保留 70% | 仅油门 | 0.25 s |
| EJECTED | 车手飞出（抛物线），车失控滑行 | 无 | 直到碰到车 |
| 捡车中 | 车手跑向车（2 m/s），此时最脆 | 无（可被打） | 直到上车 |
| WRECKED | 黑屏 + 结算 | 无 | 2 s |
| BUSTED | 警车抓捕 | 无 | 罚时 |

---

## 6. 实现路径（每阶段都能跑起来）

| 阶段 | 内容 | 验收 |
|---|---|---|
| **M1 摩托接入** | `models/vehicle-motorcycle.glb` + 现有 `vehicle.gd` 球驱动；起跑线加 1 台摩托，按 Tab / B 在车和摩托间切换（照 Bontsie 的双载具套路） | 能骑摩托跑完一圈不掉地 |
| **M2 载具抽象** | 抽 `Racer` 基类（状态机 + stamina/damage），car / bike 分装；旧 `vehicle.gd` 作为 `CarRacer` 保留 | 切载具不丢手感，GDTuner 里两套参数都在 |
| **M3 撞击 + 碎片** | 距离/相对速度判定 → impulse + `debris-*` 喷发 + 抖屏 | 撞一下有明确反馈，帧率不塌 |
| **M4 拳脚 + wipeout + 捡车** | 完整状态机（第 5 章） | 能稳定做到“撞飞对手 → 自己摔 → 跑回去 → 继续跑” |
| **M5 环境** | 警车、油渍/碎石、路牌树障碍、坡道起飞 | 路上有“要不要绕一下”的取舍 |
| **M6 回归** | 防黑体检 + 多 seed 校验 + 手感固化 | `check_materials` P0=0 P1=0；`gen_map` 闭环正确 |

---

## 7. 验收标准

1. 每次进图都是新随机闭环赛道，起跑线上 4 台载具并排、全部压在沥青上
   （已有自动校验 `Temp/spawnchk.gd`：把车坐标换算回 GridMap 格，报告 `item >= 3 = ROAD`）
2. 摩托满速 lean 自然、不抽搐、不掉地
3. 撞击 → 碎片 → wipeout → 捡车 全链路稳定可复现
4. `tools/check_materials.tscn` 体检 P0=0、P1=0
5. 多 seed（`-- --seed=N`）生成结果闭环闭合、无孤立砖

---

## 8. 本项目 4.7 专属坑（写新代码前必读）

- **`..` 区间语法不可用**：`for x in a..b:` 直接 Parse Error，**一律写 `range(a, b+1)`**。
- GridMap 在 4.7 没有 `map_to_world()` / `has_cell()` / `get_item_transform()` /
  `get_cell_item_orientation_basis()`；朝选用 `GridMap.get_cell_item_basis(pos)`。
- **`.tscn` / `.tres` 属性行尾不能写 `#` 注释**（只认整行 `#`），否则该节点块之后的
  `[node]` 会被静默吞掉且不报错。
- **`BoxShape3D` 厚度 0 = 没有碰撞**（vendor 原兜底地板就这么写的）。
- `scripts/vehicle.gd` **每帧覆写 `sphere.linear_velocity`** ⇒ 车不会自由下落，
  **出生高度 = 最终高度**（`CAR_Y = 1.3`）。
- `Object.get_meta(key, null)` 会报错，默认值给 `-1`。
- `MainLoop._process` 返回 `true` 会立刻结束主循环，中间帧要 `return false`。
- headless 下正常场景能跑 100~400 帧物理（不是只有 60 帧），
  但 `--script` 模式只跑 1 个 tick；长观测要在场景里挂 `Node._physics_process`。
- 本项目所有脚本/资源文件统一 **CRLF** 行尾。
