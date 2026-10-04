# 设计案：任务框架 + 僵尸/妖怪波次防守（#21）

> 状态：已拍板（2026-10-03 用户三选一回复）→ 实现中。
> 协作纪律见根目录 `AGENTS.md`；金币/任务基线见 `DESIGN_coins_taxi_cargo.md`（#20）。

## 1. 需求与拍板记录

需求：「添加任务，打僵尸/妖怪，每打 1 波获得金币。」+ 追问「有没有单独设计任务管理系统？」

现状结论：**没有**通用任务管理——#20 的 taxi/cargo 是 `modules/missions` 里手挂的 RefCounted，
生命周期（enter/leave/tick/hud_line）撞出了同款形状，但没有基类，网络 RPC 各写各的。

用户拍板（编号对应上一轮提问）：
1. 战斗方式 = **近战 + 枪**（素材里有枪：Kenney blaster-kit，另有 Starter-Kit-FPS 演示含 blaster GLB + 音效）。
2. 敌人形象 = **直接用素材里的僵尸**：`kenney_graveyard-kit_5.0` 的 character-zombie/skeleton/ghost/vampire
   四款 GLB（实测自带 AnimationPlayer：idle/walk/sprint/attack-melee-*/die 全套 33 剪辑）。
3. 任务循环 = **接任务 → 天色变暗 → 刷僵尸 → 打完天色恢复 → 交任务 +1000 金币；
   死亡 3 次任务失败：天色恢复、僵尸消失、扣 100 金币**。

方案选择（上一轮方案卡）：A（Mission 基类归位三种任务）为主 + C（波次导演，L4D Director 思路）
做进防守任务本体；B（数据驱动 .tres 任务表）放弃——防守任务程序性强，塞表变形；
D（第三方插件）放弃——未在本机 4.7 实测，且与 InteractionGate + host 权威架构强耦合。

## 2. 任务框架（方案 A）

`modules/missions/mission_base.gd`（RefCounted 基类）：
- 统一成员 `mod` / `game` / `state`，统一生命周期 `enter(g) / leave() / tick(delta) / hud_line()`；
- 沉淀公共小工具：`_find_anim/_find_skeleton/_find_right_arm/_car_pos/_stopped/_ground_y`；
- taxi/cargo/defense 三个任务改为继承基类（行为零变化，v20 探针回归验证）。

## 3. 战斗规则（全部只服务于防守任务，v1 不开放自由战斗）

| 项 | 数值/规则 |
| --- | --- |
| 玩家生命 | 100；非战斗 6s 后每秒回 8；归零 = 死亡：告示板旁重生、生命回满、死亡数 +1 |
| 开枪（鼠标左键） | 相机方向 hitscan，射程 40m，弹道半径 0.55m，伤害 40，冷却 0.35s；仅步行可用 |
| 近战（F 键） | 身前 2.4m 扇形（dot>0.35），伤害 55，冷却 0.7s，无弹道 |
| 僵尸生命 | 100（枪 3 发或拳 2 拳）；近战怪：接触 1.35m 内每 1.1s 抓 12 点 |
| 僵尸种类 | zombie(2.2m/s) / skeleton(2.6) / vampire(3.0) / ghost(3.4 悬浮 0.5m 摆动)；波次越晚越凶 |
| 枪械外观 | blaster-a.glb 挂在人物右手侧，开火播 blaster.ogg + 后移回弹 tween |

## 4. 波次防守任务（defense_mission.gd，方案 C 的导演）

- 入口：车行旁「讨伐告示板」（Interactable，priority=10，单人/联机均可）。
- 流程（host 权威状态机）：`OFF → OFFER(按 E 接) → DUSK(4s 压暗) → WAVE_i →（全灭）→ 下一波 / 全清 → DAWN(4s 复亮) → DELIVER(回板按 E +1000) → COOLDOWN(20s)`。
- 波次表：`[4, 6, 8, 10, 12]` 共 5 波；每波全灭即 `coin_earn(每人 100×波号)`（用户：每打 1 波获得金币）；
  出生点：绕玩家 55~85m 环形 + 路网点采样。
- 失败：全队死亡数 ≥3 → 立即 DAWN、全僵尸消失、每人 `coin_spend(100)`（余额不足 economy 自动拒绝，不欠条）。
- 昼夜：运行时 `duplicate()` WorldEnvironment 的环境（**绝不改共享 .tres**），
  4 秒 lerp：Sun.light_energy→0.1、ambient→冷蓝 0.22、tonemap_exposure→0.55、开淡雾；结束时反向回。
- 掉线：客机中途走人不结算不惩罚（host 继续，剩余人可打完）。

## 5. 网络（沿用 #19/#20 铁律）

- 所有僵尸由 host 模拟（运动学追击 + 形状查询避墙，无 CharacterBody），
  10Hz `_rpc_defense_sync` 打包下发：阶段/波次/死亡数 + 僵尸数组 [eid,x,y,z,yaw,hp,kind] + 每人 hp。
- 客机只见复制品（lerp 位置 + 动画），不开权威；开枪/近战发意图 RPC（from+dir），host 判命中。
- 晚进房：4s 心跳复用 missions 模块现有循环。
- 结算只发 `coin_earn/coin_spend` 事件，由 economy 落地（模块间不互抓节点）。

## 6. 已知坑与规避（实现前写明）

1. **graveyard GLB 的动画可能带根位移**（Root 位置轨道）→ 模型放在内层 pivot，
   每帧强制把 pivot 归零，僵尸世界位置只由外节点写（探针实测验证）。
2. **共享资源**：`main-environment.tres` 是场景引用，昼夜压暗必须先 duplicate 再改。
3. **开车时 player 节点不动**（#19 铁律）→ 僵尸目标点在驾驶态取「被驾车真实位置」。
4. **提示抢占**：告示板 `interact_priority = 10`，压过「按 E 下车」。
5. 鼠标左键/F 确认未被占用（project.godot 现有 action 无 LMB/F）；action 名避开已占用的 `respawn`（R=车辆复位）。
6. 探针可重入：跑前清 host 状态（血/波次/已发钱）。

## 7. 验证计划

- `--check-only` 全量（先删 script_cache）；
- v20 回归探针（框架重构不改行为）；
- `Temp/v21_probe.gd`：headless 全流程——接任务→天暗→刷波→模拟击杀（走真实攻击意图函数）→
  波次金币→全清→交付 +1000；负路径：死 3 次→失败扣 100；
- 双实例 `Temp/v21_host.gd`/`v21_client.gd`：客机开枪由 host 判死、同步数组、掉线不结算；
- GUI 截图 `Temp/v21_shot.gd`：黑夜 + 僵尸群 + 持枪 HUD + 交付面板。

## 8. 改动面

新增：`modules/missions/mission_base.gd`、`defense_mission.gd`、`models/characters/graveyard/*`、
`models/weapons/blaster-a.glb`、`assets/sounds/combat/*`、设计案本体。
修改：`modules/missions/taxi_mission.gd`、`cargo_mission.gd`（改继承+去重公共函数）、
`modules/missions/module.gd`（挂 defense + RPC）、`project.godot`（input 两条）。
不动：economy/interaction_gate/urban_game（契约已够用）。

## 9. Backlog（本轮不做）

- 自由战斗 + 警星热值（event_bus 已占位 `heat_changed`）；
- 车上开火 / 开车撞僵尸；僵尸夜间游荡生态；任务表数据驱动化（方案 B 的复用价值出现在任务 >5 种时）。
