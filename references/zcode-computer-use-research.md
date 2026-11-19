# ZCode 电脑控制（Computer Use / CUA）实现研究

> 研究对象：`ZCode-main` 仓库（AI 编程工作台，Electron 桌面 + Web + Agent CLI）。
> 本文件记录電腦控制在 ZCode 中的完整实现链路，作为 DSH 电脑控制插件的设计参考。

## 1. 结论摘要

ZCode 的电脑控制**不是**独立的 MCP server，而是一条「官方插件 + 共享 node_repl 宿主 + broker 桥接 + 原生 Helper」的链路：

```
模型 ──▶ mcp__node_repl__js（唯一工具）
         │  每次调用都是全新 JS kernel（一次性 Worker）
         ▼
      scripts/computer-use-client.mjs（插件资产，模型在每个 cell 首行照抄的 bootstrap）
         │  setupComputerUseRuntime({ globals: globalThis })
         ▼
      node_repl 宿主注入的 ComputerUseRuntimeBridge（全局 Symbol）
         │  bridge.call(method, input) → 本机 socket + token
         ▼
      ComputerUseRuntime.execute()（上游 zcode-cua runtime，本 checkout 为 fail-closed 占位）
         ▼
      原生 Helper（macOS 辅助功能 / screenRecording；Windows dev helper）
```

用户露出名是「Computer Use / 电脑控制」，插件 id `computer-use@zcode-plugins-official`，
**默认关闭**（携带 MCP server 与系统 Helper 依赖，首启即拉起 Helper 不被接受）。

## 2. 关键组件与文件

| 层 | 位置 | 职责 |
| --- | --- | --- |
| 官方插件定义 | `apps/zcode-cli/packages/bootstrap/src/app/official-plugin-definitions.ts` | seed 定义：name/version/listing(rootCandidates)/requiredSeedPaths。CUA 契约：`docs/computer-use.md`、`scripts/computer-use-client.mjs`、`skills/computer-use/SKILL.md` |
| 注册门禁 | `bootstrap/src/app/built-in-node-repl.ts` | 「browser-use 或 computer-use 任一启用」才注册 `node_repl` MCP server；`ZCODE_PLUGIN_ROOT`（browser）与 `ZCODE_CUA_PLUGIN_ROOT`（CUA）各自注入领域 root |
| 宿主 | `apps/zcode-cli/packages/node-repl-host/`（`dist/mcp/server.js`） | 共享 JS 执行面（工具 `js`）+ 两个领域 bridge；每次 `js` 调用在一次性 Worker 中执行，模块缓存随调用销毁 |
| CUA bridge | `node-repl-host/src/cua-bridge.ts` | 把 `ComputerUseRuntimeBridge` 挂到 `Symbol.for("zcode.node-repl.computer-use-bridge")`；subagent scope 与无 broker 时 fail-closed |
| CUA broker | `node-repl-host/src/cua-broker.ts` | 本机命名管道（win32: `\\.\pipe\zcode-node-repl-cua-<uuid>`）或 unix socket，32 字节随机 token，timingSafeEqual 鉴权；`bridge.call` 发 `{id, token, method, input, context}` 行 JSON |
| 运行时接口 | `packages/zcode-cua/index.js`（占位） | `createComputerUseRuntime({brokerSocketPath, refreshMarkerPath, env})` → `execute({toolName, arguments, context, signal})` / `closeSession` / `dispose` |
| 权限服务 | `packages/services/src/cua-permission-broker/` | `ICuaPermissionService`（accessibility / screenRecording 权限态，fail-closed）；Windows dev helper host/runtime |
| UI 可用性 | `packages/ui/src/settings/computerUseAvailability.ts` | 仅本地 macOS / Windows desktop 支持；remote/web/Linux 不支持 |
| 结果投影 | `core/src/tool/executor/result-display.ts` | CUA tool 名归一化（`mcp__computer-use__*` / `mcp__plugin_zcode-cua_computer-use__*`），投影 kind:"cua" 卡片 + 目标 App + 权限状态 |
| 操作事件 | `bootstrap/src/zcode-protocol/computer-use-operation-event.ts` | cell 源码含 `setupComputerUseRuntime` 即标记 `computerUse: true`（架构强制：bootstrap 与动作必须同 cell） |

## 3. 值得借鉴的设计（DSH 插件已吸收）

1. **语义优先的桌面操作**：元素树带 `index`，动作以 index 为目标；坐标只是降级路径。
   ZCode 的方法面：`get_app_state`（state_id + elements[*].index）、`list_apps`、`list_windows`、
   `request_access`、`stop_computer_control`、`screenshot_display`。
2. **每个动作后必须重新取状态**：`state_id` 绑定快照内容，旧 index/坐标不保证有效（ZCode 帧契约
   frame-pixel-latest-only 同此思想）。
3. **stable error codes**（`element_not_found` / `window_ambiguous` / `action_unavailable` / …），
   调用方不依赖错误文本做流程判断。
4. **权限 fail-closed**：不可用就明确报错，不静默降级成"看起来能跑"。
5. **subagent 隔离**：CUA 在 subagent scope 直接拒绝（`CUA_UNAVAILABLE_IN_SUBAGENT_MESSAGE`）。
6. **截图与文本观察分离**：文本树便宜且优先；截图只在视觉必要时（ZCode tool-contract 明确
   "do not console.log/JSON.stringify the complete result"、image 必须紧邻权威标记）。
7. **键盘优先**：ZCode CLI 规约「核心逻辑都可以走键盘操作，鼠标操作是增益能力」。
8. **安全边界**：页面/UI 文本是 UNTRUSTED 数据，只用于定位，不作为指令执行。

## 4. 本 checkout 的实地状态（fail-closed 占位）

- `packages/zcode-cua` 全部导出 fail-closed：`createComputerUseRuntime().execute()` 返回
  "Computer Use is not available in this build."；broker 的 `callBrokerMethod` / `dispatchRequest` /
  `handleRequestLine` 全部抛错；`frame-contract` 谓词恒 false。
- 官方插件目录 `packages/zcode-cua-plugin`（requiredSeedPaths 指向的资产）在本 checkout **不存在**；
  占位定义保留在 `official-plugin-definitions.ts`（version 0.6.3，`runtimeTopLevelPaths: []`）。
- 结论：在当前源码树上开启 computer-use，只会得到"不可用"语义——这正是 DSH 插件自实现后端的存在意义。

## 5. 与 DSH 插件的差异（为什么不能照抄）

| 维度 | ZCode CUA | DSH 插件（dsh-computer-use） |
| --- | --- | --- |
| 传递通道 | 复用 node_repl MCP 宿主 + 全局 Symbol bridge + broker socket | 独立 CLI（JSON 信封），DSH agent 直接调 `node scripts/computer-control.mjs` |
| 桌面能力来源 | 上游原生 Helper（macOS 优先） | 自实现：Windows UIAutomation/P-Invoke、macOS JXA、Linux xdotool |
| 安装方式 | 官方插件市场 seed | 标准 DSH skill 目录（`SKILL.md` + scripts），可 `npx skills` 分发 |
| 模型接入 | skill 文档指导模型在 `js` cell 中 bootstrap | SKILL.md 指导模型直接调 CLI 命令 |

## 6. 复现入口（供后续验证）

- Windows 冒烟：`powershell -File scripts/tests/smoke-windows.ps1`（独立目标应用 + 事件日志，33 项断言）
- 能力探测：`node scripts/computer-control.mjs status`
