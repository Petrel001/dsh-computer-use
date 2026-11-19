# dsh-computer-use 命令契约

所有命令：`node scripts/computer-control.mjs <command> [flags]`。每条命令输出**单个 JSON 信封**；
退出码 **0 成功 / 1 后端或验证失败 / 2 用法错误**。`--pretty` 美化输出，`--timeout <ms>` 覆盖
单次后端执行超时（`wait` 自己的 `--timeout` 是等待时长，见下）。

```jsonc
// 成功
{ "ok": true, "command": "click", "platform": "win32", "action_sent": true, "result": { ... } }
// 失败（稳定错误码，不要按 message 分支）
{ "ok": false, "command": "click", "platform": "win32", "error": { "code": "stale_state", "message": "..." } }
// 动作已发出但验证失败：带 result，便于判断半成品状态
{ "ok": false, "command": "click", "platform": "win32", "action_sent": true,
  "error": { "code": "verification_timeout", "message": "..." },
  "result": { "method": "uia-invoke", "verification": { "ok": false, "matched": false, ... } } }
```

## 通用

### 应用选择器 `--app`

| 形态 | 含义 |
| --- | --- |
| `pid:1234` | 该进程最靠前的顶层窗口（z-order 第一个） |
| `hwnd:123456` | 精确窗口句柄 |
| `name:notepad` | 进程名子串（不区分大小写） |
| `title:记事本` | 窗口标题子串（不区分大小写） |
| `记事本`（裸串） | 等价于 `title:记事本` |

- Windows 的窗口枚举走 `EnumWindows`，因此**对话框、次级窗口、最小化窗口**都能选中；
  UIA 根节点的 ghost 窗口、DWM cloaked 窗口、1×1 工具窗口与 shell 基础设施窗口默认被过滤
  （`list-apps --all` 可关闭过滤）。
- 多个匹配时失败为 `window_ambiguous`，消息中列出候选；改用 `pid:` / `hwnd:`。

### 元素目标

`get-app-state` 返回 `elements[]`，每个元素：

| 字段 | 说明 |
| --- | --- |
| `index` | 元素序号，**主动作目标**（`--element`）；只在当前快照内有意义 |
| `path` | ControlView 树中的子节点路径（如 `0.2.1`），可用 `--element-path` 直接寻址 |
| `role` | UIA ControlType（Button、Edit、CheckBox、MenuItem…） |
| `name` | 可见名称（可空） |
| `value` | ValuePattern 当前值（输入框等） |
| `patterns` | 支持的模式：`invoke / value / toggle / select / expand / scroll / text / selection / scrollitem / range / window` |
| `toggle` / `selected` | 复选框三态 / 选中态（有该模式时） |
| `bounds` | 屏幕坐标 `{x,y,width,height}`（离屏元素可能缺失） |
| `enabled` / `offscreen` | 状态标记 |
| `automation_id` | 自动化 id（有则输出） |
| `depth` / `parent` | 树深度与父元素 index |

- `--element N`：正常用法。动作前会经状态缓存解析并**校验指纹**（role/name/automation_id）。
- `--element-path P`：跳过 index→path 映射直接按路径定位；适合没有缓存或跨快照复用路径。
- 两者互斥；同时给出是用法错误（退出码 2）。

### 新鲜度（state_id 与状态缓存）

`get-app-state` 会把元素表落盘到状态缓存（`status.state_cache_dir`，可用 `CUA_STATE_DIR` 覆盖），
同时返回 `state_id`——对**完整可观测状态**（index/path/role/name/value/toggle/selected/enabled/
offscreen/bounds + 截断标记）的 SHA-256 前 12 位。因此 `value` 变化、勾选变化都会改变 `state_id`。

- `--state-id <id>`：缓存中的快照必须正好是它，否则 `stale_state`。
- 不给 `--state-id` 时：按缓存 index→path 定位，并校验**身份**：role 必须一致，且
  name 或非空 automation_id 至少一个一致（WinForms 的 Edit 会把输入值暴露成 Name，因此不能要求
  name 不变；也有控件每次生成新的 automation_id，因此不能只认 id）。不匹配即 `stale_state`，
  绝不在位移后的树上乱点。
- 无可用缓存（从未快照 / 缓存过期 / 窗口重建）时回退整树扫描，`result.target.resolve` 会写
  `index-scan`（缓存命中为 `index-path`，显式路径为 `path`）。
- 恢复方式永远相同：重新 `get-app-state`，按新 index 重试。

### 动作后验证

所有**可定位元素**的变更类命令（`click/type/keypress/scroll/move/set-value`）共享以下参数
（`focus`、`drag` 不支持，它们没有可验证的元素目标）：

