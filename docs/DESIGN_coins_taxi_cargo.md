# DESIGN_coins_taxi_cargo —— 金币系统 + 出租车任务（单人）+ 合作运货（多人）

> 状态：**已拍板，进入实现**（2026-10-03，见 §7 拍板记录；§8 商店为同日追加需求）。
> 需求来源：2026-10-03 用户指令——
> ① 金币系统；② 单人出租车任务：乘客招手 → 载客 → 到达指定地点 → 得金币；
> ③ 多人运货系统：一起运一大堆货，多次才运得完，全完成发金币报酬。
> 归属：`DESIGN_gta_openworld.md` 的 economy/ + mission/ 两个域的第一块砖。

---

## 1. 现有架构接入点（全部已交付、直接复用）

| 接入点 | 现状 | 本设计怎么用 |
| --- | --- | --- |
| Modules 模块系统 | `modules/<name>/mod.cfg` + `mod_setup(ctx)`，拓扑排序 | 金币=新模块 `economy`；任务=新模块 `missions`（不新增 autoload，铁律只有 EventBus/Modules/Lobby 三个） |
| EventBus | `scripts/core/event_bus.gd`，模块间只走事件 | 新信号：`coins_changed(who, total, delta)`、`mission_state_changed`、`cargo_progress(delivered, total)` |
| InteractionGate | C1 距离∧C2 就绪∧C3 可用，组扫描+最近目标 | 乘客、装货区、卸货区都是新 `Interactable` 子类——门控机制天然为任务交互而生 |
| urban_net 联机层 | 驾驶者权威 + 20Hz 快照 + reliable 事件 RPC | 运货的「装/卸」走 reliable RPC 意图上报，host 结算广播 |
| 小地图 | `scripts/ui/minimap.gd` 是 SubViewport 正交俯视，**直接渲染 3D 世界**（无独立标记层） | 目的地/货区用 3D 光柱与色块地面——俯视相机天然把它们画进小地图，零改动 |
| 素材 | `models/cars/taxi.glb`、`delivery.glb`、`box.glb`、shipping-container、character.glb 多皮肤（animated-characters） | 出租车=taxi.glb；货堆=box.glb 多份；乘客=换肤 character |
| 多语言 | DESIGN_localization.md（待实现） | 全部新文案写 `tr("中文原文")`——中文即 key，本地化落地时整体迁 CSV，不需返工 |

素材缺口核查：Kenney animated-characters **没有挥手动画**（只有 idle/walk/run/jump）→ 见 §3 方案卡 A 的坑位与拍板问题 2。

## 2. 金币系统（三套方案）

### A. `modules/economy`：单钱包 + EventBus 广播（推荐）

| 字段 | 内容 |
| --- | --- |
| 核心理念 | 金币是每个玩家的一个整数，所有增减只走 `earn()/spend()` 两个口，改动即发事件，HUD/存档/结算都是订阅者 |
| 机制 | `coins: Dictionary<peer_id, int>`；单人 peer_id=1；多人 host 权威（客机只上报交互意图，host 调 earn 后广播 `coins_changed`）；HUD 左上角金币条订阅事件刷新 |
| 优点 | 符合模块铁律；消费端（买车/改装/房产）将来只加 spend 调用点，不动骨架 |
| 缺点 | 无价格/物品表——故意的，现在没有商店需求 |
| 代表作品 | GTA 系列 cash 模型；《Starter Kit Racing》的 coin 计数 |
| 坑 | 客机本地直接加钱 = 不同步灾难。规则写死：**只有 host 能调 earn/spend**，客机只读 |

### B. 完整经济 Resource（.tres 物品/价格表 + 钱包）

现在没有商店、没有物品，做了就是空转。**放弃**（方向保留：将来 `economy` 模块内加 items.tres，不改对外 API）。

### C. autoload 单例 Economy

违反「只有三个 autoload」定版纪律。**放弃**。

## 3. 出租车任务 · 单人（三套方案）

### A. 状态机任务 + Interactable 乘客（推荐）

```
IDLE ──(路点刷乘客)──> HAILING ──E 接载──> PICKED_UP ──(目的地 15m 内 E)──> SETTLE ──发金币──> IDLE
```

