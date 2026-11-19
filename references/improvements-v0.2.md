# v0.2 迁移改进记录（差距分析 + 验证证据）

来源：`C:\Users\Administrator\.agents\skills\dsh-computer-use`（v0.1.0）。
目标：`D:\MyProject\computeruse`（v0.2.0）。原目录保持不动，便于对比回滚。

迁移方式：先整包复制并跑基线冒烟，再按「性能与精确定位 / 动作后验证与等待 / 状态新鲜度与安全」
三个方向逐项改造。下面每条都写明**观察到的证据**与**改动**，没有依据的猜测不列入。

---

## A. 迁移时立刻复现的既有缺陷

### A1. 冒烟测试在中文 Windows 上 100% 失败（原版声称 46/46）

**证据**：在原目录和新目录各跑一次 `smoke-windows.ps1`，都在 `get-app-state` 处崩在
`ConvertFrom-Json`：

```text
ConvertFrom-Json : 转换为类型 ... 无效 (610): {"ok":true,...,"text":"...\"系统菜单�?..."}
```

**根因**：PowerShell 5.1 用 `[Console]::OutputEncoding`（中文机器上是 GBK）解码原生子进程 stdout，
而 node 写的是 UTF-8；含中文元素名时 JSON 被解码成乱码，解析失败。测试脚本此前没有固定编码。

**改动**：`smoke-windows.ps1` 首行固定 `[Console]::OutputEncoding`/`$OutputEncoding` 为 UTF-8。
**证据**：固定后同一测试在同一机器上可以完整跑到断言阶段。

### A2. 状态缓存读取用 ANSI 解码，中文元素名导致缓存永久失效

**证据**：实现状态缓存后，`click --state-id <正确值>` 返回 `state_cache_missing`，`find --use-cache`
始终 `source=live`。缓存 JSON 里有中文元素名，`Get-Content`（PS 5.1 默认 ANSI）读入即损坏。

**改动**：缓存读取改用 `[IO.File]::ReadAllText(path, UTF8)`。
**证据**：同一命令随后返回 `stale_state`（错误码正确），`find --use-cache` 返回 `source=cache`。

### A3. 全局 `--timeout` 吞掉 `wait --timeout`

**证据**：`wait --for name:never --timeout 700` 返回 `error.code=timeout`（进程被 700 ms 杀掉），
而不是 `verification_timeout`。

**改动**：命令自带同名 flag 时优先按命令参数解析；全局执行超时只在命令没有该 flag 时生效。
**证据**：同一命令现在返回 `verification_timeout`，`result.elapsed_ms≈1100`。

### A4. 剪贴板恢复优先用 OLE 数据对象，文本反而丢失

**证据**：冒烟断言「中文输入后剪贴板仍为 sentinel」失败，`clipboard=''`——恢复函数报告成功
（`clipboard_restored=true`），但重新发布的 IDataObject 已不再提供 CF_UNICODETEXT。

**改动**：快照优先保存文本并用 `SetText` 恢复；只有剪贴板不含文本时才退回原始数据对象。
**证据**：同一断言随后通过（`clipboard='clipboard-sentinel'`），非 ASCII 文本也确实进入了目标输入框。

---

## B. 状态新鲜度与安全

### B1. `state_id` 只生成、从不校验

**证据**：v0.1 的 `state_id` 仅由**文本树**哈希得到（`zcc-state.ps1`），任何动作都不接受它；
动作按 index 在**当前**树上重新遍历，UI 一变就可能点到别的控件。

**改动**：
- 快照元素新增 `path`，`get-app-state` 把元素表写入状态缓存（按 hwnd 分文件，原子替换，1 天清理）。
- 动作解析 `index → path → 元素`，并校验缓存里的 `role/name/automation_id` 指纹。
- 新增 `--state-id`：与缓存不一致即 `stale_state`；指纹不符同样 `stale_state`；从未快照则
  `state_cache_missing`（提示先 `get-app-state`）。
- `state_id` 改为对**完整可观测状态**（index/path/role/name/value/toggle/selected/enabled/
  offscreen/bounds + 截断标记）取哈希。

**证据**：
- 错误 `--state-id` → `stale_state`（退出码 1）；正确的 → 动作成功并回显 `resolved_from_state_id`。
- `set-value --expect-change` 写入新值 → `state_changed=true`；旧实现下文本树不变，会误判为 no-op。
- 空闲窗口连续两次快照 `state_id` 一致。
- **身份判定不能只认 name 或 id**：实测 WinForms 的 `Edit` 会把输入值暴露成 UIA `Name`，
  填完一个值后第二次操作同一控件会被误判 `stale_state`；而部分 WinForms 控件的 automation id
  又是每次实例化都变。最终规则：role 必须一致，且 name 或非空 automation_id **至少一个**一致。

### B2. 前台切换失败是静默的，输入可能打进别的窗口

**证据**：v0.1 的 `Set-WindowForeground` 重试两次后**静默返回**；`Invoke-Type` 随后直接 SendKeys。

