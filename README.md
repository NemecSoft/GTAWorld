<p align="center"><img src="icon.png"/></p>

# GTAWorld

> 一个跑在 **Godot 4.7** 上的驾驶 / 开放世界项目。
> 基线是 Kenney 的 *Starter Kit Racing* 模板（CC0 素材 + MIT 代码），我们在这块基座上往「GTA 式开放世界」方向改。

现在手里有两张图：

| 地图 | 场景 | 一句话 |
| --- | --- | --- |
| 随机赛道 | `scenes/main.tscn` | 进图现拼一条闭环赛道（`scripts/world/mapgen.gd` 生成），seed 相同就一模一样 |
| 纳格兰草原 | `scenes/nagrand.tscn` | 2048m 代码生成高度场：草原 → 丘陵 → 台地 → 孤峰 → 环形山脉，仿魔兽世界纳格兰 |

启动第一屏是选图页（`run/main_scene` = `res://scenes/select.tscn`）：先选车，再选地图。

**当前特性清单**

- 极品飞车式街机手感：车头 yaw 与速度方向分离，甩尾角是真能开出来的
- 自研车辆控制器：Node3D + `RayCast3D` 贴地 + Sphere 刚体（不是 `VehicleBody3D`）
- 程序化赛道生成 / 代码生成地形（高度场 + `HeightMapShape3D` 分块碰撞）
- 程序化低模植被：`MultiMeshInstance3D` 卡通树、灌木、浮空岩
- GDTuner 实时调参（F12 滑条，可调完 Bake 回源码）；另有 Tab 收起的 TuneHUD
- 3D 模型与音效沿用模板（CC0）

### Screenshot

<p align="center"><img src="screenshots/screenshot.png"/></p>

### Controls（键盘）

| Key | Command |
| --- | --- |
| <kbd>W</kbd> | 油门 / 刹车 |
| <kbd>S</kbd> | 刹车 / 倒车 |
| <kbd>A</kbd> <kbd>D</kbd> | 转向 |
| <kbd>空格</kbd> | 跳一下 |

## 快速开始

项目基线是 Kenney 的 *Starter Kit Racing*（Godot 4）。我们在这个基座上做过的改造：

1. 相机换成极品飞车式第三人称追尾 + 速度前馈（满速也不会被甩远），距离滚轮可调。
2. 起手改成**选图页**：先选车再选地图，按 1 / 2 直接进图，Esc 退回。
3. 换了启动图与项目图标（GTA 风格封面），项目名定为 **GTAWorld**。
4. `scripts/world/` 下按玩法域拆了模块；另有事件总线 / 模块加载器 / 联机房型三个 autoload。
5. `project.godot` 里把 MSAA 关到 1 —— 否则 AMD 显卡上会满屏花屏。

> 技术事实、已知坑、调参结论都收在 `docs/agent/MEMORY.md`，不堆在这里，免得越写越难改。

### 引擎在哪

本项目全程用下面这个目录里的 4.7 stable 验证过：

| 用途 | 可执行文件 |
| --- | --- |
| 编辑器（GUI） | `C:\Tools\Godot\Godot_v4.7-stable_win64.exe` |
| 命令行 / 无头（截图、自动化验证） | `C:\Tools\Godot\Godot_v4.7-stable_win64_console.exe` |

把项目文件夹拖到编辑器图标上就能打开，或者在编辑器里 `Project > Import` 选 `project.godot`。

### 进去先选地图

`run/main_scene` 指向 `scenes/select.tscn`，启动后第一屏是选图（先选车，再选地图）：

- **随机赛道**（`scenes/main.tscn`）—— `scripts/world/mapgen.gd` 在 `_ready()` 里现拼一条随机闭环：直道、转角、终点门、外圈林地帐篷。
- **纳格兰草原**（`scenes/nagrand.tscn`）—— `scripts/world/terrain.gd` 运行时现算 2048m 高度场（8×8 分块）+ 卡通树 + 浮空岩。**还没接进选图页**：要进就在编辑器里打开 `scenes/nagrand.tscn` 按 F6，从选图页按 2 进去的还是随机赛道。

> 程序化地形是代码运行时生成的，编辑器里场景树只有个空壳 —— 打开 `nagrand.tscn` 看见 3D 视图空荡荡属正常，跑起来才有地。

嫌点鼠标慢就直接敲键盘：<kbd>1</kbd> 进地图 1、<kbd>2</kbd> 进地图 2，<kbd>Esc</kbd> 退回选图。