| 字段 | 内容 |
| --- | --- |
| 核心理念 | 乘客是站在路边招手的 Interactable；目的地是随机路网点 + 3D 光柱标记 + 小地图图标；报酬 = 起步价 + 准时奖励 − 损毁扣减 |
| 机制 | `missions` 模块监听 urban 场景就绪 → 在路边点（复用 city_builder 路网坐标算法，距玩家 40~120m）生成乘客（换肤 character.glb + 程序摆臂循环）；`PassengerInteractable.can_interact()` = 门控三条 + 「玩家正开出租车」；送达判定用距离圈 + `DropoffInteractable`；结算走 EventBus → economy.earn |
| 优点 | 全链路复用已交付系统（门控/小地图/路网/金币）；状态机 5 个状态，单人一周内可做完做稳 |
| 缺点 | 硬编码状态机，第二、第三种任务再加状态会膨胀 |
| 代表作品 | GTA Vice City 第一个出租车任务（Romeo's Taxi）；Kenney 演示场景常见套路 |
| 坑 | ① **无挥手动画** → 方案 a：程序摆臂（找 Arm 骨骼 rotation 循环，探针验证）；方案 b：跳一下+头顶「!」Label3D 代替。② 乘客上车后必须从 interactable 组摘掉（否则门控又亮「上车」提示）；下车落点复用 `_exit_point` 的地面高度逻辑。③ 目的地必须选**路网上的点**，别随机撒进建筑里——用 city_builder 的路中心线采样 |

### B. 数据驱动任务模板（.tres objective graph）

通用「目标图」框架（参考《Game-Development-Patterns-with-Godot-4》的 command 模式），出租车只是第一个实例。架构漂亮，但**一种任务就上框架 =  premature**。**放弃本轮**，留作：当任务种类 ≥3 时把 A 的状态机抽出来重构。

### C. 固定出租车趴活（无乘客 NPC）

站牌按 E 直接出目的地，最省事，但不满足「乘客招手」的明确要求。**放弃**。

## 4. 合作运货 · 多人（三套方案）

需求拆解：一大堆货（总量 > 单车容量）→ 必须多次往返；所有人合力完成 → 集体发金币。

### A. 容量往返制：货是计数不是物理（推荐）

| 字段 | 内容 |
| --- | --- |
| 核心理念 | 货堆总量 24 箱、卡车容量 6 箱 → 天然要跑 4 趟；车斗里的箱子只是按当前载货量显隐的 box.glb 复制品，不参与物理 |
| 机制 | 装货区/卸货区各一个 Interactable（门控：距离∧车停稳∧有空位/有货）；客机按 E → reliable RPC 上报意图 → **host** 改 `delivered/cargo` 计数 → 广播进度（HUD 进度条 + 小地图）；delivered==total → host 给所有参与玩家 earn 金币 |
| 视觉 | 装货区一堆 box（数量=剩余待运），车斗按载货量排 1x6 箱子，卸货区堆递增——纯显隐，零物理 |
| 优点 | 同步面最小（两个整数 + 每车一个载货数，全走现有快照/事件通道）；多人「一起干」的体感来自进度条共涨，不需要共享物理 |
| 缺点 | 没有「箱子晃出来」的乐子 |
| 代表作品 | 《GTA Online》Cargo Ship、《Muck》式计数交付；《Starter Kit Racing》送货关卡 |
| 坑 | ① 装卸必须卡「车停稳」（复用 exit_max_speed 阈值），否则边开边刷箱子；② 玩家中途退出/掉线：host 把该车货物**回退到装货区**（防吞货）；③ 奖励只发给「完成时刻在场且参与过运输」的人，避免挂机躺分——参与判定=至少卸过 1 箱 |

### B. 真实物理堆装（每箱 RigidBody 进车斗）

Kenney Starter Kit Racing 原版有 cargo 物理演示，但联机下刚体同步是地狱级（本项目物理后端刚切回 GodotPhysics3D，车都靠权威快照）。**放弃**，单人沙盒玩具模式将来可另立项。

### C. 肩扛手搬（Overcooked 式，下车搬箱挂人物身上）

要新建 carry 系统（挂点、碰撞豁免、门控扩展），且把「开车游戏」玩成搬砖，和主干手感冲突。**放弃本轮**，留作运货的小品变体（如「卡车抛锚段」）。

## 5. 数值起点（可 GDTuner 调，拍板问题 3）

| 参数 | 建议初值 | 说明 |
| --- | --- | --- |
| 出租车起步价 | 50 币 | 送达即得 |
| 准时奖励 | ≤50 币线性衰减 | 时限 = 路程/8m/s ×1.6 |
| 损毁扣减 | 每次撞击 -5，最多 -30 | 复用 vehicle 撞击信号 |
| 货堆总量 | 24 箱 | 2~4 人跑 2~4 趟 |
| 单车容量 | 6 箱 | delivery.glb 车斗 2x3 |
| 运货报酬 | 300 币/次卸货 12 币 | 大头在集体完成奖，鼓励跑满 |

## 6. 验收清单（实现轮照此测）

