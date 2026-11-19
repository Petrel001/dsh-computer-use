// DSH Computer Use - 平台探测与能力矩阵。
// 每个平台后端的可用性是运行时事实，不是配置声明；探测失败一律 fail-closed。
import { commandExists } from "./runner.mjs";

export const PLATFORMS = {
  win32: "win32",
  darwin: "darwin",
  linux: "linux",
};

const BASE_CAPABILITIES = [
  "status",
  "list-apps",
  "list-windows",
  "get-app-state",
  "screenshot",
  "focus",
  "click",
  "type",
  "keypress",
  "scroll",
  "move",
];

// Commands each platform actually implements beyond BASE_CAPABILITIES.
const PLATFORM_EXTRA_CAPABILITIES = {
  win32: ["find", "wait", "drag", "set-value", "stop-worker"],
  darwin: [],
  linux: ["drag"],
};

export async function probePlatform() {
  switch (process.platform) {
    case "win32":
      return {
        platform: "win32",
        backend: "uiautomation+powershell",
        available: true,
        capabilities: [...BASE_CAPABILITIES, ...PLATFORM_EXTRA_CAPABILITIES.win32],
        notes:
          "Windows 全功能后端：UIAutomation 语义操作为主路径，坐标鼠标/键盘注入为降级路径；动作前校验快照新鲜度并断言前台窗口，可用 --wait-for/--expect-change 验证效果。",
      };
    case "darwin": {
      const hasOsascript = await commandExists("osascript");
      const hasScreencapture = await commandExists("screencapture");
      // JXA implements everything in BASE except `move` (no cursor-position
      // API in System Events without cliclick); it must not be advertised.
      const capabilities = [
        ...BASE_CAPABILITIES.filter((c) => c !== "move"),
        ...PLATFORM_EXTRA_CAPABILITIES.darwin,
      ];
      return {
        platform: "darwin",
        backend: "applescript-jxa+screencapture",
        available: hasOsascript && hasScreencapture,
        capabilities: hasScreencapture ? capabilities : capabilities.filter((c) => c !== "screenshot"),
        notes: hasOsascript
          ? "macOS 后端需要「辅助功能」与「屏幕录制」权限；未授权时系统会弹窗或返回空树。"
          : "osascript unavailable",
      };
    }
    case "linux": {
      const display = process.env.DISPLAY || process.env.WAYLAND_DISPLAY;
      const hasXdotool = await commandExists("xdotool");
      const hasWmctrl = await commandExists("wmctrl");
      const hasScreenshotTool =
        (await commandExists("import")) || (await commandExists("scrot")) || (await commandExists("gnome-screenshot"));
      const capabilities = [
        ...BASE_CAPABILITIES.filter(
          (c) => c !== "get-app-state" && (hasScreenshotTool || c !== "screenshot"),
        ),
        ...PLATFORM_EXTRA_CAPABILITIES.linux,
      ];
      const available = Boolean(display) && hasXdotool && hasWmctrl && hasScreenshotTool;
      return {
        platform: "linux",
        backend: "xdotool+wmctrl",
        available,
        capabilities,
        notes: !display
          ? "no DISPLAY/WAYLAND_DISPLAY: 无图形会话"
          : !hasXdotool || !hasWmctrl || !hasScreenshotTool
            ? "缺少 xdotool/wmctrl/截图工具（import 或 scrot 或 gnome-screenshot）"
            : "Linux 后端不支持完整无障碍树（get-app-state 不可用），请用截图辅助定位。",
      };
    }
    default:
      return {
        platform: process.platform,
        backend: "none",
        available: false,
        capabilities: [],
        notes: `unsupported platform: ${process.platform}`,
      };
  }
}

/** 供 mac/linux 后端复用：解析选择器。 */
export function parseSelector(selector) {
  const raw = String(selector ?? "").trim();
  const match = raw.match(/^(pid|hwnd|name|title):(.*)$/s);
  if (match) return { kind: match[1], value: match[2] };
  return { kind: "title", value: raw };
}

/** 统一 JSON 解析后端 stdout（后端只允许打印一个 JSON 信封）。 */
export function parseBackendJson(stdout, command) {
  const trimmed = stdout.trim();
  if (!trimmed) {
    const err = new Error(`backend produced no output for command '${command}'`);
    err.code = "backend_error";
    throw err;
  }
  try {
    return JSON.parse(trimmed);
  } catch {
    const err = new Error(
      `backend output is not valid JSON for command '${command}': ${trimmed.slice(0, 300)}`,
    );
    err.code = "backend_error";
    throw err;
  }
}