| 按键 | 作用 |
| --- | --- |
| <kbd>W</kbd> | 油门 / 刹车 |
| <kbd>S</kbd> | 刹车 / 倒车 |
| <kbd>A</kbd> <kbd>D</kbd> | 转向 |
| <kbd>空格</kbd> | 跳一下 |
| <kbd>鼠标滚轮</kbd> | 调追尾视角的距离 |
| <kbd>1</kbd> / <kbd>2</kbd> | 直接从选图界面进地图 1 / 2 |
| <kbd>Esc</kbd> | 回到选图界面 |
| <kbd>Tab</kbd> | 收起 / 展开调参小面板 |
| <kbd>F12</kbd> | GDTuner 完整滑条面板（仅桌面端编辑器 / 运行时） |

### AI 协作方式

这个项目是跟 AI 一起做的，有一条硬规矩：**先给 2～5 套业界成熟方案做对比 → 我拍板 → 才动手实现 → 首版必须能跑可用 → 之后稳步迭代，不推倒重来。**

完整守则见仓库根目录的 [`AGENTS.md`](AGENTS.md)（AI 每次进项目先读这份文件）。日常技术细节、已知坑、调参结论记在 `docs/agent/MEMORY.md`。

### 日常怎么改东西

**改赛道**：`scenes/main.tscn` 上挂了 `scripts/world/mapgen.gd`，改它的生成规则就行；想先看某个 seed 长什么样，`tools/gen_map.gd` 会吐一份 ASCII 闭环到 `Temp/gen_map_report.txt`。想手工摆砖，就选场景里的 `GridMap` 节点直接铺 tile。

**换车模型**：从 `models/` 里挑一台（比如 `vehicle-truck-yellow.glb`）拖进场景，挂在 `Container` 下，名字改成 `Model`；`scripts/world/vehicle_picker.gd` 会按新模型实测重算车身站位。

**加自己的车**：同上，但模型里得有这几个子节点 ——

- `body` 车身
- `wheel-front-left` / `wheel-front-right` 前轮
- `wheel-back-left` / `wheel-back-right` 后轮

**加一张地图**：在 `scripts/select.gd` 顶部补一张卡（scene / preview / num / title / sub / tags），预览图丢进 `ui/`；预览图只能 GUI 模式下截（headless 截不了图）。

**调手感**：别去扒源码改默认值 —— `scripts/hud/tune_hud.gd`（Tab 收起）给三根常用滑条；桌面端按 **F12** 是 GDTuner 的完整面板，调完能 Bake 回源码。

## 附录：已经下线的实验地图

早期那张「迷你中国城」（把 34 个省级行政区边界当成真实路网铺出来）已经从构建里摘掉了：场景与生成器都挪到了 `Temp/removed_city/`，`tools/gen_city.py` 一并撤掉，选图页现在只有随机赛道一张卡。「改配置前先看一眼这些坑」里关于城市的那几条形同历史经验，留着备查。

哪天真要重做这张图，直接说一声就行。

**画风**：纳格兰那张走「低多边形卡通 + 顶点色分层」—— 一大片亮黄绿草原，赭红土丘和蓝紫远山靠高度与坡度分色，远景压成灰蓝做大气透视；树是一根细杆顶个圆球（不是锥子松，那套不适合草原），配浮空岩和天上那条紫色极光带。随机赛道那张沿用模板的 Kenney 色板：草绿地面、深灰沥青、红白路沿护栏、糖果色低模方块。

### 改配置前先看一眼这些坑