| 参数 | 含义 |
| --- | --- |
| `--wait-for "<spec>"` | 动作后轮询，直到条件成立 |
| `--wait-gone "<spec>"` | 动作后轮询，直到条件不再成立 |
| `--wait-timeout <ms>` | 等待上限，默认 5000（100–120000） |
| `--expect-change` | 比较动作前后 state_id；无变化即判为 no-op |

**spec 语法**：逗号分隔的 `key:value`，全部满足才算匹配；值为大小写不敏感子串。

| key | 匹配对象 |
| --- | --- |
| `role` | 元素 role |
| `name` | 元素 name |
| `value` | ValuePattern 值 |
| `id` / `automation-id` / `automation_id` | automation id |
| `enabled` | `true/false/1/0/yes/no` |
| `pattern` / `patterns` | 是否支持该模式（如 `invoke`） |
| `toggle` | `on/off/indeterminate` |
| `selected` | `true/false/1/0/yes/no` |
| `text` | name+value+id 的联合子串（裸文本即此 key） |

例：`--wait-for "role:button,name:save,enabled:true"`、`--wait-gone "name:loading"`。

- 成功：`result.verification = { kind, spec, ok, matched, elapsed_ms, polls, state_id, element? }`，
  其中 `verification.state_id` 与 `result.state_id` 是**验证时**（动作后）的快照 id；
  而 `result.resolved_from_state_id` 是动作解析目标时依据的快照 id（仅元素目标动作有）。
- 超时：`ok:false`、`action_sent:true`、`error.code=verification_timeout`，并附 `result`。
- 动作被判定为 no-op：`ok:false`、`error.code=no_state_change`，附 `result`
  （`result.state_changed=false`、`state_before`、`state_id`）。

## 命令

### status
只读。输出 `result`：`{ platform, backend, capabilities[], window_count, input_desktop, thread_desktop,
desktop_mismatch, session_locked, worker_mode, state_cache_dir, audit_enabled, trajectory_enabled,
deny_list_active, notes }`。

### stop-worker
Windows 后端专用。停止在后台保持预热的 `zcc-worker.ps1` 常驻进程，返回 `{ stopped, previous_pid }`。

### list-apps
只读。`--all` 关闭过滤。`result.windows[]`：
`{ hwnd, pid, process, title, class, bounds, visible, minimized, maximized, cloaked, owned,
tool_window, foreground, z_order }`。按 z-order（前台的在前）排序，上限 200。

### list-windows
`--app`（必填），`--all`。列出该选择器匹配的所有窗口（`result.windows[]` 同上）。

### get-app-state
`--app`（必填），`--max-elements`（100–5000，默认 2000），`--compact`（省略 stdout 中的 `elements[]`，
仅保留 `text` 树与 `state_id`，完整元素仍落盘缓存以节省小模型 Token），`--scope-element N` /
`--scope-path P`（仅扫描指定子树，并保留从窗口根出发的真实 `path`）。
`result`：`{ app, state_id, state_cached, element_count, truncated, scoped, compact, scope_path?, text, elements? }`。
`text` 是缩进文本树（`[3] Edit "Search"`）；大窗口可能截断（`truncated=true`）。
对 `Chrome_WidgetWin*` 类且元素过少的窗口会自动发送一次 `WM_GETOBJECT` 提示唤醒无障碍树；
若仍无法读取则会明确报错，而不是返回空树。

### find
`--app`（必填）；`--role`、`--name`、`--value` 至少一个；`--name-exact`、
`--limit`（1–500，默认 20）、`--use-cache`、`--max-age <ms>`（默认 2000）。
`result`：`{ app, state_id, source: "live"|"cache", count, limit, truncated, matches[] }`。
`matches[]` 结构同 `elements[]`（含 `index`/`path`）。
`--use-cache` 只在缓存足够新（`--max-age` 内）且窗口/pid 匹配时使用，否则自动改用实时快照。

### wait
`--app`（必填）；`--for` 或 `--gone`（二选一）；`--timeout <ms>`（100–120000，默认 5000）；
`--interval <ms>`（50–5000，默认 250）。
命中：`result = { app, kind, spec, matched, elapsed_ms, polls, state_id, element? }`。
未命中：退出码 1，`error.code=verification_timeout`，并附同一份 `result`。

### screenshot
`--app` 或 `--screen`（二选一）；`--element N` 或 `--element-path P`；`--out <path>`；
`--inline`（≤512 KiB 时附带 base64）；`--annotate`（需 `--app`）；`--grid [px]`（20–500，裸用 100）。
`result`：`{ path, width, height, bytes, capture, capture_method, bounds, app?, annotated, annotated_elements, grid, state_id? }`。