- [ ] 单人：路边出现招手乘客 → 门控提示「按 E 载客」→ 目的地光柱+小地图 → 送达后 HUD 金币跳动（探针断言 coins_changed）。
- [ ] 双实例联机：A 装 B 卸交替，两端进度条一致；全部交付后两端同时收到金币；中途 B 退出，A 端货量回退。
- [ ] GUI 截图四连：hailing / driving / settle / cargo_progress.png；`--check-only` 全绿；文案全走 tr() key。

## 7. 需要拍板的 3 个问题 → 拍板记录（2026-10-03）

> 用户原话：「先按照你设定的来，再测试，游玩后再做调整或融合」——三问全部按推荐项执行。

1. **金币持久化**：单人档存 `user://save.cfg`（联机局由 host 写同一文件；离线重开钱还在）。
2. **乘客招手表现**：程序摆臂优先（运行时探针找 Skeleton3D 中名字含 arm/elbow/shoulder 的骨骼，停掉 idle 后逐帧摆 right 侧骨骼）；找不到骨骼走保底「原地跳 + 头顶『!』Label3D」。两条路都实现。
3. **数值起点**：按 §5 建议表开工，游玩后调。

## 8. 金币商店（本轮追加需求：买车 + 买角色能力）

需求原话：「金币可以购买 1、车辆，先设定几辆。2、角色自身能力，比如能力强了，开车速度更快、更不容易撞坏车。」

### 8.1 入口与 UI

- 「车行」摊位摆在城外环路侧草地 `(92, 0, 128)`（避开环树木带），带招牌 Label3D。
- 走近平间（步行状态）→ 门控提示「按 E 打开车行」→ 居中面板（复用大厅同款 StyleBox），两栏：**车辆** / **能力**。
- 面板打开释放鼠标，Esc/关闭按钮收回；面板开着时摊位 `can_interact()` 为假（门控不再亮提示）。

### 8.2 车辆货架（价目 + 底盘差异）

现车辆全部共用同一套街机参数，购买的差异直接在售货架写 `max_speed / engine_power / lateral_grip`（上车即生效、无需新物理系统）。

| 车型 | 模型 | 价格 | 极速 | 定位 |
| --- | --- | --- | --- | --- |
| 出租车 | taxi.glb | 400 | 10.4 | 跑出租任务的自家车（不买也有任务车趴活） |
| SUV | suv.glb | 900 | 11.5 | 均衡 |
| 肌肉车 | race.glb | 1200 | 13.5 | 快、略飘 |
| 跑车 | sedan-sports.glb | 1800 | 15.5 | 最快、最飘 |

规则：买断制；已购的车停在自己的**车行车位**（摊位旁 x 方向每 6.5m 一个车位）；跨局持久；联机客机购买走「意图→host 校验→全端快照广播」，各端本地补 spawn 同名牌车（车位由 id 推导，天然确定同步）。

### 8.3 角色能力线（乘算在街机参数上）

| 能力 | 等级/价 | 效果 |
| --- | --- | --- |
| 驾驶训练 | Lv1/2/3：300/600/1200 币 | 每级所有车极速 +10%（`ability_speed_mult` 乘算进 `_speed_mps()`） |
| 钣金强化 | Lv1/2：400/800 币 | 每级撞击受伤 −25%（`armor_mult` 乘算进伤害公式） |

买完即时生效：下一次上车时由 economy 模块把倍率写到车上（经 EventBus `vehicle_boarded` 事件，不碰车节点的所有权）。

### 8.4 最小车辆伤害模型（「撞坏」的第一块砖）

vehicle_arcade 现在**没有血量**，本轮加最小版本，供钣金强化与出租损毁扣减两个消费端：

- `health 0~100`，撞击（相对速度 > 3 m/s）扣 `(v−3)×1.5×armor_mult`，300ms 冷却防连帧重复扣；
- 血量不满即降速：有效极速 = `max_speed × ability_speed_mult × lerp(0.6, 1.0, health/100)`；
- 松油门滑行时缓慢回血（0.8/s），本轮不做修理厂；
- 扣血时发 EventBus `vehicle_damaged(car_name, amount, health)`——出租车任务的「撞击扣减」订阅它计数。

## 9. 未来融合方向（本轮只记录，不实现）

- **喇叭揽客**（用户 2026-10-03 提出）：开车按喇叭（建议键位 H）→ 附近**步行 NPC** 有一定概率转为「等客」状态，进入出租车状态机的 HAILING 分支。前置：步行 NPC 人流系统（本设计 §3 的乘客只是任务点，不是街面人流）。数值接入现成：招手乘客与喇叭路人共用 `PassengerInteractable`。
- 运货变体：肩扛手搬（§4-C）、箱子物理（§4-B）。
- 任务模板化：任务种类 ≥3 时把 §3-A 状态机抽成数据驱动 objective graph（§3-B）。