**改动**：新增 `Assert-ForegroundWindow`：先探测锁屏/安全桌面（`OpenInputDesktop` + 前台进程是否
`LockApp`/`LogonUI`），再重试切换并**失败即报错**；所有鼠标/键盘注入路径（click 坐标路径、type、
keypress、scroll 滚轮、drag、move）都先断言。
**证据**：本机锁屏期间 `type`/`move`/坐标点击全部返回 `session_locked`；锁屏前同样的调用正常。
这同时解释了为什么「报错」比「静默成功」更有价值：v0.1 在这种状态下会假装已输入。

### B3. 非 ASCII 输入会覆盖并丢失用户剪贴板

**证据**：v0.1 `Send-TypeText` 直接 `Clipboard::SetText` 后粘贴，从不恢复。

**改动**：非 ASCII 路径先快照剪贴板（所有格式优先，文本兜底），粘贴并等待目标消费后恢复；
结果字段 `clipboard_restored`；`--keep-clipboard` 可关闭。剪贴板被占用时 `clipboard_unavailable`。
**证据**：冒烟用例「中文输入后剪贴板仍为 sentinel」；当前处于锁屏，该断言需解锁后完成最终确认。

### B4. 无黑名单 / 无审计

**改动**：`CUA_DENY_TITLES` / `CUA_DENY_PROCESSES`（子串匹配）命中即 `target_blocked`；
`CUA_AUDIT_PATH` 追加 JSONL，记录命令/窗口/目标/长度，**不记录输入文本**；`status` 暴露
`audit_enabled` / `deny_list_active` / `session_locked` / `state_cache_dir`。

---

## C. 性能与精确定位

### C1. 每个元素 7 次跨进程模式探测

**证据**：v0.1 `Get-ElementSnapshot` 对每个元素逐个 `GetCurrentPattern` 探测 7 种模式
（invoke/value/toggle/select/expand/scroll/text），每次都是一次跨进程调用。

**改动**：改用 `GetSupportedPatterns()`（1 次调用返回全部支持的模式），并保留逐项探测作为
provider 抛异常时的兜底。新增 `selection/scrollitem/range/window` 等模式输出。

### C2. 每次动作都重走整棵树

**证据**：v0.1 的 `Find-ElementByIndex` 每次都从根节点重新遍历并按同一规则过滤。

**改动**：`get-app-state` 记录的 `path` 让动作只沿路径向下走（`Find-ElementByPath`），并用指纹
校验正确性；缓存缺失时仍走整树扫描，语义不变。
**证据**：实测解析阶段 `Resolve-ElementTarget` 约 50 ms（14 元素窗口）；动作结果
`target.resolve=index-path`，缓存不可用时为 `index-scan`。

### C3. 每次调用都先探测 PowerShell 是否存在

**证据**：`windows.mjs` 的 `resolvePowerShell()` 在每条命令前都跑一次
`powershell -NoProfile -Command "exit 0"`。

**改动**：直接尝试 `powershell.exe`，仅在 spawn ENOENT 时回退 `pwsh.exe`。
**证据**：裸 `powershell -Command "exit 0"` 单次约 120 ms，加进程创建后约 0.4–0.5 s/次调用。

### C4. 窗口枚举依赖 UIA 根节点，混入 ghost 窗口

**证据**：v0.1 `list-apps` 在本机返回 10 个窗口，其中包含 `GameViewerPrivacyMonitorWindowName`
（1×1）和一个位于 `-32000,-32000` 的 160×28 窗口；`ApplicationFrameHost/设置` 之类托管窗口
也只有空标题条目。

**改动**：改用 `EnumWindows` + user32/DWM 事实（可见性、DWM cloaked、工具窗口、owner、最小化、
z-order、窗口类），过滤 shell 基础设施与幽灵窗口；`list-apps --all` 可看全量。
**证据**：同一机器同一时刻返回 5 个窗口，目标窗口带 `class`/`visible`/`bounds` 等字段。

### C5. `title:` 选择器选不中对话框 / 次级窗口

**证据**：v0.1 的 `Resolve-WindowHwnd` 只遍历 `Get-Process | MainWindowHandle/MainWindowTitle`，
而 `get-app-state` 走 UIA 根节点；同一台机器上 OpenCode 的 "打开项目" 对话框能被 `get-app-state`
读取，但无法作为 `click/type` 的 `--app title:` 目标。

**改动**：选择器统一走 `EnumWindows`（`Resolve-WindowHwnd`），动作再按 hwnd 精确取 UIA 元素。

### C6. `FromHandle` 让整棵树退化成 Pane

**证据（实现期发现）**：为「精确取窗口元素」改用 `AutomationElement.FromHandle(hwnd)` 后，
同一个 WinForms 窗口的元素 role 全部变成 `Pane`（Button/Edit/Text 全部丢失），而按 UIA 根节点
子元素取则正常。`FromHandle` 返回的是 HWND 侧的 legacy proxy。

**改动**：`Get-UiaWindowElementByHwnd` 优先在 UIA 根节点子元素中按 hwnd 匹配，`FromHandle` 仅作兜底。

### C7. 右键/双击被语义模式劫持