- `--annotate` 的框与 `[N]` 标签与 `get-app-state` 的 index **完全一致**（同一遍历实现），会自动过滤
  顶层窗口与超大纯布局容器框，使用多色标注与标签避让，并同步刷新状态缓存与返回 `state_id`。
- 目标窗口处于后台时优先使用 `PrintWindow`（`capture_method=printwindow`）避免被遮挡窗口污染。
- `--grid` 刻度是**绝对屏幕坐标**，可直接作为 `click --x/--y`。
- `--element`/`--element-path` 走与 click 相同的定位/校验路径。

### focus
`--app`（必填）。切前台并**断言成功**（含最小化还原）。失败 `focus_failed`；锁屏 `session_locked`。

### click
`--app`（必填）；元素目标或 `--x --y`（二选一）；`--button left|right|middle`；`--double`。
语义优先级 Invoke（带模态弹窗非阻塞保护 `uia-invoke-modal`）→ SelectionItem → Toggle →
ExpandCollapse（按当前状态自动 `Expand`/`Collapse`）→ 元素中心坐标（离屏且支持 `ScrollItemPattern`
时先 `ScrollIntoView`）；
`--button` 非 left 或 `--double` **强制走坐标注入**（语义模式无法表达）。
`result`：`{ app, method, button, double, target:{index?,path?,resolve?}, at?, resolved_from_state_id?,
state_before?, state_id?, verification?, state_changed? }`。
`method`：`uia-invoke / uia-invoke-modal / uia-select / uia-toggle / uia-expand / uia-collapse / coordinate-fallback / coordinate`。

### type
`--app`（必填）；`--text`（必填）；元素目标；`--submit`；`--keep-clipboard`。
ASCII 走 SendKeys（元字符已转义）；非 ASCII 走剪贴板粘贴，并在完成后**恢复用户原剪贴板**
（`result.clipboard_restored`）。`--keep-clipboard` 可关闭恢复。
`result`：`{ app, length, focused_element, submitted, clipboard_restored, target?, resolved_from_state_id?, ... }`。

### keypress
`--app`、`--keys`（必填）；元素目标（先 SetFocus）。
`result`：`{ app, keys, send_keys, target?, resolved_from_state_id?, ... }`。
语法：`,` 分隔和弦序列，`+` 分隔和弦内修饰键与主键。
例：`ctrl+s`、`alt,f4`、`ctrl,shift,p`、`down,enter`。
命名键：enter tab esc space backspace delete insert up down left right home end pageup pagedown f1..f12
capslock；修饰键 ctrl/alt/shift（Linux 额外 cmd→super）。单字符直接作为主键。

### scroll
`--app`（必填）；`--direction up|down|left|right`（默认 down）；`--amount 1..20`（默认 3）；
元素目标或 `--x --y`（默认窗口中心）。
目标元素支持 `ScrollPattern` 且对应方向可滚动时走语义滚动（`method=uia-scroll`），否则滚轮
（`method=wheel`，横向使用 `MOUSEEVENTF_HWHEEL`）。

### drag
`--app`（必填）；`--path "x1,y1>x2,y2>x3,y3"`（必填，≥2 点，绝对屏幕像素）。
（`--path` 在 drag 里是坐标折线，不是元素路径。）

### move
`--app`（必填）；元素目标或 `--x --y`（二选一）。只移动光标、不点击；先断言前台。
`result`：`{ app, method, target?, at, resolved_from_state_id?, ... }`。

### set-value
`--app`、元素目标、`--text`（均必填）。经 ValuePattern 直接设置值：不敲键、不抢焦点。
元素不支持时 `action_unavailable`，改用 `type`。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `CUA_STATE_DIR` | 状态缓存目录（默认 `%LOCALAPPDATA%\dsh-computer-use\state`） |
| `CUA_WORKER` | 设为 `0` 关闭 Windows 常驻预热 worker（默认开启，文件队列 IPC） |
| `CUA_WORKER_IDLE_MS` | Windows 常驻 worker 空闲自动退出时长（默认 `60000` ms） |
| `CUA_AUDIT_PATH` | 开启审计：每个变更动作追加一行 JSONL（含命令/窗口/目标/长度，**不含输入文本**） |
| `CUA_TRAJECTORY_PATH` | 开启轨迹记录：追加 JSONL（含状态树、前后 `state_id`、动作、方法、耗时 `duration_ms`、验证结果，供模型训练/评测） |
| `CUA_TRAJECTORY_INCLUDE_TEXT` | 设为 `1` 时在轨迹记录中包含原始输入文本（默认关闭） |
| `CUA_DENY_TITLES` | 标题子串黑名单（逗号/分号分隔），命中即 `target_blocked` |
| `CUA_DENY_PROCESSES` | 进程名子串黑名单，同上 |
| `CUA_DPI_AWARE` | `0` 关闭 per-monitor DPI 感知（诊断用） |

