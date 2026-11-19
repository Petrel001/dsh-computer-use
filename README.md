# dsh-computer-use

DeepSeek Harness（DSH）电脑控制插件：自实现的跨平台桌面自动化能力，让 agent 能枚举本地桌面
应用窗口、读取无障碍元素树、操作它们（点击 / 输入 / 按键 / 滚动 / 拖拽 / 设置值 / 截图），
并**验证动作是否真的产生了预期效果**。

本版本（v0.3）在 v0.2 基础上围绕**低延迟执行（服务小模型快速反应）**、**Token 精简与状态闭环**、
**UI 边界健壮性**与**跨平台一致性**做了新一轮升级。设计参考 ZCode 的 Computer Use 实现
（见 `references/zcode-computer-use-research.md`），但**完全独立**：不依赖 zcode-cua 原生 Helper，
也不依赖 Orca CLI，后端全部自实现。

## v0.3 的主要改动

| 方向 | 改动 |
| --- | --- |
| 极速执行 | 新增文件队列常驻 worker（`zcc-worker.ps1`，`CUA_WORKER=0` 可关闭，`stop-worker` 可手动停止），保持 .NET UIA/Drawing/WinForms 与 C# 编译程序集常驻内存；`ZccNative` 编译产物落盘缓存为 `zcc-native-<hash>.dll`；`Get-TopLevelWindows` 改为先用 Win32 属性过滤再用 `QueryFullProcessImageNameW` 按需解析进程名，消除全量 `Get-Process` 扫描 |
| 状态闭环 | `--wait-for` / `--wait-gone` / `--expect-change`、`wait`、`find`（实时路径）与 `screenshot --annotate` 在获取新快照后自动调用 `Save-SnapshotCache` 刷新磁盘缓存；`screenshot --annotate` 同步返回 `state_id`，后续动作可直接复用 `--state-id`，无需重复 `get-app-state` |
| 小模型友好 | `get-app-state` 新增 `--compact`（省略 stdout 的 `elements[]`，实测小窗口 JSON 载荷缩减 79%，树文本附带非重复值提示且完整树仍写入缓存）与 `--scope-element` / `--scope-path` 局部子树扫描；新增 `CUA_TRAJECTORY_PATH` JSONL 轨迹录制（默认不记录输入明文，可选 `CUA_TRAJECTORY_INCLUDE_TEXT=1`） |
| Windows 边界 | `InvokePattern.Invoke()` 增加 1.5 s 模态弹窗非阻塞探测（`uia-invoke-modal`）；`ExpandCollapsePattern` 按状态自动 `Expand`/`Collapse`（`uia-expand`/`uia-collapse`）；离屏元素自动 `ScrollIntoView()`；`scroll` 新增 `left\|right` 横向滚动；`Chrome_WidgetWin*` 空/极小树自动发送 `WM_GETOBJECT` 提示；`screenshot` 对后台窗口优先走 `PrintWindow`（`capture_method=printwindow`），`--annotate` 过滤超大纯容器框并做四色调色板与标签防重叠；`status` 暴露 `thread_desktop` / `desktop_mismatch` / `worker_mode` |
| 跨平台修复 | 修复 macOS JXA `walkTree` 与 `findElement` 索引错位 bug 并补充元素 `path`；修复 Linux `platform.mjs` `capabilities` 重复 `"screenshot"`；Linux 窗口枚举改用 `wmctrl -lp` 支持 `pid:` / `hwnd:` 与横向滚动 |
| 单测覆盖 | 新增 `npm test`（`node --test scripts/tests/cli.test.mjs`），在无 GUI 环境下快速验证 CLI 解析、互斥校验、超时与跨平台选择器解析 |

## v0.2 的主要改动（基础能力）