- **花屏**：`project.godot` 里 `anti_aliasing/quality/msaa_3d` 必须是 `1`。设成 `2`（4x MSAA）后，AMD RX 580 + Vulkan Forward+ 下 SSAO / SSIL / Glow 会把几何打碎，满屏花纹。
- **`HeightMapShape3D` 的格距恒为 1**：`CollisionShape3D.scale` 必须设成高度场步长（本项目 4.0），误设成分块边长（256）会让每一块撑成 16km、块块互穿，车直接自由落体。
- **碰撞层要跟车对齐**：车在 layer 8，地形 `StaticBody3D` 得同时覆盖 1 和 8（本项目 `collision_layer = 11` / `collision_mask = 11`），交集为 0 就是「有地面没碰撞」。
- **Godot 的正面是顺时针**：手写 `ArrayMesh` 索引如果按 OpenGL 习惯写 CCW，朝上的面会被背面剔除掉，物理在、渲染一片白。
- **太阳别压太低**：`scenes/city.tscn` 里 Sun 的仰角要够高。压到约 19° 时高楼会投出几百米的阴影，楼群互相盖住，侧面全是死黑。
- **`AmbientLight3D` 和 `HemisphereLight3D` 在 4.7 都没了**：环境光只能在 `WorldEnvironment` 的环境资源里加（城市场景是 `city.gd` 的 `_tune_environment()` 现调的）。
- **光照总量要压在 1 附近**：太阳 0.45 + 环境 0.55。超过 1 糖果色楼整片过曝成白墙（卡通感全丢），低于 1 暗部又黑成一团。原版那份环境是 Reinhard 色调映射，还会把饱和色洗成粉彩，所以城市场景改成线性色调映射。
- **原版的 SSAO 强度 4.0 会把楼涂黑**：互相遮挡的墙面瞬间变死黑，卡通风格要「暗部也有颜色」，所以城市场景关掉 SSAO / SSIL。
- **`.tscn` 里不许写「属性行尾 # 注释」**：只有整行以 `#` 开头才算注释。行尾 `#…` 会被算进属性值、赋值失败，然后该节点块之后的解析被静默中断，后面所有 `[node]` 整段丢失，引擎还不报错。
- **`.tscn` 里写中文注释会炸**：无 BOM UTF-8 的中文注释会让 `ResourceFormatText` 解析失败（报 `Invalid color code: #.`）。`.gd` 里中文随便写，`.tscn` 里只能纯 ASCII。
- **`.tscn` 的段序是死的**：`ext_resource` 必须整段排在 `sub_resource` 前面，反了报 `Unknown tag 'ext_resource'`。另外内联的 `[sub_resource type="Environment"]` 通过 `SubResource("id")` 引用会注册不上（`!int_resources.has(id)`），所以城市场景直接复用 `main-environment.tres`，调参走代码。
- **Godot 4.7 的 `SurfaceTool` 没有 `append_with_transform`**，`BoxMesh` 也没有 `uv_scale`，材质上叫 `emission` 而不是 `emissive`，所以城市几何是手写 `ArrayMesh` 的；4.7 的 `SurfaceTool` 也**没有 `add_index_array`**，索引得一条条 `add_index`。
- **`.tscn` 里混进第三方 shader 语法会静默丢属性**：把 `shader_type` / `render_mode` 写进 `type="Material"` 的 `.tres`，解析器会把这些当嵌套属性丢掉，顶点色之类跟着失效。材质能代码内建就别走 `.tres`。
- **移动 / 改名 `.gd` 之后要清缓存**：`.godot/uid_cache.bin` 和 `global_script_class_cache.cfg` 里的 uid→path 还指向旧路径，引擎拿旧 path 找 ext_resource，报 `File not found`。删这两个（加 `script_cache.bin`）+ 跑 `--import` 重建。
- **`.godot/script_cache.bin` 会让体检给假绿灯**：验收前先删它，因为 `--check-only` 走缓存。
- **跑生成器**：`tools/gen_city.py` 会比较慢（楼群循环几万次点到线段的距离计算，一两分钟）。重定向输出到文件时记得加 `python -u`，否则块缓冲会让你以为它卡死了。
- **改 GDScript 后先查缩进层级**：用编辑工具插在 `for` 循环体里的几行，`old_string` / `new_string` 的 tab 数对不齐，就会把循环体拆成两层 —— 报的是 `Parse Error: Expected statement, found "Indent"`，行号还会指到后面几行，极具误导性。插代码前先看一眼已有行的 tab 数（本项目 `.gd` 一律用 **tab 缩进**）。
- **`..` 区间语法在本项目的 4.7 build 不可用**：`for x in a..b:` 直接 Parse Error，一律写 `range(a, b+1)`。
- **`edges.values()` 不能直接按 `(a, b)` 拆**：key 是 `(id_a, id_b)`、value 是 `(格坐标a, 格坐标b)`，只拆 values 会让 pattern 的第二个元组把「某端的格坐标」再拆成两个整数，报 `TypeError: 'int' object is not subscriptable`。要按 `items()` 拆。
- **启动图只认 PNG**：引擎按文件魔数判定（`main.cpp:3954 "The only supported format is PNG"`），把 `boot_splash/image` 指向 `.jpg` 会静默降级成默认色块不看扩展名。要 jpg 文件名就得把 PNG 字节塞进那个文件名里。

## License

MIT License

Copyright (c) 2026 GTAWorld

本项目在 Kenney *Starter Kit Racing*（MIT，Copyright (c) 2023 Kenney）的基础上改造，代码沿用 MIT；
项目新增的代码与资产版权归 **GTAWorld** 所有，模板自带的 2D sprite / 3D 模型 / 音效仍是 CC0。
`LICENSE` 文件保持模板原件不动 —— 那是素材来源的授权链路，改它的版权行反而把来源说模糊了。

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Assets included in this package (2D sprites, 3D models and sound effects) are [CC0 licensed](https://creativecommons.org/publicdomain/zero/1.0/)

The skid sound effect was made by [Landeplage](https://github.com/Landeplage) and is also CC0 licensed