## 错误码（稳定，按码分支）

| 错误码 | 退出码 | 含义 |
| --- | --- | --- |
| `invalid_arguments` | 2 | 参数缺失/非法/互斥冲突 |
| `unknown_command` | 2 | 命令不存在 |
| `unsupported_platform` | 1 | 平台后端不可用（无图形会话/缺依赖） |
| `capability_unavailable` | 1 | 该命令或参数在当前后端不可用 |
| `window_not_found` | 1 | 选择器无匹配 |
| `window_ambiguous` | 1 | 选择器多匹配（消息含候选） |
| `invalid_selector` | 1 | 选择器语法错误 |
| `element_not_found` | 1 | 元素序号不存在 |
| `stale_state` | 1 | 快照过期/指纹不符/路径已失效——重新 get-app-state |
| `state_cache_missing` | 1 | 用了 `--state-id` 但该窗口没有缓存的快照 |
| `action_unavailable` | 1 | 元素不支持所需模式 |
| `coordinates_out_of_bounds` | 1 | 坐标在虚拟屏幕外 |
| `element_offscreen` | 1 | 元素无可截图/点击的可见边界 |
| `window_has_no_bounds` | 1 | 窗口边界不可用（滚动需要显式目标） |
| `empty_capture_area` | 1 | 截图区域为空 |
| `focus_failed` | 1 | 无法把目标窗口切到前台（拒绝盲目注入） |
| `session_locked` | 1 | 会话锁屏/安全桌面，输入无法送达 |
| `target_blocked` | 1 | 命中 `CUA_DENY_*` 黑名单 |
| `clipboard_unavailable` | 1 | 剪贴板被占用，非 ASCII 输入无法粘贴 |
| `verification_timeout` | 1 | 动作已发出，但等待的条件未在时限内成立（附 result） |
| `no_state_change` | 1 | `--expect-change` 未观察到状态变化（附 result） |
| `permission_denied` | 1 | 系统权限拒绝（macOS 辅助功能/录屏） |
| `timeout` | 1 | 后端执行超时 |
| `spawn_failed` | 1 | 后端可执行文件缺失 |
| `backend_error` | 1 | 其他后端错误 |

## 平台差异

| 能力 | Windows | macOS | Linux |
| --- | --- | --- | --- |
| `get-app-state` / `find` / `wait` | ✅ | ✅（无 find/wait） | ❌（无无障碍树） |
| 状态缓存 / `--state-id` / `--element-path` / 验证参数 | ✅ | ❌（明确 `capability_unavailable`） | ❌ |
| `--annotate` | ✅ | ❌ | ❌ |
| `--grid` | ✅ | ✅ | ✅ |
| `move` | ✅ | ❌ | ✅ |
| `drag` | ✅ | ❌ | ✅ |
| `set-value` | ✅ | ❌ | ❌ |
| 审计 / 黑名单 | ✅ | ❌ | ❌ |

## 性能参考（Windows，本机同机对照）

同一台机器、同一个 14 元素 WinForms 目标窗口，每项取 3 次中位数（含进程启动与平台探测）：

| 命令 | v0.1 | v0.2 | 变化 |
| --- | --- | --- | --- |
| `status` | 853 ms | 717 ms | −136 ms |
| `list-apps` | 831 ms | 709 ms | −122 ms |
| `get-app-state` | 1130 ms | 1034 ms | −96 ms |
| `set-value` | 1061 ms | 878 ms | −183 ms |
| `click --element` | 909 ms | 821 ms | −88 ms |
| `type`（ASCII） | 1286 ms | 1213 ms | −73 ms |
| `screenshot` | 729 ms | 599 ms | −130 ms |

主要来源：去掉每条命令前的 PowerShell 存在性探测、快照模式探测从 7 次/元素降为 1 次/元素、
动作定位从整树重扫改为缓存路径（`target.resolve=index-path`）。元素越多，快照差距越明显
（每元素约省 1 ms × 元素数）；14 元素窗口下这部分约 0.1 s，500 元素窗口约 0.5 s。

注：UIA `Invoke()` 的耗时由目标应用的无障碍 provider 决定，与定位开销无关；锁屏/安全桌面下
系统会拒绝前台切换，此时所有需要前台的动作都以 `session_locked` 失败（实测锁屏时单次
`Invoke` 还会被拖到约 4 s，解锁后回到毫秒级）。