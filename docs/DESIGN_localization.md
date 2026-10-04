# DESIGN_localization —— 多语言本地化设计（中 / 英 / 韩）

> 状态：**待拍板**（按 AGENTS.md 流程：调研 → 我选 → 细化 → 实现）。
> 需求来源：2026-10-03 用户指令「开始就要设计多语言版本，先添加中文、英文、韩文版本」。
> 目标读者：实现轮次的 AI / 我自己。所有 API 名以本机 Godot 4.7 stable 实测为准，
> 文中标 ⚠ 的条目实现前要先验证。

---

## 1. 需求与目标

1. 全部 **用户可见文案** 三语化：简体中文 zh_CN、英文 en、朝鲜语 ko_KR。
2. 首次启动**自动跟随系统语言**（OS.get_locale()），识别不了的回落英文。
3. 玩家可**手动切换语言并持久化**（重启保持），切换入口在选图页（select）。
4. 架构上为后续语言（日、西、法…）留位：**加一列翻译 = 加一门语言**，不改代码。
5. 韩文/中文渲染不能出豆腐块（□）：字体策略必须写死在方案里。

不在本轮范围：语音、日期/数字本地化（游戏里没有货币/时间格式需求）、RTL（三语都不需要）。

## 2. 现状盘点（2026-10-03 扫描）

| 位置 | 文案 | 条数 |
| --- | --- | --- |
| `scripts/vehicles/vehicle_interactable.gd` | 按 E 上车 / 按 E 下车 | 2 |
| `scripts/net/urban_net.gd` | 联机大厅、创建/加入/退出、状态行、房间信息 | ~15 |
| `scripts/select.gd` | 选择地图、卡片标题/副标题/标签、按键说明、进入按钮 | ~10 |
| `scripts/hud/tune_hud.gd` | 调参面板标题、三行滑条名、提示 | 5 |
| `modules/fps_stats/module.gd` | FPS/节点/在线人数模板行 | 3 |
| `project.godot` `config/name` | 窗口标题 GTAWorld（英文，可不动） | 1 |

合计 ≈ 45 条，全部是代码里动态 set 的 `text`（没有 .tscn 静态文案），迁移成本低。
字体：当前中文正常 = 引擎默认字体的**系统字体回退**在 Windows 上生效（微软雅黑）。
⚠ 韩文未实测；且系统回退在 Linux/手机导出上不可依赖。

## 3. 方案卡

### A. Godot 内置 tr() + CSV 翻译表（官方主流）

| 字段 | 内容 |
| --- | --- |
| 核心理念 | 文案不写在代码里，写进一张 `translations.csv`（列=语言），代码只喊 key；引擎按当前 locale 查表 |
| 适用 | 文案量 < 几千条、单人/小团队、要运行时切换 —— 正是本项目 |
| 核心机制 | CSV 自动导入成 `.translation` 资源；`tr("NET_TITLE")` 取当前语言文本；`TranslationServer.set_locale("ko_KR")` 全局切换；Control 的 text 属性在切语言时自动重译（auto_translate_mode） |
| 优点 | 零依赖；编辑器/导出全内置；加语言=加一列；`internationalization/locale/fallback` 兜底 ⚠ |
| 缺点与代价 | CSV 里改文案没有代码高亮/重构；带参数的句子要自己定占位符规范；翻译多了以后 CSV 一列一列横向膨胀，diff 不友好 |
| 代表作品 | Godot 官方 docs「Exporting translations」；Kenney 系 demo 常用做法 |
| 关键坑 | ① CSV 必须 UTF-8（无 BOM 最稳）；② header 首列必须叫 `keys`，语言列名就是 locale 码（`zh_CN` 而非 `zh`）⚠ 实测为准；③ 运行时拼接的整句（如「已连接 ｜ %d 人在线」）必须整句进表、占位符替换，不许半句拼接——语序在各语言里不同 |

### B. gettext .po / .pot（翻译行业通用格式，4.2+ 可直接导入）

| 字段 | 内容 |
| --- | --- |
| 核心理念 | 用翻译行业 30 年的标准格式，Poedit/Lokalise/Crowdin 等工具链全兼容 |
| 适用 | 有外部译者/翻译平台协作、文案量大的商业项目 |
| 核心机制 | 代码 `tr("key")` 不变，翻译存 `locale/ko_KR.po`，Godot 4.2+ 自动导入 ⚠；可配 gettext 域 |
| 优点 | 单语言单文件、diff 友好；有「未翻译/模糊翻译」状态标记；专业译者零学习成本 |
| 缺点与代价 | 单人开发属于过度工程；.po 语法（msgid/msgstr/复数）学习成本；本项目暂无外部译者 |
| 代表作品 | 大量开源 Steam 游戏 |
| 关键坑 | 复数规则三语各不同（韩文无复数、英文有），Godot 的 po 复数支持程度 ⚠ |

### C. 自研 autoload 语言表（`Lang.t(key)` + Dictionary）

| 字段 | 内容 |
| --- | --- |
| 核心理念 | 自己维护 `{"zh_CN": {...}, "en": {...}}`，完全脱离引擎 i18n |
| 适用 | 引擎 i18n 缺关键能力时的最后手段 |
| 优点 | 想怎么扩展怎么扩展 |
| 缺点与代价 | 重新发明轮子；失去 Control 自动重译；每次引擎升级都要自己维护；**本项目没有任何需求超出 A 的能力** |
| 代表作品 | 老 Godot 3 时代教程常见（当年 CSV 流程难用） |
| 关键坑 | 和 A 双轨并存必然出现两套文案源，SoT violated |