| 方向 | 改动 |
| --- | --- |
| 精确定位 | 快照元素新增 `path`（ControlView 子节点链）；`get-app-state` 落盘状态缓存；动作按 `index→path→指纹校验` 定位，命中时 `target.resolve=index-path`，无缓存时回退整树扫描 |
| 性能 | 快照改用 `GetSupportedPatterns()`（1 次跨进程调用，替代原来 7 次 `GetCurrentPattern` 探测）；去掉每次调用前的 PowerShell 存在性探测；窗口枚举改 `EnumWindows`（不再靠 UIA 根节点，也没有 `Get-Process` 全表扫描） |
| 新鲜度 | `state_id` 现在对**完整可观测状态**（含 value/toggle/selected/bounds）取哈希；`--state-id` 可强制校验；指纹不符返回 `stale_state`，不会在位移后的树上乱点 |
| 验证 | 所有变更类命令支持 `--wait-for` / `--wait-gone` / `--wait-timeout` / `--expect-change`；新增 `wait` 命令；验证超时仍返回已发送的动作结果 |
| 查找 | 新增 `find`（按 role/name/value 检索，可复用新鲜缓存），避免为找一个按钮 dump 整棵树 |
| 安全 | 输入注入前**断言前台**（失败 `focus_failed`），锁屏/安全桌面识别为 `session_locked`；非 ASCII 输入后恢复用户剪贴板；可选 `CUA_DENY_TITLES/PROCESSES` 黑名单与 `CUA_AUDIT_PATH` 审计日志 |
| 正确性 | 右键/双击强制走坐标注入（UIA 模式表达不了）；`set-value` 不再抢焦点；滚动优先 `ScrollPattern`；`--app title:` 现在能选中对话框/次级窗口（原先只看 `MainWindowHandle`） |
| 测试 | 冒烟测试从 46 项扩到 80+ 项；修掉原测试在中文 Windows 上**必然失败**的编码缺陷（PowerShell 5.1 用 GBK 解码 node 的 UTF-8 stdout） |

完整的差距分析与逐项证据见 `references/improvements-v0.2.md`。

## 能力矩阵

| 平台 | 后端 | 能力 |
| --- | --- | --- |
| Windows（已端到端验证） | UIAutomation + user32 P/Invoke + System.Drawing | 全量：status / list-apps / list-windows / get-app-state / find / wait / screenshot（`--annotate`/`--grid`）/ focus / move / click / type / keypress / scroll / drag / set-value；状态缓存、新鲜度校验、动作后验证、审计、黑名单 |
| macOS（未在本机验证） | JXA (System Events) + `screencapture` | status / list-apps / list-windows / get-app-state / screenshot / focus / click / type / keypress / scroll |
| Linux（未在本机验证） | xdotool + wmctrl + import/scrot/gnome-screenshot | status / list-apps / list-windows / screenshot / focus / move / click / type / keypress / scroll / drag（无 get-app-state） |

新鲜度与验证参数仅在 Windows 后端可用；在其他平台上使用会明确失败为 `capability_unavailable`，
不会被静默忽略。

## 性能与验证

同机实测（15 元素 WinForms 窗口，3 次中位数）：

- **常驻 Worker（`CUA_WORKER=1`，默认）**：`status` 49 ms、`list-apps` 50 ms、`get-app-state` 249 ms、
  `get-app-state --compact` 255 ms（JSON 载荷 5072→1056 bytes，缩减 79%）、`screenshot --annotate` 271 ms、
  `set-value` 2138 ms。
- **单次进程模式（`CUA_WORKER=0`，含 `ZccNative` DLL 缓存与按需进程解析）**：`status` 485 ms
  （v0.2 为 717 ms）、`list-apps` 472 ms（v0.2 为 709 ms）、`get-app-state` 940 ms（v0.2 为 1034 ms）、
  `set-value` 2768 ms。

注：上述延迟为当前 `exebox` 隔离桌面下 `runWindowsCommand` 直接实测结果（跨桌面 WinForms `ValuePattern.SetValue`
本身耗时约 2.1 s）；在解锁的真实交互桌面上连续多步操作时，常驻 Worker 可免去重复冷启动开销。

测试入口：

- 无 GUI 契约单测：`npm test`（`node --test scripts/tests/*.test.mjs`）
- Windows 端到端冒烟：`powershell -File scripts/tests/smoke-windows.ps1`（完整 80+ 项全通过需在解锁的交互桌面上运行；
  当前隔离桌面环境下可运行验证状态树、`--compact`/`--scope-element`、闭环缓存刷新、`ExpandCollapse`、
  `PrintWindow` 截图/标注、轨迹日志、黑名单与错误契约，而前台切换、键鼠注入、UIA `Invoke`/`Toggle` 与整屏
  `CopyFromScreen` 会因系统桌面隔离限制按预期失败）。

## 快速开始

```bash
# 能力探测（任何命令之前先跑它）
node scripts/computer-control.mjs status

# 列窗口 → 读元素树 → 操作并验证 → 再读状态
node scripts/computer-control.mjs list-apps
node scripts/computer-control.mjs get-app-state --app title:记事本
node scripts/computer-control.mjs find --app title:记事本 --role button --name 保存
node scripts/computer-control.mjs click --app title:记事本 --element 7 --wait-for "role:dialog"
node scripts/computer-control.mjs click --app title:记事本 --element-path 0.2.1

# 视觉瞄准：元素标注（[N] 与 get-app-state 的 index 一致）/ 绝对坐标网格
node scripts/computer-control.mjs screenshot --app title:记事本 --out ./shot.png --annotate --grid 100
node scripts/computer-control.mjs move --app title:记事本 --x 850 --y 470

# 等一个与自身动作无关的界面变化
node scripts/computer-control.mjs wait --app title:记事本 --for "name:加载完成" --timeout 10000
```

