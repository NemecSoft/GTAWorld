# 第三方素材与代码许可

本仓库**我们自己的代码与文档**用 Apache License 2.0（见 `LICENSE`）。
下列内容不属于我们，许可按各自上游执行，本文件只做清单留档。

| 内容 | 位置 | 上游 | 许可 |
|---|---|---|---|
| 项目基线（随机赛道 + 自研车辆 + 图标 + splash） | `scenes/main.tscn`、`scripts/world/mapgen.gd`、`models/`、`audio/`、`icon.png` | [Kenney *Starter Kit Racing*](https://github.com/KenneyNL/Starter-Kit-Racing) | 代码 MIT（(c) 2023 Kenney，原文见 git 历史第一条提交的 `LICENSE`）；素材 CC0 |
| 人物 / 车辆 / 城市 / 自然 / 墓园 GLB·FBX 模型与贴图 | `models/cars/`、`models/characters/`、`models/city/`、`models/nature/`、`models/suburban/`、`models/weapons/`、`assets/` | kenney.nl 各套件（Conveyor/Car Kit/City Kit/Graveyard Kit/Suburban 等） | CC0 1.0 |
| `lowpolyterrain` 插件 | `addons/lowpolyterrain/` | Low Poly Terrain (Godot 4) | MIT，见该目录 `LICENSE` |
| `phantom_camera` 插件 | `addons/phantom_camera/` | Phantom Camera | MIT，见该目录 `LICENSE` |
| `gdtuner` 插件 | `addons/gdtuner/` | gdtuner | 目录内未附许可文件，仅作本地编辑器工具使用 |
| `terrain_3d` 插件 | `addons/terrain_3d/`（**已 gitignore，不入库**） | Terrain3D | MIT；本机 Godot 4.7 实测注册失败，项目内 0 引用 |

> 说明：`LICENSE` 之前是 Kenney 模板自带的 MIT 全文，2026-10-04 换成 Apache-2.0（覆盖我们的代码），
> Kenney 原文与上游出处保留在本文件与 git 历史里。