### D. 资源库本地化插件（如 godot-localization / gettext 编辑器插件）

| 字段 | 内容 |
| --- | --- |
| 核心理念 | 编辑器内表格化编辑翻译、缺漏检查 |
| 优点 | 编辑体验好 |
| 缺点与代价 | 第三方依赖 + 引擎版本跟进成本；本项目 45 条文案，编辑器体验收益≈0 |
| 代表作品 | Godot AssetLib 若干 |
| 关键坑 | gdextension 类插件会撞「全项目只能一份 .gdextension」铁律（Terrain3D 前车之鉴）；纯 GDScript 插件也先不装 |

## 4. 对比与推荐

| 方案 | 零依赖 | 加语言成本 | 译者协作 | 单人顺手度 | 结论 |
| --- | --- | --- | --- | --- | --- |
| A tr()+CSV | ✅ | 加一列 | 中（CSV 也能进多数平台） | ✅✅ | **主方案** |
| B .po | ✅ | 加一文件 | ✅✅ | 中 | 副：文案破千再迁（A/B 代码侧同为 tr()，迁移只换文件） |
| C 自研 | — | 改代码 | — | 中 | 放弃 |
| D 插件 | ❌ | — | — | 中 | 放弃（收益不抵依赖） |

**推荐：A 为主，预留 B 的迁移路径**（因为代码侧完全一样，将来只换翻译文件格式）。

## 5. 目标架构（A 方案细化）

```
locale/
  translations.csv        # keys,zh_CN,en,ko_KR —— 唯一文案源（SoT）
scripts/core/lang.gd      # autoload "Lang"（薄壳，只管切换与持久化，不做查表）
user://settings.cfg       # {locale="ko_KR"}
```

1. **key 规范**：`域_用途` 大写下划线，例 `PROMPT_BOARD`、`NET_CREATE_ROOM`、`SELECT_TITLE`。
2. **占位符**：整句进表，`{n}` / `{ip}` 命名占位，代码里 `tr("NET_ONLINE").replace("{n}", str(k))`。
   禁止半句拼接（英文/韩文语序与中文不同）。
3. **Lang autoload 职责**（只做三件事）：
   - 启动定 locale：user:// 存档 → 否则 `OS.get_locale()` 前缀匹配（zh*→zh_CN，ko*→ko_KR，其余→en）；
   - `set_locale(code)`：调 `TranslationServer.set_locale` + 写存档 + 发 `EventBus` 事件 `locale_changed`；
   - 不做任何文案存取（文案只活在 CSV，别开第二轨）。
4. **动态 UI**：urban_net 状态行/fps_stats 本来每帧刷新，天然跟随语言；
   select/tune_hud 是建一次的控制节点 —— 依赖 Control 自动重译（text 必须是 `tr(key)` 的结果才会被重译 ⚠ 实测），
   若实测不成立则在 `locale_changed` 里调各面板的 `rebuild()`（已列验收项）。
5. **字体（硬坑，必须做）**：打包 **Noto Sans SC + Noto Sans KR**（OFL 授权，可商用），
   做成 `Theme` 的默认字体并把 KR 设为 SC 的 fallback（两者字形互补拉丁/假名除外），
   经 `internationalization/rendering/...` 或各面板 theme 挂上 ⚠ 具体挂法实现轮实测：
   优先项目级默认 theme（`gui/theme/custom`）。理由：系统回退只在 Windows 可靠，
   导出到别的平台就是豆腐块；且字形混用截图难看。
6. **翻译内容**：en 由 AI 起草（游戏惯用语，如 "Press E to enter"）；ko 由 AI 起草 +
   请用户找懂韩文的朋友/社区过一眼（AI 韩文敬语层级容易选错：游戏 UI 用해체/합니다 要统一，建议统一 **합니다체**）。

## 6. 验收清单（实现轮照此测）

- [ ] 三语各截 4 图：select / 驾驶提示 / Tab 大厅菜单 / 房间视图，无豆腐块、无半截翻译。
- [ ] 改 locale 后**不重启**：select 标题、大厅按钮即时变字（探针断言）。
- [ ] 删 user://settings.cfg 重启：按系统语言自动选中（Windows 中文 → zh_CN）。
- [ ] CSV 加一列 `ja` 不改代码即可 `set_locale("ja")`（留空回落 fallback=en 也算通过）。
- [ ] `--check-only` + 探针报告落盘（v20 系列）。

## 7. 需要拍板的 3 个问题

1. **默认语言策略**：跟随系统（推荐）还是固定中文？跟随系统时英文/韩文用户第一眼是母语，
   但你自己调试时每次都要手动切回中文一次（存档后会记住，实际只切一次）。
2. **字体**：按第 5.6 打包 Noto SC+KR（推荐，导出跨平台稳，代价 +~10MB 字体子集），
   还是先赌 Windows 系统回退（零成本，但别的平台可能豆腐）？
3. **韩文译文**：AI 起草 + 你事后找人校对（推荐），还是这轮就要我找参照项目里的韩语素材核对？
   （参考项目内无韩文 UI 素材可参照。）