完整契约（参数、选择器、验证语义、错误码、环境变量）见 `references/command-reference.md`；
agent 使用规范见 `SKILL.md`。

## 作为 DSH skill 安装

本目录即标准 skill 包（`SKILL.md` + 资源目录）。安装方式：

```bash
# 方式一：复制到用户 skill 目录（会覆盖同名旧版本，建议先备份）
cp -r dsh-computer-use ~/.agents/skills/

# 方式二：随 marketplace / git 仓库分发（skills/<name>/SKILL.md 布局）
npx skills add <owner>/<repo>@dsh-computer-use -g -y
```

## 测试

```bash
# Windows 端到端冒烟（80+ 断言；独立目标应用 + 事件日志 + 像素级校验，无需读图）
powershell -File scripts/tests/smoke-windows.ps1
```

测试目标应用 `scripts/tests/target-app.ps1` 是带真实消息循环的独立进程：按钮点击会改状态标签
（立即 / 延迟 500 ms 两种），控件事件（点击、以屏幕坐标记录的鼠标移动）写入日志文件，因此语义
Invoke、坐标点击、键盘、hover、等待/验证都有可断言的接收证据；`--annotate` / `--grid` 叠加层
另有像素颜色校验（标注框 lime、网格标签 yellow）。

测试注意事项：

- **必须在解锁的交互桌面上运行**。锁屏时 Windows 拒绝任何前台切换与输入注入，需要输入的动作
  会以 `session_locked` 失败——这是设计行为，不是测试缺陷。
- 测试脚本开头固定 `[Console]::OutputEncoding = UTF-8`；否则 PowerShell 5.1 会用 ANSI 代码页
  解码 node 的 UTF-8 stdout，中文元素名会让 JSON 解析失败（原版测试在中文 Windows 上因此 100% 失败）。

## 已知边界（如实说明）

- macOS / Linux 后端按文档规约实现，**未在对应系统上实测**；能力探测失败时以
  `unsupported_platform` / `capability_unavailable` 明确失败。
- Windows 上非 ASCII 文本走剪贴板粘贴路径（SendKeys 的 Unicode 支持依赖键盘布局）；粘贴后会恢复
  用户剪贴板，但若原剪贴板是非文本格式，恢复是 best-effort。
- 锁屏 / 安全桌面下无法注入输入（`session_locked`）；UAC 提权对话框也属于安全桌面。
- UIA `Invoke()` 的耗时由目标应用的无障碍 provider 决定（个别 WinForms/MSAA 应用单次可达数秒），
  与定位开销无关。
- Chromium/Electron 窗口在未开启无障碍时不暴露元素树（可能只有 1–2 个元素）；请改用
  `screenshot --grid/--annotate` + 坐标点击，`get-app-state` 读取失败时会明确报错而不是给空树。
- Win32 EDIT 控件不一定支持 Ctrl+A（取决于应用自身实现）；shift+home 等标准编辑快捷键可用。
- 只能控制**本机**桌面；远程 workspace 控制的是远端机器的桌面。
- Windows 沙箱注意：所有 `.ps1` 文件保持纯 ASCII（PowerShell 5.1 在中文区域设置下会把无 BOM 的
  UTF-8 文件按 GBK 解码，吞换行符导致解析失败）；Node 与后端的通信走临时参数/输出文件而非管道 stdio。

## 目录结构

```
dsh-computer-use/
├── SKILL.md                          # skill 入口（frontmatter + agent 使用规范）
├── README.md
├── package.json
├── references/
│   ├── command-reference.md              # 完整命令契约
│   ├── improvements-v0.2.md              # 本次迁移改进的差距分析与验证记录
│   └── zcode-computer-use-research.md    # ZCode CUA 实现研究（设计依据）
└── scripts/
    ├── computer-control.mjs           # CLI 入口
    ├── lib/                           # runner / platform / cli / 三平台后端
    ├── powershell/                    # Windows 后端（UIA + P/Invoke + 截图 + 状态缓存 + 常驻 worker）
    ├── jxa/                           # macOS 后端（System Events）
    └── tests/                         # cli.test.mjs + smoke-windows.ps1 + target-app.ps1
```