**证据**：v0.1 `Invoke-Click` 不论 `--button`/`--double` 都先尝试 `InvokePattern`。
`click --button right` 会触发「默认动作」（通常是左键单击），而不是上下文菜单。

**改动**：`--button` 非 left 或 `--double` 时强制坐标注入；纯左键单击才走语义模式。

### C8. 滚动只发滚轮，子控件上常常无效

**改动**：元素目标支持 `ScrollPattern` 且可纵向滚动时优先语义滚动（`method=uia-scroll`），
否则回退滚轮（`method=wheel`）。

### C9. `type`/`keypress` 的焦点与文本内容

- `type --element` 先断言前台再 `SetFocus`；`set-value` 改为**不抢焦点**（ValuePattern 不需要）。
- `--text` 以 `--` 开头时不再被误判为布尔 flag（只有已知 flag 名才当 flag）。

---

## D. 动作后验证与等待

新增：

- `wait --for/--gone "<spec>" --timeout --interval`：轮询快照，命中返回元素与 `state_id`；
  未命中 `verification_timeout` 并附 `result`（`ActionSent=false`）。
- 所有变更类命令的 `--wait-for/--wait-gone/--wait-timeout/--expect-change`：
  - 等待命中 → `result.verification{ok,matched,elapsed_ms,polls,state_id,element?}`；
  - 等待超时 → `ok:false, action_sent:true, error.code=verification_timeout`，**保留动作结果**；
  - `--expect-change` 无变化 → `no_state_change`，`result.state_changed=false`。
- `find`：按 role/name/value 检索，`--use-cache --max-age` 复用新鲜缓存，避免整树 dump。

**证据**：
- 目标应用新增 `SlowReveal` 按钮（点击后 500 ms 才改标签）。`click --wait-for "name:slow-done"`
  实测 `elapsed_ms≈800–1000`、`polls≥2`，证明是轮询等到而不是立即命中。
- 不存在的条件 → `verification_timeout`，`action_sent:true` 且 `result.verification.matched=false`。
- `move --expect-change`（只移动光标）→ `no_state_change`，`action_sent:true`。

---

## E. 契约与文档

- 补齐三个此前未文档化的错误码：`window_has_no_bounds`、`element_offscreen`、`empty_capture_area`；
  新增 `stale_state / state_cache_missing / session_locked / focus_failed / target_blocked /
  clipboard_unavailable / verification_timeout / no_state_change`。
- `SKILL.md`、`references/command-reference.md`、`README.md` 按新契约重写；说明「何时该用
  find/wait、何时该用截图」「stale_state 的唯一恢复动作」「验证超时的语义」。
- 非 Windows 平台使用新鲜度/验证参数会明确 `capability_unavailable`，不再静默忽略。

---

## F. 验证状态（本机实测）

环境：Windows 11 / PowerShell 5.1 / Node 22 / 中文区域设置。

- **端到端冒烟 `scripts/tests/smoke-windows.ps1`：81/81 通过**（`RESULT: passed=81 failed=0`）。
  覆盖语义点击、路径点击、坐标点击、勾选切换、ASCII 输入、非 ASCII 输入 + 剪贴板还原、按键、
  滚动、拖拽、移动/悬停落点、截图（窗口/整屏/元素/annotate/grid，叠加层像素校验）、
  状态缓存与路径寻址、`stale_state`、`find`（live/cache/空结果）、`wait`（命中/`--gone`/超时）、
  `--wait-for`（延迟 1.2 s 的变化，实测 `elapsed=1183 ms, polls=3`）、`--expect-change` 正反例、
  审计日志（含「不记录输入文本」的负向断言）、黑名单、错误码与用法契约。
- **同机性能对照**（14 元素 WinForms 窗口，3 次中位数）：`status` 853→717 ms、
  `list-apps` 831→709 ms、`get-app-state` 1130→1034 ms、`set-value` 1061→878 ms、
  `click --element` 909→821 ms、`type(ASCII)` 1286→1213 ms、`screenshot` 729→599 ms。
- **锁屏防护**：会话锁屏期间 `type`/`move`/坐标点击全部返回 `session_locked`，`status` 中
  `session_locked=true`；解锁后同一调用恢复正常。锁屏下 UIA `Invoke` 单次约 4 s，解锁后
  回到毫秒级（说明该延迟来自系统激活等待，不是定位开销）。
- **窗口枚举**：同机同一时刻，v0.1 列出 10 个窗口（含 1×1 与 -32000 幽灵窗口），v0.2 列出 5 个
  可操作窗口；`list-windows --app pid:` 能同时列出主窗口与对话框。
- **真实应用**：在 OpenCode（Chromium）对话框上验证了元素树读取、`screenshot --element/-path`
  尺寸与元素 bounds 一致、`list-windows` 多窗口。

已知未覆盖：

- macOS / Linux 后端未在本机实测。
- 多显示器混合 DPI 场景未在本机实测（已加 per-monitor DPI 感知与 `CUA_DPI_AWARE=0` 开关）。
- 大型无障碍树（数百元素）的实测时间未采集；按每元素约 1 ms 的模式探测开销推算，快照收益会更大。